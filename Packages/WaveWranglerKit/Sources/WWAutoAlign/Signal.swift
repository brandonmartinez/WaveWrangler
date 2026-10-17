import Accelerate
import Foundation
import WWAlignEstimate

struct Transform {
    let count: Int
    private let forward: vDSP.DFT<Double>
    private let inverse: vDSP.DFT<Double>

    init(atLeast minimum: Int) {
        var n = 2
        while n < minimum { n *= 2 }
        count = n
        forward = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
        inverse = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
    }

    func spectrum(_ samples: [Double]) -> (real: [Double], imaginary: [Double]) {
        var input = samples
        input += repeatElement(0, count: count - input.count)
        return forward.transform(inputReal: input, inputImaginary: [Double](repeating: 0, count: count))
    }

    func correlation(_ x: [Double], _ y: [Double], phat: Bool = false) -> [Double] {
        correlation(x, spectrum: spectrum(y), phat: phat)
    }

    func correlation(_ x: [Double], spectrum b: (real: [Double], imaginary: [Double]), phat: Bool = false) -> [Double] {
        let a = spectrum(x)
        var re = [Double](repeating: 0, count: count), im = re
        let maximumPower = phat ? zip(a.real, a.imaginary).map { $0 * $0 + $1 * $1 }.max() ?? 0 : 0
        let referencePower = phat ? zip(b.real, b.imaginary).map { $0 * $0 + $1 * $1 }.max() ?? 0 : 0
        for k in 0..<count {
            let r = a.real[k] * b.real[k] + a.imaginary[k] * b.imaginary[k]
            let i = a.real[k] * b.imaginary[k] - a.imaginary[k] * b.real[k]
            // Do not amplify bins with negligible target energy into noise evidence.
            let power = a.real[k] * a.real[k] + a.imaginary[k] * a.imaginary[k]
            let otherPower = b.real[k] * b.real[k] + b.imaginary[k] * b.imaginary[k]
            let denominator = phat ? max(hypot(r, i), 1e-20) : 1
            let weight = !phat || (power > maximumPower * 1e-5 && otherPower > referencePower * 1e-5) ? 1.0 : 0.0
            re[k] = weight * r / denominator
            im[k] = weight * i / denominator
        }
        let result = inverse.transform(inputReal: re, inputImaginary: im)
        return result.real.map { $0 / Double(count) }
    }
}

struct Signal {
    static let rate = 4000.0
    let samples: [Double]

    init(_ buffer: SampleBuffer) throws {
        let ratio = Double(buffer.sampleRate) / Self.rate
        let radius = max(8, Int(ceil(4 * ratio)))
        let cutoff = 1800 / Double(buffer.sampleRate)
        let taps = (-radius...radius).map { i -> Double in
            let x = Double(i)
            let sinc = i == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return sinc * (0.5 + 0.5 * cos(.pi * x / Double(radius + 1)))
        }
        let sum = taps.reduce(0, +)
        var output = [Double](repeating: 0, count: Int(Double(buffer.samples.count - 1) / ratio) + 1)
        for k in output.indices {
            if k % 4096 == 0 { try Task.checkCancellation() }
            let position = Double(k) * ratio
            let at = Int(position), fraction = position - Double(at)
            var value = 0.0
            for i in -radius...radius {
                let a = min(max(at + i, 0), buffer.samples.count - 1)
                let b = min(a + 1, buffer.samples.count - 1)
                value += taps[i + radius] * (Double(buffer.samples[a]) * (1 - fraction) + Double(buffer.samples[b]) * fraction)
            }
            output[k] = value / sum
        }
        samples = output
    }

    /// Forward/backward high-pass removes recorder rumble without adding a timing/phase shift.
    static func speechBand(_ input: [Double]) throws -> [Double] {
        try highPass(input, hertz: 150)
    }

    static func upperSpeechBand(_ input: [Double]) throws -> [Double] {
        try highPass(speechBand(input), hertz: 600)
    }

