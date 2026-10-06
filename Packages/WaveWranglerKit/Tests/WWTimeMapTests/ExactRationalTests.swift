import Foundation
import Testing
@testable import WWTimeMap

@Suite("ExactRational")
struct ExactRationalTests {
    @Test func valuesAreCanonical() throws {
        #expect(q(2, 4) == q(1, 2))
        #expect(q(1, -2) == q(-1, 2))
        #expect(q(1, -2).denominator == 2)
        #expect(q(0, -7) == .zero)
        #expect(throws: TimeMapError.zeroDenominator) { try ExactRational(1, 0) }
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try ExactRational(numerator: .min, denominator: 1) }
    }

    /// Arithmetic agrees with raw cross-multiplication on values whose products fit (seeded).
    @Test func arithmeticMatchesCrossMultiplication() throws {
        var rng = SplitMix64(seed: 15)
        for _ in 0..<20_000 {
            let an = Int128(rng.int(-1_000_000...1_000_000)), ad = Int128(rng.int(1...1_000_000))
            let bn = Int128(rng.int(-1_000_000...1_000_000)), bd = Int128(rng.int(1...1_000_000))
            let a = q128(an, ad), b = q128(bn, bd)
            #expect(try a.adding(b) == q128(an * bd + bn * ad, ad * bd))
            #expect(try a.subtracting(b) == q128(an * bd - bn * ad, ad * bd))
            #expect(try a.multiplied(by: b) == q128(an * bn, ad * bd))
            if bn != 0 { #expect(try a.divided(by: b) == q128(an * bd, ad * bn)) }
            #expect((a < b) == (an * bd < bn * ad))
            #expect((a == b) == (an * bd == bn * ad))
        }
    }

    @Test func comparisonNeverOverflows() {
        let m = Int128.max
        let nearOne = q128(m - 1, m), lessNearOne = q128(m - 2, m - 1)
        #expect(lessNearOne < nearOne)
        #expect(!(nearOne < lessNearOne))
        #expect(q128(-(m - 1), m) < q128(-(m - 2), m - 1))
        #expect(q128(m, 1) > q128(m - 1, 1))
        #expect(q128(1, m) < q128(1, m - 1))
    }

    @Test func overflowThrowsInsteadOfWrapping() {
        let big = q128(Int128(1) << 100, 1)
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try big.multiplied(by: big) }
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try q128(.max, 1).adding(.one) }
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try q128(1, .max).adding(q128(1, .max - 1)) }
        #expect(throws: TimeMapError.zeroDenominator) { try ExactRational.one.divided(by: .zero) }
    }

    @Test func quantisationIsHalfUp() {
        #expect(q(109, 2).roundedHalfUp() == 55) // 54.5
        #expect(q(-109, 2).roundedHalfUp() == -54) // -54.5
        #expect(q(5449, 100).roundedHalfUp() == 54)
        #expect(q(-5451, 100).roundedHalfUp() == -55)
        #expect(q(7).roundedHalfUp() == 7)
        #expect(q(-7, 2).floor() == -4 && q(-7, 2).ceil() == -3)
        #expect(q(7, 2).floor() == 3 && q(7, 2).ceil() == 4)
        #expect(q(-8, 2).floor() == -4 && q(-8, 2).ceil() == -4)
        // Error of the quantiser is always <= 1/2 (seeded).
        var rng = SplitMix64(seed: 16)
        for _ in 0..<10_000 {
            let x = q(rng.int(-10_000_000...10_000_000), rng.int(1...1000))
            let error = try! q128(x.roundedHalfUp(), 1).subtracting(x)
            #expect(error <= q(1, 2) && error > q(-1, 2))
        }
    }
}
