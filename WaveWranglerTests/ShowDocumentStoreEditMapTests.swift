import AppKit
import Testing
import WWCore
import WWPersistence
import WWTimeMap

// The unhosted target compiles the real store but not the app's NSDocument or event instrumentation.
@MainActor
final class ShowDocument: NSDocument {
    let status = StoreTestStatus()
    func coalescedEditDidChangeModel() {}
}

@MainActor
final class StoreTestStatus {
    var formatUpdate: FormatUpdateState?
}

@MainActor
enum Responsiveness {
    static func interaction(_ name: StaticString) {}
}

@MainActor
@Suite("Native edit-map store")
struct ShowDocumentStoreEditMapTests {
    private func savedShow() throws -> (model: ShowDocumentModel, mappedID: EpisodeID, otherID: EpisodeID) {
        let source = SourceRecord(displayNameHint: "synthetic")
        let mapped = Episode(
            title: "Mapped", sources: [source],
            alignment: EpisodeAlignment(
                maps: [TimeMapVersion(
                    revision: 2,
                    inputs: TimeMapInputs(sources: [TimeMapSourceInput(sourceID: source.id)]),
                    map: .object([:])
                )],
                acceptedRevision: 2
            )
        )
        let other = Episode(title: "Other")
        let initial = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [mapped, other])
        let version = EditMapVersion(
            revision: 1, alignmentRevision: 2, sourceIDs: [source.id],
            removals: [EditRemoval(startFrame: 100, endFrame: 200, decisionID: UUID())]
        )
        return (try initial.recordingEditMap(version, in: mapped.id, actionName: "Shorten"), mapped.id, other.id)
    }

    private func savedPersistableShow() throws -> (model: ShowDocumentModel, mappedID: EpisodeID, otherID: EpisodeID) {
        var fixture = try savedShow()
        let group = RecorderGroupID(), epoch = RecordingEpochID(), occurrence = SourceOccurrenceID()
        let sourceID = fixture.model.episodes[0].sources[0].id
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence)
        let mapped = EpochClockMap(
            epoch: epoch,
            mapping: .mapped(
                segments: [try AffineClockSegment(
                    groupClockStart: .zero, groupClockEnd: ExactRational(10),
                    rateRatio: .one, alignedOffset: .zero
                )],
                provenance: .timelineReference
            )
        )
        let placement = OccurrencePlacement(
            occurrence: try SourceOccurrence(
                id: occurrence, source: sourceID, nominalRate: NominalRate(48_000), frameCount: 480_000
            ),
            spans: [EpochSpan(startFrame: 0, endFrame: 480_000, epoch: epoch, groupClockOffset: .zero)]
        )
        let groupMap = try GroupTimeMap(group: group, reference: reference, epochs: [mapped], placements: [placement])
        let timeline = try AlignedTimelineMap(reference: reference, groups: [groupMap])
        fixture.model.episodes[0].recorderGroups = [
            RecorderGroup(id: group, name: "Recorder", epochs: [RecordingEpoch(id: epoch, label: "Take 1")])
        ]
        fixture.model.episodes[0].sources[0].placement = SourcePlacement(recorderGroupID: group, epochID: epoch)
        fixture.model.episodes[0].alignment?.maps[0].map = try EmbeddedTimeMapCodec.encode(timeline)
        return fixture
    }

    @Test func deleteUndoRedoKeepsMapAndHistoryAtomicButNeverRestoresProof() throws {
        let fixture = try savedShow()
        let document = ShowDocument()
        let store = ShowDocumentStore(model: fixture.model)
        store.document = document
        let undo = try #require(document.undoManager)
        let prior = store.model

        #expect(!store.apply("Inject map") { model in
            var changed = model
            changed.editMaps.removeAll()
            return changed
        })
        #expect(store.lastEditMapError == .unauthorizedMutation)
        #expect(store.model == prior)
        let forbidden = try prior.removingEpisode(fixture.mappedID)
        #expect(!store.applyReplacement("Inject map", model: forbidden) { _ in })
        #expect(store.model == prior)

        #expect(store.removeEpisode(fixture.mappedID, actionName: "Delete Episode"))
        let deleted = store.model
        #expect(deleted.episode(fixture.mappedID) == nil)
        #expect(deleted.episode(fixture.otherID) != nil)
        #expect(deleted.editMaps.isEmpty)
        #expect(deleted.history.undoActionName == "Delete Episode")
        #expect(deleted.history.entries.count == prior.history.entries.count + 1)
        #expect(deleted.validationIssues().isEmpty)
        #expect(undo.canUndo)

        undo.undo()
        #expect(store.model.episode(fixture.mappedID) != nil)
        #expect(store.model.editMaps(for: fixture.mappedID)?.versions == prior.editMaps(for: fixture.mappedID)?.versions)
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(store.lastEditMapError == .proofUnavailable)
        #expect(store.model.history.undoActionName == "Invalidate Edit Map")
        #expect(store.model.validationIssues().isEmpty)

        undo.redo()
        #expect(store.model == deleted)
        #expect(store.model.validationIssues().isEmpty)
    }

    @Test func unrelatedRenamesPreserveSelectionButReadsAndAdmissionStillRefuse() throws {
        let fixture = try savedShow()
        let document = ShowDocument()
        let store = ShowDocumentStore(model: fixture.model)
        store.document = document
        let undo = try #require(document.undoManager)
        #expect(store.apply("Rename show") { model throws(DomainError) in
            try model.renamingShow(to: "Renamed show")
        })
        #expect(store.apply("Rename episode") { model throws(DomainError) in
            try model.renamingEpisode(fixture.mappedID, to: "Renamed episode")
        })
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == 1)
        #expect(store.lastEditMapError == nil)
        undo.undo()
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == 1)
        undo.redo()
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == 1)
        #expect(throws: EditMapPublicationError.proofUnavailable) {
            try store.selectedEditMap(in: fixture.mappedID)
        }
        var next = try #require(store.model.editMaps(for: fixture.mappedID)?.versions.first)
        next.revision = 2
        #expect(!store.publishEditMap(
            next, in: fixture.mappedID, expecting: store.editSnapshot(), actionName: "Shorten"
        ))
        #expect(store.lastEditMapError == .proofUnavailable)
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == 1)
    }

    @Test func relevantMutationInvalidatesSavedSelectionAndUndoCannotRestoreIt() throws {
        let fixture = try savedShow()
        let document = ShowDocument()
        let store = ShowDocumentStore(model: fixture.model)
        store.document = document
        let undo = try #require(document.undoManager)
        #expect(store.apply("Change source") { model throws(DomainError) in
            try model.settingSourceRole(
                .backup, confirmation: .provisional,
                source: model.episodes[0].sources[0].id, in: fixture.mappedID
            )
        })
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(store.model.editMaps(for: fixture.mappedID)?.versions == fixture.model.editMaps(for: fixture.mappedID)?.versions)
        #expect(store.model.history.undoActionName == "Invalidate Edit Map")
        undo.undo()
        #expect(store.model.episode(fixture.mappedID) == fixture.model.episode(fixture.mappedID))
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(store.lastEditMapError == nil)
    }

    @Test func deletedEpisodeCheckpointRestoresUndoablyAndResolvesOnlyAfterSave() throws {
        let fixture = try savedPersistableShow()
        let base = fixture.model
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-map-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let disk = root.appending(path: "show.wwshow")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalBytes = try coder.encode(base, revision: 2)
        try originalBytes.write(to: disk)

        let beforeCrash = ShowDocumentStore(model: base)
        let beforeCrashDocument = ShowDocument()
        beforeCrash.document = beforeCrashDocument
        #expect(beforeCrash.removeEpisode(fixture.mappedID, actionName: "Delete Episode"))
        let unsaved = beforeCrash.model
        #expect(unsaved.editMaps.isEmpty)
        #expect(try coder.decode(Data(contentsOf: disk)).payload == base)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(unsaved, revision: 3), base: RevisionFingerprint(of: originalBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let offer = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originalBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        )
        let candidate = try #require(offer.candidate)
        #expect(candidate.relation == .basedOnCurrent)

        let reopenedDocument = ShowDocument()
        let reopened = ShowDocumentStore(model: try coder.decode(Data(contentsOf: disk)).payload)
        reopened.document = reopenedDocument
        let undo = try #require(reopenedDocument.undoManager)
        #expect(reopened.restoreEditCheckpoint(candidate.payload, basedOn: base))
        var restoredOffers = RestoredEditCheckpoints.State<ShowDocumentModel>()
        restoredOffers.mark(candidate.url, snapshot: reopened.model, generation: restoredOffers.currentGeneration)
        #expect(reopened.model == unsaved)
        #expect(try coder.decode(Data(contentsOf: disk)).payload == base)
        #expect(recovery.offeredEditCheckpoints(for: key).count == 1)

        undo.undo()
        restoredOffers.unmark(candidate.url, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) != nil)
        #expect(reopened.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(throws: EditMapPublicationError.invalidMap) {
            try reopened.selectedEditMap(in: fixture.mappedID)
        }
        #expect(recovery.offeredEditCheckpoints(for: key).count == 1)
        undo.redo()
        restoredOffers.mark(candidate.url, snapshot: reopened.model, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) == nil)
        #expect(reopened.model.editMaps.isEmpty)

        let saved = try coder.encode(reopened.model, revision: 3)
        try saved.write(to: disk)
        let resolved = restoredOffers.resolved(started: restoredOffers.startingSave(), published: reopened.model, current: reopened.model)
        try recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        #expect(recovery.offeredEditCheckpoints(for: key).isEmpty)
        #expect(try coder.decode(Data(contentsOf: disk)).payload == unsaved)
    }

    @Test func refusedCheckpointStaysOfferedAfterUnchangedSave() throws {
        let fixture = try savedPersistableShow()
        let base = fixture.model
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-map-refusal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let baseBytes = try coder.encode(base, revision: 2)
        var forged = base
        forged.editMaps.removeAll()
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(forged, revision: 3), base: RevisionFingerprint(of: baseBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let offer = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: baseBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        )
        let candidate = try #require(offer.candidate)
        let store = ShowDocumentStore(model: base)
        #expect(!store.restoreEditCheckpoint(candidate.payload, basedOn: base))
        #expect(store.lastEditMapError == .unauthorizedMutation)
        #expect(store.model == base)
        let restoredOffers = RestoredEditCheckpoints.State<ShowDocumentModel>()
        #expect(restoredOffers.resolved(started: restoredOffers.startingSave(), published: base, current: base).isEmpty)
        #expect(recovery.offeredEditCheckpoints(for: key).count == 1)
        let newerBytes = try coder.encode(store.model, revision: 3)
        let disk = root.appending(path: "saved.wwshow")
        try newerBytes.write(to: disk)
        let reopened = try coder.decode(Data(contentsOf: disk)).payload
        #expect(reopened == base)
        #expect(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: newerBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate?.relation == .basedOnOtherRevision)
    }

    @Test func deletedEpisodeRestoreRevertThenUnrelatedSaveKeepsOffer() throws {
        let fixture = try savedPersistableShow()
        let base = fixture.model
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-map-revert-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = RecoveryStore(root: root)
        let disk = root.appending(path: "show.wwshow")
        let baseBytes = try coder.encode(base, revision: 2)
        try baseBytes.write(to: disk)
        let deleted = try base.deletingEpisode(fixture.mappedID, actionName: "Delete Episode")
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(deleted, revision: 3), base: RevisionFingerprint(of: baseBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let candidate = try #require(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: baseBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate)
        let document = ShowDocument()
        let store = ShowDocumentStore(model: base)
        store.document = document
        var restores = RestoredEditCheckpoints.State<ShowDocumentModel>()
        #expect(store.restoreEditCheckpoint(candidate.payload, basedOn: base))
        restores.mark(candidate.url, snapshot: store.model, generation: restores.currentGeneration)
        #expect(store.model.episode(fixture.mappedID) == nil)
        let oldSave = restores.startingSave()

        // NSDocument's read(from:) replaces the model on Revert to Last Saved.
        store.replaceLoadedModel(try coder.decode(Data(contentsOf: disk)).payload)
        restores.supersede()
        document.undoManager?.removeAllActions()
        #expect(store.model == base && restores.isEmpty)
        #expect(restores.resolved(started: oldSave, published: deleted, current: deleted).isEmpty)
        #expect(store.apply("Rename show") { model throws(DomainError) in
            try model.renamingShow(to: "Unrelated save")
        })
        let unrelated = store.model
        let save = restores.startingSave()
        let unrelatedBytes = try coder.encode(unrelated, revision: 3)
        try unrelatedBytes.write(to: disk)
        #expect(restores.resolved(started: save, published: unrelated, current: store.model).isEmpty)
        #expect(recovery.offeredEditCheckpoints(for: key).count == 1)
        let reopened = try coder.decode(Data(contentsOf: disk)).payload
        #expect(reopened == unrelated)
        #expect(reopened.episode(fixture.mappedID) != nil)
        #expect(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: unrelatedBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate?.url == candidate.url)
    }

    @Test func recoveryRefusesMalformedStaleOrSupersededMapsButKeepsUnrelatedRename() throws {
        let fixture = try savedShow()
        let base = fixture.model
        let store = ShowDocumentStore(model: base)
        let document = ShowDocument()
        store.document = document
        let rename = try base.renamingShow(to: "Recovered title")
        #expect(store.restoreEditCheckpoint(rename, basedOn: base))
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == 1)
        #expect(throws: EditMapPublicationError.proofUnavailable) {
            try store.selectedEditMap(in: fixture.mappedID)
        }

        store.replaceLoadedModel(base)
        var malformed = try base.deletingEpisode(fixture.mappedID, actionName: "Delete Episode")
        malformed.editMaps = base.editMaps
        #expect(!store.restoreEditCheckpoint(malformed, basedOn: base))
        #expect(store.lastEditMapError == .invalidMap)
        #expect(store.model == base)

        var stale = base
        stale.editMaps[0].versions[0].alignmentRevision = 1
        #expect(!store.restoreEditCheckpoint(stale, basedOn: base))
        #expect(store.lastEditMapError == .unauthorizedMutation)
        #expect(store.model == base)

        let deleted = try base.deletingEpisode(fixture.mappedID, actionName: "Delete Episode")
        #expect(store.apply("Rename") { model throws(DomainError) in
            try model.renamingShow(to: "Concurrent edit")
        })
        #expect(!store.restoreEditCheckpoint(deleted, basedOn: base))
        #expect(store.lastEditMapError == .superseded)
        #expect(store.model.show.title == "Concurrent edit")
    }

    @Test func deletionRecoveryKeepsOtherSavedChoicesInertAndRefusesChangingThem() throws {
        let fixture = try savedShow()
        var base = fixture.model
        let extraSource = SourceRecord(displayNameHint: "other synthetic")
        let otherMap = EditMapVersion(
            revision: 1, alignmentRevision: 2, sourceIDs: [extraSource.id],
            removals: [EditRemoval(startFrame: 200, endFrame: 300, decisionID: UUID())]
        )
        base.episodes[1].sources = [extraSource]
        base.episodes[1].alignment = EpisodeAlignment(
            maps: [TimeMapVersion(
                revision: 2,
                inputs: TimeMapInputs(sources: [TimeMapSourceInput(sourceID: extraSource.id)]),
                map: .object([:])
            )],
            acceptedRevision: 2
        )
        base = try base.recordingEditMap(otherMap, in: fixture.otherID, actionName: "Shorten other")
        let store = ShowDocumentStore(model: base)
        let document = ShowDocument()
        store.document = document

        let deleted = try base.deletingEpisode(fixture.mappedID, actionName: "Delete Episode")
            .renamingShow(to: "Unsaved rename")
        #expect(store.restoreEditCheckpoint(deleted, basedOn: base))
        #expect(store.model.episode(fixture.mappedID) == nil)
        #expect(store.model.show.title == "Unsaved rename")
        #expect(store.model.editMaps(for: fixture.otherID)?.selectedRevision == 1)
        #expect(throws: EditMapPublicationError.proofUnavailable) {
            try store.selectedEditMap(in: fixture.otherID)
        }
        let undo = try #require(document.undoManager)
        undo.undo()
        #expect(store.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(store.model.editMaps(for: fixture.otherID)?.selectedRevision == 1)
        undo.redo()
        #expect(store.model.editMaps(for: fixture.mappedID) == nil)
        #expect(store.model.editMaps(for: fixture.otherID)?.selectedRevision == 1)

        store.replaceLoadedModel(base)
        var changedChoice = deleted
        changedChoice.editMaps[0].selectedRevision = nil
        #expect(!store.restoreEditCheckpoint(changedChoice, basedOn: base))
        #expect(store.lastEditMapError == .unauthorizedMutation)
        #expect(store.model == base)

        var changedInputs = deleted
        changedInputs.episodes[0].sources[0].role = .backup
        #expect(!store.restoreEditCheckpoint(changedInputs, basedOn: base))
        #expect(store.lastEditMapError == .unauthorizedMutation)
        #expect(store.model == base)
    }

    @Test func ordinaryCheckpointWithoutMapChangesStillRestoresUndoably() throws {
        let base = ShowDocumentModel.untitled(title: "Saved")
        let snapshot = try base.renamingShow(to: "Unsaved")
        let document = ShowDocument()
        let store = ShowDocumentStore(model: base)
        store.document = document
        #expect(store.restoreEditCheckpoint(snapshot, basedOn: base))
        #expect(store.model == snapshot)
        let undo = try #require(document.undoManager)
        undo.undo()
        #expect(store.model == base)
        undo.redo()
        #expect(store.model == snapshot)
        #expect(store.apply("Another edit") { model throws(DomainError) in
            try model.renamingShow(to: "Newer unsaved work")
        })
        #expect(!store.restoreEditCheckpoint(snapshot, basedOn: base))
        #expect(store.lastEditMapError == .superseded)
        #expect(store.model.show.title == "Newer unsaved work")
    }
}
