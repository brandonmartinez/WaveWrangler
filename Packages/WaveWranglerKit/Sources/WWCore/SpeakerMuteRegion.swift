import Foundation

/// A reversible speaker-only silence on the original aligned 48 kHz grid. It never removes time.
public struct SpeakerMuteRegion: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let speaker: SpeakerID
    public let alignmentRevision: Int
    public let startFrame: Int64
    public let endFrame: Int64

    public init(id: UUID = UUID(), speaker: SpeakerID, alignmentRevision: Int,
                startFrame: Int64, endFrame: Int64) {
        self.id = id
        self.speaker = speaker
        self.alignmentRevision = alignmentRevision
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var isValid: Bool {
        alignmentRevision > 0 && startFrame >= -ManualEpisodeCut.frameLimit
            && endFrame <= ManualEpisodeCut.frameLimit && endFrame > startFrame
    }

    public var alignedStart: Double { Double(startFrame) / 48_000 }
    public var alignedEnd: Double { Double(endFrame) / 48_000 }
}

extension Episode {
    public var activeSpeakerMuteRegions: [SpeakerMuteRegion] {
        (cleanup?.speakerMuteRegions ?? []).filter {
            $0.alignmentRevision == alignment?.acceptedRevision && assignment(for: $0.speaker) != nil
        }
    }

    /// Resolve by channel, not by file alone: two speakers may share a stereo recording.
    public func speakerMuteRegions(for source: SourceID, channel: Int, channelCount: Int) -> [SpeakerMuteRegion] {
        let speakers = Set(references(to: source).filter {
            $0.channel.resolvedChannel(channelCount: channelCount) == channel
        }.map(\.speakerID))
        return activeSpeakerMuteRegions.filter { speakers.contains($0.speaker) }
    }
}
