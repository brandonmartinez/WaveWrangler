import AppKit
import Observation
import SwiftUI
import WWCore
import WWOrganizer

/// Per-window state and commands for the Library window. Menu commands route here (CMD-01) so every
/// toolbar, context-menu and drag action also has a menu/keyboard path.
@MainActor
@Observable
final class LibraryWindowState {
    enum Region: Hashable {
        case sidebar
        case entries
        case episodes
    }

    var sidebarSelection: LibrarySidebarItem? = .shows {
        didSet {
            if oldValue != sidebarSelection {
                entrySelection = []
                Responsiveness.interaction("library.sidebarSelection")
            }
        }
    }

    var entrySelection: Set<ShowID> = [] {
        didSet {
            guard oldValue != entrySelection else { return }
            if selectedShow.map({ entrySelection != [$0.store.model.show.id] }) == true {
                selectedShow = nil
                episodeManagementState = nil
            }
            actionMessage = nil
            isLoadingShow = false
        }
    }
    private(set) var selectedShow: ShowDocument?
    private(set) var episodeManagementState: ShowWindowState?
    private(set) var isLoadingShow = false
    @ObservationIgnored private var loadingShowID: ShowID?
    @ObservationIgnored private var loadingShowTask: Task<ShowDocument, Error>?
    @ObservationIgnored private var loadingShowToken = UUID()
    var focusedRegion: Region?
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// Inline outcome of the last open/locate attempt, shown in the detail column.
    var actionMessage: String?
    /// The in-memory library notice was dismissed (window state, so every layout of the message bar agrees).
    var inMemoryNoticeDismissed = false

    @ObservationIgnored weak var window: NSWindow?
    let store: LibraryUIStore

    init(store: LibraryUIStore) {
        self.store = store
    }

    var selectedCollectionID: CollectionID? { sidebarSelection?.collectionID }

    var selectedRows: [LibraryEntryRow] {
        guard let item = sidebarSelection else { return [] }
        return store.rows(for: item).filter { entrySelection.contains($0.showID) }
    }

    var isSidebarShown: Bool { columnVisibility != .doubleColumn && columnVisibility != .detailOnly }

    func toggleSidebar() {
        columnVisibility = isSidebarShown ? .doubleColumn : .all
    }

    // MARK: - Collections

    func newCollection(adding shows: [ShowID] = []) {
        Task {
            guard let name = await Dialogs.askForName(
                in: window, title: "New Collection", fieldLabel: "Collection name", confirmTitle: "Create"
            ) else { return }
            let collection = LibraryCollection(name: name)
            let created = store.apply(UndoActionName.newCollection) { library throws(LibraryError) in
                try library.addingCollection(collection)
            }
            if created, !shows.isEmpty {
                store.apply(UndoActionName.addToCollection) { library throws(LibraryError) in
                    try library.addingShows(shows, toCollection: collection.id)
                }
            } else if created {
                sidebarSelection = .collection(collection.id)
            }
            if !created { await reportRefusal() }
        }
    }

    func renameCollection(_ id: CollectionID) {
        guard let collection = store.library.collection(id) else { return }
        Task {
            guard let name = await Dialogs.askForName(
                in: window, title: "Rename Collection", fieldLabel: "Collection name", initial: collection.name, confirmTitle: "Rename"
            ) else { return }
            if !store.apply(UndoActionName.renameCollection, { library throws(LibraryError) in try library.renamingCollection(id, to: name) }) {
                await reportRefusal()
            }
        }
    }

