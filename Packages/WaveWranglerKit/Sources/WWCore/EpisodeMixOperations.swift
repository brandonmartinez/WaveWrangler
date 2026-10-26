import Foundation

extension ShowDocumentModel {
    /// Atomic replacement for preset/state recall. Pure edits leave history registration to the shared store.
    public func settingMix(_ mix: EpisodeMixState?, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        if let issue = mix?.validationIssues(in: episodes[index]).first { throw .invalidMix(issue.detail) }
        var result = self
        result.episodes[index].mix = mix
        return result
    }

    /// A zero-dB edit removes only this key. Switching Primaries never moves or copies input gain.
    public func settingInputGain(_ gainDB: Double, for channel: ChannelReference,
                                 in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard let source = episode.source(channel.sourceID) else { throw .sourceNotFound(channel.sourceID) }
        guard let index = channel.channel.value, index >= 0 else { throw .invalidChannel(channel) }
        if let count = source.observations.channelCount.value, index >= count {
            throw .channelOutOfRange(channel, channelCount: count)
        }
        guard EpisodeMixState.isValidGain(gainDB) else { throw .invalidMix("Input gain must be finite and within -96...24 dB.") }
        var mix = episode.mix ?? EpisodeMixState()
        if let gainIndex = mix.inputGains.firstIndex(where: { $0.reference == channel }) {
            if gainDB == 0 {
                mix.inputGains.remove(at: gainIndex)
            } else {
                mix.inputGains[gainIndex].gainDB = gainDB
            }
        } else if gainDB != 0 {
            mix.inputGains.append(RecordingInputGain(source: channel.sourceID, channel: index, gainDB: gainDB))
        }
        if episode.mix == nil, mix == EpisodeMixState() { return self }
        return try settingMix(mix, in: episodeID)
    }

    /// Replacing a strip preserves every other speaker, all recording gains, and Master.
    /// Ordered inserts may be added, removed, reordered, bypassed, or recalled in one normal undoable edit.
    public func settingSpeakerMix(_ state: SpeakerMixState, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard speaker(state.speaker) != nil else { throw .speakerNotFound(state.speaker) }
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard episode.assignment(for: state.speaker) != nil else { throw .speakerNotFound(state.speaker) }
        var mix = episode.mix ?? EpisodeMixState()
        if let index = mix.speakers.firstIndex(where: { $0.speaker == state.speaker }) {
            mix.speakers[index] = state
        } else if state != SpeakerMixState(speaker: state.speaker) {
            mix.speakers.append(state)
        }
        if episode.mix == nil, mix == EpisodeMixState() { return self }
        return try settingMix(mix, in: episodeID)
    }

    public func settingMasterMix(_ state: MasterMixState, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        var mix = episode.mix ?? EpisodeMixState()
        mix.master = state
        if episode.mix == nil, mix == EpisodeMixState() { return self }
        return try settingMix(mix, in: episodeID)
    }
}
