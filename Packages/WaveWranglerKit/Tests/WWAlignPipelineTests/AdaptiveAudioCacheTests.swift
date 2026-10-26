import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Adaptive listening PCM reuse", .serialized)
struct AdaptiveAudioCacheTests {
    static func fixture() async throws -> (PipelineFixture, SourceTimingCorrection) {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [
                .init(name: "reference", seconds: 16, signal: .scene(seed: 132), sampleRate: 8000),
            ]),
            .init(name: "Adaptive", sources: [
                .init(name: "target", channels: 2, seconds: 16, signal: .scene(seed: 132), sampleRate: 8000),
            ]),
        ], nativeAudio: true)
        let preparation = try await fixture.pipeline.prepareManual(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        _ = try await fixture.acceptAndActivate(preparation, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0),
        ])
        var aligned = 0.0
        let segments = (0..<64).map { index in
            let ratio = index.isMultiple(of: 2) ? 0.999 : 1.001
            let segment = SourceTimingSegment(sourceStart: Double(index) / 4, sourceEnd: Double(index + 1) / 4,
                alignedStart: aligned, rateRatio: ratio, kind: .estimated)
            aligned = segment.alignedEnd
            return segment
        }
        let correction = SourceTimingCorrection(
            source: fixture.id("target"), group: fixture.groups[1], epoch: fixture.epochs[1],
            reference: fixture.id("reference"), sourceRate: 8000, sourceFrames: 128_000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: segments)
        try #require(correction.isValid)
        fixture.model.episodes[0].alignment?.maps[0].sourceCorrections = [correction]
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        return (fixture, correction)
    }

    @Test func repeatedPlaybackWindowsRetainExactAudioAcrossDenseTimingTransitions() async throws {
        let (fixture, correction) = try await Self.fixture()
        let url = fixture.url("target")
        let fingerprint = try await fixture.decoder.withDecodingCursor(url, source: correction.source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(url, matching: fingerprint)
        let originals = try Data(contentsOf: url)
        let clock = ContinuousClock()
        var elapsed: [Double] = []
        var first: [[Float]]?
        for index in 0..<24 {
            let begin = clock.now
            let audio = try await fixture.pipeline.adaptiveAudioWindow(model: fixture.model, episode: fixture.episodeID,
                source: correction.source, sourceURL: url, matching: witness,
                outputFrames: Int64(index * 24_000)..<Int64((index + 1) * 24_000))
            let duration = begin.duration(to: clock.now).components
            elapsed.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            #expect(audio.count == 2 && audio.allSatisfy { $0.count == 24_000 })
            #expect(audio[0].contains { abs($0) > 0.0001 })
            if index == 0 { first = audio }
        }
        let replay = try await fixture.pipeline.adaptiveAudioWindow(model: fixture.model, episode: fixture.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<24_000)
        #expect(replay == first)
        #expect(try Data(contentsOf: url) == originals)
        let statistics = await fixture.pipeline.adaptivePCMCache.statistics
        #expect(statistics.hits == 22 && statistics.misses == 3)
        #expect(statistics.entries == 3 && statistics.sampleBytes == 3 * 2 * 240_000 * 4)
        print("ADAPTIVE_PCM_WINDOWS seconds=\(elapsed) total=\(elapsed.reduce(0, +)) hits=\(statistics.hits) misses=\(statistics.misses)")

        let key = try #require(await fixture.coordinator.state(of:
            DerivedSlot("adaptive-audio/\(fixture.episodeID)/\(correction.source)/48000/0")).key)
        let bounded = AdaptiveAudioPCMCache(maximumSampleBytes: 32, maximumEntries: 2)
        let keys = (0..<4).map { index in
            var changed = key
            changed.recipe = RecipeReference(name: "cache-bound-\(index)", revision: 1)
            return AdaptiveAudioPCMCache.Key(asset: changed, witness: witness)
        }
        let smallTile = AdaptivePCM(firstFrame: 0, channels: [[1, 2, 3, 4]])
        for cacheKey in keys.prefix(3) {
            await bounded.insert(smallTile, for: cacheKey)
            #expect(await bounded.statistics.sampleBytes <= 32)
            #expect(await bounded.statistics.entries <= 2)
        }
        #expect(await bounded.tile(for: keys[0]) == nil)
        #expect(await bounded.tile(for: keys[1]) != nil)
        await bounded.insert(smallTile, for: keys[3])
        #expect(await bounded.tile(for: keys[2]) == nil)
        #expect(await bounded.tile(for: keys[1]) != nil)
        await bounded.removeAll()
        let cleared = await bounded.statistics
        #expect(cleared.sampleBytes == 0 && cleared.entries == 0)

        var moved = fixture.model
        var shifted = correction
        shifted.segments = correction.segments.map {
            var segment = $0
            segment.alignedStart += 0.125
            return segment
        }
        moved.episodes[0].alignment?.maps[0].sourceCorrections = [shifted]
        try await fixture.pipeline.activate(model: moved, episode: fixture.episodeID)
        let changed = try await fixture.pipeline.adaptiveAudioWindow(model: moved, episode: fixture.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<24_000)
        #expect(changed != first)
        #expect(await fixture.pipeline.adaptivePCMCache.statistics.misses == 4,
                "An altered correction cannot reuse PCM from the same revision number")
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.adaptiveAudioWindow(model: fixture.model, episode: fixture.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<24_000) == first)

        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.pipeline.adaptiveAudioWindow(model: fixture.model, episode: fixture.episodeID,
                source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<24_000)
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await fixture.pipeline.adaptiveAudioWindow(model: fixture.model, episode: fixture.episodeID,
                source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<24_000)
        }
        await ConcurrencyTests.expectQuiescent(fixture)
        await fixture.pipeline.shutdown()
        let stopped = await fixture.pipeline.adaptivePCMCache.statistics
        #expect(stopped.entries == 0 && stopped.sampleBytes == 0)
    }
}
