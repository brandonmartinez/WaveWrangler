import AppKit
import Testing
import WWCore

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
}
