import Foundation
import WWCore

public enum ProgramTimelineError: Error, Sendable, Equatable {
    case invalidArrangement([ValidationIssue])
    case invalidAlignment([ValidationIssue])
    case invalidCuts
    case missingAcceptedAlignment
    case missingDialogueCoverage
    case invalidDialogueCoverage(Range<Int64>)
    case cutOutsideDialogueCoverage(Range<Int64>)
    case outsideFrameEnvelope(Int64)
    case arithmeticOverflow
    case mapIdentityFailure(String)
    case unsupportedAbsoluteInsertion(AudioInsertionRegionID)
    case nestedInsertion(AudioInsertionRegionID)
    case regionRequiresReview(AudioInsertionRegionID, AudioDialogueAnchor)
    case regionOutsideDialogueCoverage(AudioInsertionRegionID)
    case unknownInsertion(AudioInsertionRegionID)
    case invalidInsertionOffset(AudioInsertionRegionID, Int64)
    case placementRequiresReview(AudioDialogueAnchor)
    case placementOutsideDialogueCoverage
    case clipRequiresReview(AudioClipID, AudioDialogueAnchor)
    case clipOutsideDialogueCoverage(AudioClipID)
    case invalidClip(AudioClipID)
}

public enum ProgramDialoguePosition: Sendable, Equatable {
    case mapped(frame: Int64)
    case removed(interval: Range<Int64>, seam: Int64)
    case outsideCoverage
}

public enum ProgramInversePosition: Sendable, Equatable {
    /// An original-aligned coordinate, not proof that any particular speaker has a source sample.
    case dialogue(frame: Int64)
    case insertion(region: AudioInsertionRegionID, offsetFrames: Int64)
    case outsideCoverage
}

public enum AudioPlacementProjection: Sendable, Equatable {
    case placed(frame: Int64)
    case clampedToCutSeam(frame: Int64, removed: Range<Int64>)
    case reviewRequired(AudioDialogueAnchor)
    /// Retained for caller compatibility; finite sample coverage does not reject bound placement points.
    case outsideDialogueCoverage
}

public struct ProgramDialogueSpan: Sendable, Equatable {
    public let originalFrames: Range<Int64>
    public let programFrames: Range<Int64>
}

public struct ProgramInsertion: Sendable, Equatable {
    public let region: AudioInsertionRegion
    /// After merged dialogue removal, before insertion. Equal boundaries use saved region array order.
    public let baseFrame: Int64
    public let programFrames: Range<Int64>
}

public enum ProgramTimelineSegment: Sendable, Equatable {
    case dialogue(ProgramDialogueSpan)
    case insertion(region: AudioInsertionRegionID, offsetFrames: Int64, programFrames: Range<Int64>)
    case outsideDialogueCoverage(Range<Int64>)
}

/// One downstream, signed 48 kHz prescription. No source map, transcript, cut, or saved anchor is changed.
/// Dialogue coverage is caller-owned original-aligned coverage, including silent lane gaps; it is not
/// decoder coverage or an authorization. Production always collapses ALL active cuts, never Show cut.
public struct ProgramTimeline: Sendable, Equatable {
    public let dialogueFrames: Range<Int64>?
    public let cuts: ManualCutTimeline
    public let insertions: [ProgramInsertion]
    public let dialogueSpans: [ProgramDialogueSpan]
    public let arrangement: AudioArrangement

    private let binding: AudioDialogueAnchor?

