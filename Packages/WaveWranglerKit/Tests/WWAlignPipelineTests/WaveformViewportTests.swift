import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Measured alignment viewport and listening comparison")
struct WaveformViewportTests {
    @Test func inverseViewportUsesOffsetAndClockRateRatherThanSourceOrigin() throws {
        let source = SourceID()
        let map = try WaveformTestAudio.map(source: source, rate: 1_000, frames: 10_000, offset: ExactRational(-1), ratio: ExactRational(2))
        let ranges = try WaveformViewport.frameRanges(
            source: source, rate: 1_000, totalFrames: 10_000, groupMap: map,
            startSeconds: 3, durationSeconds: 2
        )
        #expect(ranges == [2_000..<3_000])
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
        for start in [-1.0, .nan, .infinity, 86_401] {
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
}
