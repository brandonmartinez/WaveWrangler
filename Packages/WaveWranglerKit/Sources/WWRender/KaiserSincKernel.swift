import Foundation

/// The tabulated Kaiser-windowed sinc prototype of a ``KaiserSincKernelSpec``.
///
/// `h(v) = 2 fc sinc(2 fc v) * I0(beta * sqrt(1 - (v/H)^2)) / I0(beta)` for `|v| < H` (lower-rate samples),
/// zero outside. Self-written from the textbook definitions (no third-party code).
struct KaiserSincKernel: Sendable {
    let halfWidth: Int
    let phasesPerSample: Int
    /// `h(j / phasesPerSample)` for `j = 0 ... halfWidth * phasesPerSample + 1` (the last two are 0).
    let table: [Double]

    init(_ spec: KaiserSincKernelSpec) {
        halfWidth = spec.halfWidth
        phasesPerSample = spec.tablePhasesPerSample
        let fc = spec.cutoffCyclesPerSample
        let h = Double(spec.halfWidth)
        let i0Beta = Self.besselI0(spec.kaiserBeta)
        let count = spec.halfWidth * spec.tablePhasesPerSample
        var table = [Double](repeating: 0, count: count + 2)
        for j in 0 ..< count {
            let v = Double(j) / Double(spec.tablePhasesPerSample)
            let r = v / h
            let window = Self.besselI0(spec.kaiserBeta * (1 - r * r).squareRoot()) / i0Beta
            table[j] = 2 * fc * Self.sinc(2 * fc * v) * window
        }
        self.table = table
    }

    /// The prototype at `|v|` (lower-rate samples), linearly interpolated from the table.
    @inline(__always)
    func value(atMagnitude v: Double) -> Double {
        let scaled = v * Double(phasesPerSample)
        let index = Int(scaled)
        guard index < halfWidth * phasesPerSample else { return 0 }
        let fraction = scaled - Double(index)
        return table[index] + fraction * (table[index + 1] - table[index])
    }

    /// Fills `weights[t]` for taps `m = i - halfTaps + 1 + t` around source position `i + fraction`,
    /// scaled by `scale` (min(1, output/input rate)) and normalized to unit sum (unit DC gain).
    func weights(fraction: Double, scale: Double, halfTaps: Int, into weights: inout [Double]) {
        var sum = 0.0
        weights.withUnsafeMutableBufferPointer { w in
            for t in 0 ..< 2 * halfTaps {
                let tau = fraction + Double(halfTaps - 1 - t)
                let value = scale * self.value(atMagnitude: abs(tau) * scale)
                w[t] = value
                sum += value
            }
            let inverse = 1 / sum
            for t in 0 ..< 2 * halfTaps { w[t] *= inverse }
        }
    }

    static func sinc(_ x: Double) -> Double {
        x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
    }

    /// Modified Bessel function of the first kind, order 0, by its power series (converges for all x).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let quarterSquare = x * x / 4
        var k = 1.0
        while true {
            term *= quarterSquare / (k * k)
            sum += term
            if term < sum * 1e-17 { break }
            k += 1
        }
        return sum
    }
}
