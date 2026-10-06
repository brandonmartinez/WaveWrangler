import Foundation
import WWCore

// MARK: - Conventions
//
// Coordinate chain (the WW-014..017 timing contract, docs/research/foundation-spikes.md):
//
//   source frame n of an occurrence at nominal rate F  (integer n, integer F > 0)
//     -> group clock   u = n/F + e        e = the span's group-clock offset (seconds, exact rational)
//     -> aligned       t = a*u + b        per positive affine segment of the epoch (a > 0)
//
// * Units: n in source frames; F in frames per second; e, u, b, t in seconds (exact rationals).
// * Rate ratio a = dt/du (aligned seconds per group-clock second). map_ppm = 1e6 * (a - 1).
//   Positive ppm (a > 1) means the group's recorder clock runs SLOW relative to the reference timeline:
//   its F nominal frames span a > 1 aligned seconds (actual rate F/a), so its content drifts later on the
//   aligned timeline than naive n/F placement.
// * Clock pitch: playing such a recording at its nominal F raises pitch by a; rendering it onto the
//   aligned timeline changes pitch by 1/a relative to nominal-rate playback. That is the clock correction
//   itself, restoring true pitch. It is NOT a time stretch: WWTimeMap has no time-stretch parameter and
//   none may be inferred from a (pitch-preserving stretch is never a clock correction).
// * Lag sign: see ``CorrelationLag``. Positive lag L (target frames) means the same event occurs L frames
//   LATER in the target than in the reference; with equal origins and a = 1 the aligning offset is
//   b = -L/F.
// * Rounding: arithmetic is exact. The only rounding is quantising an exact source position to a frame
//   index, HALF-UP (`floor(x + 1/2)`), so a returned frame is always within 1/2 frame of the exact inverse.

/// Bounds of the supported parameter envelope. Parameters outside them are refused with a typed error.
/// Inside them a map can still be refused with ``TimeMapError/exactArithmeticEnvelopeExceeded``: construction
/// proves that forward mapping of every placed frame, and inversion of every hull instant whose canonical
/// denominator is at most ``maxNominalRate`` (any `k/G` grid with `G <= 2^20`), fit `Int128` (see
/// ``GroupTimeMap``). Inverting instants with larger denominators is exact but may throw that error.
public enum TimeMapEnvelope {
    /// Largest nominal rate (frames per second). 2^20 = 1,048,576 Hz covers 768 kHz.
    public static let maxNominalRate: Int64 = 1 << 20
    /// Largest frame count of one occurrence. 2^40 frames is about 265 days at 48 kHz.
    public static let maxFrameCount: Int64 = 1 << 40
    /// Largest denominator of a supplied rational parameter (a, b, e, segment bounds).
    public static let maxParameterDenominator: Int128 = 1 << 40
    /// Largest magnitude, in seconds, of a supplied time parameter (b, e, segment bounds). 2^31 s = 68 years.
    public static let maxParameterSeconds: Int128 = 1 << 31
    /// Rate ratios are accepted in [1/2, 2] (ppm in [-500,000, +1,000,000]).
    public static let minRateRatio = ExactRational(canonicalNumerator: 1, denominator: 2)
    public static let maxRateRatio = ExactRational(canonicalNumerator: 2, denominator: 1)

    static func checkTime(_ value: ExactRational, _ name: String) throws(TimeMapError) {
        guard value.denominator <= maxParameterDenominator,
              value.numerator.magnitude <= maxParameterSeconds.magnitude * value.denominator.magnitude
        else { throw .parameterOutsideEnvelope(name) }
    }
}

// MARK: - Identity

public enum SourceOccurrenceTag {}
/// Identity of one use of a source in an episode. A repeated source keeps distinct occurrence IDs.
public typealias SourceOccurrenceID = LogicalID<SourceOccurrenceTag>

