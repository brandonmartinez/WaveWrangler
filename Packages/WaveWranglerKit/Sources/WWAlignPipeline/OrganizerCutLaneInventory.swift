import WWCommonEdit
import WWCore
import WWDecode
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
    /// The count is unknown or disagrees with a current, keyed stored source-probe snapshot.
    case unverifiedChannels
    case unmappedLane
    case ambiguousSelectedPrimary
    case inspectionLimit
    case backupWithoutIndependentProof
    case independentProtectionUnavailable
}

/// All channels of every placed episode source in the stored probe snapshot, not a live-backing
/// witness, CommonEditLaneManifest or admission proof.
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
    /// Inventories every placed channel only when its organizer count agrees with the previously
    /// consent-gated, current keyed SourceFacts for that source. Opens no source; a stored probe
    /// cannot certify that the live backing or any lane's speech protection is still current.
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
            guard let token = inputs.sources[source.id], token.hasPrefix("metadata:") else {
                throw .unverifiedChannels
            }
            let key = SourceProbe.key(source: source.id, token: token)
            let slot = PipelineSlots.sourceFacts(source.id)
            guard await coordinator.state(of: slot) == .ready(key),
                  let payload = await coordinator.readyPayload(for: slot),
                  let facts = try? SourceFacts.decode(payload),
                  facts.source == source.id, facts.revisionToken == token,
                  (try? SourceProbe.verify(facts.interpretation, source: source.id, token: token)) != nil,
                  facts.interpretation.container.typeCode == facts.interpretation.container.kind.typeCode,
                  facts.interpretation.codec.formatID == facts.interpretation.codec.kind.formatID,
                  DecodeEnvelope.entries.contains(where: {
                      $0.container == facts.interpretation.container.kind
                          && $0.codec == facts.interpretation.codec.kind
                          && $0.sampleFormats.contains(facts.interpretation.sampleFormat)
                          && $0.sampleRates.contains(facts.sampleRate)
                          && $0.channelCounts.contains(facts.channelCount)
                  }),
                  facts.interpretation.output.sampleType == "float32",
                  facts.interpretation.output.isPlanar,
                  facts.interpretation.output.channelOrder == "file",
                  facts.interpretation.output.sampleRate == facts.sampleRate,
                  facts.interpretation.output.channelCount == facts.channelCount,
                  facts.interpretation.output.representsSourceSamplesExactly
                    == facts.interpretation.sampleFormat.isExactInFloat32,
                  facts.interpretation.origin.sourceSampleRate == facts.sampleRate,
                  facts.interpretation.origin.decodedFrameCount == facts.frameCount,
                  facts.interpretation.origin.sourceFrameOfFirstDecodedFrame == 0,
                  facts.interpretation.origin.discardedLeadingStreamFrames
                    == facts.interpretation.frames.primingFrames,
                  facts.interpretation.origin.declaredTrailingStreamFrames
                    == facts.interpretation.frames.remainderFrames,
                  facts.frameCount > 0, facts.channelCount == count
            else { throw .unverifiedChannels }
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
                guard placement.occurrence.id == alignmentOccurrenceID(for: source.id),
                      placement.occurrence.nominalRate.framesPerSecond == Int64(facts.sampleRate),
                      placement.occurrence.frameCount == facts.frameCount
                else { throw .unverifiedChannels }
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
        guard await coordinator.inputs == inputs,
              !(await coordinator.isShutdown),
              await coordinator.state(of: identity.slot) == .ready(identity.key)
        else { throw .staleMap }
        for source in episode.sources {
            guard let token = inputs.sources[source.id],
                  await coordinator.state(of: PipelineSlots.sourceFacts(source.id))
                    == .ready(SourceProbe.key(source: source.id, token: token))
            else { throw .unverifiedChannels }
        }
        return ProvisionalOrganizerCutLanes(
            episode: episodeID, acceptedAlignmentRevision: revision, lanes: lanes
        )
    }
}
