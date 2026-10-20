import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAutoAlign

enum SyntheticSpeech {
    static func noise(_ seed: UInt64, _ index: Int64) -> Double {
        var x = seed &+ UInt64(bitPattern: index) &* 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return Double((x ^ (x >> 31)) >> 11) / Double(1 << 53) - 0.5
    }

    static func value(_ t: Double, seed: UInt64) -> Double {
        let syllable = Int64(floor(t / 0.19))
        let phase = t / 0.19 - floor(t / 0.19)
        let envelope = pow(sin(.pi * phase), 2)
        if Int64(floor(t / 1.3)).isMultiple(of: 7) { return 0 }
        let f0 = 110 + 90 * (noise(seed, syllable) + 0.5)
        var voice = 0.0
        for h in 1...8 {
            voice += sin(2 * .pi * Double(h) * f0 * t) / pow(Double(h), 1.3)
        }
        let x = t * 2500, i = Int64(floor(x)), f = x - floor(x)
        let air = noise(seed &+ 99, i) * (1 - f) + noise(seed &+ 99, i + 1) * f
        return envelope * (0.12 * voice + 0.6 * air)
    }

    static func track(
        start: Double, duration: Double, sampleRate: Int = 8000, offset: Double = 0,
        ppm: Double = 0, seed: UInt64 = 42, processed: Bool = false,
        stepAt: Double? = nil, step: Double = 0, noiseLevel: Double = 0.002, gain: Double = 1
    ) throws -> EstimatorTrack {
        let samples = (0..<Int(duration * Double(sampleRate))).map { frame -> Float in
            let u = start + Double(frame) / Double(sampleRate)
            let t = (1 + ppm / 1e6) * u + offset + (stepAt.map { u >= $0 ? step : 0 } ?? 0)
            let raw = value(t, seed: seed)
            let signal = processed
                ? tanh(2 * (raw - 0.4 * value(t - 0.0005, seed: seed) + 0.2 * value(t - 0.001, seed: seed))) * 0.4
                : raw
            return Float(gain * signal + noiseLevel * noise(seed &+ (processed ? 1001 : 2002), Int64(frame)))
        }
        return EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                              groupClockStart: try ExactRational(Int64((start * 1e6).rounded()), 1_000_000),
                              buffer: try SampleBuffer(samples: samples, sampleRate: sampleRate))
    }
}

@Suite("Automatic alignment consensus")
struct AutomaticConsensusTests {
    static func points(_ statuses: [String]? = nil, outliers: [Int: Double] = [:]) -> [DelayEvidence] {
        (0..<16).map {
            DelayEvidence(station: $0, attempt: 0, targetCenter: 1 + Double($0) * 299.8,
                          status: statuses?[$0] ?? "eligible",
                          offsetSeconds: -38.617 + 120e-6 * Double($0) * 299.8 + (outliers[$0] ?? 0),
                          nccScore: 0.7, nccSecond: 0.1, phatOffsetSeconds: nil, phatPeakRatio: 0.1, method: "synthetic-measurement")
        }
    }

