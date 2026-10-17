import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAutoAlign

/// Diagnostic only: independent half-second waveform searches, never accepted timing evidence.
enum LocalizedTimingProbe {
    static let method = "diagnostic-local-.5s-ncc-phat/1"
    static let upperMethod = "diagnostic-upper-speech-.5s-ncc-phat/1"
    static let seconds = 0.5

    static func measureUpperSpeech(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int, predictedOffset: Double
    ) throws -> [DelayEvidence] {
        try AdaptiveAlignment.measureBand(reference: reference, target: target, station: station,
            predictedOffset: predictedOffset, deviation: 0.35, rateRatio: 1, upperSpeech: true).map {
                DelayEvidence(station: $0.station, attempt: $0.attempt, targetCenter: $0.targetCenter,
                    status: $0.status, offsetSeconds: $0.offsetSeconds, nccScore: $0.nccScore,
                    nccSecond: $0.nccSecond, phatOffsetSeconds: $0.phatOffsetSeconds,
                    phatPeakRatio: $0.phatPeakRatio, method: "diagnostic-upper-speech/" + $0.method,
                    polarity: $0.polarity, corroborations: $0.corroborations)
            }
    }

    static func measure(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int, predictedOffset: Double,
        upperSpeech: Bool = false
    ) throws -> [DelayEvidence] {
        guard target.buffer.durationSeconds <= 4.01, reference.buffer.durationSeconds <= 5,
              predictedOffset.isFinite, (0..<16).contains(station) else {
            throw AlignEstimateError.invalidParameter("localized diagnostic exceeds bounded buffers")
        }
        func filtered(_ buffer: SampleBuffer) throws -> [Double] {
            let samples = try Signal(buffer).samples
            return try upperSpeech ? Signal.upperSpeechBand(samples) : Signal.speechBand(samples)
        }
        let method = upperSpeech ? upperMethod : method
        let r = try filtered(reference.buffer)
        let t = try filtered(target.buffer)
        let n = Int(seconds * Signal.rate)
        return try [0.5, 1.25, 2, 2.75].enumerated().compactMap { attempt, center in
            try Task.checkCancellation()
            let at = Int(((center - seconds / 2) * Signal.rate).rounded())
            guard at >= 0, at + n <= t.count else { return nil }
            let time = target.groupClockStart.approximateDouble + Double(at) / Signal.rate
            let expected = (time + predictedOffset - reference.groupClockStart.approximateDouble) * Signal.rate
            guard expected.isFinite, abs(expected) < 1e12 else {
                throw AlignEstimateError.invalidParameter("localized diagnostic search coordinate")
            }
            let lo = max(0, Int(floor(expected - 0.35 * Signal.rate)))
            let hi = min(r.count, Int(ceil(expected + 0.35 * Signal.rate)) + n + 1)
            guard hi - lo >= n + 3 else {
                return DelayEvidence(station: station, attempt: attempt, targetCenter: time + seconds / 2,
                    status: "noReference", offsetSeconds: nil, nccScore: 0, nccSecond: 0,
                    phatOffsetSeconds: nil, phatPeakRatio: nil, method: method)
            }
            let x = Statistics.centered(Array(t[at..<at + n]))
            let y = Statistics.centered(Array(r[lo..<hi]))
            let transform = Transform(atLeast: x.count + y.count)
            let raw = transform.correlation(x, y)
            let white = transform.correlation(x, y, phat: true)
            let ex = x.reduce(0) { $0 + $1 * $1 }
            var sum = y.prefix(n).reduce(0, +)
            var energy = y.prefix(n).reduce(0) { $0 + $1 * $1 }
            var scores = [Double](repeating: 0, count: y.count - n + 1)
            for lag in scores.indices {
                let ey = max(0, energy - sum * sum / Double(n))
                if ex > 1e-12, ey > 1e-12 {
                    scores[lag] = max(-1, min(1, raw[lag] / sqrt(ex * ey)))
                }
                if lag + n < y.count {
                    sum += y[lag + n] - y[lag]
                    energy += y[lag + n] * y[lag + n] - y[lag] * y[lag]
                }
            }

            let peak = Statistics.peak(scores.map(abs), exclusion: 20)
            let phat = Statistics.peak(white.prefix(scores.count).map(abs), exclusion: 20)
            let offset = reference.groupClockStart.approximateDouble
                + (Double(lo) + peak.refined) / Signal.rate - time
            let phatOffset = reference.groupClockStart.approximateDouble
                + (Double(lo) + phat.refined) / Signal.rate - time
            let phatRatio = phat.value > 0 ? phat.second / phat.value : 1
            let polarity = scores[peak.index] >= 0 ? 1 : -1
            var status = "eligible"
            if Statistics.rms(x) < 1e-4 { status = "silent" }
            else if peak.value < 0.6 { status = "weak" }
            else if peak.second >= 0.8 * peak.value || phatRatio >= 0.8 { status = "ambiguous" }
            else if peak.index == 0 || peak.index + 1 == scores.count
                || phat.index == 0 || phat.index + 1 == scores.count { status = "edgePeak" }
            else if abs(offset - phatOffset) > 0.001
                || (white[phat.index] >= 0 ? 1 : -1) != polarity { status = "inconsistentMethods" }
            return DelayEvidence(station: station, attempt: attempt, targetCenter: time + seconds / 2,
                status: status, offsetSeconds: offset, nccScore: peak.value, nccSecond: peak.second,
                phatOffsetSeconds: phatOffset, phatPeakRatio: phatRatio, method: method, polarity: polarity)
        }
    }
}

