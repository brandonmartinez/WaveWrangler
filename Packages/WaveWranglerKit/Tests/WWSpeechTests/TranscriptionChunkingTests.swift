import Foundation
import Testing
@testable import WWSpeech

@Suite("Pause-preferred bounded transcription")
struct TranscriptionChunkingTests {
    private let rate = 48_000

    @Test func pausesMoveOnlyTheCoreBoundaryAndKeepFullContext() throws {
        var planner = try TranscriptionChunkPlanner(start: -0.0000208333333, end: 70)
        let candidate = try #require(planner.candidate)
        var pcm = [Float](repeating: 0.1, count: candidate.audioFrames.count)
        let quiet = (26 * rate)..<(27 * rate)
        pcm.replaceSubrange(quiet, with: repeatElement(Float(0), count: quiet.count))
        let selected = try planner.next(pcm: pcm)
        #expect(selected.coreFrames.lowerBound == -1)
        #expect(selected.coreFrames.upperBound == -1 + Int64(26.5 * Double(rate)))
        #expect(selected.audioFrames.upperBound == selected.coreFrames.upperBound + Int64(rate))
        #expect(planner.candidate?.coreFrames.lowerBound == selected.coreFrames.upperBound)
        #expect(planner.candidate?.audioFrames.lowerBound == selected.coreFrames.upperBound - Int64(rate))
        #expect(selected.audioFrames.lowerBound == -1)
    }

    @Test(arguments: [Float(0.2), 0.001, 0.00001])
    func uninterruptedOrUniformlyQuietSpeechAndNoiseKeepTheFixedMaximum(_ amplitude: Float) throws {
        var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
        let candidate = try #require(planner.candidate)
        let pcm = [Float](repeating: amplitude, count: candidate.audioFrames.count)
        #expect(try planner.next(pcm: pcm) == candidate)
    }

    @Test func shortDipsAndBreathsDoNotQualifyAndTheLatestLongPauseWins() throws {
        var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
        let candidate = try #require(planner.candidate)
        var pcm = [Float](repeating: 0.1, count: candidate.audioFrames.count)
        for (start, end, value) in [(24.1, 24.8, Float(0)), (25.2, 25.9, 0),
                                   (26.2, 26.4, 0), (27.0, 27.8, 0.008)] {
            let frames = Int(start * Double(rate))..<Int(end * Double(rate))
            pcm.replaceSubrange(frames, with: repeatElement(value, count: frames.count))
        }
        let selected = try planner.next(pcm: pcm)
        #expect(selected.coreFrames.upperBound == Int64(25.55 * Double(rate)))
    }

    @Test func pauseAroundMaximumUsesRightContextButNeverExceedsTheCap() throws {
        var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
        let candidate = try #require(planner.candidate)
        var pcm = [Float](repeating: 0.1, count: candidate.audioFrames.count)
        let quiet = Int(27.8 * Double(rate))..<pcm.count
        pcm.replaceSubrange(quiet, with: repeatElement(Float(0), count: quiet.count))
        #expect(try planner.next(pcm: pcm) == candidate)
    }

    @Test(arguments: [148.874229167, -148.874, -86_400, 1.0 / 48_000])
    func streamingZeroAndFixedReferencesCoverEveryFrameIncludingOneFrameTails(_ start: Double) throws {
        let end = start + 56 + 1.0 / 48_000
        for policy in [TranscriptionChunking.fixed, .pausePreferred] {
            var planner = try TranscriptionChunkPlanner(start: start, end: end, policy: policy)
            var cursor = Int64((start * 48_000).rounded())
            let last = Int64((end * 48_000).rounded())
            var windows: [TranscriptionWindow] = []
            while let candidate = planner.candidate {
                let window = try planner.next(pcm: [Float](repeating: 0, count: candidate.audioFrames.count))
                #expect(window.coreFrames.lowerBound == cursor)
                #expect(window.coreFrames.count > 0 && window.coreFrames.count <= 28 * rate)
                #expect(window.audioFrames.count <= 30 * rate)
                #expect(window.audioFrames.lowerBound == max(Int64((start * 48_000).rounded()), cursor - 48_000))
                #expect(window.audioFrames.upperBound == min(last, window.coreFrames.upperBound + 48_000))
                cursor = window.coreFrames.upperBound
                windows.append(window)
            }
            #expect(cursor == last)
            if policy == .fixed { #expect(windows.last?.coreFrames.count == 1) }
        }
    }

    @Test func finalAndClippedWindowsAreNotSplitUnnecessarily() throws {
        for length in [1, 47, 4_800, 28 * rate] {
            var planner = try TranscriptionChunkPlanner(start: -1, end: -1 + Double(length) / 48_000)
            let candidate = try #require(planner.candidate)
            #expect(try planner.next(pcm: [Float](repeating: 0, count: candidate.audioFrames.count)) == candidate)
            #expect(planner.candidate == nil)
        }
        for (start, end) in [(Double.nan, 1.0), (0, .infinity), (1, 1), (2, 1),
                             (-86_401, 0), (0, 86_401), (0, 1.0 / 96_001)] {
            #expect(throws: TranscriptionChunkingError.invalidRange) {
                try TranscriptionChunkPlanner(start: start, end: end)
            }
        }
        var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
        #expect(throws: TranscriptionChunkingError.invalidPCM) { try planner.next(pcm: []) }
        let candidate = try #require(planner.candidate)
        var pcm = [Float](repeating: 0, count: candidate.audioFrames.count)
        pcm[25 * rate] = .nan
        #expect(throws: TranscriptionChunkingError.invalidPCM) { try planner.next(pcm: pcm) }
        #expect(planner.candidate == candidate, "Invalid audio cannot advance ownership")
    }