    public init(episode: Episode, dialogueFrames: Range<Int64>? = nil) throws(ProgramTimelineError) {
        if let alignment = episode.alignment {
            let issues = alignment.structuralIssues(episode: episode.id)
            guard issues.isEmpty else { throw .invalidAlignment(issues) }
        }
        let accepted = episode.alignment?.acceptedMap
        if accepted != nil, dialogueFrames == nil { throw .missingDialogueCoverage }
        if let frames = dialogueFrames {
            guard accepted != nil else { throw .missingAcceptedAlignment }
            guard !frames.isEmpty else { throw .invalidDialogueCoverage(frames) }
            try Self.checkFrame(frames.lowerBound)
            try Self.checkFrame(frames.upperBound)
        }
        let arrangement = episode.audioArrangement ?? AudioArrangement()
        let issues = arrangement.validationIssues(in: episode)
        guard issues.isEmpty else { throw .invalidArrangement(issues) }
        let binding: AudioDialogueAnchor?
        do {
            binding = try accepted.map { try AudioDialogueAnchor(map: $0, frame: 0) }
        } catch { throw .mapIdentityFailure(String(describing: error)) }
        let activeCuts = episode.activeManualCuts
        guard Set(activeCuts.map(\.id)).count == activeCuts.count else { throw .invalidCuts }
        let cuts: ManualCutTimeline
        do { cuts = try ManualCutTimeline(cuts: activeCuts) } catch { throw .invalidCuts }
        if let frames = dialogueFrames {
            for removal in cuts.removals {
                guard removal.lowerBound >= frames.lowerBound, removal.upperBound <= frames.upperBound else {
                    throw .cutOutsideDialogueCoverage(removal)
                }
            }
        }
        var boundaries: [(index: Int, region: AudioInsertionRegion, frame: Int64)] = []
        for (index, region) in arrangement.insertionRegions.enumerated() {
            switch region.anchor {
            case .absolute: throw .unsupportedAbsoluteInsertion(region.id)
            case .insertion: throw .nestedInsertion(region.id)
            default: break
            }
            let frame: Int64
            switch try Self.basePosition(region.anchor, binding: binding, cuts: cuts) {
            case .placed(let value), .clampedToCutSeam(let value, _): frame = value
            case .reviewRequired(let anchor): throw .regionRequiresReview(region.id, anchor)
            case .outsideDialogueCoverage: throw .regionOutsideDialogueCoverage(region.id)
            }
            boundaries.append((index, region, frame))
        }
        boundaries.sort { $0.frame == $1.frame ? $0.index < $1.index : $0.frame < $1.frame }
        var inserted: Int64 = 0
        var insertions: [ProgramInsertion] = []
        for boundary in boundaries {
            let start = try Self.add(boundary.frame, inserted)
            let end = try Self.add(start, boundary.region.durationFrames)
            insertions.append(.init(region: boundary.region, baseFrame: boundary.frame, programFrames: start..<end))
            inserted = try Self.add(inserted, boundary.region.durationFrames)
        }
        self.dialogueFrames = dialogueFrames
        self.cuts = cuts
        self.arrangement = arrangement
        self.binding = binding
        self.insertions = insertions
        self.dialogueSpans = try Self.makeDialogueSpans(coverage: dialogueFrames, cuts: cuts, insertions: insertions)
    }

    /// Forward SAMPLE mapping. A removed frame is not a sample at the returned placement seam.
    public func dialoguePosition(atAlignedFrame frame: Int64) throws(ProgramTimelineError) -> ProgramDialoguePosition {
        try Self.checkFrame(frame)
        guard dialogueFrames?.contains(frame) == true else { return .outsideCoverage }
        let base = cuts.editedFrame(forAlignedFrame: frame)
        let program = try Self.insertedPosition(base, insertions: insertions)
        if let removal = cuts.removals.first(where: { $0.contains(frame) }) {
            return .removed(interval: removal, seam: program)
        }
        return .mapped(frame: program)
    }

    public func inverse(atProgramFrame frame: Int64) throws(ProgramTimelineError) -> ProgramInversePosition {
        try Self.checkFrame(frame)
        if let region = insertions.first(where: { $0.programFrames.contains(frame) }) {
            return .insertion(region: region.region.id, offsetFrames: frame - region.programFrames.lowerBound)
        }
        if let span = dialogueSpans.first(where: { $0.programFrames.contains(frame) }) {
            return .dialogue(frame: span.originalFrames.lowerBound + (frame - span.programFrames.lowerBound))
        }
        return .outsideCoverage
    }

    /// Placements are POSITIONS on the bound grid, including before/after finite dialogue coverage.
    /// A removed start clamps to its seam, downstream of all insertions there. No samples are invented.
    public func project(_ anchor: AudioPlacementAnchor) throws(ProgramTimelineError) -> AudioPlacementProjection {
        switch anchor {
        case .absolute(let frame):
            try Self.checkFrame(frame)
            return .placed(frame: frame)
        case .insertion(let id, let offset):
            guard let region = insertions.first(where: { $0.region.id == id }) else { throw .unknownInsertion(id) }
            guard offset >= 0, offset < region.region.durationFrames else { throw .invalidInsertionOffset(id, offset) }
            return .placed(frame: try Self.add(region.programFrames.lowerBound, offset))
        case .dialogue, .programOrigin:
            switch try Self.basePosition(anchor, binding: binding, cuts: cuts) {
            case .placed(let frame):
                return .placed(frame: try Self.insertedPosition(frame, insertions: insertions))
            case .clampedToCutSeam(let frame, let removal):
                return .clampedToCutSeam(
                    frame: try Self.insertedPosition(frame, insertions: insertions), removed: removal)
            case .reviewRequired(let anchor): return .reviewRequired(anchor)
            case .outsideDialogueCoverage: return .outsideDialogueCoverage
            }
        }
    }

