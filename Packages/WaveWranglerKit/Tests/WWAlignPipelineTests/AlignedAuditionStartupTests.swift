import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Bounded aligned listening startup", .serialized)
struct AlignedAuditionStartupTests {
    private struct Fixture {
        let folder: URL
        let url: URL
        let source = SourceID()
        let decoder = SourceDecoder(access: SourceAccessContext())
        let map: GroupTimeMap
        let witness: RawSourceIdentity
        let revision = MapRevisionReference(episode: EpisodeID(), revision: 1)

        init(ratio: ExactRational = .one, channels: Int = 1) async throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("generated-listening.wav")
            let samples = (0..<(48_000 * 8 * channels)).map { Int16(($0 % 1_000) * 20 - 10_000) }
            try WaveformTestAudio.wave(rate: 48_000, samples: samples, channels: channels).write(to: url)
            map = try WaveformTestAudio.map(
                source: source, rate: 48_000, frames: 48_000 * 8, offset: .zero, ratio: ratio
            )
            let context = SourceAccessContext()
            guard case let .success(metadata) = context.io.metadata(at: url) else { throw DecodeFailure.notFound }
            witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        }

        func read(_ frames: Range<Int64>, cache: AlignedAuditionPCMCache? = nil,
                  channel: Int = 0, revision: MapRevisionReference? = nil,
                  map: GroupTimeMap? = nil) async throws -> [Float] {
            try await AlignedAuditionWindowReader.readWindow(
                sourceURL: url, source: source, matching: witness, decoder: decoder,
                groupMap: map ?? self.map, decodedChannel: channel, outputFrames: frames,
                cache: cache, revision: revision ?? self.revision
            )
        }
    }

    @Test func exactSharedFramesAreContiguousForShortSelectionsNegativeStartsAndCycles() throws {
        for range in [-0.001...0.001, 0.0...0.1, 0.25...3.73, 2.0...8.0] {
            var firstCycle: [Range<Int64>] = []
            for cycle in 0..<3 {
                var schedule = try AlignedAuditionSchedule(startSeconds: range.lowerBound, endSeconds: range.upperBound)
                var windows: [Range<Int64>] = []
                while let frames = schedule.next() {
                    #expect(!frames.isEmpty)
                    #expect(frames.count <= (windows.isEmpty
                        ? Int(AlignedAuditionSchedule.initialFrames) : Int(AlignedAuditionSchedule.followingFrames)))
                    if let prior = windows.last { #expect(prior.upperBound == frames.lowerBound) }
                    windows.append(frames)
                }
                #expect(windows.first?.lowerBound == schedule.firstFrame)
                #expect(windows.last?.upperBound == schedule.endFrame)
                if cycle == 0 { firstCycle = windows } else { #expect(windows == firstCycle) }
            }
        }
        for range in [(Double.nan, 1.0), (0, .infinity), (2, 1), (-86_401, 1)] {
            #expect(throws: WaveformWindowError.invalidWindow) {
                try AlignedAuditionSchedule(startSeconds: range.0, endSeconds: range.1)
            }
        }
    }

    @Test func mixerFormatInspectionUsesTheListeningWitnessAndRefusesAReplacedFile() async throws {
        let fixture = try await Fixture(channels: 2)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let format = try await AlignedAuditionWindowReader.inspectFormat(
            sourceURL: fixture.url, source: fixture.source, matching: fixture.witness, decoder: fixture.decoder)
        #expect(format.source == fixture.source && format.channelCount == 2 && format.sourceSampleRate == 48_000)
        #expect(format.frames.validFrames == 8 * 48_000)
        try FileManager.default.moveItem(at: fixture.url, to: fixture.folder.appendingPathComponent("prior.wav"))
        try WaveformTestAudio.wave(rate: 48_000, samples: Array(repeating: 1, count: 8 * 48_000))
            .write(to: fixture.url)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await AlignedAuditionWindowReader.inspectFormat(
                sourceURL: fixture.url, source: fixture.source, matching: fixture.witness, decoder: fixture.decoder)
        }
    }

    @Test func adaptiveSchedulePrimesOneTileAndKeepsTwoTilesOfPreparationAhead() throws {
        for interval in [-0.25...0.1, 0.0...16.0, 4.75...20.0] {
            var schedule = try AlignedAuditionSchedule(
                startSeconds: interval.lowerBound, endSeconds: interval.upperBound, usesAdaptiveTiming: true)
            #expect(schedule.maximumBufferedSeconds == 10)
            let initial = schedule.next()
            let first = try #require(initial)
            #expect(first.lowerBound == schedule.firstFrame)
            #expect(first.count == min(240_000, Int(schedule.endFrame - schedule.firstFrame)))
            var end = first.upperBound
            while let frames = schedule.next() {
                #expect(frames.lowerBound == end && frames.count <= 24_000)
                end = frames.upperBound
            }
            #expect(end == schedule.endFrame)
        }
        var ordinary = try AlignedAuditionSchedule(startSeconds: 0, endSeconds: 16)
        let ordinaryFirst = ordinary.next()
        #expect(ordinaryFirst?.count == 48_000)
        #expect(ordinary.maximumBufferedSeconds == 3)
    }

    @Test func replayAndWarmSubwindowsAreExactAndStillCheckTheOriginalFile() async throws {
        let fixture = try await Fixture(ratio: ExactRational(10_001, 10_000))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let cache = AlignedAuditionPCMCache()
        let frames: Range<Int64> = 0..<96_000
        let original = try await fixture.read(frames, cache: cache)
        for _ in 0..<3 { #expect(try await fixture.read(frames, cache: cache) == original) }
        let subwindow = try await fixture.read(24_000..<48_000, cache: cache)
        #expect(subwindow == Array(original[24_000..<48_000]))
        #expect(try await fixture.read(24_000..<48_000) == subwindow)
        let stats = await cache.statistics
        #expect(stats.hits == 4)
        #expect(stats.misses == 1)
        #expect(stats.entries == 1)
        #expect(stats.sampleBytes == original.count * 4)

        let old = fixture.folder.appendingPathComponent("original.wav")
        try FileManager.default.moveItem(at: fixture.url, to: old)
        try WaveformTestAudio.wave(rate: 48_000, samples: Array(repeating: 1, count: 48_000 * 8)).write(to: fixture.url)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            _ = try await fixture.read(frames, cache: cache)
        }
        #expect(await cache.statistics.hits == 4)
    }

    @Test func cacheSeparatesChannelExactMapAndAcceptedRevision() async throws {
        let fixture = try await Fixture(channels: 2)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let cache = AlignedAuditionPCMCache()
        let frames: Range<Int64> = 0..<240
        _ = try await fixture.read(frames, cache: cache)
        _ = try await fixture.read(frames, cache: cache, channel: 1)
        _ = try await fixture.read(frames, cache: cache,
            revision: MapRevisionReference(episode: fixture.revision.episode, revision: 2))
        let shifted = try WaveformTestAudio.map(
            source: fixture.source, rate: 48_000, frames: 48_000 * 8, offset: ExactRational(1)
        )
        let silence = try await fixture.read(frames, cache: cache, map: shifted)
        #expect(silence.allSatisfy { $0 == 0 })
        #expect(await cache.statistics.misses == 4)
        #expect(await cache.statistics.hits == 0)
        await #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            let bad = try WaveformTestAudio.map(
                source: fixture.source, rate: 44_100, frames: 48_000 * 8, offset: .zero
            )
            _ = try await fixture.read(frames, cache: cache, map: bad)
        }
        await #expect(throws: SampleStreamFailure.invalidChannel(2)) {
            _ = try await fixture.read(frames, cache: cache, channel: 2)
        }
    }

    @Test func adjacentAndOverlappingCachedWindowsServeIndexedSeeksWithoutAnotherDecode() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let cache = AlignedAuditionPCMCache()
        _ = try await fixture.read(0..<48_000, cache: cache)
        _ = try await fixture.read(48_000..<72_000, cache: cache)
        _ = try await fixture.read(72_000..<96_000, cache: cache)
        let expected = try await fixture.read(24_000..<84_000)
        #expect(try await fixture.read(24_000..<84_000, cache: cache) == expected)
        #expect(await cache.statistics.hits == 1)
        #expect(await cache.statistics.misses == 3)
        let stitchedStats = await cache.statistics
        #expect(stitchedStats.entries == 3 && stitchedStats.sampleBytes == 96_000 * 4)
        let otherRevision = MapRevisionReference(episode: fixture.revision.episode, revision: 2)
        _ = try await fixture.read(24_000..<84_000, cache: cache, revision: otherRevision)
        #expect(await cache.statistics.misses == 4, "Stitching cannot cross accepted map revisions")
        let gapped = AlignedAuditionPCMCache()
        _ = try await fixture.read(0..<24_000, cache: gapped)
        _ = try await fixture.read(48_000..<72_000, cache: gapped)
        _ = try await fixture.read(0..<72_000, cache: gapped)
        let gapStats = await gapped.statistics
        #expect(gapStats.hits == 0 && gapStats.misses == 3,
                "A gap requires a witnessed decode, never invented or bridged samples")
        let changed = fixture.folder.appendingPathComponent("original.wav")
        try FileManager.default.moveItem(at: fixture.url, to: changed)
        try WaveformTestAudio.wave(rate: 48_000, samples: Array(repeating: 1, count: 48_000 * 8)).write(to: fixture.url)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            _ = try await fixture.read(24_000..<84_000, cache: cache)
        }
        #expect(await cache.statistics.hits == 1, "A stitched cache hit remains subject to source authorization")
    }

    @Test func cacheEvictsWithinBothBoundsAndCanceledHitsDoNotEscape() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let cache = AlignedAuditionPCMCache(maximumSampleBytes: 400, maximumEntries: 2)
        for frame in stride(from: Int64(0), to: 400, by: 100) {
            _ = try await fixture.read(frame..<(frame + 100), cache: cache)
            #expect(await cache.statistics.sampleBytes <= 400)
            #expect(await cache.statistics.entries <= 2)
        }
        #expect(await cache.statistics.entries == 1)
        let entryBound = AlignedAuditionPCMCache(maximumSampleBytes: 16_000, maximumEntries: 2)
        for frame in stride(from: Int64(0), to: 300, by: 100) {
            _ = try await fixture.read(frame..<(frame + 100), cache: entryBound)
        }
        #expect(await entryBound.statistics.entries == 2)
        #expect(await entryBound.statistics.sampleBytes == 800)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.read(300..<400, cache: cache)
        }
        await #expect(throws: (any Error).self) { _ = try await canceled.value }
        #expect(await cache.statistics.hits == 0)
        _ = try await fixture.read(0..<100, cache: cache)
        #expect(await cache.statistics.misses == 5)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LISTENING_BENCHMARK"] == "1"))
    func syntheticTwoTrackStartupFillAndReplay() async throws {
        let identity = try await Fixture()
        let drift = try await Fixture(ratio: ExactRational(10_001, 10_000))
        let otherDrift = try await Fixture(ratio: ExactRational(10_001, 10_000))
        defer {
            try? FileManager.default.removeItem(at: identity.folder)
            try? FileManager.default.removeItem(at: drift.folder)
            try? FileManager.default.removeItem(at: otherDrift.folder)
        }
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        for (name, fixtures) in [("identity+drift", [identity, drift]), ("two-drift", [drift, otherDrift])] {
            let cache = AlignedAuditionPCMCache()
            let legacyStart = clock.now
            for fixture in fixtures { _ = try await fixture.read(0..<240_000) }
            let legacy = seconds(legacyStart.duration(to: clock.now))
            var startup: [Double] = []
            var fill: [Double] = []
            for _ in 0..<3 {
                var schedule = try AlignedAuditionSchedule(startSeconds: 0, endSeconds: 4)
                var queuedAt: ContinuousClock.Instant?
                while let frames = schedule.next() {
                    let begin = clock.now
                    for fixture in fixtures { _ = try await fixture.read(frames, cache: cache) }
                    let elapsed = seconds(begin.duration(to: clock.now))
                    if frames.lowerBound == 0 {
                        startup.append(elapsed)
                        queuedAt = clock.now
                    } else {
                        fill.append(elapsed)
                        let queued = try #require(queuedAt)
                        let elapsedSinceEnqueue = seconds(queued.duration(to: clock.now))
                        let deadline = Double(frames.lowerBound) / 48_000 + 0.1 - 0.02
                        #expect(elapsedSinceEnqueue < deadline, "Synthetic producer missed the previous buffer's deadline")
                    }
                    #expect(elapsed < 1.5, "Synthetic two-track window took \(elapsed)s")
                }
            }
            #expect(startup[0] < legacy)
            #expect(startup.dropFirst().allSatisfy { $0 < startup[0] })
            let stats = await cache.statistics
            #expect(stats.hits == 28)
            print("LISTENING_TWO_TRACK \(name) legacy5s=\(legacy) startup=\(startup) fill=\(fill) hits=\(stats.hits) misses=\(stats.misses) bytes=\(stats.sampleBytes)")
        }
    }
}
