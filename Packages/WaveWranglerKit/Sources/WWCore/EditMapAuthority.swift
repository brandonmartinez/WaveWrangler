import Foundation

/// A provisional, non-executable episode-wide shortening plan. Selection is durable, but it is not
/// permission to read sources or a render/speech credential. A consumer must obtain fresh source and
/// protection proof from the organizer before using it; no production consumer is admitted yet.
public struct EditMapVersion: Sendable, Equatable, Codable {
    public var revision: Int
    public var alignmentRevision: Int
    public var sourceIDs: [SourceID]
    public var removals: [EditRemoval]

    public init(revision: Int, alignmentRevision: Int, sourceIDs: [SourceID], removals: [EditRemoval]) {
        self.revision = revision
        self.alignmentRevision = alignmentRevision
        self.sourceIDs = sourceIDs
        self.removals = removals
    }
}

/// Half-open aligned-frame interval. The decision ID is a reference to a protected-speech review
/// decision, not proof that the decision still permits shortening.
public struct EditRemoval: Sendable, Equatable, Codable {
    public var startFrame: Int64
    public var endFrame: Int64
    public var decisionID: UUID

    public init(startFrame: Int64, endFrame: Int64, decisionID: UUID) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.decisionID = decisionID
    }
}

public struct EpisodeEditMaps: Sendable, Equatable, Codable {
    public var episodeID: EpisodeID
    public var versions: [EditMapVersion]
    /// A saved choice, never an assertion that the map is currently safe or executable.
    public var selectedRevision: Int?

    public init(episodeID: EpisodeID, versions: [EditMapVersion], selectedRevision: Int?) {
        self.episodeID = episodeID
        self.versions = versions
        self.selectedRevision = selectedRevision
    }

    public var selected: EditMapVersion? {
        selectedRevision.flatMap { revision in versions.first { $0.revision == revision } }
    }
}

public enum EditMapPublicationError: Error, Sendable, Equatable {
    case superseded
    case episodeUnavailable
    case alignmentChanged
    case sourcesChanged
    case invalidMap
    case revisionAlreadyUsed
    case proofUnavailable
    case unauthorizedMutation
}

/// A document store's live snapshot, including its mutation serial. Model equality alone misses
/// edit/undo ABA sequences across awaits. This is not proof of device access or protected speech.
public struct EditMapSnapshot: Sendable {
    public let model: ShowDocumentModel
    public let serial: UInt64

    public init(model: ShowDocumentModel, serial: UInt64) {
        self.model = model
        self.serial = serial
    }
}

/// Synchronous mutation boundary shared by the document store and synthetic tests. The `prove`
/// callback must be organizer-owned, independently resolving live source/access/protected decisions.
/// Production supplies none until those interfaces are qualified; no caller can mint authority here.
@MainActor
public enum EditMapPublication {
    public typealias Proof = @MainActor (ShowDocumentModel, EpisodeID, EditMapVersion) throws -> Void

    public static func recording(
        _ version: EditMapVersion, in episodeID: EpisodeID, actionName: String,
        expecting snapshot: EditMapSnapshot, current: () -> EditMapSnapshot, prove: Proof?
    ) throws(EditMapPublicationError) -> ShowDocumentModel {
        try check(snapshot, current: current)
        let successor = try snapshot.model.recordingEditMap(version, in: episodeID, actionName: actionName)
        try verify(version, in: episodeID, model: snapshot.model, prove: prove)
        try check(snapshot, current: current)
        return successor
    }

    public static func selecting(
        _ revision: Int, in episodeID: EpisodeID, expecting snapshot: EditMapSnapshot,
        current: () -> EditMapSnapshot, prove: Proof?
    ) throws(EditMapPublicationError) -> ShowDocumentModel {
        try check(snapshot, current: current)
        let successor = try snapshot.model.selectingEditMap(revision, in: episodeID, actionName: "Select Edit Map")
        guard let selected = successor.editMaps(for: episodeID)?.selected else { throw .invalidMap }
        try verify(selected, in: episodeID, model: snapshot.model, prove: prove)
        try check(snapshot, current: current)
        return successor
    }

