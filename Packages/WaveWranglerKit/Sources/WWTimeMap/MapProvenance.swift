import Foundation
import WWCore

// Map provenance: WHY an epoch's group-clock -> aligned segments are believed.
//
// Hard rules encoded by the types (WW-015/016, kickoff M2 §3-4):
// * An acoustic-consistent proposal is never a clock correction. No API converts one into
//   `clockApproved`; human acceptance of a proposal is recorded as `manual(.acceptedAcousticProposal)`,
//   which is still not clock approval (human acceptance is not oscillator truth). Proposals carry
//   ``AcousticConsistencyMeasurements``, a type distinct from the ``ClockGateMeasurements`` an approval needs.
// * There is no public way to construct a ``ClockApproval`` (or an ``IndependentClockReference``): their
//   initialisers are internal and neither type is publicly `Decodable`. The only public route to an
//   existing approval is decoding a persisted ``MapProvenance``, so persistence must decode only from its
//   own store. A public construction path will exist only once a frozen-holdout-qualified WW-016 evaluator
//   does, and will require an opaque token that only that evaluator can issue (M2-C4).
// * Capture metadata (file dates, embedded timestamps, recorded-on day) is never clock proof. The only
//   place a ``CaptureMetadataSeed`` can appear is as the `seed` of an ``AcousticConsistencyProposal``.
// * Scores are evidence measures, never probabilities, confidences or likelihoods.

/// Provenance of one mapped epoch.
public enum MapProvenance: Hashable, Sendable {
    /// The reference epoch of the reference group: identity by definition, not by evidence.
    case timelineReference
    /// Clock relationship established from an independent clock reference meeting the provisional gates.
    case clockApproved(ClockApproval)
    /// Waveform/acoustic consistency only. Acoustic propagation delay can masquerade as a clock offset or
    /// drift, so this is a proposal for review and must never be treated as clock correction.
    case acousticConsistentProposal(AcousticConsistencyProposal)
    /// Entered or accepted by a person (numeric values, anchors, or accepting a proposal).
    case manual(ManualCorrection)
    /// Attested by evidence outside the audio (e.g. a shared timecode generator) that WaveWrangler did not verify.
    case externalEvidence(ExternalClockEvidence)

    public var kind: Kind {
        switch self {
        case .timelineReference: .timelineReference
        case .clockApproved: .clockApproved
        case .acousticConsistentProposal: .acousticConsistentProposal
        case .manual: .manual
        case .externalEvidence: .externalEvidence
        }
    }

    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case timelineReference, clockApproved, acousticConsistentProposal, manual, externalEvidence

        /// True only for `clockApproved`. Acoustic, manual and external provenance never qualify.
        public var isClockApproved: Bool { self == .clockApproved }
    }
}

/// The region state reported by a map query. `gap`, `unsupported` and `outsideCoverage` have no inverse.
public enum TimeMapRegionState: Hashable, Sendable {
    case mapped(MapProvenance.Kind)
    /// Between two spans of an occurrence separated by a known discontinuity (an epoch restart).
    case gap
    /// The epoch exists but has no supported map (e.g. the estimator abstained or the drift is nonlinear).
    case unsupported(UnsupportedReason)
    case outsideCoverage
}

public enum UnsupportedReason: String, Hashable, Sendable, Codable, CaseIterable {
    case notAttempted, estimatorAbstained, insufficientOverlap, nonlinear, disconnected, acousticOnly
}

// MARK: - Clock approval

/// Provisional WW-016 clock gates (docs/planning/kickoffs/m2.md §4). Not yet frozen-holdout qualified;
/// a later freeze may only tighten them.
public enum ProvisionalClockGates {
    public static let minimumWindows = 5
    public static let minimumOverlapSpanFraction = 0.8
    public static let minimumEligibleWindowFraction = 0.6
    public static let maximumResidualP95Milliseconds = 5.0
    public static let maximumResidualMaxMilliseconds = 10.0
}

