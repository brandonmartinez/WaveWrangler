import Foundation
import Testing
import WWAlignEstimate
@testable import WWAutoAlign

@Suite("Quiet-only adaptive transitions")
struct QuietTimingTests {
    func timing(rightOffset: Double = 0.02, rightStart: Int = 12) throws -> AdaptiveTimingResult {
        try AdaptiveAlignment.regions(
            observations: AdaptiveAlignmentTests.points(0..<7, offset: 0)
                + AdaptiveAlignmentTests.points(rightStart..<rightStart + 7, offset: rightOffset),
            start: 0, end: Double(rightStart + 8))
    }

    func profile(
        rate: Int = 8000, channels: Int = 2, selected: Int = 1, allChannels: Bool = true,
        chunk: Int = 16384, duration: Double = 20, floor: Float = 0.00003,
        disturbance: ((Double, Int) -> Float?)? = nil
    ) throws -> QuietAudioProfile {
        var builder = try QuietAudioProfileBuilder(
            sampleRate: rate, channelCount: channels, selectedChannel: selected, allChannels: allChannels)
        let frames = Int(duration * Double(rate))
        for first in stride(from: 0, to: frames, by: chunk) {
            let count = min(chunk, frames - first)
            var samples = [Float](repeating: 0, count: count * channels)
            for channel in 0..<channels {
                for index in 0..<count {
                    let t = Double(first + index) / Double(rate)
                    let base: Float = (6..<10).contains(t) ? floor : 0.1
                    samples[channel * count + index] = disturbance?(t, channel) ?? base
                }
            }
            try builder.append(samples, firstFrame: Int64(first), frameCount: count)
        }
        return try builder.finish()
    }

    @Test func independentlyAnchoredQuietDoesNotChangeSpeechEvidenceOrUnknownEdges() throws {
        let original = try timing()
        let result = try AdaptiveQuietTiming.adding(
            to: original, target: profile(), reference: profile(allChannels: false))
        let quiet = try #require(result.quietTransitions?.first)
        #expect(result.quietTransitions?.count == 1)
        #expect(result.regions == original.regions && result.supportedSeconds == original.supportedSeconds)
        #expect(result.usableWindows == original.usableWindows && result.attemptedWindows == original.attemptedWindows)
        #expect(result.quietSeconds > 3 && result.quietSeconds < 4)
        #expect(abs(quiet.rateRatio - (1 + 0.02 / 6)) < 1e-12)
        #expect(quiet.target.checkedChannels == 2 && quiet.reference.checkedChannels == 1)
        #expect(result.referenceTime(at: 6.1) == nil && result.referenceTime(at: 10.5) == nil)
        #expect(result.referenceTime(at: -1) == nil && result.referenceTime(at: 19) == nil)
        #expect(result.referenceTime(at: 8) != nil)
        #expect(result.referenceIntervals.filter { $0.kind == .quietTransition }.count == 1)
        #expect(!result.containsPlayableInterval(from: 5, to: 8))
        #expect(try JSONDecoder().decode(AdaptiveTimingResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(original.quietTransitions == nil)
        #expect(try JSONDecoder().decode(AdaptiveTimingResult.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func roomToneFloorsCanDifferWithoutTreatingQuietAsAMatch() throws {
        let result = try AdaptiveQuietTiming.adding(to: timing(),
            target: profile(floor: 0.0002), reference: profile(allChannels: false, floor: 0.00032))
        #expect(result.quietSeconds > 3)
        #expect(try #require(result.quietTransitions?.first).target.noiseFloor > 0.0001)
    }

