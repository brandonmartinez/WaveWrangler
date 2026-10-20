import AppKit
import Foundation
import Testing
import WWCore
import WWOrganizer
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Episode-bound editors and Library management", .serialized)
struct EpisodeWindowTests {
    private func document(_ title: String = "Synthetic Show") -> ShowDocument {
        let document = ShowDocument()
        document.store.replaceLoadedModel(ShowDocumentModel(
            show: Show(title: title),
            episodes: [Episode(title: "First", number: 1), Episode(title: "Second", number: 2)]
        ))
        NSDocumentController.shared.addDocument(document)
        return document
    }

    @Test func editorIdentitySurvivesOtherSelectionAndDeletion() throws {
        let document = document()
        defer { document.close() }
        let first = document.store.model.episodes[0]
        let second = document.store.model.episodes[1]
        let state = ShowWindowState(store: document.store, episodeID: first.id)
        state.sidebarSelection = .episode(second.id)
        #expect(state.selectedEpisodeID == first.id)
        #expect(state.selectedEpisode?.title == "First")

        let original = document.store.model
        document.store.replaceLoadedModel(try original.removingEpisode(first.id))
        state.reconcileSelection(previousOrder: [first.id, second.id])
        #expect(state.selectedEpisodeID == first.id)
        #expect(state.selectedEpisode == nil)
        #expect(!state.canEdit)
        document.store.replaceLoadedModel(original)
        #expect(state.selectedEpisode?.id == first.id)
        #expect(state.canEdit)
    }

    @Test func multipleEpisodesAndShowsShareOnlyTheirOwnDocument() throws {
        let firstShow = document("One")
        let otherShow = document("Two")
        defer { firstShow.close(); otherShow.close() }
        let first = firstShow.store.model.episodes[0].id
        let second = firstShow.store.model.episodes[1].id
        let firstWindow = try #require(firstShow.openEpisode(first))
        let secondWindow = try #require(firstShow.openEpisode(second))
        let otherWindow = try #require(otherShow.openEpisode(otherShow.store.model.episodes[0].id))
        #expect(firstWindow !== secondWindow)
        #expect(firstWindow.state.store === secondWindow.state.store)
        #expect(firstWindow.state.store !== otherWindow.state.store)
        #expect(firstWindow.state.boundEpisodeID == first)
        #expect(secondWindow.state.boundEpisodeID == second)
        #expect(firstShow.openEpisode(first) === firstWindow)
        let duplicate = try #require(firstShow.openEpisode(first, inNewWindow: true))
        #expect(duplicate !== firstWindow)
        #expect(duplicate.state.boundEpisodeID == first)
        #expect(firstShow.openEpisode(EpisodeID()) == nil)
    }

    @Test func libraryLoadsLiveEpisodesWithoutOpeningAnEditorAndUsesShowUndo() async throws {
        let document = document()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let model = document.store.model
        let backend = InMemoryLibraryBackend(seed: LibraryModel(entries: [
            LibraryShowEntry(showID: model.show.id, lastKnownTitle: model.show.title)
        ]))
        let store = LibraryUIStore(services: LibraryServices(persistence: backend, entries: backend, location: backend))
        await store.load()
        let library = LibraryWindowState(store: store)
        library.entrySelection = [model.show.id]
        await library.loadSelectedShow()
        #expect(library.selectedShow === document)
        #expect(document.windowControllers.compactMap { $0 as? EpisodeWindowController }.isEmpty)
        let management = try #require(library.episodeManagementState)
        #expect(management.boundEpisodeID == nil)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        management.newEpisode()
        undo.endUndoGrouping()
        let added = try #require(management.selectedEpisode)
        #expect(document.store.model.episodes.count == 3)
        undo.beginUndoGrouping()
        let renamed = management.commitRename(added.id, to: "New title")
        undo.endUndoGrouping()
        #expect(renamed)
        library.focusedRegion = .episodes
        #expect(library.deleteTitle == "Delete Episode…")
        #expect(library.canMove(by: -1))
        undo.beginUndoGrouping()
        library.move(by: -1)
        undo.endUndoGrouping()
        #expect(document.store.model.episodes[1].id == added.id)
        document.undoManager?.undo()
        #expect(document.store.model.episodes[2].id == added.id)
        #expect(document.store.model.episode(added.id)?.title == "New title")
        document.undoManager?.undo()
        #expect(document.store.model.episode(added.id)?.title == added.title)
    }