/// Measurements of a fitted map against INDEPENDENT clock truth (not correlation peaks or the fitted map).
public struct ClockGateMeasurements: Hashable, Sendable {
    public let windowCount: Int
    /// Fraction of the declared overlap spanned by the windows, 0...1.
    public let overlapSpanFraction: Double
    /// Fraction of windows that were eligible, 0...1.
    public let eligibleWindowFraction: Double
    /// Nearest-rank p95 of absolute clock residuals, milliseconds.
    public let residualP95Milliseconds: Double
    public let residualMaxMilliseconds: Double

    public init(windowCount: Int, overlapSpanFraction: Double, eligibleWindowFraction: Double, residualP95Milliseconds: Double, residualMaxMilliseconds: Double) throws(TimeMapError) {
        guard windowCount >= 0 else { throw .invalidMeasurement("windowCount") }
        guard overlapSpanFraction.isFinite, (0...1).contains(overlapSpanFraction) else { throw .invalidMeasurement("overlapSpanFraction") }
        guard eligibleWindowFraction.isFinite, (0...1).contains(eligibleWindowFraction) else { throw .invalidMeasurement("eligibleWindowFraction") }
        guard residualP95Milliseconds.isFinite, residualP95Milliseconds >= 0 else { throw .invalidMeasurement("residualP95Milliseconds") }
        guard residualMaxMilliseconds.isFinite, residualMaxMilliseconds >= residualP95Milliseconds else { throw .invalidMeasurement("residualMaxMilliseconds") }
        self.windowCount = windowCount
        self.overlapSpanFraction = overlapSpanFraction
        self.eligibleWindowFraction = eligibleWindowFraction
        self.residualP95Milliseconds = residualP95Milliseconds
        self.residualMaxMilliseconds = residualMaxMilliseconds
    }

    /// Names of the provisional gates these measurements fail (empty when all pass).
    public var failedProvisionalGates: [String] {
        var failed: [String] = []
        if windowCount < ProvisionalClockGates.minimumWindows { failed.append("windowCount") }
        if overlapSpanFraction < ProvisionalClockGates.minimumOverlapSpanFraction { failed.append("overlapSpanFraction") }
        if eligibleWindowFraction < ProvisionalClockGates.minimumEligibleWindowFraction { failed.append("eligibleWindowFraction") }
        if residualP95Milliseconds > ProvisionalClockGates.maximumResidualP95Milliseconds { failed.append("residualP95Milliseconds") }
        if residualMaxMilliseconds > ProvisionalClockGates.maximumResidualMaxMilliseconds { failed.append("residualMaxMilliseconds") }
        return failed
    }
}

/// The independent clock reference behind an approval (e.g. certified clock anchors). Acoustic events
/// and capture metadata are not independent clock references and have no representation here.
///
/// Not publicly constructible: a free-text description must not be enough to start an approval.
public struct IndependentClockReference: Hashable, Sendable {
    public let description: String

    init(description: String) throws(TimeMapError) {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyDescription("IndependentClockReference") }
        self.description = description
    }
}

/// A clock approval. Internally it can only be constructed from an independent clock reference whose
/// measurements meet every provisional gate. Meeting these gates is necessary, not sufficient: per M2-C4
/// (docs/m2/ww-019-m2-contracts.md) an evaluator may only issue `clockApproved` after the frozen WW-016
/// holdout gate passes, and nothing in WWTimeMap promotes any map to `clockApproved` automatically.
///
/// Not publicly constructible (internal initialiser, encode-only conformance): until a holdout-qualified
/// WW-016 evaluator exists there is no public construction path, and that path is planned to require an
/// opaque evaluator token rather than free-standing measurements.
///
/// An approval is bound to the exact epoch and segments it measured (#177): it stores the epoch ID and
/// a copy of the approved segments, and ``GroupTimeMap`` compilation and ``EpochClockMap`` decoding refuse
/// a `clockApproved` epoch whose ID or segments differ in any way. Editing a map therefore drops its
/// approval; it cannot be carried over to different or relabelled segments.
public struct ClockApproval: Hashable, Sendable {
    /// Identifier and version of the evaluator that produced the measurements.
    public let evaluator: String
    public let reference: IndependentClockReference
    public let measurements: ClockGateMeasurements
    /// The epoch this approval was measured for.
    public let epoch: RecordingEpochID
    /// The exact segments this approval was measured for (compared with exact `==`).
    public let segments: [AffineClockSegment]

