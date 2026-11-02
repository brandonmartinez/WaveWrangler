import Foundation
import WWCommonEdit
import WWCore

/// Whole-value downstream edits. No source, clock, transcript, cut, or clip audio is rewritten.
struct AudioInsertionEditing {
    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    struct Edit {
        let arrangement: AudioArrangement
        let before: ProgramComposition
        let after: ProgramComposition
        let regionID: AudioInsertionRegionID
        let position: Int64
        let clampedClips: Set<AudioClipID>
        let retargetedClip: AudioClipID?
    }

    let episode: Episode
    let composition: ProgramComposition

    init(episode: Episode, composition: ProgramComposition) throws {
        guard try ProgramTimeline(episode: episode, dialogueFrames: composition.timeline.dialogueFrames)
            .composition() == composition else {
            throw Refusal("The program changed. Reopen inserted-time editing against the current projection.")
        }
        self.episode = episode
        self.composition = composition
    }

    var introPosition: Int64 {
        let starts = composition.timeline.dialogueSpans.map(\.programFrames.lowerBound)
            + composition.timeline.insertions.map(\.programFrames.lowerBound)
            + composition.clips.compactMap { clip -> Int64? in
                if case .absolute = clip.clip.anchor { return nil }
                return clip.programFrames.lowerBound
            }
        return starts.min() ?? composition.programFrames?.lowerBound ?? 0
    }

    func inserting(at frame: Int64, duration: Int64, moving clipID: AudioClipID? = nil,
                   id: AudioInsertionRegionID = AudioInsertionRegionID()) throws -> Edit {
        try checkDuration(duration)
        let site = try insertionSite(at: frame, timeline: composition.timeline)
        var arrangement = composition.timeline.arrangement
        let region = AudioInsertionRegion(id: id, anchor: site.anchor, durationFrames: duration)
        arrangement.insertionRegions.insert(region, at: site.index ?? arrangement.insertionRegions.endIndex)
        if let clipID {
            guard let index = arrangement.clips.firstIndex(where: { $0.id == clipID }) else {
                throw Refusal("The selected clip is no longer available.")
            }
            if case .absolute = arrangement.clips[index].anchor {
                arrangement.clips[index].anchor = .absolute(frame: frame)
            } else {
                arrangement.clips[index].anchor = .insertion(region: id, offsetFrames: 0)
            }
        }
        return try result(arrangement, region: id, position: frame, retargeted: clipID)
    }

    /// A position is specified on the program with this region removed. Existing region-relative
    /// starts follow a moved region; only offsets in a removed tail clamp to the new tail seam.
    func replacing(_ id: AudioInsertionRegionID, at frame: Int64, duration: Int64) throws -> Edit {
        try checkDuration(duration)
        let old = try region(id)
        if frame == old.programFrames.lowerBound {
            var arrangement = composition.timeline.arrangement
            let index = try savedIndex(id)
            arrangement.insertionRegions[index].durationFrames = duration
            return try repairing(arrangement, region: id, position: frame, duration: duration)
        }
        let removed = try removing(id)
        let site = try insertionSite(at: frame, timeline: removed.after.timeline)
        var arrangement = removed.arrangement
        var replacement = old.region
        replacement.anchor = site.anchor
        replacement.durationFrames = duration
        arrangement.insertionRegions.insert(replacement, at: site.index ?? arrangement.insertionRegions.endIndex)
        // Removal re-anchors these clips for its standalone result; a move retains region affinity.
        for (index, clip) in composition.timeline.arrangement.clips.enumerated() {
            if case .insertion(let region, _) = clip.anchor, region == id {
                arrangement.clips[index].anchor = clip.anchor
            }
        }
        return try repairing(arrangement, region: id, position: frame, duration: duration)
    }