/// A nominal (declared) integer frame rate F. It is what the decoder reports, not a measured clock.
public struct NominalRate: Hashable, Sendable, Codable, CustomStringConvertible {
    public let framesPerSecond: Int64

    public init(_ framesPerSecond: Int64) throws(TimeMapError) {
        guard framesPerSecond >= 1, framesPerSecond <= TimeMapEnvelope.maxNominalRate else {
            throw .invalidNominalRate(framesPerSecond)
        }
        self.framesPerSecond = framesPerSecond
    }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(framesPerSecond)
    }

    public var description: String { "\(framesPerSecond) Hz" }

    /// Exact instant of frame `index` at this rate, `index / F` seconds (e.g. an aligned output frame).
    public func instant(ofFrame index: Int64) -> ExactRational {
        // F >= 1, so this cannot fail.
        (try? ExactRational(numerator: Int128(index), denominator: Int128(framesPerSecond))) ?? .zero
    }
}

/// One occurrence of a source: plain decoded frame count and nominal rate (no decoder types).
public struct SourceOccurrence: Hashable, Sendable {
    public let id: SourceOccurrenceID
    public let source: SourceID
    public let nominalRate: NominalRate
    /// Number of frames; valid frame indices are `0 ..< frameCount`.
    public let frameCount: Int64

    public init(id: SourceOccurrenceID = SourceOccurrenceID(), source: SourceID, nominalRate: NominalRate, frameCount: Int64) throws(TimeMapError) {
        guard frameCount >= 1, frameCount <= TimeMapEnvelope.maxFrameCount else { throw .invalidFrameCount(frameCount) }
        self.id = id
        self.source = source
        self.nominalRate = nominalRate
        self.frameCount = frameCount
    }
}

extension SourceOccurrence: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, source, nominalRate, frameCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "SourceOccurrence")
        try self.init(
            id: c.decode(SourceOccurrenceID.self, forKey: .id),
            source: c.decode(SourceID.self, forKey: .source),
            nominalRate: c.decode(NominalRate.self, forKey: .nominalRate),
            frameCount: c.decode(Int64.self, forKey: .frameCount)
        )
    }
}

/// Which source occurrence and clock epoch DEFINE the aligned timeline.
///
/// By definition the aligned time of the reference occurrence's frame n (inside the reference epoch) is
/// exactly n/F: the reference epoch maps with a = 1, b = 0 and the reference span has e = 0. Every other
/// epoch/group is expressed relative to it. Maps with different references are never combined.
public struct TimelineReference: Hashable, Sendable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    public let occurrence: SourceOccurrenceID

    public init(group: RecorderGroupID, epoch: RecordingEpochID, occurrence: SourceOccurrenceID) {
        self.group = group
        self.epoch = epoch
        self.occurrence = occurrence
    }
}

extension TimelineReference: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case group, epoch, occurrence }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "TimelineReference")
        self.init(
            group: try c.decode(RecorderGroupID.self, forKey: .group),
            epoch: try c.decode(RecordingEpochID.self, forKey: .epoch),
            occurrence: try c.decode(SourceOccurrenceID.self, forKey: .occurrence)
        )
    }
}

// MARK: - Affine segment

/// One positive affine piece `t = a*u + b` of an epoch's group-clock -> aligned map, valid on the
/// half-open group-clock interval `[groupClockStart, groupClockEnd)`.
public struct AffineClockSegment: Hashable, Sendable {
    /// Inclusive group-clock start u0, seconds.
    public let groupClockStart: ExactRational
    /// Exclusive group-clock end u1, seconds. `u1 > u0`.
    public let groupClockEnd: ExactRational
    /// a = dt/du > 0 (aligned seconds per group-clock second). See the conventions at the top of this file.
    public let rateRatio: ExactRational
    /// b, aligned seconds: the aligned time of group-clock instant u = 0 under this segment.
    public let alignedOffset: ExactRational

