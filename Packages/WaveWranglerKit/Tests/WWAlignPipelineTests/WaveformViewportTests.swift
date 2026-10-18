import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Measured alignment viewport and listening comparison")
struct WaveformViewportTests {
    @Test func overviewBoundsWorkAndKeepsEpochBoundaries() throws {
        let source = SourceID()
        #expect(try WaveformViewport.overviewRanges(
            source: source, rate: 1_000, totalFrames: 86_400_000, groupMap: nil
        ) == [0..<86_400_000])
        for frames in [Int64(-1), 86_400_001, Int64.max] {
            #expect(throws: WaveformWindowError.overviewBudgetExceeded) {
                try WaveformViewport.overviewRanges(source: source, rate: 1_000, totalFrames: frames, groupMap: nil)
            }
        }
        #expect(throws: WaveformWindowError.overviewBudgetExceeded) {
            try WaveformViewport.overviewRanges(source: source, rate: 0, totalFrames: 1, groupMap: nil)
        }
        let first = RecordingEpochID()
        let second = RecordingEpochID()
        let map = try WaveformTestAudio.map(source: source, rate: 1_000, frames: 10_000, offset: .zero, spans: [
            EpochSpan(startFrame: 0, endFrame: 5_000, epoch: first, groupClockOffset: .zero),
            EpochSpan(startFrame: 5_000, endFrame: 10_000, epoch: second, groupClockOffset: .zero),
        ])
        #expect(try WaveformViewport.overviewRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: map
        ) == [0..<5_000, 5_000..<10_000])
        #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            try WaveformViewport.overviewRanges(source: source, rate: 1_000, totalFrames: 9_000, groupMap: map)
        }
    }

    @Test func inverseViewportUsesOffsetAndClockRateRatherThanSourceOrigin() throws {
        let source = SourceID()
        let map = try WaveformTestAudio.map(source: source, rate: 1_000, frames: 10_000, offset: ExactRational(-1), ratio: ExactRational(2))
        let ranges = try WaveformViewport.frameRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: map,
            startSeconds: 3, durationSeconds: 2
        )
        #expect(ranges == [2_000..<3_000])
        let early = try WaveformTestAudio.map(
            source: source, rate: 1_000, frames: 10_000, offset: ExactRational(-2)
        )
        #expect(try WaveformViewport.frameRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: early,
            startSeconds: -1, durationSeconds: 1
        ) == [1_000..<2_000])
        #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            try WaveformViewport.frameRanges(
                source: source, rate: 2_000, totalFrames: 10_000, groupMap: map,
                startSeconds: 3, durationSeconds: 2
            )
        }
    }

    @Test func clipsAtSourceCoverageAndNeverReadsAcrossRestartGaps() throws {
        let source = SourceID()
        let first = RecordingEpochID()
        let restarted = RecordingEpochID()
        let map = try WaveformTestAudio.map(
            source: source, rate: 1_000, frames: 10_000, offset: .zero,
            spans: [
                EpochSpan(startFrame: 0, endFrame: 2_000, epoch: first, groupClockOffset: .zero),
                EpochSpan(startFrame: 8_000, endFrame: 10_000, epoch: restarted, groupClockOffset: ExactRational(-8))
            ]
        )
        #expect(try WaveformViewport.frameRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: map,
            startSeconds: 1, durationSeconds: 8
        ) == [1_000..<2_000, 8_000..<9_000])
        #expect(try WaveformViewport.frameRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: map,
            startSeconds: 4, durationSeconds: 1
        ).isEmpty)
    }

    @Test func invalidViewportDoesNotTrapOrInventAWindow() throws {
        for start in [-86_401.0, .nan, .infinity, 86_401] {
            #expect(throws: WaveformWindowError.invalidWindow) {
                try WaveformViewport.frameRanges(
                    source: SourceID(), rate: 48_000, totalFrames: 1_000, groupMap: nil,
                    startSeconds: start, durationSeconds: 1
                )
            }

        }
        #expect(try WaveformViewport.frameRanges(
            source: SourceID(), rate: 48_000, totalFrames: 48_000, groupMap: nil,
            startSeconds: 0.5, durationSeconds: 1
        ) == [24_000..<48_000])
    }

    @Test func negativeAlignedWindowReadsWitnessedAudioWithoutChangingSourceTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 16_000
        let source = SourceID()
        let url = folder.appendingPathComponent("generated-early.wav")
        var samples = Array(repeating: Int16(0), count: rate * 2)
        for frame in (rate / 2)..<(rate / 2 + rate / 20) { samples[frame] = 16_384 }
        try WaveformTestAudio.wave(rate: rate, samples: samples).write(to: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let map = try WaveformTestAudio.map(
            source: source, rate: rate, frames: Int64(samples.count), offset: ExactRational(-1)
        )
        let envelope = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: -0.75, durationSeconds: 0.5, groupMap: map
        )
        #expect(envelope.bins.first?.firstFrame == 4_000)
        #expect(envelope.bins.last?.endFrame == 12_000)
        let clip = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            groupMap: map, decodedChannel: 0, startSeconds: -0.75, durationSeconds: 0.5
        )
        #expect(clip.count == 24_000)
        #expect(clip.contains { $0 > 0.1 })
    }

    @Test func boundsDecodedPrefixIncludingClockOffsetsAndRestartSeeking() throws {
        let source = SourceID()
        let rate = 1_000
        let end = Int64(rate) * WaveformWindowReader.maximumDecodedPrefixSeconds
        try WaveformViewport.verifyDecodeBudget(ranges: [end - 1..<end], rate: rate)
        #expect(throws: WaveformWindowError.decodeBudgetExceeded) {
            try WaveformViewport.verifyDecodeBudget(ranges: [end..<end + 1], rate: rate)
        }
        let map = try WaveformTestAudio.map(
            source: source, rate: rate, frames: end + 10_000, offset: ExactRational(-600)
        )
        let ranges = try WaveformViewport.frameRanges(
            source: source, rate: rate, totalFrames: end + 10_000, groupMap: map,
            startSeconds: 0, durationSeconds: 1
        )
        #expect(ranges == [end..<end + 1_000])
        #expect(throws: WaveformWindowError.decodeBudgetExceeded) {
            try WaveformViewport.verifyDecodeBudget(ranges: ranges, rate: rate)
        }
        try WaveformViewport.verifyDecodeBudget(ranges: ranges, rate: rate, randomAccess: true)
        #expect(throws: WaveformWindowError.decodeBudgetExceeded) {
            try WaveformViewport.verifyDecodeBudget(ranges: ranges, rate: 0, randomAccess: true)
        }
    }

    @Test func twoHourPCMWindowAndAlignedListeningReadTheLateEvent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 16_000
        let frame: Int64 = Int64(rate) * 7_200
        let url = folder.appendingPathComponent("generated-long.wav")
        try WaveformTestAudio.sparseWave(
            at: url, rate: rate, frames: frame + Int64(rate),
            landmarks: [frame: 16_384, frame + 1: -16_384]
        )
        let decoder = SourceDecoder(access: SourceAccessContext())
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let source = SourceID()
        let map = try WaveformTestAudio.map(
            source: source, rate: rate, frames: frame + Int64(rate),
            offset: ExactRational(-7_200)
        )
        let envelope = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: 0, durationSeconds: 0.5, groupMap: map
        )
        #expect(envelope.bins.first?.firstFrame == frame)
        #expect(envelope.bins.last?.endFrame == frame + 8_000)
        #expect(envelope.bins.first?.minimum == -0.5 && envelope.bins.first?.maximum == 0.5)
        let clip = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder, groupMap: map,
            decodedChannel: 0, startSeconds: 0, durationSeconds: 0.25
        )
        #expect(clip.count == 12_000)
        #expect(clip.contains { abs($0) > 0.1 })
        #expect(clip.suffix(1_000).allSatisfy { abs($0) < 0.001 })
        let direct = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: 7_200, durationSeconds: 0.5
        )
        #expect(direct.bins == envelope.bins)
    }

    @Test func actualMixedRateAudioRendersCoincidentEventsWithCorrectSign() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func clip(rate: Int, delay: Int, name: String) async throws -> [Float] {
            let source = SourceID()
            let url = folder.appendingPathComponent(name)
            var samples = Array(repeating: Int16(0), count: rate * 2)
            for frame in (rate / 2 + delay)..<(rate / 2 + delay + rate / 20) { samples[frame] = 16_384 }
            try WaveformTestAudio.wave(rate: rate, samples: samples).write(to: url)
            let access = SourceAccessContext()
            guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
            let decoder = SourceDecoder(access: access)
            let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
            let map = try WaveformTestAudio.map(
                source: source, rate: rate, frames: Int64(samples.count),
                offset: ExactRational(numerator: -Int128(delay), denominator: Int128(rate))
            )
            return try await AlignedAuditionWindowReader.readWindow(
                sourceURL: url, source: source, matching: witness, decoder: decoder, groupMap: map,
                decodedChannel: 0, startSeconds: 0, durationSeconds: 1
            )
        }
        let reference = try await clip(rate: 48_000, delay: 0, name: "reference.wav")
        let target = try await clip(rate: 32_000, delay: 5_760, name: "target.wav")
        #expect(reference.count == 48_000)
        #expect(target.count == reference.count)
        let expected = 24_000..<26_400
        #expect(reference[expected].allSatisfy { abs($0 - 0.5) < 0.01 })
        #expect(target[(expected.lowerBound + 100)..<(expected.upperBound - 100)].allSatisfy { abs($0 - 0.5) < 0.01 })
        #expect(reference.firstIndex(where: { $0 > 0.25 }) == 24_000)
        #expect(abs((target.firstIndex(where: { $0 > 0.25 }) ?? -1) - 24_000) <= 1)
        #expect(target[30_000..<40_000].allSatisfy { abs($0) < 0.001 })
    }

    @Test func frameDomainListeningPreservesFractionalStartsAndAdjacentSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 16_000, source = SourceID()
        let url = folder.appendingPathComponent("generated-frame-grid.wav")
        let samples = (0..<(rate * 2)).map { Int16(($0 % 1_000 - 500) * 30) }
        try WaveformTestAudio.wave(rate: rate, samples: samples).write(to: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let map = try WaveformTestAudio.map(source: source, rate: rate, frames: Int64(samples.count), offset: .zero)
        func render(_ frames: Range<Int64>) async throws -> [Float] {
            try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source, matching: witness,
                decoder: decoder, groupMap: map, decodedChannel: 0, outputFrames: frames)
        }
        let whole = try await render(1..<48_239)
        let first = try await render(1..<17_777)
        let second = try await render(17_777..<48_239)
        #expect(whole.count == 48_238)
        #expect(first + second == whole, "No frame is repeated or lost by a seconds round trip")
        for frames: Range<Int64> in [0..<0, 0..<240_001, Int64.min..<Int64.max] {
            await #expect(throws: WaveformWindowError.invalidWindow) { try await render(frames) }
        }
    }
}
