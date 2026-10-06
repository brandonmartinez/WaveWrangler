import Foundation
import Testing
@testable import WWRender

/// Design checks of the candidate kernel prototype itself (not the gates: those are measured end to end
/// in RenderCalibrationTests).
@Suite("Kaiser-sinc kernel")
struct KernelTests {
    static let kernel = KaiserSincKernel(RenderRecipe.m2Candidate.kernel)

    /// Continuous-time frequency response of the prototype (f in cycles per lower-rate sample), by a
    /// dense Riemann sum over the even prototype.
    static func response(_ f: Double, step: Int = 8) -> Double {
        let p = Double(kernel.phasesPerSample)
        var sum = kernel.table[0]
        var j = step
        while j < kernel.halfWidth * kernel.phasesPerSample {
            sum += 2 * kernel.table[j] * cos(2 * .pi * f * Double(j) / p)
            j += step
        }
        return sum * Double(step) / p
    }

    static func dB(_ x: Double) -> Double { 20 * log10(abs(x)) }

    @Test func besselAndSincAreCorrect() {
        #expect(KaiserSincKernel.besselI0(0) == 1)
        #expect(abs(KaiserSincKernel.besselI0(1) - 1.266065877752008) < 1e-14)
        #expect(abs(KaiserSincKernel.besselI0(10) - 2815.716628466254) / 2815.716628466254 < 1e-12)
        #expect(KaiserSincKernel.sinc(0) == 1)
        #expect(abs(KaiserSincKernel.sinc(0.5) - 2 / Double.pi) < 1e-15)
    }

    @Test func prototypePassbandIsFlat() {
        var worst = 0.0
        for i in 0 ... 80 {
            let f = 0.4 * Double(i) / 80
            worst = max(worst, abs(Self.dB(Self.response(f))))
        }
        #expect(worst <= 0.01, "passband deviation \(worst) dB")
    }

    @Test func prototypeStopbandIsDeep() {
        var worst = -400.0
        for i in 0 ... 700 {
            let f = 0.5 + 3.5 * Double(i) / 700
            worst = max(worst, Self.dB(Self.response(f)))
        }
        #expect(worst <= -90, "stopband peak \(worst) dB")
    }

    /// Tap weights at every phase sum to one, and are symmetric about the source position.
    @Test func tapWeightsAreNormalizedAndSymmetric() {
        var w = [Double](repeating: 0, count: 64)
        var mirror = [Double](repeating: 0, count: 64)
        for i in 0 ..< 16 {
            let fraction = Double(i) / 16
            Self.kernel.weights(fraction: fraction, scale: 1, halfTaps: 32, into: &w)
            #expect(abs(w.reduce(0, +) - 1) < 1e-12)
            if fraction > 0 {
                Self.kernel.weights(fraction: 1 - fraction, scale: 1, halfTaps: 32, into: &mirror)
                // Tap t sits at tau = f + 31 - t; tap 63 - t of the mirrored phase sits at -tau.
                for t in 0 ..< 64 { #expect(abs(w[t] - mirror[63 - t]) < 1e-12) }
            }
        }
    }
}
