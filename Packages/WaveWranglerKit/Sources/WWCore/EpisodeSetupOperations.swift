import Foundation

// Pure episode-setup operations used by the Setup destination: recorder groups, epoch numbers, stated
// channels, speakers, primaries/backups, source removal/order and import batches.
//
// Every operation returns a new value or throws without partial mutation, never touches referenced
// originals and never reads media. Schema v1 encodings used here:
// - **Epoch number** `n` of a grouped source is the 1-based position of its `placement.epochID` in its
//   group's `epochs`. Groups gain epochs labelled "1", "2", … as needed; unused epochs are kept.
// - **Stated channel.** M1 never observes channel counts. A channel the user has stated for a source is
//   recorded as a `ChannelLabel` in `placement.channelLabels`; when none is stated the channel is
//   *unknown*. Speaker channel references of a source without a stated channel use index 0 as a
//   placeholder that the UI always presents as "Unknown", never as "channel 1".

/// One source to add in an import batch with the user-confirmed recorder group and speaker names
/// (`nil` = Ungrouped / Unassigned). Unconfirmed suggestions are never passed here.
public struct SourceImportItem: Sendable, Equatable {
    public var source: SourceRecord
    public var recorderGroupName: String?
    public var speakerName: String?

    public init(source: SourceRecord, recorderGroupName: String? = nil, speakerName: String? = nil) {
        self.source = source
        self.recorderGroupName = recorderGroupName
        self.speakerName = speakerName
    }
}

public enum MoveDirection: Sendable, Equatable {
    case up
    case down
}

extension Episode {
    /// 1-based epoch number of a grouped source, or `nil` when the source is ungrouped or has no epoch.
    public func epochNumber(of sourceID: SourceID) -> Int? {
        guard let source = source(sourceID),
              let groupID = source.placement.recorderGroupID,
              let epochID = source.placement.epochID,
              let group = recorderGroup(groupID),
              let index = group.epochs.firstIndex(where: { $0.id == epochID })
        else { return nil }
        return index + 1
    }

    /// Zero-based channel the user stated for a source, or `nil` when the channel is unknown.
    public func statedChannel(of sourceID: SourceID) -> Int? {
        source(sourceID)?.placement.channelLabels.first?.channel
    }

    /// Every speaker channel reference that points at `sourceID`, in assignment order.
    public func references(to sourceID: SourceID) -> [SpeakerChannelReference] {
        speakerAssignments.flatMap { assignment -> [SpeakerChannelReference] in
            var result: [SpeakerChannelReference] = []
            if let primary = assignment.primary, primary.sourceID == sourceID {
                result.append(SpeakerChannelReference(speakerID: assignment.speakerID, channel: primary, isPrimary: true))
            }
            for backup in assignment.backups where backup.sourceID == sourceID {
                result.append(SpeakerChannelReference(speakerID: assignment.speakerID, channel: backup, isPrimary: false))
            }
            return result
        }
    }

    public func sources(inRecorderGroup groupID: RecorderGroupID?) -> [SourceRecord] {
        sources.filter { $0.placement.recorderGroupID == groupID }
    }
}

/// A speaker's reference to one channel of a source.
public struct SpeakerChannelReference: Sendable, Hashable {
    public var speakerID: SpeakerID
    public var channel: ChannelReference
    public var isPrimary: Bool

    public init(speakerID: SpeakerID, channel: ChannelReference, isPrimary: Bool) {
        self.speakerID = speakerID
        self.channel = channel
        self.isPrimary = isPrimary
    }
}

extension ShowDocumentModel {
    // MARK: Recorder groups