    public static func selected(
        in episodeID: EpisodeID, current: () -> EditMapSnapshot, prove: Proof?
    ) throws(EditMapPublicationError) -> EditMapVersion {
        let snapshot = current()
        guard let selected = snapshot.model.editMaps(for: episodeID)?.selected else { throw .invalidMap }
        try snapshot.model.checkEditMapInputs(selected, in: episodeID)
        try verify(selected, in: episodeID, model: snapshot.model, prove: prove)
        try check(snapshot, current: current)
        return selected
    }

    /// An unchanged saved choice survives an unrelated edit without becoming executable authority.
    /// A newly restored choice must obtain fresh proof; revoke it in the same replacement if proof fails.
    public static func revalidated(
        _ candidate: ShowDocumentModel, replacing previous: ShowDocumentModel,
        current: () -> EditMapSnapshot, prove: Proof?
    ) -> (model: ShowDocumentModel, refusal: EditMapPublicationError?) {
        var safe = candidate.invalidatingChangedEditMaps(from: previous)
        var refusal: EditMapPublicationError?
        for index in safe.editMaps.indices {
            guard let selected = safe.editMaps[index].selected else { continue }
            let episodeID = safe.editMaps[index].episodeID
            if previous.editMaps(for: episodeID) == safe.editMaps[index] { continue }
            let serial = current().serial
            do {
                try safe.checkEditMapInputs(selected, in: episodeID)
                try verify(selected, in: episodeID, model: safe, prove: prove)
                guard current().serial == serial else { throw EditMapPublicationError.superseded }
            } catch {
                safe.editMaps[index].selectedRevision = nil
                safe.history = safe.history.recording(.current(actionName: "Invalidate Edit Map"))
                refusal = (error as? EditMapPublicationError) ?? .proofUnavailable
            }
        }
        return (safe, refusal)
    }

    private static func check(
        _ snapshot: EditMapSnapshot, current: () -> EditMapSnapshot
    ) throws(EditMapPublicationError) {
        let live = current()
        guard snapshot.serial == live.serial, snapshot.model == live.model else { throw .superseded }
    }

    private static func verify(
        _ version: EditMapVersion, in episodeID: EpisodeID,
        model: ShowDocumentModel, prove: Proof?
    ) throws(EditMapPublicationError) {
        guard let prove else { throw .proofUnavailable }
        do { try prove(model, episodeID, version) }
        catch let error as EditMapPublicationError { throw error }
        catch { throw .proofUnavailable }
    }
}

extension ShowDocumentModel {
    public func editMaps(for episodeID: EpisodeID) -> EpisodeEditMaps? {
        editMaps.first { $0.episodeID == episodeID }
    }