    init(evaluator: String, reference: IndependentClockReference, measurements: ClockGateMeasurements, epoch: RecordingEpochID, segments: [AffineClockSegment]) throws(TimeMapError) {
        guard !evaluator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyDescription("ClockApproval.evaluator") }
        let failed = measurements.failedProvisionalGates
        guard failed.isEmpty else { throw .clockApprovalGateNotMet(failed) }
        guard !segments.isEmpty else { throw .emptyEpochMap(epoch) }
        self.evaluator = evaluator
        self.reference = reference
        self.measurements = measurements
        self.epoch = epoch
        self.segments = segments
    }

    /// True when this approval was issued for exactly `segments` of `epoch`.
    func approves(epoch: RecordingEpochID, segments: [AffineClockSegment]) -> Bool {
        self.epoch == epoch && self.segments == segments
    }
}

extension MapProvenance {
    /// Throws unless a `clockApproved` provenance is bound to exactly this epoch and these segments.
    /// Other provenance kinds carry no binding and always pass.
    func checkClockApprovalBinding(epoch: RecordingEpochID, segments: [AffineClockSegment]) throws(TimeMapError) {
        guard case .clockApproved(let approval) = self else { return }
        guard approval.approves(epoch: epoch, segments: segments) else { throw .clockApprovalBindingMismatch(epoch) }
    }
}

// MARK: - Proposals, manual and external evidence

/// Capture metadata (file dates, embedded timestamps, recorded-on day). It may seed a proposal's search;
/// it is never clock proof and cannot appear in any other provenance.
public struct CaptureMetadataSeed: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case fileCreationDate, fileModificationDate, embeddedTimestamp, recordedOnDay, other
    }

    public let kind: Kind
    /// Suggested starting offset for a proposal search, aligned seconds. A hint, not a measurement.
    public let suggestedOffset: ExactRational?
    public let note: String

    public init(kind: Kind, suggestedOffset: ExactRational? = nil, note: String = "") {
        self.kind = kind
        self.suggestedOffset = suggestedOffset
        self.note = note
    }
}

/// Measurements of a fitted map against ACOUSTIC events (correlation peaks, onsets). Acoustic propagation
/// delay and drift make these consistency measures, not clock truth: unlike ``ClockGateMeasurements`` this
/// type has no clock-gate check, and nothing converts it into clock-gate measurements or an approval.
public struct AcousticConsistencyMeasurements: Hashable, Sendable {
    public let windowCount: Int
    /// Fraction of the declared overlap spanned by the windows, 0...1.
    public let overlapSpanFraction: Double
    /// Fraction of windows that were eligible, 0...1.
    public let eligibleWindowFraction: Double
    /// Nearest-rank p95 of absolute residuals against the acoustic events, milliseconds.
    public let acousticResidualP95Milliseconds: Double
    public let acousticResidualMaxMilliseconds: Double

    public init(windowCount: Int, overlapSpanFraction: Double, eligibleWindowFraction: Double, acousticResidualP95Milliseconds: Double, acousticResidualMaxMilliseconds: Double) throws(TimeMapError) {
        guard windowCount >= 0 else { throw .invalidMeasurement("windowCount") }
        guard overlapSpanFraction.isFinite, (0...1).contains(overlapSpanFraction) else { throw .invalidMeasurement("overlapSpanFraction") }
        guard eligibleWindowFraction.isFinite, (0...1).contains(eligibleWindowFraction) else { throw .invalidMeasurement("eligibleWindowFraction") }
        guard acousticResidualP95Milliseconds.isFinite, acousticResidualP95Milliseconds >= 0 else { throw .invalidMeasurement("acousticResidualP95Milliseconds") }
        guard acousticResidualMaxMilliseconds.isFinite, acousticResidualMaxMilliseconds >= acousticResidualP95Milliseconds else { throw .invalidMeasurement("acousticResidualMaxMilliseconds") }
        self.windowCount = windowCount
        self.overlapSpanFraction = overlapSpanFraction
        self.eligibleWindowFraction = eligibleWindowFraction
        self.acousticResidualP95Milliseconds = acousticResidualP95Milliseconds
        self.acousticResidualMaxMilliseconds = acousticResidualMaxMilliseconds
    }
}

