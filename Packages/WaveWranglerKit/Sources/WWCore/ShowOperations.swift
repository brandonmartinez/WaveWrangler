import Foundation

/// Why a pure domain operation refused to produce a new value.
public enum DomainError: Error, Sendable, Equatable {
    case emptyTitle
    case duplicateEpisode(EpisodeID)
    case duplicateSpeaker(SpeakerID)
    case duplicateRecorderGroup(RecorderGroupID)
    case duplicateSource(SourceID)
    case episodeNotFound(EpisodeID)
    case speakerNotFound(SpeakerID)
    case sourceNotFound(SourceID)
    case recorderGroupNotFound(RecorderGroupID)
    case epochNotFound(RecordingEpochID)
    case invalidChannel(ChannelReference)
    /// The channel index exceeds a *known* channel count. Unknown counts are not range-checked.
    case channelOutOfRange(ChannelReference, channelCount: Int)
    case channelIsPrimaryOfAnotherSpeaker(ChannelReference, SpeakerID)
    case channelIsSpeakersPrimary(ChannelReference)
    case duplicateBackup(ChannelReference)
    case backupNotFound(ChannelReference)
    /// The user confirmed the source as a recording-level `backup`; change its role before making it a primary.
    case sourceIsDesignatedBackup(SourceID)
}

/// Pure, validated operations. Each returns a new value or throws without partial mutation.
extension ShowDocumentModel {
    public func renamingShow(to title: String) throws(DomainError) -> ShowDocumentModel {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        var copy = self
        copy.show.title = trimmed
        return copy
    }

