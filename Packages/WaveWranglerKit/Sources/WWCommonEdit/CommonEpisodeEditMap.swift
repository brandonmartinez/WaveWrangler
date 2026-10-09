import Foundation
import WWCore
import WWTimeMap

/// A half-open interval on the episode's shared, aligned output-frame grid.
public struct RemovedFrameSpan: Sendable, Hashable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

/// A source interval and its destination in the shortened, common output grid.
public struct KeptFrameSpan: Sendable, Hashable {
    public let alignedStart: Int64
    public let alignedEnd: Int64
    public let outputStart: Int64

    public var outputEnd: Int64 { outputStart + (alignedEnd - alignedStart) }
}

public enum CommonEpisodeEditMapError: Error, Equatable, Sendable {
    case invalidTimelineLength(Int64)
    case alignedFrameEndOverflow(origin: Int64, count: Int64)
    case invalidRemoval(RemovedFrameSpan)
    case removalsOutOfOrder
    case overlappingRemovals
}

/// A position on the shared output grid; a rounded boundary position may equal `outputFrameCount`.
public struct CommonOutputPosition: Sendable, Hashable {
    public let exactFrame: ExactRational
    public let nearestFrame: Int64
}

public enum CommonAlignedOutputMapping: Sendable, Hashable {
    case mapped(CommonOutputPosition)
    case removed(RemovedFrameSpan)
    case outsideCoverage
}

public enum CommonSourceOutputMapping: Sendable, Hashable {
    case mapped(position: CommonOutputPosition, aligned: AlignedPosition)
    case removed(aligned: AlignedPosition, span: RemovedFrameSpan)
    case gap(GapBoundary)
    case unsupported(epoch: RecordingEpochID, reason: UnsupportedReason)
    case outsideCoverage
}

/// Pure WW-043 frame prescription; no cut approval, fade, sample copying, or independent per-track ripple.
///
/// `alignedFrameOrigin` is a signed frame index relative to the M2 reference's t=0. Together with
/// `alignedFrameCount` it defines `[origin, origin + count)` on ONE output-rate grid. Removals and kept
/// aligned endpoints use those absolute indices; output frames start at zero. Each kept span is copied
/// at the same output offsets for every track, including silent tracks; uncovered occurrence regions
/// remain gaps/unsupported as classified by `AlignedTimelineMap`, never invented samples.
/// The two revision tokens are caller-owned dependency keys, not evidence of acceptance. Compare the
/// complete value (including the upstream map and removals) for deterministic undo/identity.
public struct CommonEpisodeEditMap: Sendable, Equatable {
    public let alignment: AlignedTimelineMap
    public let alignmentRevision: UInt64
    public let editRevision: UInt64
    public let outputRate: NominalRate
    public let alignedFrameOrigin: Int64
    public let alignedFrameCount: Int64
    public let alignedFrameEnd: Int64
    public let removals: [RemovedFrameSpan]
    public let keptSpans: [KeptFrameSpan]
    public let outputFrameCount: Int64

    public init(
        alignment: AlignedTimelineMap,
        alignmentRevision: UInt64,
        editRevision: UInt64,
        outputRate: NominalRate,
        alignedFrameOrigin: Int64,
        alignedFrameCount: Int64,
        removals: [RemovedFrameSpan]
    ) throws(CommonEpisodeEditMapError) {
        guard alignedFrameCount >= 0, alignedFrameCount <= TimeMapEnvelope.maxFrameCount else {
            throw .invalidTimelineLength(alignedFrameCount)
        }
        let (end, overflow) = alignedFrameOrigin.addingReportingOverflow(alignedFrameCount)
        guard !overflow else {
            throw .alignedFrameEndOverflow(origin: alignedFrameOrigin, count: alignedFrameCount)
        }
        var kept: [KeptFrameSpan] = []
        var cursor = alignedFrameOrigin
        var output: Int64 = 0
        for (index, span) in removals.enumerated() {
            guard span.start >= alignedFrameOrigin, span.start < span.end, span.end <= end else {
                throw .invalidRemoval(span)
            }
            if index > 0, span.start < removals[index - 1].start { throw .removalsOutOfOrder }
            if span.start < cursor { throw .overlappingRemovals }
            if span.start > cursor {
                kept.append(KeptFrameSpan(alignedStart: cursor, alignedEnd: span.start, outputStart: output))
                output += span.start - cursor
            }
            cursor = span.end
        }
        if cursor < end {
            kept.append(KeptFrameSpan(alignedStart: cursor, alignedEnd: end, outputStart: output))
            output += end - cursor
        }
        self.alignment = alignment
        self.alignmentRevision = alignmentRevision
        self.editRevision = editRevision
        self.outputRate = outputRate
        self.alignedFrameOrigin = alignedFrameOrigin
        self.alignedFrameCount = alignedFrameCount
        self.alignedFrameEnd = end
        self.removals = removals
        self.keptSpans = kept
        self.outputFrameCount = output
    }

