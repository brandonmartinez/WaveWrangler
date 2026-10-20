import Accelerate
import Foundation
import Testing
import WWAlignEstimate
@testable import WWAutoAlign

@Suite("Recording alignment Double DSP", .serialized)
struct RecordingDSPTests {
    /// Frozen pre-optimization arithmetic, independent of the production correlation helper.
    static func legacyCorrelation(_ x: [Double], _ y: [Double], count: Int, phat: Bool) -> [Double] {
        let forward = vDSP.DFT(count: count, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
        let inverse = vDSP.DFT(count: count, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
        func spectrum(_ samples: [Double]) -> (real: [Double], imaginary: [Double]) {
            let padded = samples + repeatElement(0.0, count: count - samples.count)
            return forward.transform(inputReal: padded, inputImaginary: [Double](repeating: 0, count: count))
        }
        let b = spectrum(y), a = spectrum(x)
        var re = [Double](repeating: 0, count: count), im = re
        let maximumPower = phat ? zip(a.real, a.imaginary).map { $0 * $0 + $1 * $1 }.max() ?? 0 : 0
        let referencePower = phat ? zip(b.real, b.imaginary).map { $0 * $0 + $1 * $1 }.max() ?? 0 : 0
        for k in 0..<count {
            let r = a.real[k] * b.real[k] + a.imaginary[k] * b.imaginary[k]
            let i = a.real[k] * b.imaginary[k] - a.imaginary[k] * b.real[k]
            let power = a.real[k] * a.real[k] + a.imaginary[k] * a.imaginary[k]
            let otherPower = b.real[k] * b.real[k] + b.imaginary[k] * b.imaginary[k]
            let denominator = phat ? max(hypot(r, i), 1e-20) : 1
            let weight = !phat || (power > maximumPower * 1e-5 && otherPower > referencePower * 1e-5) ? 1.0 : 0.0
            re[k] = weight * r / denominator
            im[k] = weight * i / denominator
        }
        return inverse.transform(inputReal: re, inputImaginary: im).real.map { $0 / Double(count) }
    }

    static func legacyTemplate(_ input: [Double], start: Int, count: Int, ratio: Double) throws -> [Double] {
        if ratio == 1 { return Array(input[start..<start + count]) }
        var output = [Double](repeating: 0, count: count)
        for i in output.indices {
            if i.isMultiple(of: 1024) { try Task.checkCancellation() }
            let position = Double(start) + Double(i) / ratio
            let center = Int(floor(position))
            var value = 0.0, weight = 0.0
            for at in max(0, center - 11)...min(input.count - 1, center + 12) {
                let distance = position - Double(at)
                let tap = abs(distance) < 1e-12 ? 1 : sin(.pi * distance) / (.pi * distance)
                    * (0.5 + 0.5 * cos(.pi * distance / 12))
                value += tap * input[at]
                weight += tap
            }
            output[i] = value / weight
        }
        return output
    }

    @Test(arguments: [8192, 32768, 131072], ["scene", "silence", "tone", "differentBands", "inverted", "lowEnergy"])
    func sharedSpectraAreBitwiseEqualToIndependentTransforms(count: Int, kind: String) {
        let x = (0..<count / 4).map { i -> Double in
            switch kind {
            case "silence": return 0
            case "tone": return sin(2 * .pi * Double(i) / 32) + 1e-7 * sin(2 * .pi * Double(i) / 7)
            case "differentBands": return sin(2 * .pi * Double(i) / 32) + 0.001 * sin(2 * .pi * Double(i) / 7)
            case "lowEnergy": return SyntheticSpeech.noise(51, Int64(i)) * 1e-12
            default: return SyntheticSpeech.noise(51, Int64(i))
            }
        }
        var y = [Double](repeating: 0, count: count / 2 + 1)
        let polarity = kind == "inverted" ? -1.0 : 1.0
        for i in x.indices { y[i + 37] = x[i] * polarity * 0.7 }
        if kind == "differentBands" {
            for i in y.indices { y[i] += 30 * sin(2 * .pi * Double(i) / 7) }
        }
        let transform = Transform(atLeast: count)
        let actual = transform.correlations(x, y)
        for phat in [false, true] {
            let expected = Self.legacyCorrelation(x, y, count: count, phat: phat)
            let result = phat ? actual.phat : actual.raw
            #expect(result.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(transform.correlation(x, y, phat: phat).map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(transform.correlation(x, spectrum: transform.spectrum(y), phat: phat).map(\.bitPattern) == expected.map(\.bitPattern))
        }
        if ["scene", "inverted"].contains(kind) {
            let peak = Statistics.peak(Array(actual.raw.prefix(y.count - x.count + 1)).map(abs), exclusion: 20)
            #expect(peak.index == 37)
            #expect((actual.raw[37] > 0 ? 1.0 : -1.0) == polarity)
        }
        let changed = transform.correlations(y, x)
        #expect(changed.raw.map(\.bitPattern) == Self.legacyCorrelation(y, x, count: count, phat: false).map(\.bitPattern))
        #expect(changed.phat.map(\.bitPattern) == Self.legacyCorrelation(y, x, count: count, phat: true).map(\.bitPattern))
    }

    @Test func impulseLagSignAndInverseNormalizationAreUnchanged() {
        let transform = Transform(atLeast: 32)
        var x = [Double](repeating: 0, count: 8), y = [Double](repeating: 0, count: 16)
        x[2] = 2
        y[7] = -3
        let result = transform.correlations(x, y)
        #expect(abs(result.raw[5] + 6) < 1e-14)
        #expect(Statistics.peak(result.raw.map(abs), exclusion: 1).index == 5)
        let reversed = transform.correlations(y, x)
        #expect(Statistics.peak(reversed.raw.map(abs), exclusion: 1).index == 27)
    }

    @Test(arguments: [0.9995, 1.0, 1.0001497245994102, 1.0005, Double(1).nextDown, Double(1).nextUp])
    func sincPreservesTwentyFourTapNormalizationAndClippedEdges(ratio: Double) throws {
        var maximum = 0.0, squaredError = 0.0, samples = 0
        for start in [0, 1, 111, 31_999, 159_999] {
            for count in [1, 32, 2000, 8000] {
                let length = Int(ceil(Double(start) + Double(count - 1) / ratio)) + 1
                let input = (0..<length).map { SyntheticSpeech.noise(990, Int64($0)) }
                let expected = try Self.legacyTemplate(input, start: start, count: count, ratio: ratio)
                let actual = try Signal.template(input, start: start, count: count, rateRatio: ratio)
                for (a, b) in zip(actual, expected) {
                    #expect(a.isFinite)
                    let error = abs(a - b)
                    maximum = max(maximum, error)
                    squaredError += error * error
                    samples += 1
                }
                if ratio == 1 { #expect(actual == Array(input[start..<start + count])) }
                let constant = try Signal.template(Array(repeating: 0.37, count: length),
                    start: start, count: count, rateRatio: ratio)
                #expect(constant.allSatisfy { abs($0 - 0.37) < 1e-14 })
            }
        }
        #expect(maximum < 1e-12)
        print("RECORDING-SINC ratio=\(ratio) maxAbsolute=\(maximum) rms=\(sqrt(squaredError / Double(samples))) samples=\(samples)")
    }

    /// Valid-input replay of the old fine path, including original padding and source-clock arithmetic.
    static func legacyMeasure(
        reference: EstimatorTrack, target: EstimatorTrack, ratio: Double, offset: Double, upper: Bool, seconds: Double
    ) throws -> [DelayEvidence] {
        let r = try Signal(reference.buffer), t = try Signal(target.buffer)
        let rs = try upper ? Signal.upperSpeechBand(r.samples) : Signal.speechBand(r.samples)
        let ts = try upper ? Signal.upperSpeechBand(t.samples) : Signal.speechBand(t.samples)
        let n = Int(seconds * Signal.rate)
        let available = Double(t.samples.count - 1) - 7999 / ratio
        var evidence: [DelayEvidence] = []
        var paddingSizes: Set<Int> = []
        for attempt in 0..<3 {
            let start = Int((floor(available) * Double(attempt) / 2).rounded())
                + Int(((2 - seconds) * Signal.rate / (2 * ratio)).rounded())
            let time = target.groupClockStart.approximateDouble + Double(start) / Signal.rate
            let center = time + seconds / (2 * ratio)
            let expected = (time + offset - reference.groupClockStart.approximateDouble) * Signal.rate
            let lo = max(0, Int(floor(expected - 0.35 * Signal.rate)))
            let hi = min(r.samples.count, Int(ceil(expected + 0.35 * Signal.rate)) + n + 1)
            if hi - lo < n + 3 {
                evidence.append(DelayEvidence(station: 0, attempt: attempt, targetCenter: center, status: "noReference",
                    offsetSeconds: nil, nccScore: 0, nccSecond: 0, phatOffsetSeconds: nil, phatPeakRatio: nil,
                    method: AutomaticAlignment.fineMethod))
                continue
            }
            let x = Statistics.centered(try legacyTemplate(ts, start: start, count: n, ratio: ratio))
            let y = Statistics.centered(Array(rs[lo..<hi]))
            var count = 2
            while count < x.count + y.count { count *= 2 }
            paddingSizes.insert(count)
            let raw = legacyCorrelation(x, y, count: count, phat: false)
            let white = legacyCorrelation(x, y, count: count, phat: true)
            let ex = x.reduce(0) { $0 + $1 * $1 }
            var scores = [Double](repeating: 0, count: y.count - n + 1), sum = 0.0, energy = 0.0
            for k in 0..<n { sum += y[k]; energy += y[k] * y[k] }
            for lag in scores.indices {
                let ey = max(0, energy - sum * sum / Double(n))
                if ex > 1e-12, ey > 1e-12 { scores[lag] = max(-1, min(1, raw[lag] / sqrt(ex * ey))) }
                if lag + n < y.count {
                    sum += y[lag + n] - y[lag]
                    energy += y[lag + n] * y[lag + n] - y[lag] * y[lag]
                }
            }
            let peak = Statistics.peak(scores.map(abs), exclusion: 20)
            let phat = Statistics.peak(white.prefix(scores.count).map(abs), exclusion: 20)
            let polarity = scores[peak.index] >= 0 ? 1 : -1
            let measured = reference.groupClockStart.approximateDouble + (Double(lo) + peak.refined) / Signal.rate
                + seconds / 2 - center
            let phatOffset = reference.groupClockStart.approximateDouble + (Double(lo) + phat.refined) / Signal.rate
                + seconds / 2 - center
            let phatRatio = phat.value > 0 ? phat.second / phat.value : 1
            var status = "eligible"
            if Statistics.rms(Array(t.samples[start..<min(t.samples.count, start + n)])) < 1e-4 {
                let predicted = Int(expected.rounded()) - lo
                status = predicted >= 0 && lo + predicted + n <= r.samples.count
                    && Statistics.rms(Array(r.samples[lo + predicted..<lo + predicted + n])) < 1e-4 ? "sharedSilence" : "silent"
            } else if peak.value < 0.35 { status = "weak" }
            else if peak.second >= 0.8 * peak.value || phatRatio >= 0.8 { status = "ambiguous" }
            else if peak.index == 0 || peak.index + 1 == scores.count || phat.index == 0 || phat.index + 1 == scores.count {
                status = "edgePeak"
            } else if abs(measured - phatOffset) > AutomaticAlignment.fitToleranceSeconds
                || (white[phat.index] >= 0 ? 1 : -1) != polarity { status = "inconsistentMethods" }
            evidence.append(DelayEvidence(station: 0, attempt: attempt, targetCenter: center, status: status,
                offsetSeconds: measured, nccScore: peak.value, nccSecond: peak.second,
                phatOffsetSeconds: phatOffset, phatPeakRatio: phatRatio,
                method: AutomaticAlignment.fineMethod, polarity: polarity))
        }
        if seconds == 2 { #expect(paddingSizes == [16384, 32768]) }
        return evidence
    }

    @Test(arguments: [-480.0, 0, 480.0], [false, true])
    func fineReplayPreservesShortUpperSpeechAndSourceBoundaryEvidence(ppm: Double, upper: Bool) throws {
        let offset = ppm < 0 ? -0.17 : 0.17, ratio = 1 + ppm / 1e6
        let target = try SyntheticSpeech.track(start: 100, duration: 4, offset: offset, ppm: ppm, gain: -0.3)
        let reference = try SyntheticSpeech.track(start: 100 + offset + ppm * 100 / 1e6,
            duration: 3.72, sampleRate: 11025, noiseLevel: 0)
        for seconds in [1.0, 2.0] {
            let actual = try AutomaticAlignment.measure(reference: reference, target: target, station: 0,
                predictedOffset: offset + ppm * 102 / 1e6, deviation: 0.35, rateRatio: ratio, upperSpeech: upper,
                windowSeconds: seconds)
            let expected = try Self.legacyMeasure(reference: reference, target: target, ratio: ratio,
                offset: offset + ppm * 102 / 1e6, upper: upper, seconds: seconds)
            #expect(actual.count == 3 && expected.count == 3)
            for (a, b) in zip(actual, expected) {
                #expect(a.targetCenter == b.targetCenter && a.status == b.status && a.polarity == b.polarity)
                #expect(abs(a.nccScore - b.nccScore) < 1e-12 && abs(a.nccSecond - b.nccSecond) < 1e-12)
                #expect(abs(try #require(a.offsetSeconds) - #require(b.offsetSeconds)) < 1e-9)
                #expect(abs(try #require(a.phatOffsetSeconds) - #require(b.phatOffsetSeconds)) < 1e-9)
                #expect(abs(try #require(a.phatPeakRatio) - #require(b.phatPeakRatio)) < 1e-12)
            }
            if ratio == 1 { #expect(actual == expected) }
        }
        #expect(target.groupClockStart.approximateDouble == 100 && target.buffer.durationSeconds == 4)
    }

    @Test func nonUnitySincRemainsCancellable() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Signal.template(Array(repeating: 0.1, count: 20_000), start: 0, count: 8000, rateRatio: 1.00018)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
