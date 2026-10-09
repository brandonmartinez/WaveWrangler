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
    private enum ChangedSelectedMapInput: CaseIterable {
        case sourceRecord, placement, speakerAssignment, recorderEpoch
        case acceptedAlignment, alignmentRevision, sourceDigest, formatVersion, recipe
    }

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
        let other = try base.renamingShow(to: "Other session's changes")
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(other, revision: 3), base: RevisionFingerprint(of: originalBytes),
            schemaVersion: SchemaVersion.show, for: key, at: Date(timeIntervalSince1970: 1_000)
        )
        try recovery.setAsideEditCheckpoints(for: key)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(unsaved, revision: 3), base: RevisionFingerprint(of: originalBytes),
            schemaVersion: SchemaVersion.show, for: key, at: Date(timeIntervalSince1970: 2_000)
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let offer = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originalBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        )
        let candidate = try #require(offer.candidate)
        #expect(candidate.relation == .basedOnCurrent)
        let otherCandidate = try #require(offer.usable.last)
        #expect(otherCandidate.payload == other && otherCandidate.relation == .basedOnCurrent)

        let reopenedDocument = ShowDocument()
        let reopened = ShowDocumentStore(model: try coder.decode(Data(contentsOf: disk)).payload)
        reopened.document = reopenedDocument
        let undo = try #require(reopenedDocument.undoManager)
        #expect(reopened.restoreEditCheckpoint(candidate.payload, basedOn: base))
        var restoredOffers = RestoredEditCheckpoints.State<ShowDocumentModel>()
        restoredOffers.mark(candidate.url, snapshot: reopened.model, generation: restoredOffers.currentGeneration)
        #expect(reopened.model == unsaved)
        #expect(try coder.decode(Data(contentsOf: disk)).payload == base)
        #expect(recovery.offeredEditCheckpoints(for: key).count == 2)

        undo.undo()
        restoredOffers.unmark(candidate.url, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) != nil)
        #expect(reopened.model.editMaps(for: fixture.mappedID)?.selectedRevision == nil)
        #expect(throws: EditMapPublicationError.invalidMap) {
            try reopened.selectedEditMap(in: fixture.mappedID)
        }
        #expect(recovery.offeredEditCheckpoints(for: key).count == 2)
        undo.redo()
        restoredOffers.mark(candidate.url, snapshot: reopened.model, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) == nil)
        #expect(reopened.model.editMaps.isEmpty)

        let saved = try coder.encode(reopened.model, revision: 3)
        try saved.write(to: disk)
        let resolved = restoredOffers.resolved(started: restoredOffers.startingSave(), published: reopened.model, current: reopened.model)
        try recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        restoredOffers.retire(candidate.url)
        #expect(recovery.offeredEditCheckpoints(for: key).count == 1)
        #expect(try coder.decode(Data(contentsOf: disk)).payload == unsaved)
        undo.undo()
        restoredOffers.unmark(candidate.url, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) != nil)
        undo.redo()
        restoredOffers.mark(candidate.url, snapshot: reopened.model, generation: restoredOffers.currentGeneration)
        #expect(reopened.model.episode(fixture.mappedID) == nil)
        #expect(restoredOffers.isEmpty)
        let remaining = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: saved), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).excluding(restoredOffers.urls)
        #expect(remaining.candidate?.url == otherCandidate.url)
        #expect(remaining.candidateMode(restoreInEffect: !restoredOffers.isEmpty) == .copyOnlyOlderRevision)
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

    @Test(arguments: [false, true])
    func saveAsOfRestoredCheckpointNeverResolvesOriginalOffer(autosaveEnabled: Bool) throws {
        let base = ShowDocumentModel.untitled(title: "Original")
        let restored = try base.renamingShow(to: "Restored")
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-restore-save-as-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = RecoveryStore(root: root.appending(path: "Recovery"))
        let origin = root.appending(path: "Original.wwshow")
        let destination = root.appending(path: "Saved As.wwshow")
        let originalBytes = try coder.encode(base, revision: 2)
        try originalBytes.write(to: origin)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(restored, revision: 3), base: RevisionFingerprint(of: originalBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let offered = try #require(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originalBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate)
        let document = ShowDocument()
        let store = ShowDocumentStore(model: base)
        store.document = document
        #expect(store.restoreEditCheckpoint(offered.payload, basedOn: base))
        var restores = RestoredEditCheckpoints.State<ShowDocumentModel>()
        restores.mark(offered.url, snapshot: store.model, generation: restores.currentGeneration)
        let saveStart = restores.startingSave()

        var copyGate = CopyElsewhereRetryGate()
        if autosaveEnabled {
            copyGate.begin(retryPending: true)
            #expect(!copyGate.allowsAutomaticSave, "a queued autosave must not publish the original during the copy panel")
        }
        let encoded = try coder.encodeDocument(restored, revision: 3, publicationID: UUID())
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        let receipt = try publisher.publish(
            encoded: encoded, key: key, to: destination, target: .saveAs(replacingExisting: true),
            retainPrior: false, isCancelled: { false }, step: .stagedReplace, followUp: .none
        )
        #expect(receipt.url == destination)
        #expect(try Data(contentsOf: origin) == originalBytes)
        #expect(try coder.decode(Data(contentsOf: destination)).payload == restored)
        let resolved = try restores.resolvedAfterVerifiedOriginSave(
            started: saveStart, published: restored, current: store.model, origin: origin,
            receipt: receipt, candidate: encoded, coder: coder, coordination: AlreadyCoordinated()
        )
        #expect(resolved.isEmpty, "Save As published only the destination, never the offered checkpoint's origin")
        try recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        let originAfterSave = try Data(contentsOf: origin)
        #expect(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originAfterSave), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate?.url == offered.url, "reopening the original must still offer its checkpoint")

        // Only a later, genuine in-place publication of the offered bytes at the origin may retire it.
        let originCandidate = try coder.encodeDocument(restored, revision: 3, publicationID: UUID())
        let originReceipt = try publisher.publish(
            encoded: originCandidate, key: key, to: origin, target: .inPlace(expectedBase: RevisionFingerprint(of: originalBytes)),
            retainPrior: true, isCancelled: { false }, step: .stagedReplace, followUp: .none
        )
        let publishedBytes = try Data(contentsOf: origin)
        try coder.encode(base, revision: 4).write(to: origin)
        #expect(throws: PublicationError.self) {
            try restores.resolvedAfterVerifiedOriginSave(
                started: saveStart, published: restored, current: store.model, origin: origin,
                receipt: originReceipt, candidate: originCandidate, coder: coder, coordination: AlreadyCoordinated()
            )
        }
        #expect(recovery.offeredEditCheckpoints(for: key).map(\.url) == [offered.url])
        try publishedBytes.write(to: origin)
        let originResolved = try restores.resolvedAfterVerifiedOriginSave(
            started: saveStart, published: restored, current: store.model, origin: origin,
            receipt: originReceipt, candidate: originCandidate, coder: coder, coordination: AlreadyCoordinated()
        )
        #expect(originResolved == [offered.url])
        try recovery.discardOfferedEditCheckpoints(Array(originResolved), for: key)
        #expect(try coder.decode(Data(contentsOf: origin)).payload == restored)
        #expect(recovery.offeredEditCheckpoints(for: key).isEmpty)
    }

    @Test func saveACopyWithQueuedRetryLeavesOriginAndOfferUntouched() throws {
        let base = ShowDocumentModel.untitled(title: "Original")
        let restored = try base.renamingShow(to: "Restored")
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-restore-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = RecoveryStore(root: root.appending(path: "Recovery"))
        let origin = root.appending(path: "Original.wwshow")
        let destination = root.appending(path: "Copy.wwshow")
        let originalBytes = try coder.encode(base, revision: 2)
        try originalBytes.write(to: origin)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(restored, revision: 3), base: RevisionFingerprint(of: originalBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let offer = try #require(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originalBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate)
        var restores = RestoredEditCheckpoints.State<ShowDocumentModel>()
        restores.mark(offer.url, snapshot: restored, generation: restores.currentGeneration)
        let saveStart = restores.startingSave()
        var gate = CopyElsewhereRetryGate()
        gate.begin(retryPending: true)
        #expect(!gate.allowsAutomaticSave)
        let retryRearmed = gate.end(copySaved: false)
        #expect(retryRearmed, "a cancelled or failed copy re-arms the old retry")
        #expect(recovery.offeredEditCheckpoints(for: key).map(\.url) == [offer.url])

        gate.begin(retryPending: true)
        let copy = restored.duplicatedAsNewShow()
        let encoded = try coder.encodeDocument(copy, revision: 1, publicationID: UUID())
        let receipt = try DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery).publish(
            encoded: encoded, key: .show(copy.show.id), to: destination, target: .saveAs(replacingExisting: true),
            retainPrior: false, isCancelled: { false }, step: .stagedReplace, followUp: .none
        )
        #expect(!gate.allowsAutomaticSave)
        #expect(try restores.resolvedAfterVerifiedOriginSave(
            started: saveStart, published: copy, current: copy, origin: origin,
            receipt: receipt, candidate: encoded, coder: coder, coordination: AlreadyCoordinated()
        ).isEmpty)
        let retryAfterCopy = gate.end(copySaved: true)
        #expect(!retryAfterCopy, "the window now edits the new show, not the original")
        #expect(try Data(contentsOf: origin) == originalBytes)
        #expect(try coder.decode(Data(contentsOf: destination)).payload == copy)
        #expect(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: originalBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate?.url == offer.url)
    }

    @Test func changedSourceAndAlignmentInputsWithEqualEditMapsRefuseExactCheckpoint() throws {
        let base = try savedPersistableShow().model
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-map-inputs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let baseBytes = try coder.encode(base, revision: 2)
        var changed = base
        changed.episodes[0].sources[0].role = .backup
        changed.episodes[0].alignment?.maps[0].inputs.sources[0].contentDigest = "different-input"
        #expect(changed.editMaps == base.editMaps)
        #expect(changed.validationIssues().isEmpty)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(changed, revision: 3), base: RevisionFingerprint(of: baseBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let candidate = try #require(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: baseBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate)
        let store = ShowDocumentStore(model: base)
        store.document = ShowDocument()
        #expect(!store.restoreEditCheckpoint(candidate.payload, basedOn: base))
        #expect(store.model == base)
        #expect(recovery.offeredEditCheckpoints(for: key).map(\.url) == [candidate.url])
        #expect(try coder.decode(candidate.record.snapshot).payload == changed)
    }

    @Test(arguments: ChangedSelectedMapInput.allCases)
    private func retainedSelectedMapRequiresEveryCanonicalInput(_ input: ChangedSelectedMapInput) throws {
        var base = try savedPersistableShow().model
        let speaker = Speaker(name: "Synthetic speaker")
        base.speakers = [speaker]
        base.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker.id,
                primary: ChannelReference(sourceID: base.episodes[0].sources[0].id, statedChannel: 0)
            )
        ]
        #expect(base.validationIssues().isEmpty)
        var changed = base
        switch input {
        case .sourceRecord:
            changed.episodes[0].sources[0].displayNameHint = "Different recording"
        case .placement:
            changed.episodes[0].sources[0].placement.channelLabels.append(ChannelLabel(channel: 0, label: "Mic"))
        case .speakerAssignment:
            changed.episodes[0].speakerAssignments[0].primaryConfirmation = .userConfirmed
        case .recorderEpoch:
            changed.episodes[0].recorderGroups[0].epochs[0].note = "Different epoch"
        case .acceptedAlignment:
            changed.episodes[0].alignment?.acceptedRevision = nil
        case .alignmentRevision:
            var next = try #require(changed.episodes[0].alignment?.maps[0])
            next.revision = 3
            next.derivedFrom = 2
            changed.episodes[0].alignment?.maps.append(next)
        case .sourceDigest:
            changed.episodes[0].alignment?.maps[0].inputs.sources[0].contentDigest = "new-digest"
        case .formatVersion:
            changed.episodes[0].alignment?.maps[0].inputs.sources[0].formatInterpretationVersion = 2
        case .recipe:
            changed.episodes[0].alignment?.maps[0].inputs.recipe = RecipeReference(name: "synthetic", revision: 2)
        }
        #expect(changed.editMaps == base.editMaps)
        #expect(changed.validationIssues().isEmpty, "\(input)")
        let store = ShowDocumentStore(model: base)
        store.document = ShowDocument()
        #expect(!store.restoreEditCheckpoint(changed, basedOn: base), "\(input)")
        #expect(store.lastEditMapError == .unauthorizedMutation, "\(input)")
        #expect(store.model == base, "\(input)")
    }

    @Test func saveAfterRefusedInputChangeCannotResolveDifferentPayload() throws {
        let base = try savedPersistableShow().model
        let key = DocumentKey.show(base.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let root = FileManager.default.temporaryDirectory.appending(path: "ww-map-refused-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = RecoveryStore(root: root)
        let disk = root.appending(path: "show.wwshow")
        let baseBytes = try coder.encode(base, revision: 2)
        try baseBytes.write(to: disk)
        var changed = base
        changed.episodes[0].alignment?.maps[0].inputs.sources[0].contentDigest = "different-input"
        #expect(changed.editMaps == base.editMaps)
        try recovery.writeEditCheckpoint(
            snapshot: coder.encode(changed, revision: 3), base: RevisionFingerprint(of: baseBytes),
            schemaVersion: SchemaVersion.show, for: key
        )
        try recovery.setAsideEditCheckpoints(for: key)
        let candidate = try #require(EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue,
            onDisk: RevisionFingerprint(of: baseBytes), coder: coder,
            belongsToDocument: { $0.show.id == base.show.id }
        ).candidate)
        let store = ShowDocumentStore(model: base)
        store.document = ShowDocument()
        var restores = RestoredEditCheckpoints.State<ShowDocumentModel>()
        let restored = store.restoreEditCheckpoint(candidate.payload, basedOn: base)
        if restored {
            restores.mark(candidate.url, snapshot: store.model, generation: restores.currentGeneration)
        }
        #expect(!restored)
        #expect(store.model == base)

        let started = restores.startingSave()
        let published = store.model
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        _ = try publisher.publish(
            published, revision: 3, key: key, to: disk,
            target: .inPlace(expectedBase: RevisionFingerprint(of: baseBytes))
        )
        #expect(try coder.decode(Data(contentsOf: disk)).payload == published)
        #expect(published != candidate.payload)
        let resolved = restores.resolved(started: started, published: published, current: store.model)
        try recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        #expect(resolved.isEmpty)
        #expect(recovery.offeredEditCheckpoints(for: key).map(\.url) == [candidate.url])
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
