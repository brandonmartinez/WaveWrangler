import Foundation
import Testing
import WWCore
@testable import WWAlignPipeline

@Suite("Coherent pitch-preserving adaptive audio", .serialized)
struct PitchPreservingAudioTests {
    @Test func estimatedJoinsCrossfadeWithoutSilencingContinuousAudioOrChangingChannels() async throws {
        let rate = 8000
        let tone = (0..<rate * 16).map { Float(0.2 * sin(2 * .pi * 220 * Double($0) / Double(rate))) }
        let channels = [tone, tone.map { -0.5 * $0 }]
        for ratio in [0.995, 1, 1.005] {
            let end = 5 + 5 * ratio
            let correction = SourceTimingCorrection(source: SourceID(), group: RecorderGroupID(),
                epoch: RecordingEpochID(), reference: SourceID(), sourceRate: rate, sourceFrames: Int64(tone.count),
                channelCount: 2, analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
                segments: [
                    SourceTimingSegment(sourceStart: 0, sourceEnd: 5, alignedStart: 0, rateRatio: 1),
                    SourceTimingSegment(sourceStart: 5, sourceEnd: 10, alignedStart: 5, rateRatio: ratio, kind: .estimated),
                    SourceTimingSegment(sourceStart: 10, sourceEnd: 16, alignedStart: end, rateRatio: 1, kind: .anchorGuided),
                ])
            try #require(correction.isValid && correction.version == 3)
            let left = try await AdaptiveAudioRendering.tile(correction: correction, index: 0, outputRate: rate) { range in
                channels.map { Array($0[Int(range.lowerBound)..<Int(range.upperBound)]) }
            }
            let right = try await AdaptiveAudioRendering.tile(correction: correction, index: 1, outputRate: rate) { range in
                channels.map { Array($0[Int(range.lowerBound)..<Int(range.upperBound)]) }
            }
            let audio = left.channels[0] + right.channels[0]
            let around = Array(audio[rate * 5 - 16..<rate * 5 + 16])
            let rms = sqrt(around.reduce(0.0) { $0 + Double($1 * $1) } / Double(around.count))
            #expect(rms > 0.07, "continuous join must not use two fades to silence: ratio=\(ratio), RMS=\(rms)")
            let jump = abs(audio[rate * 5] - audio[rate * 5 - 1])
            #expect(jump < 0.06, "join jump=\(jump), ratio=\(ratio)")
            #expect(zip(right.channels[0], right.channels[1]).allSatisfy { abs($0 * 0.5 + $1) < 0.0001 })
        }
    }

