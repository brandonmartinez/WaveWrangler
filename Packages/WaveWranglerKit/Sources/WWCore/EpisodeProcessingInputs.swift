import Foundation

/// Canonical dependencies for processed output, separate from raw waveform/alignment/transcription inputs.
/// This is not source authorization or a complete render recipe: the processing layer must additionally
/// freeze verified source identities, resolved channels, output format, and latency/tail policy.
public struct EpisodeProcessingInputs: Sendable, Equatable {
    public let media: EpisodeMediaInputs
    public let mix: EpisodeMixState
    public let manualCuts: [ManualEpisodeCut]

    public init(_ episode: Episode) {
        media = EpisodeMediaInputs(episode, includingWorkingRange: true)
        var mix = episode.mix ?? EpisodeMixState()
        // Sparse controls are sets by recording/channel and speaker; only insert order is processing order.
        mix.inputGains = mix.inputGains.filter { $0.gainDB != 0 }.sorted {
            $0.source == $1.source ? $0.channel < $1.channel : $0.source.description < $1.source.description
        }
        mix.speakers = mix.speakers.filter { $0 != SpeakerMixState(speaker: $0.speaker) }
            .sorted { $0.speaker.description < $1.speaker.description }
        self.mix = mix
        manualCuts = episode.activeManualCuts
    }
}

extension ShowDocumentModel {
    public func hasSameProcessingInputs(as other: Self, in episodeID: EpisodeID) -> Bool {
        guard let live = episode(episodeID), let prior = other.episode(episodeID) else { return false }
        return EpisodeProcessingInputs(live) == EpisodeProcessingInputs(prior)
    }
}