    public func renamingRecorderGroup(_ groupID: RecorderGroupID, in episodeID: EpisodeID, to name: String) throws(DomainError) -> ShowDocumentModel {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.recorderGroups.firstIndex(where: { $0.id == groupID }) else { throw .recorderGroupNotFound(groupID) }
            episode.recorderGroups[index].name = trimmed
        }
    }

    /// Deletes a recorder group without touching its sources: they become Ungrouped (and lose their epoch,
    /// which only has meaning inside a group).
    public func removingRecorderGroup(_ groupID: RecorderGroupID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.recorderGroups.firstIndex(where: { $0.id == groupID }) else { throw .recorderGroupNotFound(groupID) }
            episode.recorderGroups.remove(at: index)
            for sourceIndex in episode.sources.indices where episode.sources[sourceIndex].placement.recorderGroupID == groupID {
                episode.sources[sourceIndex].placement.recorderGroupID = nil
                episode.sources[sourceIndex].placement.epochID = nil
            }
        }
    }

    /// Moves sources into a recorder group (`nil` = Ungrouped). A source keeps its epoch number when it
    /// had one; otherwise it starts in epoch 1.
    public func assigningSources(_ sourceIDs: [SourceID], toRecorderGroup groupID: RecorderGroupID?, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            if let groupID, episode.recorderGroup(groupID) == nil { throw .recorderGroupNotFound(groupID) }
            for sourceID in sourceIDs {
                guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
                let number = episode.epochNumber(of: sourceID) ?? 1
                episode.sources[index].placement.recorderGroupID = groupID
                episode.sources[index].placement.epochID = nil
                if let groupID {
                    episode.sources[index].placement.epochID = Self.ensureEpoch(number, in: groupID, of: &episode)
                }
            }
        }
    }

    public func settingEpochNumber(_ number: Int, forSources sourceIDs: [SourceID], in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard number >= 1 else { throw .invalidEpochNumber(number) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            for sourceID in sourceIDs {
                guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
                guard let groupID = episode.sources[index].placement.recorderGroupID else { throw .sourceNotInRecorderGroup(sourceID) }
                episode.sources[index].placement.epochID = Self.ensureEpoch(number, in: groupID, of: &episode)
            }
        }
    }

    /// Increments each source's epoch number by 1 (the recorder was stopped and started again).
    public func startingNewEpoch(forSources sourceIDs: [SourceID], in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            for sourceID in sourceIDs {
                guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
                guard let groupID = episode.sources[index].placement.recorderGroupID else { throw .sourceNotInRecorderGroup(sourceID) }
                let next = (episode.epochNumber(of: sourceID) ?? 0) + 1
                episode.sources[index].placement.epochID = Self.ensureEpoch(next, in: groupID, of: &episode)
            }
        }
    }

    // MARK: Channels

    /// Records the channel the user says carries speech (`nil` = Unknown). Never checked against the file.
    public func settingStatedChannel(_ channel: Int?, forSource sourceID: SourceID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        if let channel, channel < 0 { throw .invalidChannel(ChannelReference(sourceID: sourceID, channel: channel)) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
            if let count = episode.sources[index].observations.channelCount.value, let channel, channel >= count {
                throw .channelOutOfRange(ChannelReference(sourceID: sourceID, channel: channel), channelCount: count)
            }
            episode.sources[index].placement.channelLabels = channel.map { [ChannelLabel(channel: $0, label: "")] } ?? []
            let target = ChannelReference(sourceID: sourceID, channel: channel ?? 0)
            for assignmentIndex in episode.speakerAssignments.indices {
                var assignment = episode.speakerAssignments[assignmentIndex]
                if assignment.primary?.sourceID == sourceID { assignment.primary = target }
                assignment.backups = assignment.backups.map { $0.sourceID == sourceID ? target : $0 }
                var seen = Set<ChannelReference>()
                assignment.backups = assignment.backups.filter { seen.insert($0).inserted && $0 != assignment.primary }
                episode.speakerAssignments[assignmentIndex] = assignment
            }
            if let conflict = Self.conflictingPrimary(in: episode) { throw .channelIsPrimaryOfAnotherSpeaker(conflict.0, conflict.1) }
        }
    }

    // MARK: Speakers

    /// Adds a show speaker and lists them in the episode (an assignment with no channels yet).
    public func addingSpeaker(_ speaker: Speaker, toEpisode episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        let added = try addingSpeaker(speaker)
        return try added.includingSpeaker(speaker.id, inEpisode: episodeID)
    }

    /// Lists an existing show speaker in an episode.
    public func includingSpeaker(_ speakerID: SpeakerID, inEpisode episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            if episode.assignment(for: speakerID) == nil {
                episode.speakerAssignments.append(SpeakerAssignment(speakerID: speakerID))
            }
        }
    }

    public func renamingSpeaker(_ speakerID: SpeakerID, to name: String) throws(DomainError) -> ShowDocumentModel {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else { throw .speakerNotFound(speakerID) }
        var copy = self
        copy.speakers[index].name = trimmed
        return copy
    }

    /// Removes a speaker from an episode; their sources become Unassigned. The show-level speaker is
    /// removed too when no other episode lists them.
    public func removingSpeaker(_ speakerID: SpeakerID, fromEpisode episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        var copy = try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.speakerAssignments.firstIndex(where: { $0.speakerID == speakerID }) else { throw .speakerNotFound(speakerID) }
            let removed = episode.speakerAssignments.remove(at: index)
            let channels = (removed.primary.map { [$0] } ?? []) + removed.backups
            for sourceID in Set(channels.map(\.sourceID)) where episode.references(to: sourceID).isEmpty {
                Self.setRole(.unassigned, .provisional, of: sourceID, in: &episode)
            }
        }
        if !copy.episodes.contains(where: { $0.assignment(for: speakerID) != nil }) {
            copy.speakers.removeAll { $0.id == speakerID }
        }
        return copy
    }

    /// Assigns a source to one speaker (`nil` = Unassigned), replacing any *other* speaker's references to
    /// it. A source that already references `speakerID` keeps that reference, its role and confirmation
    /// (so a multi-select Assign Speaker never strips a user-confirmed primary). A newly assigned source's
    /// role is not chosen yet: the channel is held as a provisional backup until the user picks one.
    public func assigningSpeaker(_ speakerID: SpeakerID?, toSource sourceID: SourceID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        if let speakerID, speaker(speakerID) == nil { throw .speakerNotFound(speakerID) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard episode.source(sourceID) != nil else { throw .sourceNotFound(sourceID) }
            let alreadyAssigned = speakerID.map { id in episode.references(to: sourceID).contains { $0.speakerID == id } } ?? false
            Self.removeReferences(to: sourceID, in: &episode, except: speakerID)
            guard let speakerID else {
                Self.setRole(.unassigned, .provisional, of: sourceID, in: &episode)
                return
            }
            guard !alreadyAssigned else { return }
            var assignment = episode.assignment(for: speakerID) ?? SpeakerAssignment(speakerID: speakerID)
            assignment.backups.append(ChannelReference(sourceID: sourceID, channel: episode.statedChannel(of: sourceID) ?? 0))
            Self.set(assignment, in: &episode)
            Self.setRole(.backup, .provisional, of: sourceID, in: &episode)
        }
    }

    /// The user makes `channel` the speaker's primary. The previous primary stays referenced as a Backup.
    public func usingAsPrimary(_ channel: ChannelReference, for speakerID: SpeakerID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard var assignment = episode.assignment(for: speakerID),
                  assignment.primary == channel || assignment.backups.contains(channel)
            else { throw .channelNotAssignedToSpeaker(channel, speakerID) }
            if let other = episode.speakerAssignments.first(where: { $0.speakerID != speakerID && $0.primary == channel }) {
                throw .channelIsPrimaryOfAnotherSpeaker(channel, other.speakerID)
            }
            if let previous = assignment.primary, previous != channel {
                assignment.backups.append(previous)
                Self.setRole(.backup, .userConfirmed, of: previous.sourceID, in: &episode)
            }
            assignment.backups.removeAll { $0 == channel }
            assignment.primary = channel
            assignment.primaryConfirmation = .userConfirmed
            Self.set(assignment, in: &episode)
            Self.setRole(.primary, .userConfirmed, of: channel.sourceID, in: &episode)
        }
    }

    /// The user makes `channel` one of the speaker's backups (if it was the primary, the speaker has none).
    public func usingAsBackup(_ channel: ChannelReference, for speakerID: SpeakerID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        return try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard var assignment = episode.assignment(for: speakerID),
                  assignment.primary == channel || assignment.backups.contains(channel)
            else { throw .channelNotAssignedToSpeaker(channel, speakerID) }
            if assignment.primary == channel {
                assignment.primary = nil
                assignment.primaryConfirmation = .provisional
            }
            if !assignment.backups.contains(channel) { assignment.backups.append(channel) }
            Self.set(assignment, in: &episode)
            Self.setRole(.backup, .userConfirmed, of: channel.sourceID, in: &episode)
        }
    }

    /// Speaker inspector "Primary" pop-up: one of the speaker's channels, or `nil` (None — the previous
    /// primary stays referenced as a Backup).
    public func settingPrimary(_ channel: ChannelReference?, for speakerID: SpeakerID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        if let channel { return try usingAsPrimary(channel, for: speakerID, in: episodeID) }
        guard let primary = episode(episodeID)?.assignment(for: speakerID)?.primary else {
            guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
            return self
        }
        return try usingAsBackup(primary, for: speakerID, in: episodeID)
    }

    public func movingSpeaker(_ speakerID: SpeakerID, _ direction: MoveDirection, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.speakerAssignments.firstIndex(where: { $0.speakerID == speakerID }) else { throw .speakerNotFound(speakerID) }
            let target = direction == .up ? index - 1 : index + 1
            guard episode.speakerAssignments.indices.contains(target) else { return }
            episode.speakerAssignments.swapAt(index, target)
        }
    }

    // MARK: Sources

    /// Removes a source reference from the episode (the file itself is never touched).
    public func removingSource(_ sourceID: SourceID, from episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
            Self.removeReferences(to: sourceID, in: &episode)
            episode.sources.remove(at: index)
        }
    }

    /// Moves a source before/after its neighbour in the same recorder group (manual order).
    public func movingSource(_ sourceID: SourceID, _ direction: MoveDirection, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        try updatingSetup(episodeID) { (episode: inout Episode) throws(DomainError) in
            guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
            let groupID = episode.sources[index].placement.recorderGroupID
            let candidates = direction == .up
                ? Array(episode.sources.indices.prefix(upTo: index).reversed())
                : Array(episode.sources.indices.suffix(from: index + 1))
            guard let neighbour = candidates.first(where: { episode.sources[$0].placement.recorderGroupID == groupID }) else { return }
            episode.sources.swapAt(index, neighbour)
        }
    }

    /// Adds a batch of user-reviewed sources as one value. Groups and speakers are matched by name to
    /// existing ones in the episode/show (they are user-facing labels, not source identity) or created.
    public func importingSources(_ items: [SourceImportItem], into episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard episode(episodeID) != nil else { throw .episodeNotFound(episodeID) }
        var model = self
        for item in items {
            var source = item.source
            source.placement = SourcePlacement()
            source.role = .unassigned
            source.roleConfirmation = .provisional
            model = try model.addingSource(source, to: episodeID)
            if let name = item.recorderGroupName.map(Self.trimmed), !name.isEmpty {
                let groupID: RecorderGroupID
                if let existing = model.episode(episodeID)?.recorderGroups.first(where: { $0.name == name }) {
                    groupID = existing.id
                } else {
                    let group = RecorderGroup(name: name)
                    model = try model.addingRecorderGroup(group, to: episodeID)
                    groupID = group.id
                }
                model = try model.assigningSources([source.id], toRecorderGroup: groupID, in: episodeID)
            }
            if let name = item.speakerName.map(Self.trimmed), !name.isEmpty {
                let speakerID: SpeakerID
                if let existing = model.speakers.first(where: { $0.name == name }) {
                    speakerID = existing.id
                    model = try model.includingSpeaker(speakerID, inEpisode: episodeID)
                } else {
                    let speaker = Speaker(name: name)
                    model = try model.addingSpeaker(speaker, toEpisode: episodeID)
                    speakerID = speaker.id
                }
                model = try model.assigningSpeaker(speakerID, toSource: source.id, in: episodeID)
            }
        }
        return model
    }

    // MARK: Helpers

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updatingSetup(_ id: EpisodeID, _ transform: (inout Episode) throws(DomainError) -> Void) throws(DomainError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var copy = self
        try transform(&copy.episodes[index])
        return copy
    }

    private static func ensureEpoch(_ number: Int, in groupID: RecorderGroupID, of episode: inout Episode) -> RecordingEpochID? {
        guard let groupIndex = episode.recorderGroups.firstIndex(where: { $0.id == groupID }) else { return nil }
        while episode.recorderGroups[groupIndex].epochs.count < number {
            let label = "\(episode.recorderGroups[groupIndex].epochs.count + 1)"
            episode.recorderGroups[groupIndex].epochs.append(RecordingEpoch(label: label))
        }
        return episode.recorderGroups[groupIndex].epochs[number - 1].id
    }

    private static func removeReferences(to sourceID: SourceID, in episode: inout Episode, except keptSpeaker: SpeakerID? = nil) {
        for index in episode.speakerAssignments.indices where episode.speakerAssignments[index].speakerID != keptSpeaker {
            if episode.speakerAssignments[index].primary?.sourceID == sourceID {
                episode.speakerAssignments[index].primary = nil
                episode.speakerAssignments[index].primaryConfirmation = .provisional
            }
            episode.speakerAssignments[index].backups.removeAll { $0.sourceID == sourceID }
        }
    }

    private static func set(_ assignment: SpeakerAssignment, in episode: inout Episode) {
        if let index = episode.speakerAssignments.firstIndex(where: { $0.speakerID == assignment.speakerID }) {
            episode.speakerAssignments[index] = assignment
        } else {
            episode.speakerAssignments.append(assignment)
        }
    }

    private static func setRole(_ role: SourceRole, _ confirmation: Confirmation, of sourceID: SourceID, in episode: inout Episode) {
        guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { return }
        episode.sources[index].role = role
        episode.sources[index].roleConfirmation = confirmation
    }

    private static func conflictingPrimary(in episode: Episode) -> (ChannelReference, SpeakerID)? {
        var seen: [ChannelReference: SpeakerID] = [:]
        for assignment in episode.speakerAssignments {
            guard let primary = assignment.primary else { continue }
            if seen[primary] != nil { return (primary, assignment.speakerID) }
            seen[primary] = assignment.speakerID
        }
        return nil
    }
}
