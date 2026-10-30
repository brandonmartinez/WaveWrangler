import Foundation

/// Canonical dependencies for processed output, separate from raw waveform/alignment/transcription inputs.
/// This is not source authorization or a complete render recipe: the processing layer must additionally
/// freeze verified source identities, resolved channels, output format, and latency/tail policy.
public struct EpisodeProcessingInputs: Sendable, Equatable {
    public let media: EpisodeMediaInputs
    public let mix: EpisodeMixState
    public let manualCuts: [ManualEpisodeCut]
    public let audioArrangement: AudioArrangement?
    private let audioSources: [SourceRecord]

    public init(_ episode: Episode) {
        media = EpisodeMediaInputs(episode, includingWorkingRange: true)
        var mix = episode.mix ?? EpisodeMixState()
        // Sparse controls are sets by recording/channel and speaker; only insert order is processing order.
        mix.inputGains = mix.inputGains.filter { $0.gainDB != 0 }.sorted {
            $0.source == $1.source ? $0.channel < $1.channel : $0.source.description < $1.source.description
        }
        mix.speakers = mix.speakers.filter { $0 != SpeakerMixState(speaker: $0.speaker) }
            .sorted { $0.speaker.description < $1.speaker.description }
        let tracks = (mix.audioTracks ?? []).filter { $0 != AudioTrackMixState(track: $0.track) }
            .sorted { $0.track.description < $1.track.description }
        mix.audioTracks = tracks.isEmpty ? nil : tracks
        self.mix = mix
        manualCuts = episode.activeManualCuts
        let used = Set(episode.audioArrangement?.clips.map(\.source) ?? [])
        var arrangement = episode.audioArrangement ?? AudioArrangement()
        arrangement.assets = arrangement.assets.filter { used.contains($0.source) }
            .sorted { $0.source.description < $1.source.description }
        arrangement.clips.sort { $0.id.description < $1.id.description }
        // Names and display order do not change audio. Insertion order remains a program dependency.
        arrangement.tracks = arrangement.tracks.map { AudioTrack(id: $0.id, name: "") }
            .sorted { $0.id.description < $1.id.description }
        audioArrangement = arrangement == AudioArrangement() ? nil : arrangement
        audioSources = episode.sources.filter { used.contains($0.id) }.map {
            SourceRecord(id: $0.id, displayNameHint: "", observations: $0.observations, purpose: $0.purpose)
        }.sorted { $0.id.description < $1.id.description }
    }

    /// Live fader updates may change mix controls, never the prepared program or source geometry.
    public func hasSameProgramInputs(as other: Self) -> Bool {
        media == other.media && manualCuts == other.manualCuts
            && audioArrangement == other.audioArrangement && audioSources == other.audioSources
    }

    /// Native-state capture is required before replacing program inputs or insert chains, not live levels.
    public func hasSameMixerTopology(as other: Self) -> Bool {
        let speakers = Set(mix.speakers.map(\.speaker) + other.mix.speakers.map(\.speaker))
        let tracks = Set((mix.audioTracks ?? []).map(\.track) + (other.mix.audioTracks ?? []).map(\.track))
        return hasSameProgramInputs(as: other) && mix.master.inserts == other.mix.master.inserts
            && speakers.allSatisfy { mix.state(for: $0).inserts == other.mix.state(for: $0).inserts }
            && tracks.allSatisfy { mix.state(for: $0).inserts == other.mix.state(for: $0).inserts }
    }
}

extension ShowDocumentModel {
    public func hasSameProcessingInputs(as other: Self, in episodeID: EpisodeID) -> Bool {
        guard let live = episode(episodeID), let prior = other.episode(episodeID) else { return false }
        return EpisodeProcessingInputs(live) == EpisodeProcessingInputs(prior)
    }
}