    @Test func durationPitchChannelsAndTransientTiming() async throws {
        let rate = 48000, count = rate * 3
        let tone = (0..<count).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / Double(rate))) }
        for ratio in [0.995, 1.0, 1.005] {
            let output = try await PitchPreservingAudio.stretch([tone, tone.map { -0.5 * $0 }], sampleRate: rate, rateRatio: ratio)
            #expect(output.count == 2)
            #expect(output[0].count == Int((Double(count) * ratio).rounded()))
            #expect(zip(output[0], output[1]).map { abs($0 * 0.5 + $1) }.max()! < 0.0001)
            let middle = Array(output[0][rate..<2 * rate])
            let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            #expect(abs(crossings - 440) <= 1)
        }
        var pulse = [Float](repeating: 0, count: count)
        for index in 0..<48 { pulse[rate + index] = Float(sin(.pi * Double(index) / 48)) }
        for ratio in [0.9997, 1, 1.0003] {
            let output = try await PitchPreservingAudio.stretch([pulse], sampleRate: rate, rateRatio: ratio)
            let peak = try #require(output[0].indices.max(by: { output[0][$0] < output[0][$1] }))
            let expected = Int((Double(rate + 24) * ratio).rounded())
            print("ADAPTIVE-PITCH pulse ratio=\(ratio) expected=\(expected) measured=\(peak)")
            #expect(abs(peak - expected) <= 48)
        }
    }

    @Test func sampleRateConversionPreservesPitchAndChannelRelationship() async throws {
        for inputRate in [8000, 11025, 48000] {
            let tone = (0..<inputRate * 3).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / Double(inputRate))) }
            let output = try await PitchPreservingAudio.stretch([tone, tone.map { -0.5 * $0 }],
                sampleRate: inputRate, rateRatio: 1.0002, outputRate: 48000)
            #expect(output[0].count == Int((3 * 48000 * 1.0002).rounded()))
            #expect(zip(output[0], output[1]).map { abs($0 * 0.5 + $1) }.max()! < 0.0001)
            let middle = Array(output[0][48000..<96000])
            #expect(abs(zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count - 440) <= 1)
        }
    }

    @Test func supportedOutputRatesKeepPitchAndStereoRelationship() async throws {
        let inputRate = 48000
        let tone = (0..<inputRate * 3).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / Double(inputRate))) }
        for outputRate in [8000, 11025, 44100, 48000, 96000, 192000] {
            let output = try await PitchPreservingAudio.stretch([tone, tone.map { -0.5 * $0 }],
                sampleRate: inputRate, rateRatio: 1.0002, outputRate: outputRate)
            #expect(output[0].count == Int((3 * Double(outputRate) * 1.0002).rounded()))
            #expect(zip(output[0], output[1]).allSatisfy { abs($0 * 0.5 + $1) < 0.0001 })
            let middle = output[0][outputRate..<2 * outputRate]
            #expect(abs(zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count - 440) <= 1)
        }
    }

    @Test(arguments: [1, 8, 16, 32])
    func multichannelFilesKeepOneDurationAndChannelRelationship(count: Int) async throws {
        let tone = (0..<4000).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / 8000)) }
        let gains = (0..<count).map { Float($0.isMultiple(of: 2) ? 1 : -1) / Float($0 + 1) }
        let output = try await PitchPreservingAudio.stretch(gains.map { gain in tone.map { $0 * gain } },
            sampleRate: 8000, rateRatio: 1.001, outputRate: 48000)
        try #require(output.count == count)
        #expect(output.allSatisfy { $0.count == 24024 })
        #expect(output[0].contains { abs($0) > 0.01 })
        for channel in output.indices {
            let error = try #require(zip(output[0], output[channel]).map { abs($0 * gains[channel] - $1) }.max())
            let oneSamplePhase = Float(0.2 * 2 * .pi * 440 / 48000) * abs(gains[channel])
            #expect(error < oneSamplePhase, "channels=\(count) channel=\(channel) maximumError=\(error)")
        }
    }

    @Test(arguments: [8, 16, 32])
    func independentChannelPulsesKeepTheirIdentityAndTiming(count: Int) async throws {
        let channels = (0..<count).map { channel -> [Float] in
            var pulse = [Float](repeating: 0, count: 8000)
            for sample in 0..<8 { pulse[2000 + channel * 64 + sample] = Float(sin(.pi * Double(sample) / 8)) }
            return pulse
        }
        let output = try await PitchPreservingAudio.stretch(channels, sampleRate: 8000, rateRatio: 1.0003, outputRate: 48000)
        for channel in 0..<count {
            let peak = try #require(output[channel].indices.max(by: { abs(output[channel][$0]) < abs(output[channel][$1]) }))
            let expected = Int((Double(2004 + channel * 64) * 6 * 1.0003).rounded())
            #expect(abs(peak - expected) <= 48, "channels=\(count) channel=\(channel) expected=\(expected) measured=\(peak)")
            #expect(abs(output[channel][peak]) > 0.1)
        }
    }

    @Test func canonicalTileBoundariesDoNotIntroduceClicks() async throws {
        let rate = 48000
        let tone = (0..<rate * 26).map { index -> Float in
            let time = Double(index) / Double(rate)
            return Float(0.12 * (sin(2 * .pi * 440 * time)
                + 0.4 * sin(2 * .pi * 997 * time) + 0.3 * sin(2 * .pi * 121 * time)))
        }
        for ratio in [0.9995, 1, 1.0005] {
            let correction = SourceTimingCorrection(source: SourceID(), group: RecorderGroupID(),
                epoch: RecordingEpochID(), reference: SourceID(), sourceRate: rate,
                sourceFrames: Int64(tone.count), channelCount: 2, analysisDigest: String(repeating: "a", count: 64),
                processing: PitchPreservingAudio.identifier,
                segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 26, alignedStart: 0, rateRatio: ratio)])
            let channels = [tone, tone.map { -0.5 * $0 }]
            func tile(_ index: Int64) async throws -> AdaptivePCM {
                try await AdaptiveAudioRendering.tile(correction: correction, index: index, outputRate: rate) { range in
                    channels.map { Array($0[Int(range.lowerBound)..<Int(range.upperBound)]) }
                }
            }
            let left = try await tile(0), right = try await tile(1), third = try await tile(2)
            let jump = abs(try #require(left.channels[0].last) - #require(right.channels[0].first))
            print("ADAPTIVE-PITCH tile ratio=\(ratio) jump=\(jump)")
            #expect(jump < 0.016, "ratio=\(ratio) boundaryJump=\(jump)")
            #expect(abs(try #require(right.channels[0].last) - #require(third.channels[0].first)) < 0.016)
            let blockJump = try #require(zip(third.channels[0], third.channels[0].dropFirst()).map { abs($0 - $1) }.max())
            #expect(blockJump < 0.016, "ratio=\(ratio) processingBlockJump=\(blockJump)")
            #expect(zip(third.channels[0], third.channels[1]).allSatisfy { abs($0 * 0.5 + $1) < 0.0001 })
        }
    }

    @Test func lateTransientsFollowTheRequestedStretch() async throws {
        let rate = 48000
        var input = [Float](repeating: 0, count: rate * 5)
        for sample in 0..<48 { input[rate * 4 + sample] = Float(sin(.pi * Double(sample) / 48)) }
        for ratio in [0.98, 0.9995, 1, 1.0005, 1.02] {
            let output = try await PitchPreservingAudio.stretch([input], sampleRate: rate, rateRatio: ratio)
            let peak = try #require(output[0].indices.max(by: { output[0][$0] < output[0][$1] }))
            let expected = Int((Double(rate * 4 + 24) * ratio).rounded())
            print("ADAPTIVE-PITCH late ratio=\(ratio) expected=\(expected) measured=\(peak) error=\(peak - expected)")
            // Native transient placement has its own tolerance, separate from the 1ms evidence-fit gate.
            #expect(abs(peak - expected) <= rate / 200, "ratio=\(ratio) expected=\(expected) measured=\(peak)")
        }
    }

    @Test func invalidPCMAndCancellationRefuse() async throws {
        for channels in [[], [[]], [[Float.nan]], [[0], [0, 0]], Array(repeating: [0], count: 33)] as [[[Float]]] {
            await #expect(throws: PitchPreservingAudio.Failure.self) {
                try await PitchPreservingAudio.stretch(channels, sampleRate: 48000, rateRatio: 1)
            }
        }
        for ratio in [Double.nan, 0, 0.979, 1.021] {
            await #expect(throws: PitchPreservingAudio.Failure.self) {
                try await PitchPreservingAudio.stretch([[0]], sampleRate: 48000, rateRatio: ratio)
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PitchPreservingAudio.stretch([[0]], sampleRate: 48000, rateRatio: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