    func deleteCollection(_ id: CollectionID) {
        guard let collection = store.library.collection(id) else { return }
        let wording = ConfirmationWording.deleteCollection(collection.name)
        Task {
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button,
                                        destructiveIsDefault: true) else { return }
            let index = store.library.collections.firstIndex { $0.id == id }
            if store.apply(UndoActionName.deleteCollection, { library throws(LibraryError) in try library.deletingCollection(id) }) {
                // Selection moves to the next collection (or the previous at the end), else Shows.
                let remaining = store.library.collections
                if let index, !remaining.isEmpty {
                    sidebarSelection = .collection(remaining[min(index, remaining.count - 1)].id)
                } else {
                    sidebarSelection = .shows
                }
            }
        }
    }

    func addShows(_ ids: [ShowID], to collectionID: CollectionID) {
        store.apply(UndoActionName.addToCollection) { library throws(LibraryError) in
            try library.addingShows(ids, toCollection: collectionID)
        }
    }

    func removeSelectedShowsFromCollection() {
        guard let collectionID = selectedCollectionID, !entrySelection.isEmpty else { return }
        let ids = Array(entrySelection)
        let rows = store.rows(for: .collection(collectionID))
        let next = nextSelection(after: Set(ids), in: rows.map(\.showID))
        if store.apply(UndoActionName.removeFromCollection, { library throws(LibraryError) in
            try library.removingShows(ids, fromCollection: collectionID)
        }) {
            entrySelection = next.map { [$0] } ?? []
        }
    }

    func removeSelectedShowsFromLibrary() {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        let wording = ConfirmationWording.removeFromLibrary(rows.map(\.name))
        let all = sidebarSelection.map { store.rows(for: $0).map(\.showID) } ?? []
        Task {
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button,
                                        destructiveIsDefault: true) else { return }
            let ids = rows.map(\.showID)
            let next = nextSelection(after: Set(ids), in: all)
            if store.apply(UndoActionName.removeFromLibrary, { library throws(LibraryError) in try library.removingEntries(ids) }) {
                entrySelection = next.map { [$0] } ?? []
            }
        }
    }

    private func nextSelection(after removed: Set<ShowID>, in order: [ShowID]) -> ShowID? {
        guard let lastIndex = order.lastIndex(where: { removed.contains($0) }) else { return nil }
        if let after = order[(lastIndex + 1)...].first(where: { !removed.contains($0) }) { return after }
        return order[..<lastIndex].last { !removed.contains($0) }
    }

    // MARK: - Move Up / Move Down (⌥⌘↑ / ⌥⌘↓)

    enum MoveTarget {
        case collection(CollectionID)
        case showInCollection(ShowID, CollectionID)
    }

    var moveTarget: MoveTarget? {
        if focusedRegion == .entries, let collectionID = selectedCollectionID, entrySelection.count == 1, let show = entrySelection.first {
            return .showInCollection(show, collectionID)
        }
        if let collectionID = selectedCollectionID, focusedRegion != .entries {
            return .collection(collectionID)
        }
        return nil
    }

    var moveNoun: String {
        if focusedRegion == .episodes { return "Episode" }
        return switch moveTarget {
        case .collection: "Collection"
        case .showInCollection: "Show"
        case nil: ""
        }
    }

    func canMove(by offset: Int) -> Bool {
        if focusedRegion == .episodes { return episodeManagementState?.canMoveSelectedEpisode(by: offset) == true }
        switch moveTarget {
        case .collection(let id):
            return store.library.canMoveCollection(id, by: offset)
        case .showInCollection(let show, let collection):
            guard let ids = store.library.collection(collection)?.showIDs, let index = ids.firstIndex(of: show) else { return false }
            return ids.indices.contains(index + offset)
        case nil:
            return false
        }
    }

    func move(by offset: Int) {
        guard canMove(by: offset) else { return }
        if focusedRegion == .episodes {
            episodeManagementState?.moveSelectedEpisode(by: offset)
            return
        }
        switch moveTarget {
        case .collection(let id):
            store.apply(UndoActionName.moveCollection, moving: .init(collections: [id])) { library throws(LibraryError) in
                try library.movingCollection(id, by: offset)
            }
        case .showInCollection(let show, let collection):
            store.apply(UndoActionName.moveCollection, moving: .init(shows: [collection: [show]])) { library throws(LibraryError) in
                try library.movingShow(show, inCollection: collection, by: offset)
            }
        case nil:
            break
        }
    }

    func moveCollections(fromOffsets source: IndexSet, toOffset destination: Int) {
        let movedIDs = Set(source.compactMap { store.library.collections[safe: $0]?.id })
        store.apply(UndoActionName.moveCollection, moving: .init(collections: movedIDs)) { library throws(LibraryError) in
            library.movingCollections(fromOffsets: source, toOffset: destination)
        }
    }

    // MARK: - Delete (⌫) acts on the focused list

    var deleteTitle: String? {
        if focusedRegion == .episodes {
            return episodeManagementState?.selectedEpisode == nil ? nil : "Delete Episode…"
        }
        if focusedRegion == .entries, !entrySelection.isEmpty {
            return selectedCollectionID == nil ? "Remove from Library…" : "Remove from Collection"
        }
        if focusedRegion != .entries, selectedCollectionID != nil {
            return "Delete Collection…"
        }
        return nil
    }

    func deleteFocused() {
        if focusedRegion == .episodes {
            episodeManagementState?.deleteSelectedEpisode()
            return
        }
        if focusedRegion == .entries, !entrySelection.isEmpty {
            if selectedCollectionID == nil { removeSelectedShowsFromLibrary() } else { removeSelectedShowsFromCollection() }
        } else if let id = selectedCollectionID {
            deleteCollection(id)
        }
    }

    // MARK: - Open and remedies

    func openSelected(readOnly: Bool = false) {
        for row in selectedRows { open(row.showID, readOnly: readOnly) }
    }

    func open(_ id: ShowID, readOnly: Bool = false) {
        entrySelection = [id]
        Task {
            await loadSelectedShow(readOnly: readOnly)
        }
    }

    func loadSelectedShow(readOnly: Bool = false) async {
        guard entrySelection.count == 1, let id = entrySelection.first,
              selectedShow?.store.model.show.id != id else { return }
        let task: Task<ShowDocument, Error>
        if loadingShowID == id, let pending = loadingShowTask {
            task = pending
        } else {
            loadingShowID = id
            loadingShowToken = UUID()
            let entries = store.services.entries
            task = Task { try await entries.openShow(id, readOnly: readOnly, display: false) }
            loadingShowTask = task
        }
        let token = loadingShowToken
        isLoadingShow = true
        actionMessage = nil
        defer {
            if loadingShowToken == token {
                loadingShowID = nil
                loadingShowTask = nil
                isLoadingShow = false
            }
        }
        do {
            let document = try await task.value
            guard !Task.isCancelled, entrySelection == [id] else { return }
            browse(document)
        } catch {
            if !Task.isCancelled, entrySelection == [id] { actionMessage = error.localizedDescription }
        }
    }

    func browse(_ document: ShowDocument) {
        let model = document.store.model
        document.retainForLibrary(in: window)
        store.showDidOpen(id: model.show.id, model: model, fileURL: document.fileURL, hasUnsavedChanges: document.isDocumentEdited)
        entrySelection = [model.show.id]
        selectedShow = document
        if episodeManagementState?.store !== document.store {
            let state = ShowWindowState(store: document.store)
            state.attachForLibrary(to: window)
            episodeManagementState = state
        }
        isLoadingShow = false
        document.windowDidAttach()
        document.presentFormatUpdatePromptIfNeeded(preferring: window)
    }

    func documentDidClose(_ document: ShowDocument) {
        guard selectedShow === document else { return }
        selectedShow = nil
        episodeManagementState = nil
        actionMessage = "The show was closed. Open it again to manage its episodes."
    }

    func openSelectedEpisode(inNewWindow: Bool = false) {
        guard let state = episodeManagementState, let id = state.selectedEpisode?.id else { return }
        openEpisode(id, inNewWindow: inNewWindow)
    }

    func openEpisode(_ id: EpisodeID, inNewWindow: Bool = false) {
        guard let document = selectedShow else { return }
        guard document.openEpisode(id, inNewWindow: inNewWindow) != nil else {
            actionMessage = "That episode is no longer in the show."
            return
        }
    }

    func perform(_ remedy: LibraryRemedy, for id: ShowID) {
        switch remedy {
        case .openShow: open(id)
        case .openReadOnly: open(id, readOnly: true)
        case .removeFromLibrary:
            entrySelection = [id]
            removeSelectedShowsFromLibrary()
        case .locate, .grantAccess:
            Task {
                do {
                    actionMessage = nil
                    try await store.services.entries.locateShow(id)
                } catch {
                    actionMessage = error.localizedDescription
                }
            }
        case .tryAgain:
            Task { await store.services.entries.refresh([id]) }
        case .revertTo:
            open(id, readOnly: true)
        case .showInFinder:
            if !store.services.entries.revealShowInFinder(id) {
                actionMessage = LibraryBackendError.showLocationUnknown.localizedDescription
            }
        }
    }

    func revealSelectedInFinder() {
        for row in selectedRows where !store.services.entries.revealShowInFinder(row.showID) {
            actionMessage = LibraryBackendError.showLocationUnknown.localizedDescription
        }
    }

    func perform(_ action: LibraryLevelAction) {
        if action == .librarySettings {
            SettingsWindowController.show(pane: .general)
            return
        }
        Task {
            let followUp = await store.services.location.perform(action)
            switch action {
            case .combine, .useOtherMacsVersion, .recoverEarlierVersion, .grantAccess, .tryAgain:
                await store.libraryWasReplaced(published: store.services.location.lastActionPublished)
            case .librarySettings:
                break
            }
            if case .offerDifferentLibrary(let folder) = followUp {
                await offerDifferentLibrary(folderDisplayName: folder)
            }
        }
    }

    /// Grant Access… chose a folder with a different library: Use That Library · Choose Another Folder… ·
    /// Cancel, no default button. Nothing has changed until the user chooses.
    private func offerDifferentLibrary(folderDisplayName: String) async {
        let wording = LibraryRegrantWording.differentLibrarySheet(folderDisplayName: folderDisplayName)
        let alert = NSAlert()
        alert.messageText = wording.title
        alert.informativeText = wording.text
        alert.addButton(withTitle: "Use That Library").keyEquivalent = ""
        alert.addButton(withTitle: "Choose Another Folder…").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:
            var used = true
            if case .failed(let reason) = await store.services.location.useOfferedLibrary() {
                actionMessage = "Couldn't use that library: \(reason)"
                used = false
            }
            await store.libraryWasReplaced(published: used)
        case .alertSecondButtonReturn:
            perform(.grantAccess)
        default:
            break
        }
    }

    func rebuildIndex() {
        Task { await store.services.entries.refresh(store.library.entries.map(\.showID)) }
    }

    private func reportRefusal() async {
        guard let message = store.lastError else { return }
        await Dialogs.inform(in: window, message: "The change wasn't made", informative: message)
    }
}
