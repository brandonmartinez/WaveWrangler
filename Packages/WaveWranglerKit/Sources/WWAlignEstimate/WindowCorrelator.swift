import Foundation

/// The raw outcome of one window before window-level bookkeeping.
struct WindowObservation: Sendable {
    var status: WindowStatus
    var peakScore: Double = 0
    var secondPeakScore: Double = 0
    var periodicityScore: Double = 0
    /// Aligned (or pseudo-reference clock) time minus target group-clock time, seconds.
    var offsetSeconds: Double?
}

/// Normalised cross-correlation of one target window against a bounded reference search region.
///
/// Both real signals go through ONE complex FFT (target in the real part, reference region in the
/// imaginary part); one inverse FFT then returns the cross-correlation (real part) and the target's
/// self-correlation (imaginary part), used for the periodicity check.
struct WindowCorrelator {
    let parameters: EstimatorParameters
    let windowLength: Int
    let exclusion: Int
    private var ffts: [Int: FFT] = [:]

    init(parameters: EstimatorParameters, windowLength: Int) {
        self.parameters = parameters
        self.windowLength = windowLength
        self.exclusion = max(1, Int((parameters.lobeExclusionMilliseconds / 1000 * parameters.proxyRate).rounded(.up)))
    }

    private mutating func fft(_ size: Int) -> FFT {
        if let cached = ffts[size] { return cached }
        let made = FFT(size: size)
        ffts[size] = made
        return made
    }

    /// - Parameters:
    ///   - targetStart: proxy index of the window's first sample in `target`.
    ///   - targetClockStart / referenceClockStart: clock time of proxy index 0 of each signal, seconds.
    ///   - predictedOffset: centre of the search, reference time minus target time, seconds.
    ///   - deviation: half-width of the search, seconds.
    mutating func observe(target: ProxySignal, targetStart: Int, targetClockStart: Double, reference: ProxySignal, referenceClockStart: Double, predictedOffset: Double, deviation: Double) -> WindowObservation {
        let nw = windowLength
        let rate = parameters.proxyRate
        let floorEnergy = parameters.silenceRMS * parameters.silenceRMS * Double(nw)
        let windowStartTime = targetClockStart + Double(targetStart) / rate
        let centreIndex = (windowStartTime + predictedOffset - referenceClockStart) * rate
        let span = (deviation * rate).rounded(.up)
        guard centreIndex.isFinite, abs(centreIndex) < 1e12 else { return WindowObservation(status: .noReference) }
        let lo = max(0, Int((centreIndex - span).rounded(.down)))
        let hi = min(reference.samples.count, Int((centreIndex + span).rounded(.up)) + nw + 1)
        guard hi - lo >= nw + 2 else { return WindowObservation(status: .noReference) }
        let targetRange = targetStart..<(targetStart + nw)
        if target.centredRMS(targetRange) < parameters.silenceRMS || reference.centredRMS(lo..<hi) < parameters.silenceRMS {
            return WindowObservation(status: .silent)
        }

        let m = hi - lo
        let size = FFT.size(atLeast: max(m, 2 * nw))
        let transform = fft(size)
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        // Pearson correlation: centring the target alone makes the numerator invariant to the reference's
        // local mean (sum of x' is zero), and the denominators below use centred energies.
        let targetMean = target.mean(targetRange)
        for n in 0..<nw { re[n] = target.samples[targetStart + n] - targetMean }
        for n in 0..<m { im[n] = reference.samples[lo + n] }
        transform.transform(&re, &im, inverse: false)
        // Split: X = (F[k] + conj F[N-k]) / 2, Y = (F[k] - conj F[N-k]) / 2i.
        // Cross = conj(X) * Y (correlation of y against x); Auto = |X|^2. Pack Cross + i*Auto for one inverse.
        var outRe = [Double](repeating: 0, count: size)
        var outIm = [Double](repeating: 0, count: size)
        for k in 0..<size {
            let j = k == 0 ? 0 : size - k
            let xr = 0.5 * (re[k] + re[j]), xi = 0.5 * (im[k] - im[j])
            let yr = 0.5 * (im[k] + im[j]), yi = -0.5 * (re[k] - re[j])
            let cr = xr * yr + xi * yi, ci = xr * yi - xi * yr
            let auto = xr * xr + xi * xi
            outRe[k] = cr
            outIm[k] = ci + auto
        }
        transform.transform(&outRe, &outIm, inverse: true)

        let targetEnergy = target.centredEnergy(targetRange)
        let lagCount = m - nw + 1
        var ncc = [Double](repeating: 0, count: lagCount)
        for lag in 0..<lagCount {
            let ey = reference.centredEnergy((lo + lag)..<(lo + lag + nw))
            ncc[lag] = ey < floorEnergy ? 0 : outRe[lag] / (targetEnergy * ey).squareRoot()
        }
        var best = 0
        for lag in 1..<lagCount where ncc[lag] > ncc[best] { best = lag }
        var second = 0.0
        for lag in 0..<lagCount where abs(lag - best) > exclusion {
            let left = lag > 0 ? ncc[lag - 1] : -.infinity
            let right = lag + 1 < lagCount ? ncc[lag + 1] : -.infinity
            if ncc[lag] >= left && ncc[lag] >= right { second = max(second, ncc[lag]) }
        }
        var periodicity = 0.0
        if exclusion <= nw / 2 {
            for shift in exclusion...(nw / 2) {
                let e0 = target.energy(targetStart..<(targetStart + nw - shift), about: targetMean)
                let e1 = target.energy((targetStart + shift)..<(targetStart + nw), about: targetMean)
                guard e0 >= floorEnergy * 0.5, e1 >= floorEnergy * 0.5 else { continue }
                periodicity = max(periodicity, outIm[shift] / (e0 * e1).squareRoot())
            }
        }

        var refined = Double(best)
        if best > 0 && best < lagCount - 1 {
            let a = ncc[best - 1], b = ncc[best], c = ncc[best + 1]
            let denominator = a - 2 * b + c
            if denominator < 0 { refined += max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        let offset = referenceClockStart + (Double(lo) + refined) / rate - windowStartTime
        var observation = WindowObservation(status: .eligible, peakScore: ncc[best], secondPeakScore: second, periodicityScore: periodicity, offsetSeconds: offset)
        if periodicity >= parameters.periodicityThreshold {
            observation.status = .periodic
        } else if ncc[best] < parameters.minimumPeakScore {
            observation.status = .weak
        } else if second >= parameters.ambiguityRatio * ncc[best] {
            observation.status = .ambiguous
        } else if best == 0 || best == lagCount - 1 {
            observation.status = .edgePeak
        }
        return observation
    }
}