    @Test func isolatedObservationDoesNotDefeatAnOtherwiseVerifiedLine() throws {
        let result = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: Self.points(outliers: [7: 0.04]))
        let proposal = try #require(result.proposal)
        #expect(abs(proposal.ppm - 120) < 0.001)
        #expect(abs(proposal.segment.alignedOffset.approximateDouble + 38.61712) < 1e-6)
        #expect(result.windows.filter { $0.status == "outlier" }.count == 1)
        #expect(proposal.acousticResidualMaxMilliseconds < 0.001)
    }

    @Test func aContradictoryRegionCannotBeTrimmed() throws {
        for outliers in [[7: 0.04, 8: 0.04], [14: 0.04, 15: 0.04],
                         Dictionary(uniqueKeysWithValues: (8..<16).map { ($0, 0.04) })] {
            let result = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: Self.points(outliers: outliers))
            #expect(result.proposal == nil)
            #expect(result.abstention?.reason == .discontinuous)
        }
    }

    @Test func alternateAgreeingPassagesCannotHideAdjacentContradictions() throws {
        let agreeing = Self.points()
        let conflicting = Self.points(outliers: [7: 0.04, 8: 0.04]).filter { [7, 8].contains($0.station) }
        let result = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: agreeing + conflicting)
        #expect(result.proposal == nil)
        #expect(result.abstention?.reason == .discontinuous)
    }

    @Test func sharedSilentRegionsSupportCoverageButNeverSupplyTimingMeasurements() throws {
        var points = Self.points()
        for station in [6, 7] { points[station].status = "weak" }
        let result = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: points,
                                                   sharedSilentStations: [6, 7])
        #expect(result.proposal != nil)
        #expect(result.windows.filter { $0.status == "eligible" }.count == 14)
        #expect(result.windows.filter { $0.method == "whole-track-silence" }.count == 2)
        #expect(result.attempts == points)
        let sparse = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: Array(points.prefix(4)),
                                                   sharedSilentStations: Array(4..<16))
        #expect(sparse.proposal == nil)
        #expect(sparse.abstention?.reason == .insufficientCoverage)
        #expect(throws: AlignEstimateError.self) {
            try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: points, sharedSilentStations: [16])
        }
    }

    @Test func coherentRejectedMeasurementsAreNotRetroactivelyEligible() throws {
        let statuses = ["eligible", "eligible", "periodic", "weak", "eligible", "eligible", "ambiguous", "weak",
                        "weak", "eligible", "eligible", "periodic", "eligible", "periodic", "weak", "eligible"]
        let points = Self.points(statuses).enumerated().map { index, p in
            DelayEvidence(station: p.station, attempt: 0, targetCenter: 2203 + Double(index) * 3.7,
                          status: p.status, offsetSeconds: -38.617 + Double(index % 4) * 0.001,
                          nccScore: p.nccScore, nccSecond: p.nccSecond, phatOffsetSeconds: nil, phatPeakRatio: nil,
                          method: "recorded-classification-shape-only")
        }
        let result = try AutomaticAlignment.finish(startSeconds: 2202.847, endSeconds: 2262.847, attempts: points)
        #expect(result.proposal == nil)
        #expect(result.abstention?.reason == .insufficientCoverage)
        #expect(!result.flags.contains("discontinuity"))
        #expect(result.windows.map(\.status) == statuses)
    }

    @Test func unsupportedEndsAndSparseEvidenceRemainUnsupported() throws {
        for indices in [Array(0..<4), Array(6..<12)] {
            var points = Self.points()
            for index in indices { points[index].status = "weak" }
            let result = try AutomaticAlignment.finish(startSeconds: 0, endSeconds: 4500, attempts: points)
            #expect(result.proposal == nil)
            #expect(result.abstention?.reason == .insufficientCoverage)
        }
    }

    @Test func canceledWorkStopsBeforeSignalProcessing() async throws {
        let reference = try SyntheticSpeech.track(start: 0, duration: 4)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AutomaticAlignment.coarse(reference: reference, target: reference, search: SearchRange(maximumDeviationSeconds: 1))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func coarseSilenceAndUnreachableCoverageKeepTheirOwnReasons() throws {
        let silent = EstimatorTrack(
            group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            buffer: try SampleBuffer(samples: [Float](repeating: 0, count: 8000 * 5), sampleRate: 8000)
        )
        let search = try SearchRange(maximumDeviationSeconds: 1)
        let silence = try AutomaticAlignment.coarse(reference: silent, target: silent, search: search)
        #expect(silence.offsetSeconds == nil)
        #expect(silence.abstentionReason == .silent)
        let reference = try SyntheticSpeech.track(start: 0, duration: 5)
        let target = EstimatorTrack(
            group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            groupClockStart: try ExactRational(100, 1), buffer: reference.buffer
        )
        let unreachable = try AutomaticAlignment.coarse(reference: reference, target: target, search: search)
        #expect(unreachable.offsetSeconds == nil)
        #expect(unreachable.measurements.isEmpty)
        #expect(unreachable.abstentionReason == .insufficientCoverage)
    }
}

