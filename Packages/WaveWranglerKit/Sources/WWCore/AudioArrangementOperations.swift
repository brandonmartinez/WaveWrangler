import Foundation

extension ShowDocumentModel {
    /// Whole-value transaction for imports, source removal, or compound arrangement/mix edits.
    /// The normal shared document store owns publication and Undo/Redo; media is never deleted.
    public func settingAudioState(_ arrangement: AudioArrangement?, mix: EpisodeMixState?,
                                 sources: [SourceRecord]? = nil, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        var result = self
        result.episodes[index].audioArrangement = arrangement
        result.episodes[index].mix = mix
        if let sources {
            guard sources.filter(\.isRecording) == episodes[index].alignmentSources else {
                throw .invalidAudio("An audio arrangement edit cannot change recording sources or their clock assignments.")
            }
            result.episodes[index].sources = sources
        }
        if let issue = result.validationIssues().first { throw .invalidAudio(issue.description) }
        return result
    }

    public func settingAudioArrangement(_ arrangement: AudioArrangement?,
                                        in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        return try settingAudioState(arrangement, mix: episode.mix, in: episodeID)
    }

    public func addingAudioTrack(_ track: AudioTrack, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        var arrangement = episode.audioArrangement ?? AudioArrangement()
        arrangement.tracks.append(track)
        return try settingAudioArrangement(arrangement, in: episodeID)
    }

    public func replacingAudioTrack(_ track: AudioTrack, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard var arrangement = episode.audioArrangement,
              let index = arrangement.tracks.firstIndex(where: { $0.id == track.id }) else {
            throw .invalidAudio("Audio track not found: \(track.id)")
        }
        arrangement.tracks[index] = track
        return try settingAudioArrangement(arrangement, in: episodeID)
    }

    public func removingAudioTrack(_ track: AudioTrackID, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard var arrangement = episode.audioArrangement, arrangement.tracks.contains(where: { $0.id == track }) else {
            throw .invalidAudio("Audio track not found: \(track)")
        }
        arrangement.tracks.removeAll { $0.id == track }
        arrangement.clips.removeAll { $0.track == track }
        var mix = episode.mix
        mix?.audioTracks?.removeAll { $0.track == track }
        return try settingAudioState(arrangement, mix: mix, in: episodeID)
    }

    public func addingAudioClip(_ clip: AudioClip, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        var arrangement = episode.audioArrangement ?? AudioArrangement()
        arrangement.clips.append(clip)
        return try settingAudioArrangement(arrangement, in: episodeID)
    }

    public func replacingAudioClip(_ clip: AudioClip, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard var arrangement = episode.audioArrangement,
              let index = arrangement.clips.firstIndex(where: { $0.id == clip.id }) else {
            throw .invalidAudio("Audio clip not found: \(clip.id)")
        }
        arrangement.clips[index] = clip
        return try settingAudioArrangement(arrangement, in: episodeID)
    }

    public func removingAudioClip(_ clip: AudioClipID, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard var arrangement = episode.audioArrangement, arrangement.clips.contains(where: { $0.id == clip }) else {
            throw .invalidAudio("Audio clip not found: \(clip)")
        }
        arrangement.clips.removeAll { $0.id == clip }
        return try settingAudioArrangement(arrangement, in: episodeID)
    }

    public func settingAudioTrackMix(_ state: AudioTrackMixState, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard episode.audioArrangement?.tracks.contains(where: { $0.id == state.track }) == true else {
            throw .invalidAudio("Audio track not found: \(state.track)")
        }
        var mix = episode.mix ?? EpisodeMixState()
        var tracks = mix.audioTracks ?? []
        tracks.removeAll { $0.track == state.track }
        if state != AudioTrackMixState(track: state.track) { tracks.append(state) }
        mix.audioTracks = tracks.isEmpty ? nil : tracks
        if episode.mix == nil, mix == EpisodeMixState() { return self }
        return try settingMix(mix, in: episodeID)
    }
}
