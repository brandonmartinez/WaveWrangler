import WWCore

public enum AudioClipEditError: Error, Sendable, Equatable {
    case staleProjection
    case unknownTrack(AudioTrackID)
    case invalidBounds
    case extensionRequiresEnvelope
}

/// Completed editor gestures operate on the current projection, never on a rounded native trim.
public enum AudioClipEditing {
    public static func moving(
        _ projected: ProgramAudioClip, to frame: Int64, track: AudioTrackID,
        timeline: ProgramTimeline
    ) throws -> AudioClip {
        try requireCurrent(projected, timeline: timeline)
        guard timeline.arrangement.tracks.contains(where: { $0.id == track }) else {
            throw AudioClipEditError.unknownTrack(track)
        }
        var result = projected.clip
        result.track = track
        if case .absolute = result.anchor {
            result.anchor = .absolute(frame: frame)
        } else {
            result.anchor = try timeline.unpinnedAnchor(atProgramFrame: frame)
        }
        try requireBounds(start: frame, duration: Int64(projected.programFrames.count))
        return result
    }

    public static func pinning(
        _ projected: ProgramAudioClip, pinned: Bool, timeline: ProgramTimeline
    ) throws -> AudioClip {
        try requireCurrent(projected, timeline: timeline)
        var result = projected.clip
        result.anchor = try pinned
            ? timeline.pinnedAnchor(for: result.anchor)
            : timeline.unpinnedAnchor(for: result.anchor)
        return result
    }

    /// Bounds are relative to the CURRENT clip. Negative starts/longer ends explicitly extend
    /// ownership within retained support. A discarded nonempty curve cannot be reconstructed.
    public static func resizing(
        _ projected: ProgramAudioClip, localFrames: Range<Int64>, timeline: ProgramTimeline
    ) throws -> AudioClip {
        try requireCurrent(projected, timeline: timeline)
        guard !localFrames.isEmpty,
              let owned = projected.clip.ownedOutputFrames(asset: projected.asset),
              let nominal = projected.clip.nominalDurationFrames(asset: projected.asset),
              localFrames.lowerBound >= -owned.lowerBound,
              localFrames.upperBound <= nominal - owned.lowerBound else {
            throw AudioClipEditError.invalidBounds
        }
        let duration = Int64(projected.programFrames.count)
        let extending = localFrames.lowerBound < 0 || localFrames.upperBound > duration
        let curve: AudioClipEnvelope
        if extending {
            guard projected.clip.envelope.points.isEmpty else {
                throw AudioClipEditError.extensionRequiresEnvelope
            }
            curve = projected.clip.envelope
        } else {
            curve = try AudioEnvelopeEvaluator(envelope: projected.clip.envelope, durationFrames: duration)
                .sliced(to: localFrames)
        }
        let start = projected.programFrames.lowerBound + localFrames.lowerBound
        try requireBounds(start: start, duration: Int64(localFrames.count))
        var result = try projected.clip.selectingOutputFrames(
            (owned.lowerBound + localFrames.lowerBound)..<(owned.lowerBound + localFrames.upperBound),
            asset: projected.asset, envelope: curve)
        if case .absolute = result.anchor {
            result.anchor = .absolute(frame: start)
        } else {
            result.anchor = try timeline.unpinnedAnchor(atProgramFrame: start)
        }
        return result
    }

    public static func duplicating(
        _ projected: ProgramAudioClip, timeline: ProgramTimeline
    ) throws -> AudioClip {
        var result = try moving(projected, to: projected.programFrames.lowerBound,
                                track: projected.clip.track, timeline: timeline)
        result.id = AudioClipID()
        return result
    }

    private static func requireCurrent(_ projected: ProgramAudioClip, timeline: ProgramTimeline) throws {
        guard try timeline.composition().clips.contains(projected) else {
            throw AudioClipEditError.staleProjection
        }
    }

    private static func requireBounds(start: Int64, duration: Int64) throws {
        let limit = AudioArrangement.frameLimit
        guard (-limit...limit).contains(start), duration > 0, duration <= limit,
              start <= limit - duration else { throw AudioClipEditError.invalidBounds }
    }
}
