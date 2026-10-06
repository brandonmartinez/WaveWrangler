import Foundation

/// An exact rational number `numerator / denominator` with `Int128` components.
///
/// Every value is canonical: `denominator > 0` and `gcd(|numerator|, denominator) == 1`, so `==` is exact
/// value equality. All arithmetic is checked: an operation whose exact result does not fit `Int128` throws
/// ``TimeMapError/exactArithmeticEnvelopeExceeded`` instead of trapping, wrapping or rounding. Comparison
/// never overflows (it uses a continued-fraction comparison, not cross-multiplication).
///
/// No time-map computation in WWTimeMap goes through `Double`. The only rounding anywhere is the explicit,
/// single, documented quantisation of an exact result to an integer frame (``roundedHalfUp()``).
public struct ExactRational: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let numerator: Int128
    /// Always `> 0`.
    public let denominator: Int128

    public static let zero = ExactRational(canonicalNumerator: 0, denominator: 1)
    public static let one = ExactRational(canonicalNumerator: 1, denominator: 1)

    /// Creates the canonical form of `numerator / denominator`.
    public init(numerator: Int128, denominator: Int128) throws(TimeMapError) {
        guard denominator != 0 else { throw .zeroDenominator }
        // `Int128.min` has no positive counterpart; refusing it keeps negation total.
        guard numerator != .min, denominator != .min else { throw .exactArithmeticEnvelopeExceeded }
        var n = numerator
        var d = denominator
        if d < 0 {
            n = -n
            d = -d
        }
        let g = Int128(Self.gcd(n.magnitude, d.magnitude))
        self.init(canonicalNumerator: g > 1 ? n / g : n, denominator: g > 1 ? d / g : d)
    }

    public init(_ numerator: Int64, _ denominator: Int64) throws(TimeMapError) {
        try self.init(numerator: Int128(numerator), denominator: Int128(denominator))
    }

    public init(_ integer: Int64) {
        self.init(canonicalNumerator: Int128(integer), denominator: 1)
    }

    init(canonicalNumerator: Int128, denominator: Int128) {
        self.numerator = canonicalNumerator
        self.denominator = denominator
    }

    public var description: String { "\(numerator)/\(denominator)" }

    public var isInteger: Bool { denominator == 1 }

    /// Approximate value for display and diagnostics only. Never feed it back into map arithmetic.
    public var approximateDouble: Double { Double(numerator) / Double(denominator) }

    // MARK: Checked arithmetic

    public func adding(_ other: ExactRational) throws(TimeMapError) -> ExactRational {
        let g = Int128(Self.gcd(denominator.magnitude, other.denominator.magnitude))
        let left = try Self.mul(numerator, other.denominator / g)
        let right = try Self.mul(other.numerator, denominator / g)
        let d = try Self.mul(denominator / g, other.denominator)
        return try ExactRational(numerator: try Self.add(left, right), denominator: d)
    }

    public func subtracting(_ other: ExactRational) throws(TimeMapError) -> ExactRational {
        try adding(other.negated())
    }

    public func multiplied(by other: ExactRational) throws(TimeMapError) -> ExactRational {
        let g1 = Int128(Self.gcd(numerator.magnitude, other.denominator.magnitude))
        let g2 = Int128(Self.gcd(other.numerator.magnitude, denominator.magnitude))
        let n = try Self.mul(numerator / max(g1, 1), other.numerator / max(g2, 1))
        let d = try Self.mul(denominator / max(g2, 1), other.denominator / max(g1, 1))
        return try ExactRational(numerator: n, denominator: d)
    }

    public func divided(by other: ExactRational) throws(TimeMapError) -> ExactRational {
        guard other.numerator != 0 else { throw .zeroDenominator }
        return try multiplied(by: ExactRational(canonicalNumerator: other.denominator, denominator: other.numerator).normalisedSign())
    }

    public func negated() -> ExactRational {
        // Canonical numerators are never `Int128.min`, so negation is total.
        ExactRational(canonicalNumerator: -numerator, denominator: denominator)
    }

    private func normalisedSign() -> ExactRational {
        denominator < 0 ? ExactRational(canonicalNumerator: -numerator, denominator: -denominator) : self
    }

    // MARK: Integer quantisation

    /// Largest integer `<= self`.
    public func floor() -> Int128 { Self.floorDivMod(numerator, denominator).quotient }

    /// Smallest integer `>= self`.
    public func ceil() -> Int128 {
        let (q, r) = Self.floorDivMod(numerator, denominator)
        return r == 0 ? q : q + 1
    }

    /// Nearest integer with ties rounded towards positive infinity: `floor(self + 1/2)`.
    ///
    /// This is the single rounding rule of WWTimeMap (the same HALF-UP quantiser as the WW-025 synthetic
    /// contract): `54.5 -> 55`, `-54.5 -> -54`. The absolute error is always `<= 1/2`.
    public func roundedHalfUp() -> Int128 {
        let (q, r) = Self.floorDivMod(numerator, denominator)
        // r in [0, d): round up when r/d >= 1/2, i.e. r >= d - r (no overflow).
        return r >= denominator - r ? q + 1 : q
    }

    // MARK: Comparison (overflow-free)

    public static func < (lhs: ExactRational, rhs: ExactRational) -> Bool {
        compare(lhs.numerator, lhs.denominator, rhs.numerator, rhs.denominator) < 0
    }

    /// Compares `an/ad` with `bn/bd` (`ad, bd > 0`) without forming any product.
    static func compare(_ an: Int128, _ ad: Int128, _ bn: Int128, _ bd: Int128) -> Int {
        let (aq, ar) = floorDivMod(an, ad)
        let (bq, br) = floorDivMod(bn, bd)
        if aq != bq { return aq < bq ? -1 : 1 }
        if ar == 0 || br == 0 {
            if ar == br { return 0 }
            return ar == 0 ? -1 : 1
        }
        // ar/ad < br/bd  <=>  ad/ar > bd/br
        return -compare(ad, ar, bd, br)
    }

    // MARK: Integer helpers

    /// Floor division with a non-negative remainder; `d > 0`.
    static func floorDivMod(_ n: Int128, _ d: Int128) -> (quotient: Int128, remainder: Int128) {
        var q = n / d
        var r = n % d
        if r < 0 {
            q -= 1
            r += d
        }
        return (q, r)
    }

    static func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var x = a
        var y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    static func mul(_ a: Int128, _ b: Int128) throws(TimeMapError) -> Int128 {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, r != .min else { throw .exactArithmeticEnvelopeExceeded }
        return r
    }

    static func add(_ a: Int128, _ b: Int128) throws(TimeMapError) -> Int128 {
        let (r, overflow) = a.addingReportingOverflow(b)
        guard !overflow, r != .min else { throw .exactArithmeticEnvelopeExceeded }
        return r
    }
}

extension ExactRational: Codable {
    /// Encoded as the canonical string `"numerator/denominator"` (e.g. `"-1/48000"`), never as a JSON
    /// number, so no decoder can round it through `Double`. Decoding accepts only the canonical form.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int128(String(parts[0])), let d = Int128(String(parts[1])),
              let value = try? ExactRational(numerator: n, denominator: d), value.description == text
        else { throw TimeMapDecodingError.malformedRational(text) }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
