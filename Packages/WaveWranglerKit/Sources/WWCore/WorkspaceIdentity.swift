import Foundation

public enum SpeakerColor: String, Sendable, Codable, CaseIterable {
    case blue, teal, green, purple, pink, indigo, brown, orange

    public static func defaultColor(for speaker: SpeakerID) -> Self {
        let index = speaker.description.utf8.reduce(0) { ($0 + Int($1)) % allCases.count }
        return allCases[index]
    }
}

public struct SpeakerAppearance: Sendable, Equatable, Codable {
    public var color: SpeakerColor
    public var avatarPNG: Data?

    public init(color: SpeakerColor, avatarPNG: Data? = nil) {
        self.color = color
        self.avatarPNG = avatarPNG
    }

    public var isValid: Bool {
        guard let avatarPNG else { return true }
        guard (24...524_288).contains(avatarPNG.count) else { return false }
        let header = Array(avatarPNG.prefix(24))
        guard Array(header.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[12..<16]) == [73, 72, 68, 82] else { return false }
        let width = header[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = header[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (1...512).contains(width) && (1...512).contains(height)
    }
}

public struct SpeakerAppearanceOverride: Sendable, Equatable, Codable {
    public var speaker: SpeakerID
    public var appearance: SpeakerAppearance

    public init(speaker: SpeakerID, appearance: SpeakerAppearance) {
        self.speaker = speaker
        self.appearance = appearance
    }
}

public enum RecorderIcon: String, Sendable, Codable, CaseIterable {
    case microphone = "mic"
    case recorder = "hifispeaker"
    case computer = "laptopcomputer"
    case phone = "iphone"
    case camera = "video"
    case headphones = "headphones"
    case interface = "slider.horizontal.3"
    case remote = "network"
}

public struct SavedSpeakerAssignment: Sendable, Equatable, Codable {
    public var speaker: SpeakerID
    public var channel: Knowledge<Int>
    public var isPrimary: Bool

    public init(speaker: SpeakerID, channel: Knowledge<Int>, isPrimary: Bool) {
        self.speaker = speaker
        self.channel = channel
        self.isPrimary = isPrimary
    }
}

public struct SavedSourceDefinition: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var statedChannel: Int?
    public var role: SourceRole
    public var assignments: [SavedSpeakerAssignment]

    public init(id: UUID = UUID(), name: String, statedChannel: Int? = nil,
                role: SourceRole = .unassigned, assignments: [SavedSpeakerAssignment] = []) {
        self.id = id
        self.name = name
        self.statedChannel = statedChannel
        self.role = role
        self.assignments = assignments
    }
}

public struct SavedRecorderDefinition: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var deviceName: String
    public var clockNote: String
    public var icon: RecorderIcon
    public var sources: [SavedSourceDefinition]

    public init(id: UUID = UUID(), name: String, deviceName: String = "", clockNote: String = "",
                icon: RecorderIcon = .recorder, sources: [SavedSourceDefinition] = []) {
        self.id = id
        self.name = name
        self.deviceName = deviceName
        self.clockNote = clockNote
        self.icon = icon
        self.sources = sources
    }
}

public struct ShowProfile: Sendable, Equatable, Codable {
    public var hosts: [SpeakerID]
    public var recorderDefinitions: [SavedRecorderDefinition]

    public init(hosts: [SpeakerID] = [], recorderDefinitions: [SavedRecorderDefinition] = []) {
        self.hosts = hosts
        self.recorderDefinitions = recorderDefinitions
    }
}

public enum EditingPlaybackPolicy: String, Sendable, Codable, CaseIterable {
    case keepChoices
    case muteNonPrimaries
    case soloPrimaries
    case soloBackups

    public var title: String {
        switch self {
        case .keepChoices: "Keep my playback choices"
        case .muteNonPrimaries: "Mute non-primary tracks for editing"
        case .soloPrimaries: "Solo primary tracks for editing"
        case .soloBackups: "Solo non-primary tracks for backup review"
        }
    }
}

public struct RecorderPositionLock: Sendable, Equatable, Codable {
    public var group: RecorderGroupID
    public var isLocked: Bool

    public init(group: RecorderGroupID, isLocked: Bool) {
        self.group = group
        self.isLocked = isLocked
    }
}

public struct EpisodeWorkspacePreferences: Sendable, Equatable, Codable {
    public var editingPlaybackPolicy: EditingPlaybackPolicy
    public var positionLocks: [RecorderPositionLock]

    public init(editingPlaybackPolicy: EditingPlaybackPolicy = .keepChoices,
                positionLocks: [RecorderPositionLock] = []) {
        self.editingPlaybackPolicy = editingPlaybackPolicy
        self.positionLocks = positionLocks
    }
}

extension Episode {
    public func positionIsLocked(_ group: RecorderGroupID) -> Bool {
        workspace?.positionLocks.first { $0.group == group }?.isLocked
            ?? (alignment?.acceptedRevision != nil)
    }
}

