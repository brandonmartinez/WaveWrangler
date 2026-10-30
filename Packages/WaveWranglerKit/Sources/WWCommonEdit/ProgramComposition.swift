import WWCore
import WWTimeMap

public enum AudioClipSampleMapping: Sendable, Equatable {
    case source(localFrame: Int64, nativeFrame: ExactRational)
    case outsideCoverage
}

/// Asset/native trim and program coverage remain distinct, including the CEIL-rounded final frame.
public struct ProgramAudioClip: Sendable, Equatable {
    public let clip: AudioClip
    public let asset: AudioAsset
    public let programFrames: Range<Int64>
    public let placement: AudioPlacementProjection

    public var sourceChannels: [Int] { clip.channels ?? Array(0..<asset.channelCount) }

    public func sourcePosition(atProgramFrame frame: Int64) throws(TimeMapError) -> AudioClipSampleMapping {
        guard programFrames.contains(frame) else { return .outsideCoverage }
        let local = frame - programFrames.lowerBound
        let output = local + (clip.outputWindow?.offsetFrames ?? 0)
        let offset = try ExactRational(output).multiplied(by: ExactRational(Int64(asset.sampleRate)))
            .divided(by: ExactRational(AudioArrangement.frameRate))
        return .source(localFrame: local, nativeFrame: try ExactRational(clip.trim.startFrame).adding(offset))
    }
}

public struct ProgramComposition: Sendable, Equatable {
    public let timeline: ProgramTimeline
    /// Saved clip order, not source identity: repeated uses of one asset are independent placements.
    public let clips: [ProgramAudioClip]
    /// Hull of every dialogue span, insertion, and clip, regardless of visibility, mute, or Solo.
    /// Nil means genuinely empty, never an omitted stale/unresolved placement.
    public let programFrames: Range<Int64>?
}

extension ProgramTimeline {
    /// Atomic production projection. Review-required/out-of-coverage clips refuse the whole result;
    /// callers can still use `project` to present the exact individual review state.
    public func composition() throws(ProgramTimelineError) -> ProgramComposition {
        var clips: [ProgramAudioClip] = []
        var ranges = dialogueSpans.map(\.programFrames) + insertions.map(\.programFrames)
        for clip in arrangement.clips {
            guard let asset = arrangement.assets.first(where: { $0.source == clip.source }),
                let duration = clip.durationFrames(asset: asset)
            else { throw .invalidClip(clip.id) }
            let placement = try project(clip.anchor)
            let start: Int64
            switch placement {
            case .placed(let frame), .clampedToCutSeam(let frame, _): start = frame
            case .reviewRequired(let anchor): throw .clipRequiresReview(clip.id, anchor)
            case .outsideDialogueCoverage: throw .clipOutsideDialogueCoverage(clip.id)
            }
            let end = try Self.add(start, duration)
            clips.append(.init(clip: clip, asset: asset, programFrames: start..<end, placement: placement))
            ranges.append(start..<end)
        }
        let bounds: Range<Int64>?
        if let first = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() {
            bounds = first..<end
        } else {
            bounds = nil
        }
        return ProgramComposition(timeline: self, clips: clips, programFrames: bounds)
    }
}
