import Foundation

/// A semantic problem in a decoded canonical value. Readers refuse to open values with issues rather than
/// silently repairing them.
public struct ValidationIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        case schemaVersionMismatch
        case duplicateID
        case danglingReference
        case invalidChannel
        case conflictingPrimary
        case duplicateAssignment
        case historyCursorOutOfRange
        case emptyTitle
        /// A structurally inconsistent `EpisodeAlignment` (revision order, accepted/derived references, map bytes).
        case invalidAlignment
        case invalidCutAudit
    }

    public var code: Code
    public var detail: String

    public init(_ code: Code, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    public var description: String { "\(code.rawValue): \(detail)" }
}

extension ShowDocumentModel {
    /// Checks referential and semantic integrity of the whole value.
    public func validationIssues(expectedSchemaVersion: Int = SchemaVersion.show) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if schemaVersion != expectedSchemaVersion {
            issues.append(.init(.schemaVersionMismatch, "payload \(schemaVersion) != expected \(expectedSchemaVersion)"))
        }
        if show.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.emptyTitle, "show \(show.id)"))
        }
        issues += duplicates(in: episodes.map(\.id), kind: "episode")
        issues += duplicates(in: speakers.map(\.id), kind: "speaker")
        issues += duplicates(in: episodes.flatMap { $0.sources.map(\.id) }, kind: "source")
        issues += duplicates(in: episodes.flatMap { $0.recorderGroups.map(\.id) }, kind: "recorder group")
        issues += duplicates(in: episodes.flatMap { $0.recorderGroups.flatMap { $0.epochs.map(\.id) } }, kind: "epoch")
        if let cutAudits {
            if cutAudits.isEmpty {
                issues.append(.init(.invalidCutAudit, "empty cut audit collection must be omitted"))
            }
            issues += duplicates(in: cutAudits.map(\.id), kind: "cut audit")
        }

        let speakerIDs = Set(speakers.map(\.id))
        for episode in episodes {
            issues += Self.issues(in: episode, speakerIDs: speakerIDs)
            if let alignment = episode.alignment {
                issues += alignment.structuralIssues(episode: episode.id)
            }
        }

        if history.cursor < 0 || history.cursor > history.entries.count {
            issues.append(.init(.historyCursorOutOfRange, "cursor \(history.cursor) of \(history.entries.count)"))
        }
        return issues
    }

    private static func issues(in episode: Episode, speakerIDs: Set<SpeakerID>) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for source in episode.sources {
            if let groupID = source.placement.recorderGroupID {
                if let group = episode.recorderGroup(groupID) {
                    if let epochID = source.placement.epochID, !group.epochs.contains(where: { $0.id == epochID }) {
                        issues.append(.init(.danglingReference, "source \(source.id) epoch \(epochID)"))
                    }
                } else {
                    issues.append(.init(.danglingReference, "source \(source.id) recorder group \(groupID)"))
                }
            } else if let epochID = source.placement.epochID {
                issues.append(.init(.danglingReference, "source \(source.id) epoch \(epochID) without group"))
            }
        }

        var seenSpeakers = Set<SpeakerID>()
        var primaries: [ChannelReference: SpeakerID] = [:]
        for assignment in episode.speakerAssignments {
            if !speakerIDs.contains(assignment.speakerID) {
                issues.append(.init(.danglingReference, "episode \(episode.id) speaker \(assignment.speakerID)"))
            }
            if !seenSpeakers.insert(assignment.speakerID).inserted {
                issues.append(.init(.duplicateAssignment, "episode \(episode.id) speaker \(assignment.speakerID)"))
            }
            let channels = (assignment.primary.map { [$0] } ?? []) + assignment.backups
            for channel in channels {
                issues += channelIssues(channel, in: episode)
            }
            if let primary = assignment.primary {
                if let other = primaries[primary] {
                    issues.append(.init(.conflictingPrimary, "\(primary) for \(other) and \(assignment.speakerID)"))
                }
                primaries[primary] = assignment.speakerID
                if assignment.backups.contains(primary) {
                    issues.append(.init(.invalidChannel, "speaker \(assignment.speakerID) primary is also a backup"))
                }
            }
        }
        return issues
    }

    private static func channelIssues(_ channel: ChannelReference, in episode: Episode) -> [ValidationIssue] {
        guard let source = episode.source(channel.sourceID) else {
            return [.init(.danglingReference, "episode \(episode.id) channel source \(channel.sourceID)")]
        }
        // An unknown channel is a valid "not yet stated" reference; only a known index is range-checked.
        guard let index = channel.channel.value else { return [] }
        if index < 0 {
            return [.init(.invalidChannel, "\(channel)")]
        }
        if let count = source.observations.channelCount.value, index >= count {
            return [.init(.invalidChannel, "\(channel) >= \(count)")]
        }
        return []
    }

    private func duplicates<ID: Hashable & CustomStringConvertible>(in ids: [ID], kind: String) -> [ValidationIssue] {
        var seen = Set<ID>()
        var issues: [ValidationIssue] = []
        for id in ids where !seen.insert(id).inserted {
            issues.append(.init(.duplicateID, "\(kind) \(id)"))
        }
        return issues
    }
}

