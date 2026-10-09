import WWCommonEdit
import WWCore
import WWDerived
import WWPersistence
import WWTimeMap

public enum OrganizerCutLaneKind: Sendable, Equatable {
    case selectedPrimary
    case otherSpeaker
    case backup
    case unassigned
}

/// An organizer coordinate, not a verified source, protection survey or renderable lane.
public struct ProvisionalOrganizerCutLane: Sendable {
    public let key: CommonEditLaneKey
    public let epoch: RecordingEpochID
    public let registeredSourceRevision: String
    public let kind: OrganizerCutLaneKind
}

public enum OrganizerCutLaneRefusal: Error, Equatable, Sendable {
    case invalidOrganizerState
    case noAcceptedMap
    case staleMap
    case incompleteEpisode
    /// The recorded count is unknown or has no independent, current source-backed proof.
    case unverifiedChannels
    case unmappedLane
    case ambiguousSelectedPrimary
    case inspectionLimit
    case backupWithoutIndependentProof
    case independentProtectionUnavailable
}

/// A provisional metadata shape, not a CommonEditLaneManifest or an admission witness.
/// The current inspection API never returns one: organizer counts cannot prove lane completeness.
public struct ProvisionalOrganizerCutLanes: Sendable {
    public let episode: EpisodeID
    public let acceptedAlignmentRevision: Int
    public let lanes: [ProvisionalOrganizerCutLane]

    /// No production provider of independent per-lane protection, source backing, or final merged
    /// fade footprints exists. In particular, the selected Primary's consent cannot attest a Backup.
    public func mappingInputs() throws(OrganizerCutLaneRefusal) -> Never {
        if lanes.contains(where: { $0.kind == .backup }) {
            throw .backupWithoutIndependentProof
        }
        throw .independentProtectionUnavailable
    }
}

extension AlignmentPipeline {
    /// Checks recorded source/channel/occurrence structure without opening content, then refuses.
    /// An accepted map and registered revisions cannot certify the caller's mutable channel counts.
    /// No source-backed, consent-gated all-source count witness is available at this boundary.
    public func inspectCutLanes(
        model: ShowDocumentModel, episode episodeID: EpisodeID, selectedSpeaker: SpeakerID
    ) async throws(OrganizerCutLaneRefusal) -> ProvisionalOrganizerCutLanes {
        guard model.schemaVersion == SchemaVersion.show,
              model.validationIssues().isEmpty, model.embeddedMapIssues().isEmpty,
              let episode = model.episode(episodeID)
        else { throw .invalidOrganizerState }
        guard let revision = episode.alignment?.acceptedRevision,
              let version = episode.alignment?.acceptedMap
        else { throw .noAcceptedMap }
        let inputs = await coordinator.inputs
        let shutDown = await coordinator.isShutdown
        guard !shutDown,
              inputs.acceptedMaps[episodeID] == revision,
              let map = try? model.timeMap(revision: revision, in: episodeID),
              (try? episode.applicability(ofMapRevision: revision).isCurrent) == true,
              MapDependencies.verify(
                  version: version, map: map, episode: episode,
                  registered: inputs.sources, format: inputs.format
              ).isEmpty,
              let identity = try? mapIdentity(
                  revision: .init(episode: episodeID, revision: revision),
                  version: version, map: map, registered: inputs.sources
              )
        else { throw .staleMap }
        guard await coordinator.state(of: identity.slot) == .ready(identity.key) else {
            throw .staleMap
        }

        let placements = map.groups.flatMap { group in
            group.placements.map { (group: group, placement: $0) }
        }
        let sourceIDs = episode.sources.map(\.id)
        guard placements.count <= CommonEditPreflight.maximumInspectedLanes,
              sourceIDs.count <= CommonEditPreflight.maximumInspectedLanes
        else { throw .inspectionLimit }
        guard Set(sourceIDs) == Set(placements.map(\.placement.occurrence.source)),
              !sourceIDs.isEmpty, !placements.isEmpty
        else { throw .incompleteEpisode }
        guard let assignment = episode.assignment(for: selectedSpeaker),
              assignment.primaryConfirmation == .userConfirmed,
              let selected = assignment.primary, selected.channel.value != nil,
              let selectedRecord = episode.source(selected.sourceID),
              selectedRecord.role == .primary,
              selectedRecord.roleConfirmation == .userConfirmed
        else { throw .ambiguousSelectedPrimary }

        let references = episode.speakerAssignments.flatMap {
            ($0.primary.map { [$0] } ?? []) + $0.backups
        }
        guard Set(references).count == references.count else { throw .invalidOrganizerState }
        guard references.allSatisfy({ $0.channel.value != nil }) else {
            throw .unverifiedChannels
        }
        var lanes: [ProvisionalOrganizerCutLane] = []
        for source in episode.sources {
            guard let count = source.observations.channelCount.value, count > 0 else {
                throw .unverifiedChannels
            }
            let matches = placements.filter { $0.placement.occurrence.source == source.id }
            guard !matches.isEmpty else { throw .incompleteEpisode }
            for (group, placement) in matches {
                guard placement.spans.count == 1,
                      let span = placement.spans.first,
                      source.placement.recorderGroupID == group.group,
                      source.placement.epochID == span.epoch,
                      group.epochs.contains(where: { candidate in
                          guard candidate.epoch == span.epoch else { return false }
                          if case .mapped = candidate.mapping { return true }
                          return false
                      })
                else { throw .unmappedLane }
                guard let token = inputs.sources[source.id], !token.isEmpty else { throw .staleMap }
                for channel in 0..<count {
                    guard lanes.count < CommonEditPreflight.maximumInspectedLanes else {
                        throw .inspectionLimit
                    }
                    let reference = ChannelReference(sourceID: source.id, statedChannel: channel)
                    let kind: OrganizerCutLaneKind
                    if reference == selected {
                        kind = .selectedPrimary
                    } else if episode.speakerAssignments.contains(where: { $0.primary == reference }) {
                        kind = .otherSpeaker
                    } else if episode.speakerAssignments.contains(where: { $0.backups.contains(reference) })
                                || source.role == .backup {
                        kind = .backup
                    } else {
                        kind = .unassigned
                    }
                    lanes.append(.init(
                        key: .init(source: source.id, occurrence: placement.occurrence.id, channel: channel),
                        epoch: span.epoch, registeredSourceRevision: token, kind: kind
                    ))
                }
            }
        }
        guard Set(lanes.map(\.key)).count == lanes.count else { throw .invalidOrganizerState }
        guard lanes.filter({ $0.kind == .selectedPrimary }).count == 1 else {
            throw .ambiguousSelectedPrimary
        }
        // A valid organizer count can still omit a real unassigned channel. The coordinator's source
        // revision is not a live format probe, so these recorded coordinates cannot be returned as complete.
        throw .unverifiedChannels
    }
}