@Suite("Automatic alignment synthetic reliability", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["WW_ESTIMATOR_TESTS"] == "1", "CPU-heavy synthetic alignment: serialized estimator pass"))
struct AutomaticReliabilityTests {
    @Test(arguments: [-38.617, 47.25])
    func largeOffsetsAndSignedDrift(offset: Double) throws {
        let ppm = offset < 0 ? 145.0 : -180.0
        let reference = try SyntheticSpeech.track(start: 1800 - 120, duration: 300, sampleRate: 11025)
        let target = try SyntheticSpeech.track(start: 1800, duration: 60, offset: offset, ppm: ppm, processed: true)
        let coarse = try AutomaticAlignment.coarse(reference: reference, target: target, search: SearchRange(maximumDeviationSeconds: 120))
        let seed = try #require(coarse.offsetSeconds, "\(coarse.detail): \(coarse.measurements)")
        #expect(abs(seed - (offset + ppm * 1830 / 1e6)) < 0.05)
        var attempts: [DelayEvidence] = []
        for station in 0..<16 {
            let start = 100 + Double(station) * (4300 - 8) / 15
            let t = try SyntheticSpeech.track(start: start, duration: 8, offset: offset, ppm: ppm, processed: true)
            let r = try SyntheticSpeech.track(start: start + seed - 3, duration: 14, sampleRate: 11025)
            attempts += try AutomaticAlignment.measure(reference: r, target: t, station: station, predictedOffset: seed, deviation: 3)
        }
        let result = try AutomaticAlignment.finish(startSeconds: 100, endSeconds: 4400, attempts: attempts)
        let proposal = try #require(result.proposal, "\(String(describing: result.abstention)); \(result.windows)")
        let errors = [100.0, 1200, 2400, 4400].map {
            abs(proposal.segment.rateRatio.approximateDouble * $0 + proposal.segment.alignedOffset.approximateDouble
                - ((1 + ppm / 1e6) * $0 + offset)) * 1000
        }
        print("AUTO-ALIGN offset=\(offset) ppm=\(ppm) estimated=\(proposal.ppm) truthErrorsMs=\(errors) stations=\(result.windows.filter { $0.status == "eligible" }.count)/16")
        #expect(errors.max()! < 1)
        #expect(abs(proposal.ppm - ppm) < 0.5)
        #expect(proposal.provenance.estimator == AutomaticAlignment.identifier)
    }

    @Test func waveformAndPhaseWeightingAreMeasuredRatherThanAssumedSuperior() throws {
        for processed in [false, true] {
            for noise in [0.002, 0.04] {
                let offset = -0.71325, ppm = -120.0, start = 1700.0
                let target = try SyntheticSpeech.track(start: start, duration: 8, offset: offset, ppm: ppm,
                                                      processed: processed, noiseLevel: noise, gain: 0.25)
                let predicted = offset + ppm * (start + 4) / 1e6
                let reference = try SyntheticSpeech.track(start: start + predicted - 1, duration: 10, sampleRate: 16000)
                let evidence = try AutomaticAlignment.measure(reference: reference, target: target, station: 0, predictedOffset: predicted, deviation: 1)
                let nccErrors = evidence.compactMap { e in e.offsetSeconds.map { abs($0 - (offset + ppm * e.targetCenter / 1e6)) * 1000 } }
                let phatErrors = evidence.compactMap { e in e.phatOffsetSeconds.map { abs($0 - (offset + ppm * e.targetCenter / 1e6)) * 1000 } }
                print("AUTO-METHODS processed=\(processed) noise=\(noise) NCCmaxMs=\(nccErrors.max() ?? .infinity) PHATmaxMs=\(phatErrors.max() ?? .infinity) usable=\(evidence.filter { $0.status == "eligible" }.count)/3")
                #expect(evidence.filter { $0.status == "eligible" }.count >= 2)
                #expect(nccErrors.max()! < 1)
                #expect(phatErrors.max()! < 1)
            }
        }
    }

