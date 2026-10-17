import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAutoAlign

@Suite("Whole-track fingerprint streaming")
struct FingerprintTests {
    @Test(arguments: [8000, 11025, 16000])
    func framesSurviveArbitraryChunkBoundaries(rate: Int) throws {
        let track = try SyntheticSpeech.track(start: 0, duration: 2.137, sampleRate: rate)
        var whole = try SpectralFingerprintBuilder(sampleRate: rate)
        try whole.append(track.buffer.samples)
        var streamed = try SpectralFingerprintBuilder(sampleRate: rate)
        for start in stride(from: 0, to: track.buffer.samples.count, by: 137) {
            try streamed.append(Array(track.buffer.samples[start..<min(start + 137, track.buffer.samples.count)]))
        }
        let a = try whole.finish(), b = try streamed.finish()
        #expect(a.bands == b.bands)
        #expect(a.energy == b.energy)
        #expect(a.duration == b.duration)
        #expect(a.byteCount < 4000)
        let restored = try SpectralFingerprint(encoded: a.encoded())
        #expect(restored.bands == a.bands && restored.energy == a.energy && restored.duration == a.duration)
        #expect(throws: AlignEstimateError.self) { try SpectralFingerprint(encoded: a.encoded().dropLast()) }
    }

    @Test func cancellationAndInvalidSamplesDoNotProduceIndexes() async throws {
        var builder = try SpectralFingerprintBuilder(sampleRate: 8000)
        #expect(throws: AlignEstimateError.self) { try builder.append([.nan]) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var builder = try SpectralFingerprintBuilder(sampleRate: 8000)
            try builder.append([0])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

extension AutomaticReliabilityTests {
    @Test("Whole-track indexing finds sparse processed speech without an initial offset or anchor",
          arguments: [-18.617, 21.25])
    func fingerprintFindsSpeechBetweenFixedStations(offset: Double) throws {
        let rate = 8000
        let duration = 180.0
        let ppm = offset < 0 ? 145.0 : -180.0
        func track(start: Double, duration: Double, target: Bool) throws -> EstimatorTrack {
            let samples = (0..<Int(duration * Double(rate))).map { frame -> Float in
                let u = start + Double(frame) / Double(rate)
                let t = target ? (1 + ppm / 1e6) * u + offset : u
                let phase = t - floor(t / 12) * 12
                guard (4.0..<8.5).contains(phase) else { return 0 }
                let raw = SyntheticSpeech.value(t, seed: 731)
                let value = target ? tanh(2 * (raw - 0.4 * SyntheticSpeech.value(t - 0.0005, seed: 731))) * 0.4 : raw
                return Float(value + 0.002 * SyntheticSpeech.noise(target ? 401 : 902, Int64(u * Double(rate))))
            }
            return EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                  groupClockStart: try ExactRational(Int64((start * 1e9).rounded()), 1_000_000_000),
                                  buffer: try SampleBuffer(samples: samples, sampleRate: rate))
        }
        func fingerprint(target: Bool) throws -> SpectralFingerprint {
            var builder = try SpectralFingerprintBuilder(sampleRate: rate)
            for second in 0..<Int(duration) {
                try builder.append(track(start: Double(second), duration: 1, target: target).buffer.samples)
            }
            return try builder.finish()
        }
        let reference = try fingerprint(target: false), target = try fingerprint(target: true)
        let plan = try FingerprintAlignment.plan(reference: reference, target: target)
        #expect(plan.abstention == nil, "\(String(describing: plan.abstention)); \(plan.evidence)")
        #expect(plan.passages.count >= 5)
        var attempts: [DelayEvidence] = []
        for passage in plan.passages {
            let t = try track(start: passage.start, duration: 4, target: true)
            let r = try track(start: passage.start + passage.offset - 0.37, duration: 4.74, target: false)
            attempts += try AutomaticAlignment.measure(reference: r, target: t, station: passage.station,
                                                      predictedOffset: passage.offset, deviation: 0.35,
                                                      rateRatio: plan.refinementRateRatio)
        }
        let result = try AutomaticAlignment.finish(startSeconds: plan.start, endSeconds: plan.end,
                                                   attempts: attempts, expectedStations: plan.stations,
                                                   sharedSilentStations: plan.sharedSilentStations)
        let proposal = try #require(result.proposal, "\(String(describing: result.abstention)); \(result.windows)")
        let errors = [plan.start, (plan.start + plan.end) / 2, plan.end].map {
            abs(proposal.segment.rateRatio.approximateDouble * $0 + proposal.segment.alignedOffset.approximateDouble
                - ((1 + ppm / 1e6) * $0 + offset)) * 1000
        }
        print("FINGERPRINT sparse speech offset=\(offset), errorsMs=\(errors), passages=\(plan.passages.count)")
        #expect(errors.max()! < 1)
        #expect(reference.byteCount < 260_000)
    }
}
