import WWCore

public struct AudioClipOutputSplit: Sendable, Equatable {
    public let leading: AudioClip
    public let trailing: AudioClip
}

extension AudioClip {
    /// Crop or extend ownership inside the SAME retained support. The caller must explicitly supply
    /// the new local curve: discarded envelope knots cannot be reconstructed by extending a crop.
    public func selectingOutputFrames(_ frames: Range<Int64>, asset: AudioAsset,
                                      envelope: AudioClipEnvelope) throws -> AudioClip {
        guard asset.source == source, let nominal = nominalDurationFrames(asset: asset), !frames.isEmpty,
              frames.lowerBound >= 0, frames.upperBound <= nominal,
              envelope.isValid(durationFrames: Int64(frames.count)) else {
            throw AudioEnvelopeError.invalidSlice(frames)
        }
        var result = self
        result.outputWindow = .init(offsetFrames: frames.lowerBound, countFrames: Int64(frames.count))
        result.envelope = envelope
        return result
    }
}

extension ProgramAudioClip {
    /// Crop within retained support without resetting SRC phase or curve coordinates.
    public func cropped(toLocalFrames frames: Range<Int64>) throws -> AudioClip {
        guard frames.lowerBound >= 0, frames.upperBound <= programFrames.count, !frames.isEmpty else {
            throw AudioEnvelopeError.invalidSlice(frames)
        }
        let envelope = try AudioEnvelopeEvaluator(envelope: clip.envelope,
            durationFrames: Int64(programFrames.count)).sliced(to: frames)
        let start = (clip.outputWindow?.offsetFrames ?? 0) + frames.lowerBound
        return try clip.selectingOutputFrames(start..<(start + Int64(frames.count)), asset: asset, envelope: envelope)
    }

    /// Split on the CURRENT program sample grid. Native support is identical in both halves.
    public func split(atProgramFrame frame: Int64, timeline: ProgramTimeline) throws -> AudioClipOutputSplit {
        guard try timeline.composition().clips.contains(self) else { throw ProgramTimelineError.invalidClip(clip.id) }
        let local = frame - programFrames.lowerBound
        guard local > 0, local < programFrames.count else { throw AudioEnvelopeError.outsideClip(local) }
        let leading = try cropped(toLocalFrames: 0..<local)
        var trailing = try cropped(toLocalFrames: local..<Int64(programFrames.count))
        trailing.id = AudioClipID()
        if case .absolute = clip.anchor {
            trailing.anchor = .absolute(frame: frame)
        } else {
            trailing.anchor = try timeline.unpinnedAnchor(atProgramFrame: frame)
        }
        return .init(leading: leading, trailing: trailing)
    }
}