    @Test func unrelatedAndPeriodicAudioNeverSeedAMatch() throws {
        let reference = try SyntheticSpeech.track(start: 0, duration: 64, seed: 1)
        let unrelated = try SyntheticSpeech.track(start: 2, duration: 60, seed: 777)
        #expect(try AutomaticAlignment.coarse(reference: reference, target: unrelated, search: SearchRange(maximumDeviationSeconds: 2)).offsetSeconds == nil)
        let samples = (0..<8000 * 12).map { Float(0.2 * sin(2 * .pi * 160 * Double($0) / 8000)) }
        let tone = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(), buffer: try SampleBuffer(samples: samples, sampleRate: 8000))
        #expect(try AutomaticAlignment.coarse(reference: tone, target: tone, search: SearchRange(maximumDeviationSeconds: 2)).offsetSeconds == nil)
        let measurements = try AutomaticAlignment.measure(reference: tone, target: try SyntheticSpeech.track(start: 2, duration: 8, seed: 100), station: 0, predictedOffset: 0, deviation: 1)
        #expect(measurements.allSatisfy { $0.status != "eligible" })
    }

    @Test(arguments: [-1.0, 1.0])
    func processedSpeechWithRumbleAndPolarity(polarity: Double) throws {
        let start = 1200.0, ppm = 480.0, offset = -0.71325
        let predicted = offset + ppm * (start + 2) / 1e6
        let original = try SyntheticSpeech.track(
            start: start, duration: 4, offset: offset, ppm: ppm, processed: true, noiseLevel: 0.002, gain: 0.3
        )
        let samples = original.buffer.samples.enumerated().map { frame, value in
            let time = start + Double(frame) / 8000
            return Float(polarity) * value
                + Float(0.35 * sin(2 * .pi * 60 * time) + 0.2 * sin(2 * .pi * 90 * time))
        }
        let target = EstimatorTrack(
            group: original.group, epoch: original.epoch, occurrence: original.occurrence,
            groupClockStart: original.groupClockStart, buffer: try SampleBuffer(samples: samples, sampleRate: 8000)
        )
        let reference = try SyntheticSpeech.track(start: start + predicted - 0.37, duration: 4.74, sampleRate: 11025)
        let evidence = try AutomaticAlignment.measure(
            reference: reference, target: target, station: 0, predictedOffset: predicted, deviation: 0.35,
            rateRatio: 1 + ppm / 1e6
        )
        print("PROCESSED-SPEECH polarity=\(polarity) observations=\(evidence)")
        let usable = evidence.filter { $0.status == "eligible" }
        #expect(usable.count == 3)
        for point in usable {
            #expect(abs((point.offsetSeconds ?? .infinity) - (offset + ppm * point.targetCenter / 1e6)) < 0.001)
            #expect(point.polarity == Int(polarity))
        }
    }

    @Test(arguments: [-480.0, 480.0])
    func analysisResamplingImprovesLocalMatchWithoutShiftingTheMeasuredCenter(ppm: Double) throws {
        let start = 2300.0, offset = -0.381
        let predicted = offset + ppm * (start + 2) / 1e6
        let target = try SyntheticSpeech.track(start: start, duration: 4, offset: offset, ppm: ppm,
                                              noiseLevel: 0, gain: 0.2)
        let reference = try SyntheticSpeech.track(start: start + predicted - 0.37, duration: 4.74,
                                                 sampleRate: 11025, noiseLevel: 0)
        let uncorrected = try AutomaticAlignment.measure(reference: reference, target: target, station: 0,
                                                        predictedOffset: predicted, deviation: 0.35)
        let corrected = try AutomaticAlignment.measure(reference: reference, target: target, station: 0,
                                                      predictedOffset: predicted, deviation: 0.35, rateRatio: 1 + ppm / 1e6)
        let before = Statistics.median(uncorrected.map(\.nccScore))
        let after = Statistics.median(corrected.map(\.nccScore))
        print("RATE-COMPENSATION ppm=\(ppm) medianNCC=\(before)->\(after)")
        #expect(after > before + 0.1)
        #expect(corrected.allSatisfy { $0.status == "eligible" })
        for point in corrected {
            #expect(abs((point.offsetSeconds ?? .infinity) - (offset + ppm * point.targetCenter / 1e6)) < 0.00025)
        }
        #expect(target.groupClockStart.approximateDouble == start)
        #expect(target.buffer.durationSeconds == 4)
        for invalid in [Double.nan, .infinity, 0, 1.001] {
            #expect(throws: AlignEstimateError.self) {
                try AutomaticAlignment.measure(reference: reference, target: target, station: 0,
                                               predictedOffset: predicted, deviation: 0.35, rateRatio: invalid)
            }
        }
    }

    @Test func processingToleranceStillRefusesUnrelatedPeriodicAndEqualEchoes() throws {
        let rate = 8000
        let reference = try SyntheticSpeech.track(start: 0, duration: 6, seed: 911, noiseLevel: 0)
        let unrelated = try SyntheticSpeech.track(start: 1, duration: 4, seed: 820, processed: true, gain: -0.3)
        let periodic = EstimatorTrack(
            group: reference.group, epoch: reference.epoch, occurrence: reference.occurrence,
            buffer: try SampleBuffer(samples: (0..<rate * 4).map { Float(sin(2 * .pi * 180 * Double($0) / Double(rate))) },
                                     sampleRate: rate)
        )
        let echoed = EstimatorTrack(
            group: reference.group, epoch: reference.epoch, occurrence: reference.occurrence,
            groupClockStart: .one,
            buffer: try SampleBuffer(samples: (0..<rate * 4).map {
                let time = 1 + Double($0) / Double(rate)
                return Float(SyntheticSpeech.value(time, seed: 911) + SyntheticSpeech.value(time + 0.12, seed: 911))
            }, sampleRate: rate)
        )
        for target in [unrelated, echoed] {
            let attempts = try AutomaticAlignment.measure(reference: reference, target: target, station: 0,
                                                         predictedOffset: 0, deviation: 0.35, rateRatio: 1.00048)
            #expect(attempts.allSatisfy { $0.status != "eligible" }, "\(attempts)")
        }
        let attempts = try AutomaticAlignment.measure(reference: periodic, target: periodic, station: 0,
                                                     predictedOffset: 0, deviation: 0.35)
        #expect(attempts.allSatisfy { $0.status != "eligible" })
    }
}