    public func addingEpisode(_ episode: Episode) throws(DomainError) -> ShowDocumentModel {
        guard self.episode(episode.id) == nil else { throw .duplicateEpisode(episode.id) }
        guard !episode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyTitle }
        var copy = self
        copy.episodes.append(episode)
        return copy
    }

    public func removingEpisode(_ id: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var copy = self
        copy.episodes.remove(at: index)
        return copy
    }

    public func renamingEpisode(_ id: EpisodeID, to title: String) throws(DomainError) -> ShowDocumentModel {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        return try updatingEpisode(id) { $0.title = trimmed }
    }

    public func addingSpeaker(_ speaker: Speaker) throws(DomainError) -> ShowDocumentModel {
        guard self.speaker(speaker.id) == nil else { throw .duplicateSpeaker(speaker.id) }
        guard !speaker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyTitle }
        var copy = self
        copy.speakers.append(speaker)
        return copy
    }

    public func addingRecorderGroup(_ group: RecorderGroup, to episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard allRecorderGroupIDs.contains(group.id) == false else { throw .duplicateRecorderGroup(group.id) }
        return try updatingEpisode(episodeID) { $0.recorderGroups.append(group) }
    }

    public func addingSource(_ source: SourceRecord, to episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard allSourceIDs.contains(source.id) == false else { throw .duplicateSource(source.id) }
        guard let episode = self.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        if let groupID = source.placement.recorderGroupID {
            guard let group = episode.recorderGroup(groupID) else { throw .recorderGroupNotFound(groupID) }
            if let epochID = source.placement.epochID, !group.epochs.contains(where: { $0.id == epochID }) {
                throw .epochNotFound(epochID)
            }
        } else if let epochID = source.placement.epochID {
            throw .epochNotFound(epochID)
        }
        return try updatingEpisode(episodeID) { $0.sources.append(source) }
    }

    public func settingSourceRole(
        _ role: SourceRole,
        confirmation: Confirmation,
        source sourceID: SourceID,
        in episodeID: EpisodeID
    ) throws(DomainError) -> ShowDocumentModel {
        guard let episode = self.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard let index = episode.sources.firstIndex(where: { $0.id == sourceID }) else { throw .sourceNotFound(sourceID) }
        return try updatingEpisode(episodeID) {
            $0.sources[index].role = role
            $0.sources[index].roleConfirmation = confirmation
        }
    }

    /// Assigns `channel` as `speakerID`'s primary for an episode.
    ///
    /// Moving a channel that is currently one of the speaker's backups promotes it (it is removed from the
    /// backups). An `.unassigned` or provisional `.backup` source becomes a `.primary` source with the same
    /// confirmation; a user-confirmed `.backup` source is refused until the user changes its role.
    public func assigningPrimary(
        _ channel: ChannelReference,
        to speakerID: SpeakerID,
        in episodeID: EpisodeID,
        confirmation: Confirmation
    ) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        guard let episode = self.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        let source = try Self.validatedSource(for: channel, in: episode)
        guard !(source.role == .backup && source.roleConfirmation == .userConfirmed) else {
            throw .sourceIsDesignatedBackup(source.id)
        }
        if let other = episode.speakerAssignments.first(where: { $0.speakerID != speakerID && $0.primary == channel }) {
            throw .channelIsPrimaryOfAnotherSpeaker(channel, other.speakerID)
        }
        return try updatingEpisode(episodeID) { episode in
            var assignment = episode.assignment(for: speakerID) ?? SpeakerAssignment(speakerID: speakerID)
            assignment.primary = channel
            assignment.primaryConfirmation = confirmation
            assignment.backups.removeAll { $0 == channel }
            episode.setAssignment(assignment)
            if let index = episode.sources.firstIndex(where: { $0.id == source.id }), episode.sources[index].role != .primary {
                episode.sources[index].role = .primary
                episode.sources[index].roleConfirmation = confirmation
            }
        }
    }

    public func clearingPrimary(of speakerID: SpeakerID, in episodeID: EpisodeID) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        return try updatingEpisode(episodeID) { episode in
            guard var assignment = episode.assignment(for: speakerID) else { return }
            assignment.primary = nil
            assignment.primaryConfirmation = .provisional
            episode.setAssignment(assignment)
        }
    }

    /// Adds a backup channel for a speaker. Backups stay referenced; they are never analyzed in place of
    /// the selected primary.
    public func addingBackup(
        _ channel: ChannelReference,
        to speakerID: SpeakerID,
        in episodeID: EpisodeID
    ) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        guard let episode = self.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        let source = try Self.validatedSource(for: channel, in: episode)
        let existing = episode.assignment(for: speakerID)
        guard existing?.primary != channel else { throw .channelIsSpeakersPrimary(channel) }
        guard existing?.backups.contains(channel) != true else { throw .duplicateBackup(channel) }
        return try updatingEpisode(episodeID) { episode in
            var assignment = existing ?? SpeakerAssignment(speakerID: speakerID)
            assignment.backups.append(channel)
            episode.setAssignment(assignment)
            if let index = episode.sources.firstIndex(where: { $0.id == source.id }), episode.sources[index].role == .unassigned {
                episode.sources[index].role = .backup
                episode.sources[index].roleConfirmation = .provisional
            }
        }
    }

    public func removingBackup(
        _ channel: ChannelReference,
        from speakerID: SpeakerID,
        in episodeID: EpisodeID
    ) throws(DomainError) -> ShowDocumentModel {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        guard let episode = self.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard var assignment = episode.assignment(for: speakerID), assignment.backups.contains(channel) else {
            throw .backupNotFound(channel)
        }
        assignment.backups.removeAll { $0 == channel }
        return try updatingEpisode(episodeID) { $0.setAssignment(assignment) }
    }

    // MARK: - Helpers

    var allSourceIDs: Set<SourceID> {
        Set(episodes.flatMap { $0.sources.map(\.id) })
    }

    var allRecorderGroupIDs: Set<RecorderGroupID> {
        Set(episodes.flatMap { $0.recorderGroups.map(\.id) })
    }

    private func updatingEpisode(
        _ id: EpisodeID,
        _ transform: (inout Episode) -> Void
    ) throws(DomainError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var copy = self
        transform(&copy.episodes[index])
        return copy
    }

    private static func validatedSource(for channel: ChannelReference, in episode: Episode) throws(DomainError) -> SourceRecord {
        guard let source = episode.source(channel.sourceID) else { throw .sourceNotFound(channel.sourceID) }
        guard channel.channel >= 0 else { throw .invalidChannel(channel) }
        if let count = source.observations.channelCount.value, channel.channel >= count {
            throw .channelOutOfRange(channel, channelCount: count)
        }
        return source
    }
}

extension Episode {
    fileprivate mutating func setAssignment(_ assignment: SpeakerAssignment) {
        if let index = speakerAssignments.firstIndex(where: { $0.speakerID == assignment.speakerID }) {
            speakerAssignments[index] = assignment
        } else {
            speakerAssignments.append(assignment)
        }
    }
}
