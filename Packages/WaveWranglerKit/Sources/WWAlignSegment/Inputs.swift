import Foundation
import WWAlignEstimate
import WWCore
import WWTimeMap

// WWAlignSegment (WW-017): discontinuity detection and segmentation between the WW-016 estimator and the
// WWTimeMap group map.
//
// Hard rules (docs/m2/ww-019-m2-contracts.md M2-C3/M2-C4, issue #11):
// * Never fit one smooth map across a jump. A recorder group's occurrence is measured densely with the frozen
//   WW-016 estimator (`AcousticEstimator`, public API only), split where one affine line no longer explains
//   the window offsets, and every frame that cannot be localised to the gate's tolerance is UNSUPPORTED
//   (manual), never guessed. Each discontinuity becomes an epoch restart in the WWTimeMap placement.
// * Supported regions carry the frozen estimator's own `acousticConsistentProposal` for exactly that region.
//   Nothing here can construct a clock approval: audio measures where sound arrived, not when a clock ticked.
// * Detections carry evidence measures (position, size, window counts, correlation peaks), never
//   probabilities.
// * Pure and synchronous: decoded buffers in, a validated `GroupTimeMap` out. No file, content or decode
//   API (WWAlignSegmentTests and the repository-wide ForbiddenAPITests scan it). Callers run it off the main
//   thread.

public enum SegmentError: Error, Equatable, Sendable {
    /// The frozen estimator refused an input (for example an invalid buffer slice or search range).
    case estimator(AlignEstimateError)
    /// A region could not be expressed exactly as a WWTimeMap span, segment or group map.
    case timeMap(TimeMapError)
    /// The request is inconsistent (detail names the rule).
    case invalidRequest(String)
}

/// One caller-declared span of the occurrence: frames recorded within one declared clock epoch. Declared
/// boundaries (for example a known restart) are never bridged; the segmenter may split a declared span
/// further, giving each extra region a fresh epoch.
public struct DeclaredSpan: Sendable, Hashable {
    /// Half-open frame range within the occurrence.
    public let frames: Range<Int64>
    public let epoch: RecordingEpochID
    /// e in `u = n/F + e` for this span (group-clock seconds of frame 0's extension).
    public let groupClockOffset: ExactRational

    public init(frames: Range<Int64>, epoch: RecordingEpochID, groupClockOffset: ExactRational) {
        self.frames = frames
        self.epoch = epoch
        self.groupClockOffset = groupClockOffset
    }
}

/// One occurrence of a target recorder group, measured against the timeline reference.
public struct SegmentationRequest: Sendable {
    /// The timeline reference track (aligned time == its group clock). Its group must differ from `group`.
    public let reference: EstimatorTrack
    public let group: RecorderGroupID
    public let occurrence: SourceOccurrence
    /// The occurrence's decoded samples: exactly `occurrence.frameCount` frames at its nominal rate.
    public let buffer: SampleBuffer
    /// Ascending, disjoint, non-empty spans with distinct epochs. Frames outside every span are not placed.
    public let declaredSpans: [DeclaredSpan]
    public let search: SearchRange

    public init(reference: EstimatorTrack, group: RecorderGroupID, occurrence: SourceOccurrence, buffer: SampleBuffer, declaredSpans: [DeclaredSpan], search: SearchRange) {
        self.reference = reference
        self.group = group
        self.occurrence = occurrence
        self.buffer = buffer
        self.declaredSpans = declaredSpans
        self.search = search
    }
}

/// Segmenter parameters. The defaults are the values frozen by `m2-freeze-discontinuity`
/// (docs/m2/fixtures/m2-freeze-discontinuity.json); a change is a new segmenter version and needs a new
/// freeze. Setters are internal, so public callers can only run the frozen defaults; in-module (test)
/// variants are stamped `DiscontinuitySegmenter.customIdentifier`, never the frozen identifier.
public struct SegmenterParameters: Sendable, Equatable {
    /// Length of each dense-pass tile handed to the estimator, seconds. With the estimator's 16 windows of
    /// 2 s, an 8 s tile places a window centre every 0.4 s.
    public internal(set) var tileSeconds: Double = 8
    /// Extra samples either side of a tile or region slice (inside its declared span) so the estimator's
    /// proxy filter settles before the first window, seconds.
    public internal(set) var slicePaddingSeconds: Double = 0.5
    /// Every window of a supported segment lies within this distance of one affine line, milliseconds.
    public internal(set) var splitToleranceMilliseconds: Double = 0.5
    /// A boundary whose line jump exceeds this multiple of the split tolerance is an offset step;
    /// otherwise it is a slope (rate) change, localised by the lines' intersection.
    public internal(set) var stepToleranceFactor: Double = 2
    /// Fewer consistent windows than this cannot form a segment (they are unresolved evidence).
    public internal(set) var minimumSegmentWindows: Int = 5
    /// Supported regions shorter than this stay unsupported, seconds.
    public internal(set) var minimumSupportedSeconds: Double = 4
    /// The frozen estimator's proposal for a region must agree with the segment line at both ends,
    /// milliseconds; otherwise the region stays unsupported.
    public internal(set) var proposalAgreementMilliseconds: Double = 1

    public init() {}

    func validate() throws(SegmentError) {
        func check(_ ok: Bool, _ name: String) throws(SegmentError) { if !ok { throw .invalidRequest("parameter \(name)") } }
        let window = EstimatorParameters().windowSeconds
        try check(tileSeconds.isFinite && tileSeconds > window && tileSeconds <= 60, "tileSeconds")
        try check(slicePaddingSeconds.isFinite && slicePaddingSeconds >= 0 && slicePaddingSeconds <= 5, "slicePaddingSeconds")
        try check(splitToleranceMilliseconds.isFinite && splitToleranceMilliseconds > 0 && splitToleranceMilliseconds <= EstimatorParameters().consistencyToleranceMilliseconds, "splitToleranceMilliseconds")
        try check(stepToleranceFactor.isFinite && stepToleranceFactor >= 1 && stepToleranceFactor <= 20, "stepToleranceFactor")
        try check(minimumSegmentWindows >= 3 && minimumSegmentWindows <= 64, "minimumSegmentWindows")
        try check(minimumSupportedSeconds.isFinite && minimumSupportedSeconds >= window && minimumSupportedSeconds <= 600, "minimumSupportedSeconds")
        try check(proposalAgreementMilliseconds.isFinite && proposalAgreementMilliseconds > 0 && proposalAgreementMilliseconds <= ProvisionalClockGates.maximumResidualP95Milliseconds, "proposalAgreementMilliseconds")
    }
}
