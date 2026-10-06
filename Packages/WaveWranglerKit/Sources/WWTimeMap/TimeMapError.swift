import Foundation
import WWCore

/// Typed refusals. A map that would need any of these is never built, decoded or evaluated; nothing is
/// silently clamped, bridged, extrapolated or rounded instead.
public enum TimeMapError: Error, Equatable, Sendable {
    // Arithmetic and parameter envelope
    case zeroDenominator
    /// An exact intermediate would not fit `Int128`. The map (or query) is outside the exact-arithmetic
    /// envelope and is refused rather than approximated.
    case exactArithmeticEnvelopeExceeded
    case invalidNominalRate(Int64)
    case invalidFrameCount(Int64)
    case parameterOutsideEnvelope(String)

    // Segments (group clock -> aligned)
    case nonPositiveRateRatio
    case rateRatioOutsideEnvelope
    case nonPositiveSegmentLength
    case emptyEpochMap(RecordingEpochID)
    case segmentsOutOfOrder(RecordingEpochID)
    case overlappingSegments(RecordingEpochID)
    /// A hole inside one epoch's segments. A known gap must restart the epoch instead.
    case segmentsNotContiguous(RecordingEpochID)
    /// Adjacent segments of one epoch disagree at their shared boundary. A jump is a discontinuity and
    /// must be declared as an epoch restart; it is never accepted (or smoothed) inside an epoch.
    case discontinuityWithinEpoch(RecordingEpochID)
    case duplicateEpoch(RecordingEpochID)
    case overlappingEpochs(RecordingEpochID, RecordingEpochID)

    // Placements (source occurrence -> epoch)
    case duplicateOccurrence(SourceOccurrenceID)
    case emptyPlacement(SourceOccurrenceID)
    case nonPositiveSpanLength(SourceOccurrenceID)
    case spanOutsideSource(SourceOccurrenceID)
    case spansOutOfOrder(SourceOccurrenceID)
    case overlappingSpans(SourceOccurrenceID)
    /// Two consecutive spans of one occurrence (a known gap/discontinuity between them) use the same epoch.
    case gapMustRestartEpoch(SourceOccurrenceID, RecordingEpochID)
    case epochReusedWithinOccurrence(SourceOccurrenceID, RecordingEpochID)
    case unknownEpoch(RecordingEpochID)
    case placementNotCoveredByEpochMap(SourceOccurrenceID, RecordingEpochID)
    /// A later span of an occurrence lands at or before an earlier span on the aligned timeline.
    case nonMonotonicPlacement(SourceOccurrenceID)

    // Reference identity
    case referenceEpochMissing(RecordingEpochID)
    case referenceEpochNotIdentity(RecordingEpochID)
    case referenceOccurrenceNotAnchored(SourceOccurrenceID)
    case misplacedTimelineReference(RecordingEpochID)
    case referenceMismatch(RecorderGroupID)
    case missingReferenceGroup(RecorderGroupID)
    case duplicateGroup(RecorderGroupID)
    case occurrenceInMultipleGroups(SourceOccurrenceID)
    case epochInMultipleGroups(RecordingEpochID)

    // Provenance
    case clockApprovalGateNotMet([String])
    /// A `clockApproved` epoch whose approval was issued for a different epoch ID or different segments.
    case clockApprovalBindingMismatch(RecordingEpochID)
    case invalidMeasurement(String)
    case emptyDescription(String)

    // Queries
    case unknownOccurrence(SourceOccurrenceID)
}

/// Decoding refusals for persisted time maps (WW-020 will store them; this module does not).
public enum TimeMapDecodingError: Error, Equatable, Sendable {
    /// Written by a newer WaveWrangler. Never partially read, never downgraded.
    case unknownNewerSchemaVersion(found: Int, supported: Int)
    case unsupportedSchemaVersion(Int)
    case unknownKeys(type: String, keys: [String])
    case unknownKind(type: String, kind: String)
    case malformedRational(String)
}
