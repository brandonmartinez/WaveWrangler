import Foundation

// Deterministic, dependency-free signal primitives (no Accelerate, no shared mutable state).

/// Iterative radix-2 complex FFT of a fixed power-of-two size.
struct FFT: Sendable {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitReversed: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var cosTable = [Double](repeating: 0, count: size / 2)
        var sinTable = [Double](repeating: 0, count: size / 2)
        for k in 0..<(size / 2) {
            let angle = 2 * Double.pi * Double(k) / Double(size)
            cosTable[k] = cos(angle)
            sinTable[k] = sin(angle)
        }
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        var bitReversed = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
            bitReversed[i] = r
        }
        self.cosTable = cosTable
        self.sinTable = sinTable
        self.bitReversed = bitReversed
    }

    /// In-place transform. `inverse` uses e^{+i...} and scales by 1/size.
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        precondition(re.count == size && im.count == size)
        let n = size
        let sign: Double = inverse ? 1 : -1
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { m in
                cosTable.withUnsafeBufferPointer { ct in
                    sinTable.withUnsafeBufferPointer { st in
                        bitReversed.withUnsafeBufferPointer { br in
                            for i in 0..<n {
                                let j = br[i]
                                if i < j {
                                    let tr = r[i]; r[i] = r[j]; r[j] = tr
                                    let ti = m[i]; m[i] = m[j]; m[j] = ti
                                }
                            }
                            var length = 2
                            while length <= n {
                                let half = length / 2
                                let step = n / length
                                var start = 0
                                while start < n {
                                    var k = 0
                                    while k < half {
                                        let wr = ct[k * step]
                                        let wi = sign * st[k * step]
                                        let a = start + k, b = a + half
                                        let xr = r[b] * wr - m[b] * wi
                                        let xi = r[b] * wi + m[b] * wr
                                        r[b] = r[a] - xr; m[b] = m[a] - xi
                                        r[a] += xr; m[a] += xi
                                        k += 1
                                    }
                                    start += length
                                }
                                length <<= 1
                            }
                            if inverse {
                                let scale = 1 / Double(n)
                                for i in 0..<n { r[i] *= scale; m[i] *= scale }
                            }
                        }
                    }
                }
            }
        }
    }

    static func size(atLeast n: Int) -> Int {
        var size = 2
        while size < n { size <<= 1 }
        return size
    }
}

/// A track resampled to the common proxy rate: low-passed, integer-decimated, then cubic-interpolated onto
/// the exact proxy grid (sample k at `k / proxyRate` seconds after the track's sample 0). The global mean is
/// removed only to keep the prefix sums well conditioned; every window statistic is centred on the window's
/// own mean, so a DC bias (or the residue of the global mean in a silent span) is never mistaken for signal.
struct ProxySignal: Sendable {
    let samples: [Double]
    let rate: Double
    /// Prefix sums of squares: energy[i] = sum of samples[0..<i]^2.
    let energy: [Double]
    /// Prefix sums: sums[i] = sum of samples[0..<i].
    let sums: [Double]

    init(buffer: SampleBuffer, parameters: EstimatorParameters) {
        let inputRate = Double(buffer.sampleRate)
        let proxyRate = parameters.proxyRate
        // Integer decimation to an intermediate rate of at least 2x proxy, so the cubic step is accurate.
        let decimation = max(1, Int((inputRate / (2 * proxyRate)).rounded(.down)))
        let intermediateRate = inputRate / Double(decimation)
        let cutoff = parameters.proxyCutoffFraction * proxyRate / inputRate // cycles per input sample
        let halfTaps = max(8, 6 * decimation)
        var taps = [Double](repeating: 0, count: 2 * halfTaps + 1)
        var tapSum = 0.0
        for m in 0...(2 * halfTaps) {
            let x = Double(m - halfTaps)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let hann = 0.5 + 0.5 * cos(Double.pi * x / Double(halfTaps + 1))
            taps[m] = sinc * hann
            tapSum += taps[m]
        }
        for m in taps.indices { taps[m] /= tapSum }

        let input = buffer.samples
        let intermediateCount = (input.count + decimation - 1) / decimation
        var intermediate = [Double](repeating: 0, count: intermediateCount)
        input.withUnsafeBufferPointer { x in
            taps.withUnsafeBufferPointer { h in
                intermediate.withUnsafeMutableBufferPointer { y in
                    // Edge samples are extended (clamped), not zero-padded: zero padding would invent a step at
                    // each buffer end, and two invented steps correlate with each other.
                    let last = x.count - 1
                    for k in 0..<intermediateCount {
                        let center = k * decimation
                        var acc = 0.0
                        if center >= halfTaps && center + halfTaps <= last {
                            for m in 0...(2 * halfTaps) { acc += h[m] * Double(x[center + m - halfTaps]) }
                        } else {
                            for m in 0...(2 * halfTaps) { acc += h[m] * Double(x[min(max(center + m - halfTaps, 0), last)]) }
                        }
                        y[k] = acc
                    }
                }
            }
        }

        let ratio = intermediateRate / proxyRate // intermediate samples per proxy sample, >= 2
        let proxyCount = max(0, Int((Double(intermediateCount - 1) / ratio).rounded(.down)) + 1)
        var proxy = [Double](repeating: 0, count: proxyCount)
        intermediate.withUnsafeBufferPointer { y in
            for k in 0..<proxyCount {
                let position = Double(k) * ratio
                let i = Int(position.rounded(.down))
                let f = position - Double(i)
                func at(_ j: Int) -> Double { y[min(max(j, 0), y.count - 1)] }
                if f == 0 { proxy[k] = at(i); continue }
                // Catmull-Rom cubic.
                let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
                proxy[k] = p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
            }
        }
        if !proxy.isEmpty {
            let mean = proxy.reduce(0, +) / Double(proxy.count)
            for k in proxy.indices { proxy[k] -= mean }
        }
        var energy = [Double](repeating: 0, count: proxy.count + 1)
        var sums = [Double](repeating: 0, count: proxy.count + 1)
        for k in proxy.indices {
            energy[k + 1] = energy[k] + proxy[k] * proxy[k]
            sums[k + 1] = sums[k] + proxy[k]
        }
        self.samples = proxy
        self.rate = proxyRate
        self.energy = energy
        self.sums = sums
    }

    func mean(_ range: Range<Int>) -> Double {
        range.isEmpty ? 0 : (sums[range.upperBound] - sums[range.lowerBound]) / Double(range.count)
    }

    /// Sum over `range` of (sample - centre)^2.
    func energy(_ range: Range<Int>, about centre: Double) -> Double {
        let e = energy[range.upperBound] - energy[range.lowerBound]
        let s = sums[range.upperBound] - sums[range.lowerBound]
        return max(0, e - 2 * centre * s + Double(range.count) * centre * centre)
    }

    /// Energy about the range's own mean (n x variance).
    func centredEnergy(_ range: Range<Int>) -> Double { energy(range, about: mean(range)) }

    /// Standard deviation over `range`: the RMS of the range with its own mean removed.
    func centredRMS(_ range: Range<Int>) -> Double {
        range.isEmpty ? 0 : (centredEnergy(range) / Double(range.count)).squareRoot()
    }
}

enum Stats {
    /// Nearest-rank percentile (rank = ceil(p * n), 1-based) of `values`; 0 for an empty array.
    static func nearestRank(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }
}