    private static func highPass(_ input: [Double], hertz: Double) throws -> [Double] {
        let k = tan(.pi * hertz / rate)
        let norm = 1 / (1 + sqrt(2) * k + k * k)
        let a1 = 2 * (k * k - 1) * norm, a2 = (1 - sqrt(2) * k + k * k) * norm
        var output = input
        for reverse in [false, true] {
            var x1 = reverse ? output.last ?? 0 : output.first ?? 0
            var x2 = x1, y1 = 0.0, y2 = 0.0
            for step in output.indices {
                if step.isMultiple(of: 4096) { try Task.checkCancellation() }
                let i = reverse ? output.count - 1 - step : step
                let x = output[i]
                let y = norm * (x - 2 * x1 + x2) - a1 * y1 - a2 * y2
                output[i] = y
                x2 = x1; x1 = x; y2 = y1; y1 = y
            }
        }
        return output
    }

    /// Analysis-only resampling onto the reference clock; the original buffers and their coordinates stay intact.
    static func template(_ input: [Double], start: Int, count: Int, rateRatio: Double) throws -> [Double] {
        if rateRatio == 1 { return Array(input[start..<start + count]) }
        let radius = 12
        var output = [Double](repeating: 0, count: count)
        for i in output.indices {
            if i.isMultiple(of: 1024) { try Task.checkCancellation() }
            let position = Double(start) + Double(i) / rateRatio
            let center = Int(floor(position))
            var value = 0.0, weight = 0.0
            for at in max(0, center - radius + 1)...min(input.count - 1, center + radius) {
                let distance = position - Double(at)
                let tap = abs(distance) < 1e-12 ? 1 : sin(.pi * distance) / (.pi * distance)
                    * (0.5 + 0.5 * cos(.pi * distance / Double(radius)))
                value += tap * input[at]
                weight += tap
            }
            output[i] = value / weight
        }
        return output
    }

    /// Six log-power bands, 40 ms frames on a 20 ms grid. Each band's standardization removes constant EQ
    /// and gain differences. These are coarse search features, never final timing measurements.
    func features() throws -> [[Double]] {
        let bounds = [100.0, 220, 400, 650, 950, 1350, 1800]
        let transform = Transform(atLeast: 256)
        let n = samples.count >= 160 ? (samples.count - 160) / 80 + 1 : 0
        var bands = [[Double]](repeating: [], count: 6)
        for frame in 0..<n {
            if frame % 256 == 0 { try Task.checkCancellation() }
            let start = frame * 80
            let window = (0..<160).map { samples[start + $0] * (0.5 - 0.5 * cos(2 * .pi * Double($0) / 159)) }
            let spectrum = transform.spectrum(window)
            for band in 0..<6 {
                let lo = Int(ceil(bounds[band] * 256 / Self.rate))
                let hi = Int(ceil(bounds[band + 1] * 256 / Self.rate))
                var power = 0.0
                for k in lo..<hi { power += spectrum.real[k] * spectrum.real[k] + spectrum.imaginary[k] * spectrum.imaginary[k] }
                bands[band].append(log(1e-10 + power))
            }
        }
        // Common log energy mostly describes loudness and pauses, which can repeat independently of
        // speech identity. Retain spectral shape rather than allowing that shared envelope to dominate.
        for frame in 0..<n {
            let common = bands.reduce(0) { $0 + $1[frame] } / 6
            for band in 0..<6 { bands[band][frame] -= common }
        }
        return bands.map { band in
            guard !band.isEmpty else { return band }
            let mean = band.reduce(0, +) / Double(band.count)
            let rms = sqrt(band.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(band.count))
            return band.map { ($0 - mean) / max(rms, 1e-6) }
        }
    }
}

enum Statistics {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func centered(_ x: [Double]) -> [Double] {
        let mean = x.reduce(0, +) / Double(max(1, x.count))
        return x.map { $0 - mean }
    }

    static func rms(_ x: [Double]) -> Double {
        sqrt(centered(x).reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count)))
    }

    static func peak(_ values: [Double], exclusion: Int) -> (index: Int, value: Double, second: Double, refined: Double) {
        let best = values.indices.max { values[$0] < values[$1] } ?? 0
        var second = 0.0, refined = Double(best)
        for k in values.indices where abs(k - best) > exclusion {
            if (k == 0 || values[k] >= values[k - 1]) && (k + 1 == values.count || values[k] >= values[k + 1]) {
                second = max(second, values[k])
            }
        }
        if best > 0, best + 1 < values.count {
            let a = values[best - 1], b = values[best], c = values[best + 1]
            if a - 2 * b + c < 0 { refined += max(-0.5, min(0.5, 0.5 * (a - c) / (a - 2 * b + c))) }
        }
        return (best, values.isEmpty ? 0 : values[best], second, refined)
    }
}