    func removing(_ id: AudioInsertionRegionID) throws -> Edit {
        let old = try region(id)
        var arrangement = composition.timeline.arrangement
        arrangement.insertionRegions.remove(at: try savedIndex(id))
        return try repairing(arrangement, region: id, position: old.programFrames.lowerBound, duration: 0)
    }

    private func repairing(_ proposed: AudioArrangement, region id: AudioInsertionRegionID,
                           position: Int64, duration: Int64) throws -> Edit {
        var arrangement = proposed
        let affected = arrangement.clips.filter {
            if case .insertion(let region, let offset) = $0.anchor {
                return region == id && offset >= duration
            }
            return false
        }
        // Build the resulting timeline without dangling starts, then inverse-anchor at its seam.
        let affectedIDs = Set(affected.map(\.id))
        arrangement.clips.removeAll { affectedIDs.contains($0.id) }
        let timeline = try project(arrangement).timeline
        let seam: Int64
        if duration == 0 { seam = position }
        else {
            guard let insertion = timeline.insertions.first(where: { $0.region.id == id }) else {
                throw Refusal("The inserted-time region is no longer available.")
            }
            seam = insertion.programFrames.upperBound
        }
        let anchor = affected.isEmpty ? nil : try timeline.unpinnedAnchor(atProgramFrame: seam)
        var repaired = proposed
        for index in repaired.clips.indices where affectedIDs.contains(repaired.clips[index].id) {
            if let anchor { repaired.clips[index].anchor = anchor }
        }
        return try result(repaired, region: id, position: position, clamped: affectedIDs)
    }

    private func result(_ arrangement: AudioArrangement, region: AudioInsertionRegionID, position: Int64,
                        clamped: Set<AudioClipID> = [], retargeted: AudioClipID? = nil) throws -> Edit {
        let after = try project(arrangement)
        guard (after.timeline.insertions.first(where: { $0.region.id == region })?.programFrames.lowerBound
                ?? position) == position else {
            throw Refusal("This boundary cannot represent the requested program position.")
        }
        return Edit(arrangement: arrangement, before: composition, after: after, regionID: region,
                    position: position, clampedClips: clamped, retargetedClip: retargeted)
    }

    private func project(_ arrangement: AudioArrangement) throws -> ProgramComposition {
        var next = episode
        next.audioArrangement = arrangement
        return try ProgramTimeline(episode: next, dialogueFrames: composition.timeline.dialogueFrames).composition()
    }

    private func insertionSite(at frame: Int64, timeline: ProgramTimeline)
        throws -> (anchor: AudioPlacementAnchor, index: Int?) {
        guard (-AudioArrangement.frameLimit...AudioArrangement.frameLimit).contains(frame) else {
            throw Refusal("Program positions must be within minus 24 to plus 24 hours.")
        }
        if let boundary = timeline.insertions.first(where: { $0.programFrames.lowerBound == frame }) {
            return (boundary.region.anchor,
                    timeline.arrangement.insertionRegions.firstIndex { $0.id == boundary.region.id })
        }
        let anchor = try timeline.unpinnedAnchor(atProgramFrame: frame)
        if case .insertion = anchor {
            throw Refusal("This position is inside inserted time. Choose its start or end boundary; regions cannot nest.")
        }
        return (anchor, nil)
    }

    private func region(_ id: AudioInsertionRegionID) throws -> ProgramInsertion {
        guard let region = composition.timeline.insertions.first(where: { $0.region.id == id }) else {
            throw Refusal("The inserted-time region is no longer available.")
        }
        return region
    }

    private func savedIndex(_ id: AudioInsertionRegionID) throws -> Int {
        guard let index = composition.timeline.arrangement.insertionRegions.firstIndex(where: { $0.id == id }) else {
            throw Refusal("The inserted-time region is no longer available.")
        }
        return index
    }

    private func checkDuration(_ duration: Int64) throws {
        guard duration > 0, duration <= AudioArrangement.frameLimit else {
            throw Refusal("Inserted duration must be positive and no longer than 24 hours.")
        }
    }
}
