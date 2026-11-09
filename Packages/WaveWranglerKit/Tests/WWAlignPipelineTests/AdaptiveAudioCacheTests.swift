import Foundation
import Synchronization
import Testing
import WWCore
import WWDecode
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Adaptive listening PCM reuse", .serialized)
struct AdaptiveAudioCacheTests {
    static func fixture(hooks: AlignmentPipelineTestHooks = .init()) async throws -> (PipelineFixture, SourceTimingCorrection) {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [
                .init(name: "reference", seconds: 16, signal: .scene(seed: 132), sampleRate: 8000),
            ]),
            .init(name: "Adaptive", sources: [
                .init(name: "target", channels: 2, seconds: 16, signal: .scene(seed: 132), sampleRate: 8000),
            ]),
        ], hooks: hooks, nativeAudio: true)
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

    @Test func warmWindowsDoNotReserializeARecordingSizedAcceptedMap() async throws {
        let calculations = Atomic<Int>(0)
        var hooks = AlignmentPipelineTestHooks()
        hooks.didCalculateMapIdentity = { _ = calculations.wrappingAdd(1, ordering: .relaxed) }
        let (f, initial) = try await Self.fixture(hooks: hooks)
        var correction = initial
        // Dense timing outside the requested tile models long-recording metadata without a large
        // media fixture or making the test measure thousands of cold stretch operations.
        correction.segments = [.init(sourceStart: 0, sourceEnd: 8, alignedStart: 0,
                                     rateRatio: 1.001, kind: .estimated)]
        var aligned = correction.segments[0].alignedEnd
        for index in 0..<4096 {
            let segment = SourceTimingSegment(sourceStart: 8 + Double(index) / 512,
                sourceEnd: 8 + Double(index + 1) / 512, alignedStart: aligned,
                rateRatio: index.isMultiple(of: 2) ? 0.999 : 1.001, kind: .estimated)
            correction.segments.append(segment)
            aligned = segment.alignedEnd
        }
        try #require(correction.isValid)
        f.model.episodes[0].alignment?.maps[0].sourceCorrections = [correction]
        try await f.pipeline.activate(model: f.model, episode: f.episodeID)
        let version = try #require(f.model.episodes[0].alignment?.acceptedMap)
        let serializedBytes = try JSONEncoder().encode(version).count
        let url = f.url("target")
        let format = try await f.decoder.withDecodingCursor(url, source: correction.source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: format.sourceFingerprint)
        let prepared = calculations.load(ordering: .relaxed)
        let first = try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000)
        let start = ContinuousClock.now
        for _ in 0..<12 {
            #expect(try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
                source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000) == first)
        }
        let elapsed = start.duration(to: .now)
        #expect(calculations.load(ordering: .relaxed) == prepared,
                "Cold and resident tiles must use the exact identity from live map admission, not reserialize it")
        print("ADAPTIVE_MAP_SCALING segments=\(correction.segments.count) mapBytes=\(serializedBytes) warmWindows=12 elapsed=\(elapsed) identityCalculations=0")
        let admitted = try await f.pipeline.admittedMap(model: f.model, episode: f.episodeID)
        await f.coordinator.invalidate(admitted.identity.slot)
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
                source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000)
        }
        await f.pipeline.shutdown()
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