    @Test func closingLastEpisodeEditorKeepsLibraryDocumentRegistered() async throws {
        let document = document()
        defer { document.close() }
        document.retainForLibrary(in: nil)
        let window = try #require(document.openEpisode(document.store.model.episodes[1].id))
        window.close()
        await Task.yield()
        #expect(NSDocumentController.shared.documents.contains { $0 === document })
        #expect(document.store.model.episodes.count == 2)
    }

    @Test func libraryResponderUndoFollowsTheFocusedShow() throws {
        let first = document("One")
        let second = document("Two")
        let controller = LibraryWindowController.shared
        defer {
            first.updateChangeCount(.changeCleared)
            second.updateChangeCount(.changeCleared)
            first.close()
            second.close()
        }
        let window = try #require(controller.window)
        controller.state.browse(first)
        controller.state.focusedRegion = .episodes
        #expect(window.undoManager === first.undoManager)
        #expect(window.contentViewController?.undoManager === first.undoManager)
        controller.state.focusedRegion = .entries
        #expect(window.undoManager !== first.undoManager)
        controller.state.browse(second)
        controller.state.focusedRegion = .episodes
        #expect(window.undoManager === second.undoManager)
        #expect(window.contentViewController?.undoManager === second.undoManager)
        let management = try #require(controller.state.episodeManagementState)
        let episode = second.store.model.episodes[0]
        let undo = try #require(second.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(management.commitRename(episode.id, to: "Renamed"))
        undo.endUndoGrouping()
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        #expect(window.validateMenuItem(undoItem))
        #expect(undoItem.title == "Undo Rename Episode")
        window.perform(Selector(("undo:")), with: nil)
        #expect(second.store.model.episode(episode.id)?.title == episode.title)
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        #expect(window.validateMenuItem(redoItem))
        #expect(redoItem.title == "Redo Rename Episode")
        window.perform(Selector(("redo:")), with: nil)
        #expect(second.store.model.episode(episode.id)?.title == "Renamed")
    }

    @Test func aCanceledBrowserRequestDoesNotDropAnotherRequestForTheSameShow() async throws {
        let document = document()
        defer { document.close() }
        let model = document.store.model
        let backend = InMemoryLibraryBackend(seed: LibraryModel(entries: [
            LibraryShowEntry(showID: model.show.id, lastKnownTitle: model.show.title)
        ]))
        let store = LibraryUIStore(services: LibraryServices(persistence: backend, entries: backend, location: backend))
        await store.load()
        let library = LibraryWindowState(store: store)
        library.entrySelection = [model.show.id]
        let canceled = Task { await library.loadSelectedShow() }
        canceled.cancel()
        let current = Task { await library.loadSelectedShow() }
        await canceled.value
        await current.value
        #expect(library.selectedShow === document)
        #expect(library.episodeManagementState?.store === document.store)
        #expect(!library.isLoadingShow)
    }

    @Test func restorationKeepsTheSavedEpisodeInsteadOfTheFirst() throws {
        let document = document()
        defer { document.close() }
        let second = document.store.model.episodes[1].id
        let original = EpisodeWindowController(store: document.store, episodeID: second)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        original.encodeRestorableState(with: coder)
        coder.finishEncoding()
        let restored = EpisodeWindowController(store: document.store, episodeID: document.store.model.episodes[0].id)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        restored.restoreState(with: decoder)
        decoder.finishDecoding()
        #expect(restored.state.boundEpisodeID == second)
        #expect(restored.state.selectedEpisode?.id == second)
    }
}