extension ShowDocumentModel {
    public func speakerAppearance(_ speakerID: SpeakerID, in episodeID: EpisodeID? = nil) -> SpeakerAppearance? {
        guard let speaker = speaker(speakerID) else { return nil }
        if let episodeID, let appearance = episode(episodeID)?.speakerAppearanceOverrides?
            .first(where: { $0.speaker == speakerID })?.appearance { return appearance }
        return speaker.appearance ?? SpeakerAppearance(color: .defaultColor(for: speakerID))
    }

    public func settingHost(_ speakerID: SpeakerID, isHost: Bool) throws(DomainError) -> Self {
        guard speaker(speakerID) != nil else { throw .speakerNotFound(speakerID) }
        var result = self
        var profile = show.profile ?? ShowProfile()
        profile.hosts.removeAll { $0 == speakerID }
        if isHost { profile.hosts.append(speakerID) }
        result.show.profile = profile
        return result
    }

    public func settingSpeakerAppearance(_ appearance: SpeakerAppearance?, for speakerID: SpeakerID,
                                         in episodeID: EpisodeID? = nil) throws(DomainError) -> Self {
        guard let speakerIndex = speakers.firstIndex(where: { $0.id == speakerID }) else {
            throw .speakerNotFound(speakerID)
        }
        guard appearance?.isValid != false else { throw .invalidWorkspace("Use a PNG avatar no larger than 512 pixels and 512 KB.") }
        var result = self
        if let episodeID {
            guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
            guard episodes[index].assignment(for: speakerID) != nil else { throw .speakerNotFound(speakerID) }
            var overrides = episodes[index].speakerAppearanceOverrides ?? []
            overrides.removeAll { $0.speaker == speakerID }
            if let appearance { overrides.append(.init(speaker: speakerID, appearance: appearance)) }
            result.episodes[index].speakerAppearanceOverrides = overrides.isEmpty ? nil : overrides
        } else {
            result.speakers[speakerIndex].appearance = appearance
        }
        return try result.validatingWorkspace()
    }

    public func settingRecorderIcon(_ icon: RecorderIcon, group groupID: RecorderGroupID,
                                    in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        guard let group = episodes[index].recorderGroups.firstIndex(where: { $0.id == groupID }) else {
            throw .recorderGroupNotFound(groupID)
        }
        var result = self
        result.episodes[index].recorderGroups[group].icon = icon
        return result
    }

    public func settingPositionLock(_ locked: Bool, group groupID: RecorderGroupID,
                                    in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        guard episodes[index].recorderGroup(groupID) != nil else { throw .recorderGroupNotFound(groupID) }
        var result = self
        var preferences = episodes[index].workspace ?? EpisodeWorkspacePreferences()
        preferences.positionLocks.removeAll { $0.group == groupID }
        preferences.positionLocks.append(.init(group: groupID, isLocked: locked))
        result.episodes[index].workspace = preferences
        return result
    }

    public func settingEditingPlaybackPolicy(_ policy: EditingPlaybackPolicy,
                                            in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        var result = self
        var preferences = episodes[index].workspace ?? EpisodeWorkspacePreferences()
        preferences.editingPlaybackPolicy = policy
        result.episodes[index].workspace = preferences
        return result
    }

    public func savingRecorderDefinition(from groupID: RecorderGroupID,
                                         in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard let group = episode.recorderGroup(groupID) else { throw .recorderGroupNotFound(groupID) }
        let definition = SavedRecorderDefinition(
            name: group.name, deviceName: group.deviceName, clockNote: group.clockNote, icon: group.icon ?? .recorder,
            sources: episode.sources(inRecorderGroup: groupID).map { source in
                SavedSourceDefinition(name: source.displayNameHint, statedChannel: episode.statedChannel(of: source.id),
                    role: source.role, assignments: episode.references(to: source.id).map {
                        SavedSpeakerAssignment(speaker: $0.speakerID, channel: $0.channel.channel, isPrimary: $0.isPrimary)
                    })
            }
        )
        var result = self
        var profile = show.profile ?? ShowProfile()
        profile.recorderDefinitions.append(definition)
        result.show.profile = profile
        return try result.validatingWorkspace()
    }

    public func addingRecorder(from definitionID: UUID, to episodeID: EpisodeID,
                               groupID: RecorderGroupID = RecorderGroupID()) throws(DomainError) -> Self {
        guard let definition = show.profile?.recorderDefinitions.first(where: { $0.id == definitionID }) else {
            throw .invalidWorkspace("The saved recorder definition is no longer available.")
        }
        return try addingRecorderGroup(RecorderGroup(id: groupID, name: definition.name,
            deviceName: definition.deviceName, clockNote: definition.clockNote,
            epochs: [RecordingEpoch(label: "1")], icon: definition.icon, definitionID: definition.id), to: episodeID)
    }

