import Foundation

extension SourceObservations {
    public var isValid: Bool {
        durationSeconds.value.map { $0.isFinite && $0 >= 0 } != false
            && channelCount.value.map { $0 > 0 } != false
            && sampleRate.value.map { $0.isFinite && $0 > 0 } != false
    }

    public var isComplete: Bool {
        isValid && durationSeconds.isKnown && channelCount.isKnown && sampleRate.isKnown
    }
}

extension ShowDocumentModel {
    /// Absence is not new evidence. A refused inspection must not erase previously observed facts.
    public func recordingMediaObservations(_ observations: SourceObservations, source sourceID: SourceID,
                                           in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episodeIndex = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        guard let index = episodes[episodeIndex].sources.firstIndex(where: { $0.id == sourceID }) else {
            throw .sourceNotFound(sourceID)
        }
        guard observations.isValid else { throw .invalidWorkspace("The audio inspection returned invalid recording details.") }
        let episode = episodes[episodeIndex]
        if let count = observations.channelCount.value {
            let stated = episode.sources[index].placement.channelLabels.map(\.channel)
            let assigned = episode.references(to: sourceID).compactMap { $0.channel.channel.value }
            if let channel = (stated + assigned).first(where: { $0 >= count }) {
                throw .channelOutOfRange(.init(sourceID: sourceID, statedChannel: channel), channelCount: count)
            }
        }
        var result = self
        var recorded = episode.sources[index].observations
        if observations.durationSeconds.isKnown { recorded.durationSeconds = observations.durationSeconds }
        if observations.channelCount.isKnown { recorded.channelCount = observations.channelCount }
        if observations.sampleRate.isKnown { recorded.sampleRate = observations.sampleRate }
        result.episodes[episodeIndex].sources[index].observations = recorded
        return result
    }
}