    public init(groupClockStart: ExactRational, groupClockEnd: ExactRational, rateRatio: ExactRational, alignedOffset: ExactRational) throws(TimeMapError) {
        guard rateRatio > .zero else { throw .nonPositiveRateRatio }
        guard rateRatio >= TimeMapEnvelope.minRateRatio, rateRatio <= TimeMapEnvelope.maxRateRatio,
              rateRatio.denominator <= TimeMapEnvelope.maxParameterDenominator
        else { throw .rateRatioOutsideEnvelope }
        guard groupClockEnd > groupClockStart else { throw .nonPositiveSegmentLength }
        try TimeMapEnvelope.checkTime(groupClockStart, "groupClockStart")
        try TimeMapEnvelope.checkTime(groupClockEnd, "groupClockEnd")
        try TimeMapEnvelope.checkTime(alignedOffset, "alignedOffset")
        self.groupClockStart = groupClockStart
        self.groupClockEnd = groupClockEnd
        self.rateRatio = rateRatio
        self.alignedOffset = alignedOffset
    }

    /// map_ppm = 1e6 * (a - 1). Positive: the group clock runs slow relative to the aligned timeline.
    public var ppm: ExactRational {
        // a is within [1/2, 2] with a bounded denominator, so this cannot overflow.
        (try? rateRatio.subtracting(.one).multiplied(by: ExactRational(1_000_000))) ?? .zero
    }

    /// a = 1 + ppm / 1e6, exactly.
    public static func rateRatio(ppm: ExactRational) throws(TimeMapError) -> ExactRational {
        try ppm.divided(by: ExactRational(1_000_000)).adding(.one)
    }

    /// 1/a: the pitch factor of clock correction relative to playing the source at its nominal rate.
    /// Restores true pitch; it is not (and must never be presented as) a pitch-preserving time stretch.
    public var clockPitchFactor: ExactRational {
        (try? ExactRational.one.divided(by: rateRatio)) ?? .one
    }

    /// Output frames per input frame when rendering this segment onto an aligned grid: a * Fout / Fin.
    public func outputFramesPerInputFrame(input: NominalRate, output: NominalRate) throws(TimeMapError) -> ExactRational {
        try rateRatio.multiplied(by: ExactRational(numerator: Int128(output.framesPerSecond), denominator: Int128(input.framesPerSecond)))
    }

    /// Aligned time of group-clock instant u under this segment's formula (no domain check).
    func aligned(_ u: ExactRational) throws(TimeMapError) -> ExactRational {
        try rateRatio.multiplied(by: u).adding(alignedOffset)
    }

    var isIdentity: Bool { rateRatio == .one && alignedOffset == .zero }
}

extension AffineClockSegment: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case groupClockStart, groupClockEnd, rateRatio, alignedOffset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "AffineClockSegment")
        try self.init(
            groupClockStart: c.decode(ExactRational.self, forKey: .groupClockStart),
            groupClockEnd: c.decode(ExactRational.self, forKey: .groupClockEnd),
            rateRatio: c.decode(ExactRational.self, forKey: .rateRatio),
            alignedOffset: c.decode(ExactRational.self, forKey: .alignedOffset)
        )
    }
}

// MARK: - Lag sign convention

/// A correlation lag between a reference and a target, expressed in target frames.
///
/// **Sign:** positive `frames` means the same event occurs that many frames LATER in the target than in
/// the reference (target index = reference index + lag) when both are placed with equal origins. To align
/// the target onto the reference (a = 1) its offset must be `b = -lag / F`. WWTimeMap does not estimate
/// lags (WW-016/021); this type only fixes the sign so estimators and UI cannot disagree about it.
public struct CorrelationLag: Hashable, Sendable {
    public let frames: Int64
    public let rate: NominalRate

    public init(frames: Int64, rate: NominalRate) {
        self.frames = frames
        self.rate = rate
    }

    /// `b = -lag / F` seconds.
    public var aligningOffset: ExactRational { rate.instant(ofFrame: frames).negated() }
}