    /// Exact shortened duration, including any silent padding the caller supplies in the aligned domain.
    public var outputDuration: ExactRational { outputRate.instant(ofFrame: outputFrameCount) }

    /// Output sample -> original aligned time. The seam belongs to the following kept span.
    public func alignedInstant(atOutputFrame frame: Int64) -> ExactRational? {
        guard frame >= 0, frame < outputFrameCount,
              let span = keptSpans.first(where: { frame >= $0.outputStart && frame < $0.outputEnd })
        else { return nil }
        return outputRate.instant(ofFrame: span.alignedStart + (frame - span.outputStart))
    }

    /// Partial inverse: removed instants are reported, never mapped to a neighbouring seam. Off-grid
    /// positions stay exact until HALF-UP quantisation; the rounded value is a position, not a sample.
    public func outputPosition(atAlignedInstant instant: ExactRational) throws(TimeMapError) -> CommonAlignedOutputMapping {
        guard instant >= outputRate.instant(ofFrame: alignedFrameOrigin),
              instant < outputRate.instant(ofFrame: alignedFrameEnd) else { return .outsideCoverage }
        let frame = try instant.multiplied(by: ExactRational(outputRate.framesPerSecond))
        if let removal = removals.first(where: { frame >= ExactRational($0.start) && frame < ExactRational($0.end) }) {
            return .removed(removal)
        }
        guard let span = keptSpans.first(where: { frame >= ExactRational($0.alignedStart) && frame < ExactRational($0.alignedEnd) }) else {
            return .outsideCoverage
        }
        let exact = try frame.subtracting(ExactRational(span.alignedStart)).adding(ExactRational(span.outputStart))
        return .mapped(CommonOutputPosition(exactFrame: exact, nearestFrame: Int64(exact.roundedHalfUp())))
    }

    /// An absent, gapped or unsupported source remains absent; never invert a gap across an edit seam.
    public func sourceFrame(atOutputFrame frame: Int64, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> InverseMapping {
        guard alignment.group(containing: occurrence) != nil else { throw .unknownOccurrence(occurrence) }
        guard let instant = alignedInstant(atOutputFrame: frame) else { return .outsideCoverage }
        return try alignment.sourceFrame(at: instant, in: occurrence)
    }

    /// Inverse for a *specific* occurrence (repeated source uses are never conflated).
    public func outputFrame(ofSourceFrame frame: Int64, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> CommonSourceOutputMapping {
        switch try alignment.alignedTime(ofFrame: frame, in: occurrence) {
        case .aligned(let aligned):
            switch try outputPosition(atAlignedInstant: aligned.instant) {
            case .mapped(let position): return .mapped(position: position, aligned: aligned)
            case .removed(let span): return .removed(aligned: aligned, span: span)
            case .outsideCoverage: return .outsideCoverage
            }
        case .gap(let boundary): return .gap(boundary)
        case .unsupported(let epoch, let reason): return .unsupported(epoch: epoch, reason: reason)
        case .outsideCoverage: return .outsideCoverage
        }
    }
}