/// A map that is only acoustically consistent. `evidenceScore` is an estimator-specific evidence measure,
/// not a probability; it must never be shown as a percentage chance or used as clock approval.
public struct AcousticConsistencyProposal: Hashable, Sendable {
    public let estimator: String
    public let evidenceScore: Double?
    public let measurements: AcousticConsistencyMeasurements?
    public let seed: CaptureMetadataSeed?

    public init(estimator: String, evidenceScore: Double? = nil, measurements: AcousticConsistencyMeasurements? = nil, seed: CaptureMetadataSeed? = nil) throws(TimeMapError) {
        guard !estimator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyDescription("AcousticConsistencyProposal.estimator") }
        if let evidenceScore, !evidenceScore.isFinite { throw .invalidMeasurement("evidenceScore") }
        self.estimator = estimator
        self.evidenceScore = evidenceScore
        self.measurements = measurements
        self.seed = seed
    }
}

public struct ManualCorrection: Hashable, Sendable {
    public enum Basis: String, Hashable, Sendable, Codable, CaseIterable {
        /// Rate/offset typed by a person.
        case numericEntry
        /// Fitted to anchors a person placed.
        case anchors
        /// A person accepted an acoustic-consistent proposal. Still manual, still not clock approval.
        case acceptedAcousticProposal
    }

    public let basis: Basis
    public let note: String

    public init(basis: Basis, note: String = "") {
        self.basis = basis
        self.note = note
    }
}

public struct ExternalClockEvidence: Hashable, Sendable {
    /// Out-of-band clock evidence a person supplies. File/capture metadata is deliberately not a kind.
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case sharedTimecodeGenerator, sharedWordClock, userSuppliedSyncLog
    }

    public let kind: Kind
    public let description: String

    public init(kind: Kind, description: String) throws(TimeMapError) {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyDescription("ExternalClockEvidence") }
        self.kind = kind
        self.description = description
    }
}

// MARK: - Codable

extension MapProvenance: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, clockApproval, proposal, manual, external }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "MapProvenance")
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else { throw TimeMapDecodingError.unknownKind(type: "MapProvenance", kind: raw) }
        let expected: CodingKeys? = switch kind {
        case .timelineReference: nil
        case .clockApproved: .clockApproval
        case .acousticConsistentProposal: .proposal
        case .manual: .manual
        case .externalEvidence: .external
        }
        let extra = c.allKeys.filter { $0 != .kind && $0 != expected }.map(\.stringValue).sorted()
        guard extra.isEmpty else { throw TimeMapDecodingError.unknownKeys(type: "MapProvenance.\(raw)", keys: extra) }
        switch kind {
        case .timelineReference: self = .timelineReference
        case .clockApproved: self = .clockApproved(try c.decode(DecodedClockApproval.self, forKey: .clockApproval).value)
        case .acousticConsistentProposal: self = .acousticConsistentProposal(try c.decode(AcousticConsistencyProposal.self, forKey: .proposal))
        case .manual: self = .manual(try c.decode(ManualCorrection.self, forKey: .manual))
        case .externalEvidence: self = .externalEvidence(try c.decode(ExternalClockEvidence.self, forKey: .external))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .timelineReference: break
        case .clockApproved(let value): try c.encode(value, forKey: .clockApproval)
        case .acousticConsistentProposal(let value): try c.encode(value, forKey: .proposal)
        case .manual(let value): try c.encode(value, forKey: .manual)
        case .externalEvidence(let value): try c.encode(value, forKey: .external)
        }
    }
}

