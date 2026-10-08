import Foundation
import WWCore
import WWTimeMap

/// Metadata-only requirements, NOT evidence that a lane is decoded, silent, protected, or safe to cut.
/// Only the organizer and an independently revision-checked source/decision producer can establish that.
public struct ProvisionalLaneInventory: Sendable, Equatable {
    public let episode: EpisodeID
    public let alignmentRevision: UInt64
    public let editRevision: UInt64
    public let requirements: [ProvisionalLaneRequirement]

    private init(episode: EpisodeID, map: CommonEpisodeEditMap, requirements: [ProvisionalLaneRequirement]) {
        self.episode = episode
        self.alignmentRevision = map.alignmentRevision
        self.editRevision = map.editRevision
        self.requirements = requirements
    }

    /// Enumerate every channel of every occurrence in the accepted map, including backups, unassigned
    /// channels and repeated source uses. No caller-supplied lane list or silence claim is accepted.
    public static func inspect(episode: Episode, map: CommonEpisodeEditMap) throws -> Self {
        guard let alignment = episode.alignment,
              let revision = Int(exactly: map.alignmentRevision),
              alignment.acceptedRevision == revision,
              let accepted = alignment.acceptedMap
        else { throw ProvisionalLaneInventoryError.alignmentNotAccepted }

        let encoded: EmbeddedJSON
        do {
            encoded = try JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map.alignment))
        } catch {
            throw ProvisionalLaneInventoryError.alignmentNotVerifiable
        }
        guard accepted.map == encoded else { throw ProvisionalLaneInventoryError.alignmentChanged }

        var sources: [SourceID: SourceRecord] = [:]
        for source in episode.sources {
            guard sources.updateValue(source, forKey: source.id) == nil else {
                throw ProvisionalLaneInventoryError.duplicateSource(source.id)
            }
        }
        var placedSources: Set<SourceID> = []
        var seenGroups: Set<RecorderGroupID> = []
        var seenEpochs: Set<RecordingEpochID> = []
        for recorder in episode.recorderGroups {
            guard seenGroups.insert(recorder.id).inserted else {
                throw ProvisionalLaneInventoryError.duplicateRecorderGroup(recorder.id)
            }
            for epoch in recorder.epochs {
                guard seenEpochs.insert(epoch.id).inserted else {
                    throw ProvisionalLaneInventoryError.duplicateEpoch(epoch.id)
                }
            }
        }
        var requirements: [ProvisionalLaneRequirement] = []
        for group in map.alignment.groups {
            guard let recorder = episode.recorderGroup(group.group) else {
                throw ProvisionalLaneInventoryError.recorderGroupMissing(group.group)
            }
            let epochs = Set(recorder.epochs.map(\.id))
            for epoch in group.epochs where !epochs.contains(epoch.epoch) {
                throw ProvisionalLaneInventoryError.epochMissing(epoch.epoch)
            }
            for placement in group.placements {
                let occurrence = placement.occurrence
                guard let source = sources[occurrence.source] else {
                    throw ProvisionalLaneInventoryError.sourceMissing(occurrence.source)
                }
                guard source.placement.recorderGroupID == group.group else {
                    throw ProvisionalLaneInventoryError.sourceRegrouped(source.id)
                }
                let placedEpochs = placement.spans.map(\.epoch)
                for epoch in placedEpochs where !epochs.contains(epoch) {
                    throw ProvisionalLaneInventoryError.epochMissing(epoch)
                }
                if let assignedEpoch = source.placement.epochID, !placedEpochs.contains(assignedEpoch) {
                    throw ProvisionalLaneInventoryError.sourceReassignedEpoch(source.id)
                }
                guard let count = source.observations.channelCount.value, (1...1_024).contains(count) else {
                    throw ProvisionalLaneInventoryError.channelCountUnavailable(source.id)
                }
                placedSources.insert(source.id)
                for channel in 0..<count {
                    requirements.append(ProvisionalLaneRequirement(
                        key: CommonRenderLaneKey(occurrence: occurrence.id, decodedChannel: channel),
                        source: source.id, epochs: placedEpochs, sourceRole: source.role
                    ))
                }
            }
        }
        for source in episode.sources where !placedSources.contains(source.id) {
            throw ProvisionalLaneInventoryError.sourceNotPlaced(source.id)
        }
        guard !requirements.isEmpty else { throw ProvisionalLaneInventoryError.emptyInventory }
        let inputs = accepted.inputs.sources.map(\.sourceID)
        guard inputs.count == placedSources.count, Set(inputs) == placedSources else {
            throw ProvisionalLaneInventoryError.alignmentInputsChanged
        }

        var speakers: Set<SpeakerID> = []
        var primaryOwners: [ChannelReference: SpeakerID] = [:]
        for assignment in episode.speakerAssignments {
            guard speakers.insert(assignment.speakerID).inserted else {
                throw ProvisionalLaneInventoryError.duplicateSpeaker(assignment.speakerID)
            }
            if let primary = assignment.primary {
                if primaryOwners.updateValue(assignment.speakerID, forKey: primary) != nil {
                    throw ProvisionalLaneInventoryError.ambiguousPrimary(primary)
                }
            }
            for channel in (assignment.primary.map { [$0] } ?? []) + assignment.backups {
                guard let index = channel.channel.value, index >= 0,
                      let count = episode.source(channel.sourceID)?.observations.channelCount.value,
                      index < count, placedSources.contains(channel.sourceID)
                else { throw ProvisionalLaneInventoryError.ambiguousAssignment(channel) }
            }
        }
        return Self(episode: episode.id, map: map, requirements: requirements)
    }
}

public struct ProvisionalLaneRequirement: Sendable, Equatable {
    public let key: CommonRenderLaneKey
    public let source: SourceID
    public let epochs: [RecordingEpochID]
    public let sourceRole: SourceRole
}

public enum ProvisionalLaneInventoryError: Error, Equatable, Sendable {
    case alignmentNotAccepted
    case alignmentNotVerifiable
    case alignmentChanged
    case alignmentInputsChanged
    case recorderGroupMissing(RecorderGroupID)
    case duplicateRecorderGroup(RecorderGroupID)
    case epochMissing(RecordingEpochID)
    case duplicateEpoch(RecordingEpochID)
    case sourceMissing(SourceID)
    case duplicateSource(SourceID)
    case sourceNotPlaced(SourceID)
    case sourceRegrouped(SourceID)
    case sourceReassignedEpoch(SourceID)
    case channelCountUnavailable(SourceID)
    case duplicateSpeaker(SpeakerID)
    case ambiguousPrimary(ChannelReference)
    case ambiguousAssignment(ChannelReference)
    case emptyInventory
}