    @Test func cancellationDoesNotAdvanceOrRetainAudio() async throws {
        let task = Task {
            var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
            let candidate = try #require(planner.candidate)
            let pcm = [Float](repeating: 0, count: candidate.audioFrames.count)
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try planner.next(pcm: pcm) }
            #expect(planner.candidate == candidate)
        }
        try await task.value
    }

    @Test(arguments: [0.2, 0.29, 0.3, 0.5, 0.6, 0.8, 1.0])
    func generatedPauseThresholdSweepPreservesQuietSpeechAndNoise(_ duration: Double) throws {
        var planner = try TranscriptionChunkPlanner(start: 0, end: 60)
        let candidate = try #require(planner.candidate)
        var pcm = (0..<candidate.audioFrames.count).map {
            Float(0.05 * sin(Double($0) * 2 * .pi * 173 / 48_000))
        }
        let quiet = 25 * rate..<(25 * rate + Int((duration * 48_000).rounded()))
        for index in quiet { pcm[index] *= 0.01 }
        let selected = try planner.next(pcm: pcm)
        if duration < 0.3 {
            #expect(selected == candidate)
        } else {
            #expect(abs(Double(selected.coreFrames.upperBound) / 48_000 - (25 + duration / 2)) <= 0.01)
        }
        #expect(pcm.count == candidate.audioFrames.count, "Boundary detection never removes quiet audio")
        #expect(pcm[quiet.lowerBound + 1] != 0)
        #expect(TranscriptionChunking.pausePreferred.revision.contains("min300ms"))
        #expect(TranscriptionChunking.pausePreferred.revision != TranscriptionChunking.fixed.revision)
    }

    @Test func productionResamplingDoesNotIntroduceAnEarlySecondsScaleOffset() throws {
        var input = [Float](repeating: 0, count: 30 * rate)
        for onset in [2.25, 14.375, 28.75] {
            let start = Int(onset * 48_000)
            for index in start..<(start + 4_800) {
                input[index] = Float(0.25 * sin(Double(index - start) * 2 * .pi * 440 / 48_000))
            }
        }
        let output = try LocalWhisper.resample(input, sampleRate: 48_000)
        #expect(abs(output.count - 480_000) <= 16)
        for onset in [2.25, 14.375, 28.75] {
            let expected = Int(onset * 16_000)
            let search = (expected - 160)..<(expected + 1_760)
            let first = try #require(search.first { abs(output[$0]) > 0.01 })
            let last = try #require(search.last { abs(output[$0]) > 0.01 })
            #expect(abs(Double(first) / 16_000 - onset) < 0.003)
            #expect(abs(Double(last) / 16_000 - onset - 0.1) < 0.003)
        }
    }

    @Test(arguments: [Int64(-4_000_000_001), 1, 7_145_952, 4_000_000_001])
    func midpointOwnershipIsHalfOpenEvenAtFractionalAndNegativeOrigins(_ origin: Int64) {
        let left = TranscriptionWindow(coreFrames: origin..<(origin + 28 * 48_000),
            audioFrames: origin..<(origin + 29 * 48_000))
        let right = TranscriptionWindow(coreFrames: (origin + 28 * 48_000)..<(origin + 56 * 48_000),
            audioFrames: (origin + 27 * 48_000)..<(origin + 57 * 48_000))
        #expect(!left.owns(startSeconds: 27.9, endSeconds: 28.1))
        #expect(right.owns(startSeconds: 0.9, endSeconds: 1.1))
        #expect(left.owns(startSeconds: 27.8, endSeconds: 28))
        #expect(!right.owns(startSeconds: 0.8, endSeconds: 1))
        #expect(!right.owns(startSeconds: .nan, endSeconds: 2))
    }
}