    /// Inverse-anchor against THIS projection, not the unedited map. This avoids applying prior edits
    /// twice. Insertion interiors retain region identity. With accepted timing, outside-coverage points
    /// use that bound original-aligned GRID, not extrapolated samples; audio-only uses program origin.
    public func unpinnedAnchor(atProgramFrame frame: Int64) throws(ProgramTimelineError) -> AudioPlacementAnchor {
        switch try inverse(atProgramFrame: frame) {
        case .insertion(let id, let offset): return .insertion(region: id, offsetFrames: offset)
        case .dialogue(let original):
            guard var anchor = binding else { throw .missingAcceptedAlignment }
            anchor.frame = original
            return .dialogue(anchor)
        case .outsideCoverage:
            let base = try baseFrame(atProgramPosition: frame)
            if let binding {
                let original = cuts.alignedFrame(forEditedFrame: base)
                try Self.checkFrame(original)
                var anchor = binding
                anchor.frame = original
                return .dialogue(anchor)
            }
            return .programOrigin(frame: base)
        }
    }

    public func pinnedAnchor(for anchor: AudioPlacementAnchor) throws(ProgramTimelineError) -> AudioPlacementAnchor {
        .absolute(frame: try resolvedFrame(for: anchor))
    }

    public func unpinnedAnchor(for anchor: AudioPlacementAnchor) throws(ProgramTimelineError) -> AudioPlacementAnchor {
        try unpinnedAnchor(atProgramFrame: resolvedFrame(for: anchor))
    }

    /// Same-clip edits retain an unchanged anchor and never implicitly reconcile program origin
    /// onto the dialogue grid. Explicit moves into inserted time still acquire region affinity.
    public func relocatedAnchor(for anchor: AudioPlacementAnchor, toProgramFrame frame: Int64)
        throws(ProgramTimelineError) -> AudioPlacementAnchor
    {
        try Self.checkFrame(frame)
        if try resolvedFrame(for: anchor) == frame { return anchor }
        switch anchor {
        case .absolute:
            return .absolute(frame: frame)
        case .programOrigin:
            if case .insertion(let id, let offset) = try inverse(atProgramFrame: frame) {
                return .insertion(region: id, offsetFrames: offset)
            }
            return .programOrigin(frame: try baseFrame(atProgramPosition: frame))
        case .dialogue, .insertion:
            return try unpinnedAnchor(atProgramFrame: frame)
        }
    }

    /// Preserve the resolved position when explicitly admitting a program-origin clip to dialogue.
    /// The caller applies the returned anchor through F1's normal model transaction/Undo path.
    public func reconciledAnchor(for anchor: AudioPlacementAnchor) throws(ProgramTimelineError) -> AudioPlacementAnchor
    {
        switch anchor {
        case .programOrigin:
            return try unpinnedAnchor(for: anchor)
        default: return anchor
        }
    }

    /// Exact, contiguous request partition. Outside dialogue and insertion-only intervals are explicit;
    /// callers must still ask their existing accepted-map adapters for per-lane source coverage.
    public func segments(in frames: Range<Int64>) throws(ProgramTimelineError) -> [ProgramTimelineSegment] {
        try Self.checkFrame(frames.lowerBound)
        try Self.checkFrame(frames.upperBound)
        var pieces: [(range: Range<Int64>, segment: ProgramTimelineSegment)] = []
        for span in dialogueSpans {
            let lo = max(frames.lowerBound, span.programFrames.lowerBound)
            let hi = min(frames.upperBound, span.programFrames.upperBound)
            if lo < hi {
                let original = span.originalFrames.lowerBound + (lo - span.programFrames.lowerBound)
                let bounded = ProgramDialogueSpan(
                    originalFrames: original..<(original + hi - lo), programFrames: lo..<hi)
                pieces.append((lo..<hi, .dialogue(bounded)))
            }
        }
        for insertion in insertions {
            let lo = max(frames.lowerBound, insertion.programFrames.lowerBound)
            let hi = min(frames.upperBound, insertion.programFrames.upperBound)
            if lo < hi {
                pieces.append(
                    (
                        lo..<hi,
                        .insertion(
                            region: insertion.region.id,
                            offsetFrames: lo - insertion.programFrames.lowerBound, programFrames: lo..<hi)
                    ))
            }
        }
        pieces.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result: [ProgramTimelineSegment] = []
        var cursor = frames.lowerBound
        for piece in pieces {
            if cursor < piece.range.lowerBound {
                result.append(.outsideDialogueCoverage(cursor..<piece.range.lowerBound))
            }
            result.append(piece.segment)
            cursor = piece.range.upperBound
        }
        if cursor < frames.upperBound { result.append(.outsideDialogueCoverage(cursor..<frames.upperBound)) }
        return result
    }