    /// Build the complete successor before a document store publishes it as one undoable value.
    /// The store, not the caller, supplies the live model and checks source/access/protection proof.
    public func recordingEditMap(
        _ version: EditMapVersion, in episodeID: EpisodeID, actionName: String
    ) throws(EditMapPublicationError) -> ShowDocumentModel {
        try checkEditMapInputs(version, in: episodeID)
        guard version.structuralIssues.isEmpty, !actionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .invalidMap }
        var copy = self
        if let index = copy.editMaps.firstIndex(where: { $0.episodeID == episodeID }) {
            let prior = copy.editMaps[index].versions.last?.revision ?? 0
            guard prior < Int.max, version.revision == prior + 1 else { throw .revisionAlreadyUsed }
            copy.editMaps[index].versions.append(version)
            copy.editMaps[index].selectedRevision = version.revision
        } else {
            guard version.revision == 1 else { throw .revisionAlreadyUsed }
            copy.editMaps.append(EpisodeEditMaps(episodeID: episodeID, versions: [version], selectedRevision: 1))
        }
        copy.history = history.recording(.current(actionName: actionName))
        return copy
    }

    public func selectingEditMap(
        _ revision: Int, in episodeID: EpisodeID, actionName: String
    ) throws(EditMapPublicationError) -> ShowDocumentModel {
        guard let index = editMaps.firstIndex(where: { $0.episodeID == episodeID }),
              let version = editMaps[index].versions.first(where: { $0.revision == revision })
        else { throw .invalidMap }
        try checkEditMapInputs(version, in: episodeID)
        guard !actionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidMap }
        var copy = self
        copy.editMaps[index].selectedRevision = revision
        copy.history = history.recording(.current(actionName: actionName))
        return copy
    }

    public func checkEditMapInputs(
        _ version: EditMapVersion, in episodeID: EpisodeID
    ) throws(EditMapPublicationError) {
        guard let episode = episode(episodeID) else { throw .episodeUnavailable }
        guard let accepted = episode.alignment?.acceptedMap,
              accepted.revision == version.alignmentRevision else { throw .alignmentChanged }
        let sources = accepted.inputs.sources.map(\.sourceID)
        guard !sources.isEmpty, sources == version.sourceIDs,
              Set(sources) == Set(episode.sources.map(\.id)) else { throw .sourcesChanged }
        guard version.structuralIssues.isEmpty else { throw .invalidMap }
    }

    /// A source/assignment/alignment change revokes the selection in the same model publication.
    /// Restoring a deleted episode instead goes through fresh proof in `revalidated`.
    public func invalidatingChangedEditMaps(from previous: ShowDocumentModel) -> ShowDocumentModel {
        var copy = self
        for index in copy.editMaps.indices where copy.editMaps[index].selectedRevision != nil {
            let id = copy.editMaps[index].episodeID
            let before = previous.episode(id)
            let after = episode(id)
            let changedInputs: Bool
            if let before, let after {
                changedInputs = before.sources != after.sources || before.speakerAssignments != after.speakerAssignments
                    || before.recorderGroups != after.recorderGroups || before.alignment != after.alignment
            } else {
                changedInputs = before != nil
            }
            if previous.show.id != show.id || changedInputs {
                copy.editMaps[index].selectedRevision = nil
                copy.history = copy.history.recording(.current(actionName: "Invalidate Edit Map"))
            }
        }
        return copy
    }

    public func editMapIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seen = Set<EpisodeID>()
        for state in editMaps {
            if !seen.insert(state.episodeID).inserted || episode(state.episodeID) == nil || state.versions.isEmpty {
                issues.append(.init(.invalidEditMap, "duplicate, missing episode or empty map state \(state.episodeID)"))
            }
            var last = 0
            for version in state.versions {
                if last == Int.max || version.revision != last + 1 || !version.structuralIssues.isEmpty {
                    issues.append(.init(.invalidEditMap, "episode \(state.episodeID) map revision \(version.revision)"))
                }
                last = version.revision
            }
            if let selected = state.selectedRevision, state.versions.first(where: { $0.revision == selected }) == nil {
                issues.append(.init(.invalidEditMap, "episode \(state.episodeID) selected revision \(selected) missing"))
            }
        }
        return issues
    }
}

extension EditMapVersion {
    fileprivate var structuralIssues: [String] {
        var issues: [String] = []
        if revision < 1 || alignmentRevision < 1 || sourceIDs.isEmpty || Set(sourceIDs).count != sourceIDs.count
            || removals.isEmpty { issues.append("invalid revision, sources or empty removal") }
        var end: Int64 = 0
        var decisions = Set<UUID>()
        for removal in removals {
            if removal.startFrame < end || removal.endFrame <= removal.startFrame
                || !decisions.insert(removal.decisionID).inserted { issues.append("overlap or duplicate decision") }
            end = removal.endFrame
        }
        return issues
    }
}
