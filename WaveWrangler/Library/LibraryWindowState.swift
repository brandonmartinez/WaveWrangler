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
    }

    var sidebarSelection: LibrarySidebarItem? = .shows {
        didSet { if oldValue != sidebarSelection { entrySelection = [] } }
    }

    var entrySelection: Set<ShowID> = []
    var focusedRegion: Region?
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// Inline outcome of the last open/locate attempt, shown in the detail column.
    var actionMessage: String?

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
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button) else { return }
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
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button) else { return }
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
        switch moveTarget {
        case .collection: "Collection"
        case .showInCollection: "Show"
        case nil: ""
        }
    }

    func canMove(by offset: Int) -> Bool {
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
        if focusedRegion == .entries, !entrySelection.isEmpty {
            return selectedCollectionID == nil ? "Remove from Library…" : "Remove from Collection"
        }
        if focusedRegion != .entries, selectedCollectionID != nil {
            return "Delete Collection…"
        }
        return nil
    }

    func deleteFocused() {
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
        Task {
            do {
                actionMessage = nil
                try await store.services.entries.openShow(id, readOnly: readOnly)
            } catch {
                actionMessage = error.localizedDescription
            }
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
                await store.libraryWasReplaced()
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
            if case .failed(let reason) = await store.services.location.useOfferedLibrary() {
                actionMessage = "Couldn't use that library: \(reason)"
            }
            await store.libraryWasReplaced()
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