    private func baseFrame(atProgramPosition frame: Int64) throws(ProgramTimelineError) -> Int64 {
        var inserted: Int64 = 0
        for region in insertions where region.programFrames.upperBound <= frame {
            inserted = try Self.add(inserted, region.region.durationFrames)
        }
        return try Self.add(frame, -inserted)
    }

    private func resolvedFrame(for anchor: AudioPlacementAnchor) throws(ProgramTimelineError) -> Int64 {
        switch try project(anchor) {
        case .placed(let frame), .clampedToCutSeam(let frame, _): return frame
        case .reviewRequired(let anchor): throw .placementRequiresReview(anchor)
        case .outsideDialogueCoverage: throw .placementOutsideDialogueCoverage
        }
    }

    private static func basePosition(
        _ anchor: AudioPlacementAnchor, binding: AudioDialogueAnchor?,
        cuts: ManualCutTimeline
    )
        throws(ProgramTimelineError) -> AudioPlacementProjection
    {
        switch anchor {
        case .programOrigin(let frame), .absolute(let frame):
            try checkFrame(frame)
            return .placed(frame: frame)
        case .dialogue(let anchor):
            try checkFrame(anchor.frame)
            guard let binding, anchor.alignmentRevision == binding.alignmentRevision,
                anchor.mapIdentity == binding.mapIdentity
            else { return .reviewRequired(anchor) }
            let frame = cuts.editedFrame(forAlignedFrame: anchor.frame)
            try checkFrame(frame)
            if let removal = cuts.removals.first(where: { $0.contains(anchor.frame) }) {
                return .clampedToCutSeam(frame: frame, removed: removal)
            }
            return .placed(frame: frame)
        case .insertion(let id, _): throw .nestedInsertion(id)
        }
    }

    private static func insertedPosition(_ frame: Int64, insertions: [ProgramInsertion])
        throws(ProgramTimelineError) -> Int64
    {
        var lo = 0
        var hi = insertions.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if insertions[mid].baseFrame <= frame { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return frame }
        let last = insertions[lo - 1]
        return try add(frame, last.programFrames.upperBound - last.baseFrame)
    }

    private static func makeDialogueSpans(
        coverage: Range<Int64>?, cuts: ManualCutTimeline,
        insertions: [ProgramInsertion]
    )
        throws(ProgramTimelineError) -> [ProgramDialogueSpan]
    {
        guard let coverage else { return [] }
        var kept: [(original: Range<Int64>, baseStart: Int64)] = []
        var cursor = coverage.lowerBound
        var removed: Int64 = 0
        for cut in cuts.removals {
            if cursor < cut.lowerBound {
                kept.append((cursor..<cut.lowerBound, try add(cursor, -removed)))
            }
            removed += cut.upperBound - cut.lowerBound
            cursor = cut.upperBound
        }
        if cursor < coverage.upperBound {
            kept.append((cursor..<coverage.upperBound, try add(cursor, -removed)))
        }
        var result: [ProgramDialogueSpan] = []
        var insertionIndex = 0
        for (original, baseStart) in kept {
            let baseEnd = try add(baseStart, original.upperBound - original.lowerBound)
            while insertionIndex < insertions.count, insertions[insertionIndex].baseFrame <= baseStart {
                insertionIndex += 1
            }
            var boundaries = [baseStart]
            while insertionIndex < insertions.count, insertions[insertionIndex].baseFrame < baseEnd {
                let boundary = insertions[insertionIndex].baseFrame
                if boundaries.last != boundary { boundaries.append(boundary) }
                insertionIndex += 1
            }
            boundaries.append(baseEnd)
            for (lo, hi) in zip(boundaries, boundaries.dropFirst()) {
                let start = try insertedPosition(lo, insertions: insertions)
                let end = try add(start, hi - lo)
                let aligned = original.lowerBound + (lo - baseStart)
                result.append(.init(originalFrames: aligned..<(aligned + hi - lo), programFrames: start..<end))
            }
        }
        return result
    }

    static func checkFrame(_ frame: Int64) throws(ProgramTimelineError) {
        guard (-AudioArrangement.frameLimit...AudioArrangement.frameLimit).contains(frame) else {
            throw .outsideFrameEnvelope(frame)
        }
    }

    static func add(_ left: Int64, _ right: Int64) throws(ProgramTimelineError) -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw .arithmeticOverflow }
        try checkFrame(sum)
        return sum
    }
}
