import WWCore

#if DEBUG
import Darwin
#endif

public enum SpeechRefusal: Error, Sendable, Equatable {
    case unselectedPrimary
    case engineUnavailable
}

/// Media-free admission boundary. The caller must supply the current canonical show model, not a
/// cached selection. No engine, source reader, model loader, or transcript publisher is installed.
public struct SpeechInference: Sendable {
    public init() {}

    public func infer(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) {
        try requireSelectedPrimary(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
        throw .engineUnavailable
    }

    func requireSelectedPrimary(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) {
        guard model.schemaVersion == SchemaVersion.show,
              model.episodes.filter({ $0.id == episodeID }).count == 1,
              model.speakers.filter({ $0.id == speakerID }).count == 1,
              let episode = model.episode(episodeID),
              episode.speakerAssignments.filter({ $0.speakerID == speakerID }).count == 1,
              let assignment = episode.assignment(for: speakerID),
              assignment.primary == channel,
              assignment.primaryConfirmation == .userConfirmed,
              !assignment.backups.contains(channel),
              episode.speakerAssignments.filter({ $0.primary == channel }).count == 1,
              let index = channel.channel.value, index >= 0,
              episode.sources.filter({ $0.id == channel.sourceID }).count == 1,
              let source = episode.source(channel.sourceID),
              source.role == .primary, source.roleConfirmation == .userConfirmed,
              let count = source.observations.channelCount.value, index < count
        else { throw .unselectedPrimary }
    }

    #if DEBUG
    /// Exercises the same selection gate with generated numbers only. It never recognizes speech
    /// and cannot accept a media buffer, a path, an engine, or a model asset.
    public func syntheticProbe(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) -> SyntheticSpeechProbeResult {
        try requireSelectedPrimary(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
        let samples: [Float] = [0, 0.25, -0.25, 0]
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return SyntheticSpeechProbeResult(processID: getpid(), syntheticFrameCount: samples.count,
                                          signalEnergy: energy, recognizedWordCount: 0)
    }
    #endif
}

#if DEBUG
public struct SyntheticSpeechProbeResult: Sendable, Equatable {
    public let processID: Int32
    public let syntheticFrameCount: Int
    public let signalEnergy: Float
    public let recognizedWordCount: Int
}
#endif
