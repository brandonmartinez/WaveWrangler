import Foundation

/// Only canonical inputs that can affect audio admission, timing, or processing.
/// Device-local access and original-file identity must still be verified by the read gateway.
public struct EpisodeMediaInputs: Sendable, Equatable {
    private struct Source: Sendable, Equatable {
        let id: SourceID
        let observations: SourceObservations
        let placement: SourcePlacement
        let role: SourceRole
        let confirmation: Confirmation
    }

    private struct Group: Sendable, Equatable {
        let id: RecorderGroupID
        let reference: Bool?
        let epochs: [RecordingEpochID]
    }

    private let episode: EpisodeID
    private let sources: [Source]
    private let groups: [Group]
    private let fallbackReference: RecorderGroupID?
    private let assignments: [SpeakerAssignment]
    private let acceptedRevision: Int?
    private let acceptedMap: TimeMapVersion?
    private let workingRange: EpisodeWorkingRange?

    public init(_ episode: Episode, includingWorkingRange: Bool = false) {
        self.episode = episode.id
        sources = episode.sources.map {
            Source(id: $0.id, observations: $0.observations, placement: $0.placement,
                   role: $0.role, confirmation: $0.roleConfirmation)
        }.sorted { $0.id.description < $1.id.description }
        groups = episode.recorderGroups.map {
            Group(id: $0.id, reference: $0.preferredAlignmentReference, epochs: $0.epochs.map(\.id))
        }.sorted { $0.id.description < $1.id.description }
        fallbackReference = episode.recorderGroups.contains { $0.preferredAlignmentReference == true }
            ? nil : episode.recorderGroups.first?.id
        assignments = episode.speakerAssignments.sorted { $0.speakerID.description < $1.speakerID.description }
        acceptedRevision = episode.alignment?.acceptedRevision
        acceptedMap = episode.alignment?.acceptedMap
        workingRange = includingWorkingRange ? episode.cleanup?.workingRange : nil
    }
}

extension ShowDocumentModel {
    public func hasSameMediaInputs(as other: Self, in episodeID: EpisodeID,
                                   includingWorkingRange: Bool = false) -> Bool {
        guard let live = episode(episodeID), let prior = other.episode(episodeID) else { return false }
        return EpisodeMediaInputs(live, includingWorkingRange: includingWorkingRange)
            == EpisodeMediaInputs(prior, includingWorkingRange: includingWorkingRange)
    }
}
