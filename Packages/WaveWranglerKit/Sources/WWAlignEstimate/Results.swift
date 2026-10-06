import Foundation
import WWCore
import WWTimeMap

/// Why a window was not used. Every window has exactly one status.
public enum WindowStatus: String, Sendable, Hashable, CaseIterable {
    case eligible
    /// The reference has no samples in this window's search region.
    case noReference
    /// Target window or reference search region is below the silence floor.
    case silent
    /// The window is self-similar at a non-trivial shift (periodic content).
    case periodic
    /// The correlation peak is below the minimum peak score.
    case weak
    /// The best peak lies on the edge of the searchable lag range (clipped region), so it cannot be located.
    case edgePeak
    /// A second correlation peak is too close in height to the first.
    case ambiguous
}

/// One analysis window. Offsets are aligned time minus group-clock time at the window centre.
public struct WindowMeasurement: Sendable, Hashable {
    public let index: Int
    /// Group-clock time of the window centre, seconds.
    public let groupClockCenter: Double
    public let status: WindowStatus
    /// Normalised-correlation peak (a correlation coefficient in -1...1, not a probability).
    public let peakScore: Double
    /// Highest other local correlation peak outside the main lobe.
    public let secondPeakScore: Double
    /// Highest self-similarity of the window at a non-trivial shift.
    public let periodicityScore: Double
    /// Measured offset when the peak was locatable (any status but noReference/silent), seconds.
    public let offsetSeconds: Double?
}

public enum AbstentionReason: String, Sendable, Hashable, CaseIterable {
    /// No reference material in reach of the declared overlap.
    case disconnected
    /// Correlation too weak (or unlocatable) in too many windows.
    case weak
    /// Competing correlation peaks in too many windows.
    case ambiguous
    /// Periodic content in too many windows.
    case periodic
    /// Silence in too many windows.
    case silent
    /// Eligible windows split into two internally consistent groups with a step between them.
    case discontinuous
    /// Eligible windows disagree with any single affine map, without a clean step.
    case inconsistent
    /// Eligible windows span too little of the declared overlap.
    case insufficientCoverage
    /// Fitted drift beyond the plausible range.
    case implausibleDrift
    /// A cycle through this epoch and two others does not close.
    case cycleInconsistent

    /// The WWTimeMap reason recorded for an abstained epoch.
    public var unsupportedReason: UnsupportedReason {
        switch self {
        case .disconnected: .disconnected
        case .insufficientCoverage: .insufficientOverlap
        case .discontinuous, .inconsistent: .nonlinear
        case .weak, .ambiguous, .periodic, .silent, .implausibleDrift, .cycleInconsistent: .estimatorAbstained
        }
    }
}

public enum EstimateFlag: String, Sendable, Hashable, CaseIterable {
    /// The group has more than one epoch in this request (declared restart); epochs were not bridged.
    case restartedEpoch
    /// Two or more consecutive non-eligible windows lie inside the eligible span.
    case coverageGap
    /// A step between consistent window groups was detected.
    case discontinuity
    /// A cycle through this epoch did not close.
    case cycleInconsistent
}

public struct WindowCoverage: Sendable, Hashable {
    /// Declared overlap, group-clock seconds.
    public let declaredStart: Double
    public let declaredEnd: Double
    public let windowCount: Int
    public let eligibleCount: Int
    /// eligibleCount / windowCount.
    public let eligibleWindowFraction: Double
    /// (last eligible window end - first eligible window start) / declared overlap length; 0 when none.
    public let eligibleSpanFraction: Double
}

/// Evidence measures. None of these is a probability, likelihood or chance of being right.
public struct EvidenceScores: Sendable, Hashable {
    /// Median correlation peak over eligible windows (0 when none).
    public let medianPeakScore: Double
    /// Median of 1 - second/first peak over eligible windows (0 when none).
    public let medianPeakMargin: Double
}

public enum CycleConsistency: Sendable, Hashable {
    /// Fewer than three epochs with proposals, or no overlapping pair: nothing to close.
    case unavailable
    /// Worst disagreement over the measured triangles through this epoch, milliseconds.
    case measured(triangles: Int, maximumMilliseconds: Double)
}

/// An acoustically consistent offset/drift proposal. It is NOT clock evidence (see the module header).
public struct AcousticProposal: Sendable, Hashable {
    /// The proposed map over exactly the declared overlap.
    public let segment: AffineClockSegment
    /// Fitted values before exact rounding (rate to 1 ppb, offset to 1 ns).
    public let ppm: Double
    public let offsetAtCenterSeconds: Double
    /// Residuals of the eligible windows against the fitted line, milliseconds (nearest-rank p95 and max).
    public let acousticResidualP95Milliseconds: Double
    public let acousticResidualMaxMilliseconds: Double
    /// The WWTimeMap provenance payload for this proposal.
    public let provenance: AcousticConsistencyProposal
}

public struct Abstention: Sendable, Hashable {
    public let reason: AbstentionReason
    public let detail: String
}

public enum EpochOutcome: Sendable, Hashable {
    case acousticConsistentProposal(AcousticProposal)
    case abstained(Abstention)
}

public struct EpochEstimate: Sendable, Hashable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    public let occurrence: SourceOccurrenceID
    public let outcome: EpochOutcome
    public let windows: [WindowMeasurement]
    public let coverage: WindowCoverage
    public let scores: EvidenceScores
    public let flags: Set<EstimateFlag>
    public let cycle: CycleConsistency

    /// The epoch map this estimate supports: the proposal as `acousticConsistentProposal`, or an
    /// unsupported epoch. Never `clockApproved`, never a guessed map for an abstention.
    public var epochClockMap: EpochClockMap {
        switch outcome {
        case .acousticConsistentProposal(let p):
            EpochClockMap(epoch: epoch, mapping: .mapped(segments: [p.segment], provenance: .acousticConsistentProposal(p.provenance)))
        case .abstained(let a):
            EpochClockMap(epoch: epoch, mapping: .unsupported(a.reason.unsupportedReason))
        }
    }
}

public struct EstimationReport: Sendable, Hashable {
    public let estimator: String
    public let epochs: [EpochEstimate]
}