    @Test func activeOtherChannelsAndOppositePolarityNeverCancelIntoQuiet() throws {
        let active = try profile { t, channel in
            (6..<10).contains(t) && channel == 0 ? 0.1 : nil
        }
        #expect(try AdaptiveQuietTiming.adding(to: timing(), target: active,
            reference: profile(allChannels: false)).quietTransitions == nil)
        let opposite = try profile { t, channel in
            (6..<10).contains(t) ? (channel == 0 ? 0.1 : -0.1) : nil
        }
        #expect(try AdaptiveQuietTiming.adding(to: timing(), target: opposite,
            reference: profile(allChannels: false)).quietTransitions == nil)
    }

    @Test func oneSidedDropoutBassMusicBreathAndTransientDoNotLicenseTheGap() throws {
        let disturbances: [(Double, Int) -> Float?] = [
            { t, _ in (6..<10).contains(t) ? 0.004 : nil },
            { t, _ in (6..<10).contains(t) ? Float(0.01 * sin(2 * Double.pi * 40 * t)) : nil },
            { t, _ in (6..<10).contains(t) ? Float(0.005 * sin(2 * Double.pi * 440 * t)) : nil },
        ]
        for disturbance in disturbances {
            let target = try profile(disturbance: disturbance)
            #expect(try AdaptiveQuietTiming.adding(to: timing(), target: target,
                reference: profile(allChannels: false)).quietTransitions == nil)
        }
        let activeReference = try profile(allChannels: false) { t, _ in (6..<10).contains(t) ? 0.1 : nil }
        #expect(try AdaptiveQuietTiming.adding(to: timing(), target: profile(floor: 0),
            reference: activeReference).quietTransitions == nil)
        for amplitude: Float in [0.0005, 0.01] {
            let target = try profile { t, _ in (7.99..<8.01).contains(t) ? amplitude : nil }
            let result = try AdaptiveQuietTiming.adding(to: timing(), target: target,
                reference: profile(allChannels: false))
            #expect(result.quietTransitions?.count == 2)
            #expect(result.referenceTime(at: 8) == nil)
            #expect(result.quietTransitions?.allSatisfy {
                $0.sourceEnd <= 7.7 || $0.sourceStart >= 8.3
            } == true, "quiet guards protect the breath/transient, not just the bin containing it")
        }
    }

    @Test func excessiveStepsRatesAndLongUnanchoredGapsRemainUnknown() throws {
        for candidate in [try timing(rightOffset: 0.051), try timing(rightStart: 70),
                          try timing(rightOffset: 0.02, rightStart: 7)] {
            let result = try AdaptiveQuietTiming.adding(to: candidate,
                target: profile(duration: 78), reference: profile(allChannels: false, duration: 78))
            #expect(result.quietTransitions == nil)
        }
        let one = try AdaptiveAlignment.regions(
            observations: AdaptiveAlignmentTests.points(0..<7, offset: 0), start: 0, end: 20)
        #expect(try AdaptiveQuietTiming.adding(to: one, target: profile(),
            reference: profile(allChannels: false)).quietTransitions == nil)
    }

    @Test func awkwardSampleRatesAndChunkBoundariesProduceIdenticalProfilesAndTransitions() throws {
        for rate in [11025, 44100] {
            let a = try profile(rate: rate, chunk: 777)
            let b = try profile(rate: rate, chunk: 16384)
            #expect(a.bins == b.bins)
            let reference = try profile(rate: rate, allChannels: false)
            #expect(try AdaptiveQuietTiming.adding(to: timing(), target: a, reference: reference)
                == AdaptiveQuietTiming.adding(to: timing(), target: b, reference: reference))
        }
        let partial = try profile(rate: 11025, chunk: 331, duration: 17.1234)
        #expect(partial.bins.count == 172)
    }

    @Test func malformedPCMAndTamperedSerializedWitnessesRefuse() throws {
        var builder = try QuietAudioProfileBuilder(sampleRate: 8000, channelCount: 2, selectedChannel: 1, allChannels: true)
        #expect(throws: AlignEstimateError.self) { try builder.append([0, 0], firstFrame: 1, frameCount: 1) }
        #expect(throws: AlignEstimateError.self) { try builder.finish() }
        var nonfinite = try QuietAudioProfileBuilder(sampleRate: 8000, channelCount: 2, selectedChannel: 1, allChannels: true)
        try nonfinite.append([0, 0], firstFrame: 0, frameCount: 1)
        #expect(throws: AlignEstimateError.self) { try nonfinite.append([.nan, 0], firstFrame: 1, frameCount: 1) }
        #expect(throws: AlignEstimateError.self) { try nonfinite.finish() }
        var closed = try QuietAudioProfileBuilder(sampleRate: 8000, channelCount: 1, selectedChannel: 0, allChannels: true)
        try closed.append([0], firstFrame: 0, frameCount: 1)
        _ = try closed.finish()
        #expect(throws: AlignEstimateError.self) { try closed.append([0], firstFrame: 1, frameCount: 1) }
        #expect(throws: AlignEstimateError.self) { try closed.finish() }
        let result = try AdaptiveQuietTiming.adding(to: timing(), target: profile(), reference: profile(allChannels: false))
        let data = try JSONEncoder().encode(result)
        let text = try #require(String(data: data, encoding: .utf8))
        for changed in [
            text.replacingOccurrences(of: "\"checkedChannels\":2", with: "\"checkedChannels\":1"),
            text.replacingOccurrences(of: "\"leftRegion\":0", with: "\"leftRegion\":9223372036854775807"),
            text.replacingOccurrences(of: "\"maximumPeak\":", with: "\"maximumPeak\":0.5,\"ignoredPeak\":"),
        ] {
            let decoded = try JSONDecoder().decode(AdaptiveTimingResult.self, from: Data(changed.utf8))
            #expect(throws: AlignEstimateError.self) {
                try AdaptiveQuietTiming.attaching(decoded.quietTransitions ?? [], to: decoded,
                    targetChannels: 2, targetDuration: 20, referenceDuration: 20)
            }
        }

    }

    @Test func fiftyMillisecondCorrectionsAndSixtySecondGapsAreInclusiveBounds() throws {
        for offset in [-0.05, 0.05] {
            let result = try AdaptiveQuietTiming.adding(to: timing(rightOffset: offset),
                target: profile(), reference: profile(allChannels: false))
            #expect(result.quietSeconds > 3)
        }
        let long = try AdaptiveQuietTiming.adding(to: timing(rightOffset: 0.05, rightStart: 66),
            target: profile(duration: 76), reference: profile(allChannels: false, duration: 76))
        #expect(long.quietSeconds > 3)
    }
}