@Suite("Diagnostic localized waveform controls")
struct LocalizedTimingProbeTests {
    private func track(
        start: Double, offset: Double = 0, seed: UInt64 = 193, tone: Bool = false,
        silent: Bool = false, stepAt: Double? = nil, gain: Double = 1
    ) throws -> EstimatorTrack {
        func hash(_ index: Int64) -> Double {
            var value = UInt64(bitPattern: index) &+ seed
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return Double((value ^ (value >> 31)) >> 11) / 4_503_599_627_370_496 - 1
        }
        let samples = (0..<32000).map { index -> Float in
            let source = start + Double(index) / 8000
            let time = source + offset + (stepAt.map { source >= $0 ? 0.02 : 0 } ?? 0)
            let position = time * 2000, lower = floor(position), fraction = position - lower
            let noise = hash(Int64(lower)) * (1 - fraction) + hash(Int64(lower) + 1) * fraction
            return silent ? 0 : Float(gain * (tone ? sin(2 * .pi * 220 * time) : noise) * 0.2)
        }
        return try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
            occurrence: SourceOccurrenceID(),
            groupClockStart: ExactRational(Int64((start * 1e6).rounded()), 1_000_000),
            buffer: SampleBuffer(samples: samples, sampleRate: 8000))
    }

    @Test func freshSearchesRecoverKnownOffsetsAndPolarityWithoutPromotingOldWindows() throws {
        for (gain, upper) in [(0.25, false), (-0.25, false), (0.25, true), (-0.25, true)] {
            let reference = try track(start: 100)
            let target = try track(start: 100.5, offset: -0.17, gain: gain)
            let points = try LocalizedTimingProbe.measure(reference: reference, target: target,
                station: 0, predictedOffset: -0.17, upperSpeech: upper)
            #expect(points.count == 4)
            #expect(points.allSatisfy {
                $0.status == "eligible"
                    && $0.method == (upper ? LocalizedTimingProbe.upperMethod : LocalizedTimingProbe.method)
            })
            for point in points {
                #expect(abs(try #require(point.offsetSeconds) + 0.17) < 0.001)
                #expect(point.polarity == (gain > 0 ? 1 : -1))
                #expect(point.corroborations == nil)
            }
            #expect(zip(points, points.dropFirst()).allSatisfy {
                $1.targetCenter - $0.targetCenter > LocalizedTimingProbe.seconds / (1 - 500e-6)
            })
        }
    }

    @Test func periodicUnrelatedSilentAndSteppedWindowsCannotSupplyFalseTiming() throws {
        for upper in [false, true] {
            let reference = try track(start: 100)
            for target in [try track(start: 100.5, seed: 881), try track(start: 100.5, silent: true)] {
                #expect(try LocalizedTimingProbe.measure(reference: reference, target: target,
                    station: 0, predictedOffset: -0.17, upperSpeech: upper).allSatisfy { $0.status != "eligible" })
            }
            #expect(try LocalizedTimingProbe.measure(reference: track(start: 100, tone: true),
                target: track(start: 100.5, offset: -0.17, tone: true),
                station: 0, predictedOffset: -0.17, upperSpeech: upper).allSatisfy { $0.status != "eligible" })
            let points = try LocalizedTimingProbe.measure(reference: reference,
                target: track(start: 100.5, offset: -0.17, stepAt: 101.75),
                station: 0, predictedOffset: -0.17, upperSpeech: upper)
            #expect(points.contains { abs($0.targetCenter - 101.75) < 0.001 })
            #expect(points.filter { abs($0.targetCenter - 101.75) < 0.001 }.allSatisfy { $0.status != "eligible" })
            #expect(points.filter { $0.status == "eligible" }.allSatisfy {
                abs(($0.offsetSeconds ?? .infinity) - ($0.targetCenter < 101.75 ? -0.17 : -0.15)) < 0.001
            })
        }
    }
}