extension ClockGateMeasurements: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case windowCount, overlapSpanFraction, eligibleWindowFraction, residualP95Milliseconds, residualMaxMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "ClockGateMeasurements")
        try self.init(
            windowCount: c.decode(Int.self, forKey: .windowCount),
            overlapSpanFraction: c.decode(Double.self, forKey: .overlapSpanFraction),
            eligibleWindowFraction: c.decode(Double.self, forKey: .eligibleWindowFraction),
            residualP95Milliseconds: c.decode(Double.self, forKey: .residualP95Milliseconds),
            residualMaxMilliseconds: c.decode(Double.self, forKey: .residualMaxMilliseconds)
        )
    }
}

// Approval types are publicly encode-only: a public `init(from:)` would be a public construction path.
// They are decoded only as part of a `MapProvenance`, through these internal records.

extension IndependentClockReference: Encodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case description }
}

extension ClockApproval: Encodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case evaluator, reference, measurements, epoch, segments }
}

struct DecodedIndependentClockReference: Decodable {
    let value: IndependentClockReference

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: IndependentClockReference.CodingKeys.self, typeName: "IndependentClockReference")
        value = try IndependentClockReference(description: c.decode(String.self, forKey: .description))
    }
}

struct DecodedClockApproval: Decodable {
    let value: ClockApproval

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: ClockApproval.CodingKeys.self, typeName: "ClockApproval")
        value = try ClockApproval(
            evaluator: c.decode(String.self, forKey: .evaluator),
            reference: c.decode(DecodedIndependentClockReference.self, forKey: .reference).value,
            measurements: c.decode(ClockGateMeasurements.self, forKey: .measurements),
            epoch: c.decode(RecordingEpochID.self, forKey: .epoch),
            segments: c.decode([AffineClockSegment].self, forKey: .segments)
        )
    }
}

extension AcousticConsistencyMeasurements: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case windowCount, overlapSpanFraction, eligibleWindowFraction, acousticResidualP95Milliseconds, acousticResidualMaxMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "AcousticConsistencyMeasurements")
        try self.init(
            windowCount: c.decode(Int.self, forKey: .windowCount),
            overlapSpanFraction: c.decode(Double.self, forKey: .overlapSpanFraction),
            eligibleWindowFraction: c.decode(Double.self, forKey: .eligibleWindowFraction),
            acousticResidualP95Milliseconds: c.decode(Double.self, forKey: .acousticResidualP95Milliseconds),
            acousticResidualMaxMilliseconds: c.decode(Double.self, forKey: .acousticResidualMaxMilliseconds)
        )
    }
}

extension CaptureMetadataSeed: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, suggestedOffset, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "CaptureMetadataSeed")
        self.init(
            kind: try c.decode(Kind.self, forKey: .kind),
            suggestedOffset: try c.decodeIfPresent(ExactRational.self, forKey: .suggestedOffset),
            note: try c.decode(String.self, forKey: .note)
        )
    }
}

extension AcousticConsistencyProposal: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case estimator, evidenceScore, measurements, seed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "AcousticConsistencyProposal")
        try self.init(
            estimator: c.decode(String.self, forKey: .estimator),
            evidenceScore: c.decodeIfPresent(Double.self, forKey: .evidenceScore),
            measurements: c.decodeIfPresent(AcousticConsistencyMeasurements.self, forKey: .measurements),
            seed: c.decodeIfPresent(CaptureMetadataSeed.self, forKey: .seed)
        )
    }
}

extension ManualCorrection: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case basis, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "ManualCorrection")
        self.init(basis: try c.decode(Basis.self, forKey: .basis), note: try c.decode(String.self, forKey: .note))
    }
}

extension ExternalClockEvidence: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, description }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "ExternalClockEvidence")
        try self.init(kind: c.decode(Kind.self, forKey: .kind), description: c.decode(String.self, forKey: .description))
    }
}
