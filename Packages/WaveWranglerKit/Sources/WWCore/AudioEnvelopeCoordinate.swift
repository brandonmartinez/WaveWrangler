import Foundation

public enum AudioEnvelopeCoordinateError: Error, Sendable, Equatable {
    case invalidDenominator
    case nonCanonical
    case outsideEnvelope
    case unrepresentableDenominator
    case invalidFraction
}

/// Bounded exact envelope coordinates only, not a second time-map math framework.
/// Native-rate trim phases and integer local edits keep denominators within the supported source rate.
public struct AudioEnvelopeCoordinate: Sendable, Hashable, Comparable, Codable {
    public let numerator: Int64
    public let denominator: Int64
    public static let maximumDenominator: Int64 = 192_000
    /// A retained origin plus one current day-long clip, not an enlarged program-time limit.
    public static let maximumMagnitude = AudioArrangement.frameLimit * 2
    public static let zero = Self(canonicalNumerator: 0, denominator: 1)

    public init(numerator: Int64, denominator: Int64 = 1) throws(AudioEnvelopeCoordinateError) {
        try self.init(wideNumerator: Int128(numerator), denominator: Int128(denominator))
    }

    private init(canonicalNumerator: Int64, denominator: Int64) {
        self.numerator = canonicalNumerator
        self.denominator = denominator
    }

    private init(wideNumerator: Int128, denominator: Int128) throws(AudioEnvelopeCoordinateError) {
        guard denominator > 0 else { throw .invalidDenominator }
        var a = wideNumerator.magnitude
        var b = denominator.magnitude
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = Int128(a)
        let n = wideNumerator / divisor
        let d = denominator / divisor
        guard d <= Int128(Self.maximumDenominator) else { throw .unrepresentableDenominator }
        guard n.magnitude <= UInt128(Self.maximumMagnitude) * d.magnitude else { throw .outsideEnvelope }
        self.init(canonicalNumerator: Int64(n), denominator: Int64(d))
    }

    public func adding(_ other: Self) throws(AudioEnvelopeCoordinateError) -> Self {
        try Self(
            wideNumerator: Int128(numerator) * Int128(other.denominator)
                + Int128(other.numerator) * Int128(denominator),
            denominator: Int128(denominator) * Int128(other.denominator))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        Int128(lhs.numerator) * Int128(rhs.denominator) < Int128(rhs.numerator) * Int128(lhs.denominator)
    }

    public var floorFrame: Int64 {
        let q = numerator / denominator
        return numerator % denominator < 0 ? q - 1 : q
    }

    public var fractionalPart: Self? {
        let remainder = numerator - floorFrame * denominator
        return remainder == 0 ? nil : Self(canonicalNumerator: remainder, denominator: denominator)
    }

    public var isProperFraction: Bool { numerator > 0 && numerator < denominator }

    enum CodingKeys: String, CodingKey { case numerator, denominator }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int64.self, forKey: .numerator)
        let d = try c.decode(Int64.self, forKey: .denominator)
        try self.init(numerator: n, denominator: d)
        guard numerator == n, denominator == d else { throw AudioEnvelopeCoordinateError.nonCanonical }
    }
}

/// Its presence explicitly retains bracketing support knots outside the current clip's local window.
/// A zero offset is omitted inside this nondefault window, not confused with an ordinary uncut curve.
public struct AudioEnvelopeWindow: Sendable, Equatable, Codable {
    public let offset: AudioEnvelopeCoordinate

    public init(offset: AudioEnvelopeCoordinate = .zero) { self.offset = offset }

    enum CodingKeys: String, CodingKey { case offset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(offset: try c.decodeIfPresent(AudioEnvelopeCoordinate.self, forKey: .offset) ?? .zero)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if offset != .zero { try c.encode(offset, forKey: .offset) }
    }
}
