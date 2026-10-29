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
    @MainActor private final class RestorationResult {
        var window: NSWindow?
        var error: (any Error)?
        var invoked = false
    }

    private func restore(
        _ document: ShowDocument, identifier: NSUserInterfaceItemIdentifier, decoder: NSCoder
    ) throws -> NSWindow? {
        let result = RestorationResult()
        document.restoreWindow(withIdentifier: identifier, state: decoder) { window, error in
            MainActor.assumeIsolated {
                result.window = window
                result.error = error
                result.invoked = true
            }
        }
        try #require(result.invoked)
        if let error = result.error { throw error }
        return result.window
    }

    private func document(_ title: String = "Synthetic Show") -> ShowDocument {
        let document = ShowDocument()
        document.store.replaceLoadedModel(ShowDocumentModel(
            show: Show(title: title),
            episodes: [Episode(title: "First", number: 1), Episode(title: "Second", number: 2)]
        ))
        NSDocumentController.shared.addDocument(document)
        return document
    }

    @Test func buildIdentityIsVisibleAndSurvivesDocumentAndSettingsTitleChanges() async throws {
        let identity = AppBuildIdentity.current
        let number = try #require(identity.buildNumber)
        #expect(number.range(of: "^[0-9]{17}$", options: .regularExpression) != nil)
        #expect(identity.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let document = document()
        defer { document.close() }
        let episode = document.store.model.episodes[0]
        let controller = try #require(document.openEpisode(episode.id))
        let window = try #require(controller.window)
        let deadline = Date().addingTimeInterval(5)
        while controller.state.window == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.state.window === window)
        controller.synchronizeWindowTitleWithDocumentName()
        #expect(window.title == ShowSidebarPresentation.episodeRowTitle(episode))
        #expect(window.subtitle == identity.subtitle(context: "Synthetic Show"))
        document.store.replaceLoadedModel(try document.store.model.renamingShow(to: "Renamed Show"))
        controller.synchronizeWindowTitleWithDocumentName()
        #expect(window.subtitle == identity.subtitle(context: "Renamed Show"))
        #expect(LibraryWindowController.shared.window?.subtitle == identity.label)
        SettingsWindowController.show(pane: .general)
        let settings = try #require(NSApp.windows.first { $0.accessibilityIdentifier() == "ww.settings.window" })
        defer { settings.close() }
        #expect(settings.subtitle == identity.label)
        SettingsWindowController.show(pane: .sources)
        #expect(settings.title == SettingsPane.sources.title)
        #expect(settings.subtitle == identity.label)
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

    @Test func aRemovedArchivedEpisodeCannotReplaceAValidEditor() throws {
        let document = document()
        defer { document.close() }
        let first = document.store.model.episodes[0].id
        let removed = document.store.model.episodes[1].id
        let archived = EpisodeWindowController(store: document.store, episodeID: removed)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        archived.encodeRestorableState(with: coder)
        coder.finishEncoding()
        document.store.replaceLoadedModel(try document.store.model.removingEpisode(removed))
        let restored = EpisodeWindowController(store: document.store, episodeID: first)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        restored.restoreState(with: decoder)
        decoder.finishDecoding()
        #expect(restored.state.boundEpisodeID == first)
        #expect(restored.state.selectedEpisode?.id == first)
        #expect(restored.state.canEdit)
    }

    @Test func restorationDoesNotUseAnotherShowsEpisodeEvenWhenItsIDExistsHere() throws {
        let firstShow = document("First show")
        let secondShow = document("Second show")
        defer { firstShow.close(); secondShow.close() }
        let foreign = firstShow.store.model.episodes[1]
        var target = secondShow.store.model
        target.episodes[1] = foreign
        secondShow.store.replaceLoadedModel(target)
        let first = target.episodes[0].id
        let archived = EpisodeWindowController(store: firstShow.store, episodeID: foreign.id)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        archived.encodeRestorableState(with: coder)
        coder.finishEncoding()
        let restored = EpisodeWindowController(store: secondShow.store, episodeID: first)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        restored.restoreState(with: decoder)
        decoder.finishDecoding()
        #expect(restored.state.boundEpisodeID == first)
        #expect(restored.state.selectedEpisode?.id == first)
    }

    @Test func episodeWindowsHaveDistinctRestorationIdentitiesIncludingDuplicateViews() throws {
        let document = document()
        defer { document.close() }
        let first = try #require(document.openEpisode(document.store.model.episodes[0].id))
        let second = try #require(document.openEpisode(document.store.model.episodes[1].id))
        let duplicate = try #require(document.openEpisode(document.store.model.episodes[0].id, inNewWindow: true))
        let identifiers = try [first, second, duplicate].map { try #require($0.window?.identifier) }
        #expect(Set(identifiers).count == 3)
    }

    @Test func documentRestorationCreatesTheRequestedEpisodesAndDuplicateViewsIndependently() async throws {
        let original = document()
        let reopened = ShowDocument()
        defer { original.close(); reopened.close() }
        let model = original.store.model
        reopened.store.replaceLoadedModel(model)
        let first = try #require(original.openEpisode(model.episodes[0].id))
        let second = try #require(original.openEpisode(model.episodes[1].id))
        let duplicate = try #require(original.openEpisode(model.episodes[1].id, inNewWindow: true))
        var windows: [NSWindow] = []
        for controller in [second, first, duplicate] {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            controller.encodeRestorableState(with: coder)
            coder.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
            let identifier = try #require(controller.window?.identifier)
            let result = try restore(reopened, identifier: identifier, decoder: decoder)
            let restored = try #require(result)
            let restoredController = try #require(restored.windowController as? EpisodeWindowController)
            restoredController.restoreState(with: decoder)
            decoder.finishDecoding()
            #expect(restoredController.state.boundEpisodeID == controller.state.boundEpisodeID)
            #expect(restoredController.state.selectedEpisode != nil)
            restored.orderFront(nil)
            windows.append(restored)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(Set(windows.map(ObjectIdentifier.init)).count == 3)
        #expect(reopened.store.model == model)
        for window in windows {
            let state = try #require((window.windowController as? EpisodeWindowController)?.state)
            #expect(ShowWindowRegistry.state(for: window) === state)
            #expect(!window.title.contains("Unavailable"))
        }
    }

    @Test func legacyRestorationChecksMembershipAndTrackEditsKeepTheBoundEpisodeThroughUndoRedo() async throws {
        let document = document()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let episode = document.store.model.episodes[1].id
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode(episode.description, forKey: "ww.episodeID")
        coder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        let result = try restore(document, identifier: .init("legacy-window"), decoder: decoder)
        let restored = try #require(result)
        let controller = try #require(restored.windowController as? EpisodeWindowController)
        controller.restoreState(with: decoder)
        decoder.finishDecoding()
        controller.state.select(.setup)
        restored.orderFront(nil)
        let undo = try #require(document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        let source = SourceRecord(displayNameHint: "Synthetic track.wav")
        let added = document.store.apply("Add synthetic track") { model throws(DomainError) in
            try model.addingSource(source, to: episode)
        }
        undo.endUndoGrouping()
        try #require(added)
        for operation in [0, 1, 2] {
            if operation == 1 { undo.undo() }
            if operation == 2 { undo.redo() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.state.boundEpisodeID == episode)
            #expect(controller.state.selectedEpisode?.id == episode)
            #expect(controller.state.selectedEpisode?.sources.count == (operation == 1 ? 0 : 1))
            #expect(ShowWindowRegistry.state(for: restored) === controller.state)
            #expect(!restored.title.contains("Unavailable"))
        }
    }

    @Test func missingOrForeignEpisodeArchivesDoNotCreateDocumentWindows() throws {
        let document = document()
        let foreign = self.document("Foreign")
        defer { document.close(); foreign.close() }
        let missing = EpisodeWindowController(store: document.store, episodeID: EpisodeID())
        let otherShow = EpisodeWindowController(store: foreign.store, episodeID: foreign.store.model.episodes[0].id)
        let original = document.store.model
        for controller in [missing, otherShow] {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            controller.encodeRestorableState(with: coder)
            coder.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
            let identifier = try #require(controller.window?.identifier)
            #expect(try restore(document, identifier: identifier, decoder: decoder) == nil)
            decoder.finishDecoding()
        }
        #expect(document.windowControllers.isEmpty)
        #expect(document.store.model == original)
    }
}