extension EpisodeAlignment {
    /// Structure only. References to groups/epochs/sources that the episode no longer contains are *not*
    /// issues (that is staleness, reported by `WWDerived`); refusing them would let an ordinary delete make a
    /// show unopenable. The embedded map bytes are checked by WWPersistence, which knows `WWTimeMap`.
    public func structuralIssues(episode: EpisodeID) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if maps.isEmpty {
            // One representation of "no alignment": the field is omitted.
            issues.append(.init(.invalidAlignment, "episode \(episode) alignment has no maps"))
        }
        var previous = 0
        for version in maps {
            if version.revision <= previous {
                issues.append(.init(.invalidAlignment, "episode \(episode) map revision \(version.revision) after \(previous)"))
            }
            if let parent = version.derivedFrom, parent >= version.revision || !maps.contains(where: { $0.revision == parent }) {
                issues.append(.init(.invalidAlignment, "episode \(episode) map \(version.revision) derived from \(parent)"))
            }
            var seen = Set<SourceID>()
            for input in version.inputs.sources {
                if !seen.insert(input.sourceID).inserted {
                    issues.append(.init(.invalidAlignment, "episode \(episode) map \(version.revision) repeats input \(input.sourceID)"))
                }
                if let format = input.formatInterpretationVersion, format < 1 {
                    issues.append(.init(.invalidAlignment, "episode \(episode) map \(version.revision) format version \(format)"))
                }
                if let digest = input.contentDigest, digest.isEmpty {
                    issues.append(.init(.invalidAlignment, "episode \(episode) map \(version.revision) empty digest"))
                }
            }
            if let recipe = version.inputs.recipe,
               recipe.revision < 1 || recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(.invalidAlignment, "episode \(episode) map \(version.revision) recipe"))
            }
            previous = max(previous, version.revision)
        }
        if let accepted = acceptedRevision, map(revision: accepted) == nil {
            issues.append(.init(.invalidAlignment, "episode \(episode) accepted revision \(accepted) missing"))
        }
        return issues
    }
}

extension LibraryModel {
    public func validationIssues(expectedSchemaVersion: Int = SchemaVersion.library) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if schemaVersion != expectedSchemaVersion {
            issues.append(.init(.schemaVersionMismatch, "payload \(schemaVersion) != expected \(expectedSchemaVersion)"))
        }
        var seen = Set<ShowID>()
        for entry in entries where !seen.insert(entry.showID).inserted {
            issues.append(.init(.duplicateID, "library entry \(entry.showID)"))
        }
        var collectionIDs = Set<CollectionID>()
        for collection in collections where !collectionIDs.insert(collection.id).inserted {
            issues.append(.init(.duplicateID, "collection \(collection.id)"))
        }
        for collection in collections {
            for showID in collection.showIDs where !seen.contains(showID) {
                issues.append(.init(.danglingReference, "collection \(collection.id) show \(showID)"))
            }
        }
        for showID in recentShowIDs where !seen.contains(showID) {
            issues.append(.init(.danglingReference, "recent show \(showID)"))
        }
        return issues
    }
}
