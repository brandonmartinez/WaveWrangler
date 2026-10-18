import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWAlignPipeline

@Suite("Source-only adaptive waveform reads")
struct AdaptiveViewportTests {
    @Test func sharedRenderReservationIncludesEveryChannelAndRejectsOverflow() throws {
        #expect(try AlignmentPipeline.adaptiveAudioReservationBytes(channels: 2, sourceRate: 48000)
                == 2 * (48000 * 15 + 48000 * 6) * 4 * 8 + (32 << 20))
        for channels in [0, -1, Int.max] {
            #expect(throws: WaveformWindowError.invalidWindow) {
                try AlignmentPipeline.adaptiveAudioReservationBytes(channels: channels, sourceRate: 48000)
            }
        }
        for rate in [0, 7999, 192001, Int.max] {
            #expect(throws: WaveformWindowError.invalidWindow) {
                try AlignmentPipeline.adaptiveAudioReservationBytes(channels: 1, sourceRate: rate)
            }
            #expect(throws: WaveformWindowError.invalidWindow) {
                try AlignmentPipeline.adaptiveAudioReservationBytes(channels: 1, sourceRate: 48000, outputRate: rate)
            }
        }
    }

    @Test func inverseReadsKeepUnsupportedSpansAndEndsAbsent() throws {
        let source = SourceID(), group = RecorderGroupID(), epoch = RecordingEpochID()
        let correction = SourceTimingCorrection(source: source, group: group, epoch: epoch, reference: SourceID(),
            sourceRate: 8000, sourceFrames: 160000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: [
                SourceTimingSegment(sourceStart: 2, sourceEnd: 5, alignedStart: -1, rateRatio: 1),
                SourceTimingSegment(sourceStart: 8, sourceEnd: 12, alignedStart: 5, rateRatio: 1),
            ])
        #expect(try WaveformViewport.frameRanges(source: source, rate: 8000, totalFrames: 160000, groupMap: nil,
            startSeconds: 0, durationSeconds: 1, sourceCorrection: correction) == [24000..<32000])
        #expect(try WaveformViewport.frameRanges(source: source, rate: 8000, totalFrames: 160000, groupMap: nil,
            startSeconds: 2, durationSeconds: 3, sourceCorrection: correction).isEmpty)
        #expect(try WaveformViewport.frameRanges(source: source, rate: 8000, totalFrames: 160000, groupMap: nil,
            startSeconds: -1, durationSeconds: 10, sourceCorrection: correction) == [16000..<40000, 64000..<96000])
        #expect(try WaveformWindowReader.overviewCoverage(source: source, groupMap: nil,
            sourceCorrection: correction) == [16000..<40000, 64000..<96000])
        #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            try WaveformViewport.frameRanges(source: source, rate: 11025, totalFrames: 160000, groupMap: nil,
                startSeconds: 0, durationSeconds: 1, sourceCorrection: correction)
        }
        for rate in [8000, 11025, 44100, 48000, 192000] {
            var fractional = correction
            fractional.sourceRate = rate
            fractional.sourceFrames = Int64(rate * 7 + 13)
            fractional.segments = [SourceTimingSegment(sourceStart: 0,
                sourceEnd: Double(fractional.sourceFrames) / Double(rate), alignedStart: 0, rateRatio: 1.0003)]
            #expect(try WaveformWindowReader.overviewCoverage(source: source, groupMap: nil,
                sourceCorrection: fractional) == [0..<fractional.sourceFrames])
            #expect(try WaveformViewport.frameRanges(source: source, rate: rate, totalFrames: fractional.sourceFrames,
                groupMap: nil, startSeconds: 0, durationSeconds: 8, sourceCorrection: fractional) == [0..<fractional.sourceFrames])
        }
    }

    @Test func nativeWindowAndOverviewDecodeOnlySupportedRanges() async throws {
        guard ProcessInfo.processInfo.environment["WW_ESTIMATOR_TESTS"] == "1" else { return }
        let (fixture, _) = try await AdaptiveAnalysisTests.fixture(nativeAudio: true)
        let source = fixture.id("backup")
        let fingerprint = try await fixture.decoder.withDecodingCursor(fixture.url("backup"), source: source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(fixture.url("backup"), matching: fingerprint)
        var correction = SourceTimingCorrection(source: source, group: RecorderGroupID(), epoch: RecordingEpochID(),
            reference: fixture.id("ref"), sourceRate: 8000, sourceFrames: 768000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: [
                SourceTimingSegment(sourceStart: 2, sourceEnd: 5, alignedStart: -1, rateRatio: 1),
                SourceTimingSegment(sourceStart: 8, sourceEnd: 12, alignedStart: 5, rateRatio: 1),
            ])
        let overview = try await WaveformWindowReader.readOverview(sourceURL: fixture.url("backup"), source: source,
            matching: witness, decoder: fixture.pipeline.decoder, sourceCorrection: correction)
        #expect(!overview.bins.isEmpty)
        let covered = overview.bins.allSatisfy {
            ($0.firstFrame >= 16000 && $0.endFrame <= 40000) || ($0.firstFrame >= 64000 && $0.endFrame <= 96000)
        }
        #expect(covered)
        try WaveformWindowReader.verifyOverviewCoverage(envelope: overview, groupMap: nil, sourceCorrection: correction)
        let gap = try await WaveformWindowReader.readWindow(sourceURL: fixture.url("backup"), source: source,
            matching: witness, decoder: fixture.pipeline.decoder, startSeconds: 2, durationSeconds: 3, sourceCorrection: correction)
        #expect(gap.bins.isEmpty)
        let window = try await WaveformWindowReader.readWindow(sourceURL: fixture.url("backup"), source: source,
            matching: witness, decoder: fixture.pipeline.decoder, startSeconds: -0.5, durationSeconds: 1, sourceCorrection: correction)
        #expect(window.bins.first?.firstFrame == 20000)
        #expect(window.bins.last?.endFrame == 28000)
        correction.channelCount = 1
        #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            try WaveformWindowReader.verifyOverviewCoverage(envelope: overview, groupMap: nil, sourceCorrection: correction)
        }
    }
}
