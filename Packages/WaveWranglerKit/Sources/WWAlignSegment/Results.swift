import Foundation
import WWAlignEstimate
import WWCore
import WWTimeMap

/// What kind of boundary separates two measured segments of a declared span.
public enum DiscontinuityKind: String, Sendable, Hashable, CaseIterable {
    /// The two segment lines jump at the boundary (dropped or inserted samples, a clock step, a restart).
    case offsetStep
    /// The lines meet but their slopes differ (a rate change); localised by their intersection.
    case slopeChange
    /// Windows between the two segments fit neither line nor form a segment of their own.
    case unresolved
}

/// One detected discontinuity. All values are evidence measures, never probabilities.
public struct Discontinuity: Sendable, Hashable {
    public let kind: DiscontinuityKind
    /// The declared span (by its declared epoch) the discontinuity lies in.
    public let declaredEpoch: RecordingEpochID
    /// Group-clock interval (seconds) that must contain the discontinuity given the window evidence. It is
    /// unsupported in the map.
    public let bracket: ClosedRange<Double>
    /// The bracket as occurrence frames (half-open, clipped to the declared span).
    public let frames: Range<Int64>
    /// Best group-clock position: the lines' intersection for a slope change, otherwise the midpoint
    /// between the last window of the left segment and the first window of the right segment.
    public let position: Double
    /// Right line minus left line at the midpoint between the bracketing windows, milliseconds (positive:
    /// later content jumps later on the aligned timeline, as for dropped samples).
    public let stepMilliseconds: Double
    /// Right slope minus left slope, ppm.
    public let slopeChangePPM: Double
    public let leftWindowCount: Int
    public let rightWindowCount: Int
    /// Windows between the segments that fit neither (unresolved evidence).
    public let unresolvedWindowCount: Int
    /// Worst residual of each side's windows against its own line, milliseconds.
    public let leftResidualMaxMilliseconds: Double
    public let rightResidualMaxMilliseconds: Double
    /// Median correlation peak of each side's windows (coefficients, not probabilities).
    public let leftMedianPeakScore: Double
    public let rightMedianPeakScore: Double
    /// Status counts of the dense windows centred inside the bracket.
    public let bracketWindowStatus: [WindowStatus: Int]
}

/// Why a region has no supported map.
public enum RegionCause: Sendable, Hashable {
    /// The region is (part of) the bracket of these detections (indices into the report's detections).
    case discontinuity([Int])
    /// Consistent windows here belong to no segment (too few or fitting no line).
    case unresolvedWindows(Int)
    /// No usable window evidence; `dominant` is the most frequent non-eligible window status centred here.
    case noEvidence(dominant: WindowStatus)
    /// Within half a window of the last evidence of a segment: a step here could not be seen.
    case edgeMargin
    /// The supported candidate was shorter than the minimum supported length.
    case tooShort
    /// The frozen estimator abstained on the candidate region.
    case estimatorAbstained(AbstentionReason)
    /// The estimator's proposal disagreed with the segment line by this much at a region end, milliseconds.
    case lineDisagreement(Double)
    /// The candidate's aligned image overlapped a neighbouring mapped region's (not monotonic).
    case imageOverlap
}

public enum RegionOutcome: Sendable, Hashable {
    /// The frozen estimator's proposal for exactly this region. Never a clock approval.
    case supported(AcousticProposal)
    case unsupported(UnsupportedReason, RegionCause)
}

/// One placed region of the occurrence: a WWTimeMap span with its own epoch.
public struct SegmentRegion: Sendable, Hashable {
    public let frames: Range<Int64>
    public let epoch: RecordingEpochID
    /// The declared epoch this region was split from (lineage).
    public let declaredEpoch: RecordingEpochID
    public let groupClockOffset: ExactRational
    public let outcome: RegionOutcome

    public var isSupported: Bool {
        if case .supported = outcome { return true }
        return false
    }
}

/// One dense-pass window (a frozen-estimator window measured inside a tile).
public struct DenseWindow: Sendable, Hashable {
    public let declaredEpoch: RecordingEpochID
    public let groupClockCenter: Double
    public let status: WindowStatus
    public let peakScore: Double
    public let secondPeakScore: Double
    /// Aligned minus group-clock time at the window centre, seconds (nil for noReference/silent).
    public let offsetSeconds: Double?
}

public struct SegmentationReport: Sendable {
    /// Segmenter identifier (`ww-align-segment/1` for the frozen defaults).
    public let segmenter: String
    /// Identifier of the estimator that produced every window and proposal.
    public let estimator: String
    /// Every frame of every declared span, in frame order.
    public let regions: [SegmentRegion]
    public let detections: [Discontinuity]
    public let windows: [DenseWindow]
    /// The validated group map: one epoch per region, the occurrence placed by its regions.
    public let map: GroupTimeMap
}