    public func applyingSourceDefinition(_ definition: SavedSourceDefinition, to sourceID: SourceID,
                                         in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard definition.statedChannel.map({ $0 < 0 }) != true,
              Set(definition.assignments.map(\.speaker)).count == definition.assignments.count,
              definition.assignments.allSatisfy({ $0.channel.value.map { $0 >= 0 } != false })
        else { throw .invalidWorkspace("The saved source definition contains invalid or conflicting assignments.") }
        var result = try settingStatedChannel(definition.statedChannel, forSource: sourceID, in: episodeID)
        result = try result.settingSourceRole(definition.role, confirmation: .provisional, source: sourceID, in: episodeID)
        for assignment in definition.assignments {
            guard speaker(assignment.speaker) != nil else { throw .speakerNotFound(assignment.speaker) }
            result = try result.includingSpeaker(assignment.speaker, inEpisode: episodeID)
            let channel = ChannelReference(sourceID: sourceID, channel: assignment.channel)
            if assignment.isPrimary {
                if let existing = result.episode(episodeID)?.assignment(for: assignment.speaker)?.primary,
                   existing != channel {
                    throw .invalidWorkspace("This speaker already has a Primary. Choose a replacement explicitly in the track inspector.")
                }
                result = try result.assigningPrimary(channel, to: assignment.speaker, in: episodeID, confirmation: .provisional)
            } else {
                result = try result.addingBackup(channel, to: assignment.speaker, in: episodeID)
            }

        }
        return try result.validatingWorkspace()
    }

    private func validatingWorkspace() throws(DomainError) -> Self {
        if let issue = workspaceValidationIssues(expectedSchemaVersion: SchemaVersion.show).first {
            throw .invalidWorkspace(issue.detail)
        }
        return self
    }

    func workspaceValidationIssues(expectedSchemaVersion: Int) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func invalid(_ detail: String) { issues.append(.init(.invalidWorkspace, detail)) }
        if expectedSchemaVersion < 7,
           show.profile != nil || speakers.contains(where: { $0.appearance != nil })
            || episodes.contains(where: {
                $0.workspace != nil || $0.speakerAppearanceOverrides != nil || $0.cleanup?.transcriptHistory != nil
                    || $0.recorderGroups.contains { $0.icon != nil || $0.definitionID != nil }
            }) {
            invalid("schemas before 7 cannot contain workspace profiles or preferences")
        }
        let speakerIDs = Set(speakers.map(\.id))
        let hosts = show.profile?.hosts ?? []
        if Set(hosts).count != hosts.count || !Set(hosts).isSubset(of: speakerIDs) {
            invalid("show hosts must be unique existing speakers")
        }
        let definitions = show.profile?.recorderDefinitions ?? []
        if Set(definitions.map(\.id)).count != definitions.count {
            invalid("saved recorder definitions must have unique identities")
        }
        for definition in definitions {
            let primaries = definition.sources.flatMap(\.assignments).filter(\.isPrimary).map(\.speaker)
            if Set(primaries).count != primaries.count {
                invalid("saved recorder definitions cannot assign multiple Primaries to the same speaker")
            }
            if definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || Set(definition.sources.map(\.id)).count != definition.sources.count {
                invalid("invalid saved recorder definition \(definition.id)")
            }
            for source in definition.sources {
                if source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || source.statedChannel.map({ $0 < 0 }) == true
                    || source.assignments.contains(where: {
                        !speakerIDs.contains($0.speaker) || $0.channel.value.map { $0 < 0 } == true
                    }) {
                    invalid("invalid saved source definition \(source.id)")
                }
                if Set(source.assignments.map(\.speaker)).count != source.assignments.count {
                    invalid("duplicate channel assignment in saved source definition \(source.id)")
                }
            }
        }
        var avatarBytes = 0
        for speaker in speakers {
            if speaker.appearance?.isValid == false { invalid("invalid appearance for speaker \(speaker.id)") }
            avatarBytes += speaker.appearance?.avatarPNG?.count ?? 0
        }
        for episode in episodes {
            let members = Set(episode.speakerAssignments.map(\.speakerID))
            let overrides = episode.speakerAppearanceOverrides ?? []
            if Set(overrides.map(\.speaker)).count != overrides.count {
                invalid("duplicate speaker appearance override in episode \(episode.id)")
            }
            for override in overrides {
                if !members.contains(override.speaker) || !override.appearance.isValid {
                    invalid("invalid speaker appearance override in episode \(episode.id)")
                }
                avatarBytes += override.appearance.avatarPNG?.count ?? 0
            }
            let locks = episode.workspace?.positionLocks ?? []
            if Set(locks.map(\.group)).count != locks.count
                || !Set(locks.map(\.group)).isSubset(of: Set(episode.recorderGroups.map(\.id))) {
                invalid("position locks must name unique existing recorder groups in episode \(episode.id)")
            }
        }
        if avatarBytes > 16 * 1024 * 1024 { invalid("portable avatar data exceeds the 16 MB show limit") }
        return issues
    }
}
