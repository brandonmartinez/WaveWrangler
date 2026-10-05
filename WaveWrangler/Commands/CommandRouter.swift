import AppKit
import WWCore
import WWOrganizer

/// Routes WaveWrangler menu commands to the key show window's or the Library window's state, and
/// validates them (enabled state and adaptive titles). Commands never move focus except where the spec
/// says so (⌘I, New Episode's inline rename).
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    static let shared = CommandRouter()

    // MARK: - Context

    var activeShowState: ShowWindowState? {
        ShowWindowRegistry.state(for: NSApp.keyWindow) ?? ShowWindowRegistry.state(for: NSApp.mainWindow)
    }

    /// The Library window's state when it is key (for Edit/View commands that act on the focused list).
    private var keyLibraryState: LibraryWindowState? {
        guard LibraryWindowController.isOpen, NSApp.keyWindow === LibraryWindowController.shared.window else { return nil }
        return LibraryWindowController.shared.state
    }

    /// File › Library items act on the Library window's selection whenever it is open.
    private var libraryState: LibraryWindowState? {
        LibraryWindowController.isOpen ? LibraryWindowController.shared.state : nil
    }

    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private var libraryEditable: Bool {
        LibraryStore.shared.services.location.libraryState.allowsEdits
    }

    // MARK: - App and window

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }
    @objc func showLibrary(_ sender: Any?) { LibraryWindowController.show() }

    // MARK: - File

    @objc func newShow(_ sender: Any?) { NewShowCommand.run() }

    @objc func openDocument(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }

    @objc func newEpisode(_ sender: Any?) { activeShowState?.newEpisode() }

    @objc func newWindowForShow(_ sender: Any?) {
        guard let document = activeShowState?.store.document else { return }
        Self.openNewWindow(for: document)
    }

    static func openNewWindow(for document: NSDocument) {
        let before = Set(document.windowControllers.map(ObjectIdentifier.init))
        document.makeWindowControllers()
        for controller in document.windowControllers where !before.contains(ObjectIdentifier(controller)) {
            controller.showWindow(nil)
        }
    }

    @objc func closeShow(_ sender: Any?) {
        guard let document = activeShowState?.store.document else { return }
        Self.closeAllWindows(of: document)
    }

    /// File › Close Show (⇧⌘W): closes every window of the show; the last one runs the native
    /// unsaved-changes decision, so nothing closes silently while dirty.
    static func closeAllWindows(of document: NSDocument) {
        let windows = document.windowControllers.compactMap(\.window)
        for window in windows.dropLast() { window.close() }
        windows.last?.performClose(nil)
    }

    @objc func importSources(_ sender: Any?) {
        guard let state = activeShowState, let episode = state.selectedEpisodeID else { return }
        SourceCommands.handler.importSources(store: state.store, episode: episode, window: state.window)
    }

    @objc func relinkSource(_ sender: Any?) {
        guard let state = activeShowState, let episode = state.selectedEpisodeID else { return }
        SourceCommands.handler.relinkSource(store: state.store, episode: episode, window: state.window)
    }

    @objc func showInFinder(_ sender: Any?) {
        if let url = activeShowState?.store.document?.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            keyLibraryState?.revealSelectedInFinder()
        }
    }

    // MARK: - File › Library

    @objc func libraryOpenShow(_ sender: Any?) { libraryState?.openSelected() }

    @objc func libraryOpenInNewWindow(_ sender: Any?) {
        guard let state = libraryState else { return }
        for row in state.selectedRows {
            if let open = Self.openDocument(for: row.showID) {
                Self.openNewWindow(for: open)
            } else {
                state.open(row.showID)
            }
        }
    }

    static func openDocument(for id: ShowID) -> ShowDocument? {
        NSDocumentController.shared.documents.compactMap { $0 as? ShowDocument }.first { $0.store.model.show.id == id }
    }

    @objc func newCollection(_ sender: Any?) {
        LibraryWindowController.show()
        LibraryWindowController.shared.state.newCollection()
    }

    @objc func newCollectionWithSelection(_ sender: Any?) {
        guard let state = libraryState else { return }
        state.newCollection(adding: Array(state.entrySelection))
    }

    @objc func renameCollection(_ sender: Any?) {
        guard let state = libraryState, let id = state.selectedCollectionID else { return }
        state.renameCollection(id)
    }

    @objc func deleteCollection(_ sender: Any?) {
        guard let state = libraryState, let id = state.selectedCollectionID else { return }
        state.deleteCollection(id)
    }

    @objc func addToCollection(_ sender: Any?) {
        guard let state = libraryState,
              let uuid = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        state.addShows(Array(state.entrySelection), to: CollectionID(uuid))
    }

    @objc func removeFromCollection(_ sender: Any?) { libraryState?.removeSelectedShowsFromCollection() }
    @objc func removeFromLibrary(_ sender: Any?) { libraryState?.removeSelectedShowsFromLibrary() }

    @objc func locateShow(_ sender: Any?) { performRemedy(.locate) }
    @objc func grantAccess(_ sender: Any?) { performRemedy(.grantAccess) }
    @objc func tryAgain(_ sender: Any?) { performRemedy(.tryAgain) }

    private func performRemedy(_ remedy: LibraryRemedy) {
        guard let state = libraryState, let row = state.selectedRows.first else { return }
        state.perform(remedy, for: row.showID)
    }

    @objc func rebuildLibraryIndex(_ sender: Any?) {
        LibraryWindowController.show()
        LibraryWindowController.shared.state.rebuildIndex()
    }

    // MARK: - Edit

    @objc func deleteSelection(_ sender: Any?) {
        if let state = keyLibraryState {
            state.deleteFocused()
        } else {
            activeShowState?.deleteSelectedEpisode()
        }
    }

    @objc func moveUp(_ sender: Any?) { move(by: -1) }
    @objc func moveDown(_ sender: Any?) { move(by: 1) }

    private func move(by offset: Int) {
        if let state = keyLibraryState {
            state.move(by: offset)
        } else {
            activeShowState?.moveSelectedEpisode(by: offset)
        }
    }

    // MARK: - View

    @objc func toggleWWSidebar(_ sender: Any?) {
        if let state = keyLibraryState {
            state.toggleSidebar()
        } else {
            activeShowState?.toggleSidebar()
        }
    }

    @objc func toggleInspector(_ sender: Any?) { activeShowState?.toggleInspector() }
    @objc func showSaveStatus(_ sender: Any?) { activeShowState?.showSaveStatus() }

    @objc func selectDestination(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, ShowDestination.allCases.indices.contains(tag) else { return }
        activeShowState?.select(ShowDestination.allCases[tag])
    }

    @objc func textBigger(_ sender: Any?) { AppSettings.shared.makeTextBigger() }
    @objc func textSmaller(_ sender: Any?) { AppSettings.shared.makeTextSmaller() }
    @objc func textActualSize(_ sender: Any?) { AppSettings.shared.resetTextSize() }

    // MARK: - Episode

    @objc func episodeInfo(_ sender: Any?) { activeShowState?.showEpisodeInfo() }
    @objc func renameEpisode(_ sender: Any?) { activeShowState?.renameSelectedEpisode() }
    @objc func deleteEpisode(_ sender: Any?) { activeShowState?.deleteSelectedEpisode() }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let show = activeShowState
        let library = libraryState
        let keyLibrary = keyLibraryState
        let selection = library?.selectedRows ?? []
        switch item.action {
        case #selector(showSettings(_:)), #selector(showLibrary(_:)), #selector(newShow(_:)), #selector(openDocument(_:)),
             #selector(textActualSize(_:)), #selector(rebuildLibraryIndex(_:)):
            if item.action == #selector(textActualSize(_:)) { return AppSettings.shared.textSize != .actual }
            return true
        case #selector(newCollection(_:)):
            return libraryEditable
        case #selector(textBigger(_:)):
            return AppSettings.shared.textSize.bigger != nil
        case #selector(textSmaller(_:)):
            return AppSettings.shared.textSize.smaller != nil
        case #selector(newEpisode(_:)):
            return show?.canEdit == true
        case #selector(newWindowForShow(_:)):
            if let title = show?.store.model.show.title {
                item.title = "New Window for “\(title)”"
                return true
            }
            item.title = "New Window"
            return false
        case #selector(closeShow(_:)):
            return show != nil
        case #selector(importSources(_:)):
            guard let show, show.canEdit, let episode = show.selectedEpisodeID else { return false }
            return SourceCommands.handler.canImportSources(store: show.store, episode: episode)
        case #selector(relinkSource(_:)):
            guard let show, show.canEdit, let episode = show.selectedEpisodeID else { return false }
            return SourceCommands.handler.canRelinkSource(store: show.store, episode: episode)
        case #selector(showInFinder(_:)):
            if let show { return show.store.document?.fileURL != nil }
            return keyLibrary?.selectedRows.isEmpty == false
        case #selector(libraryOpenShow(_:)), #selector(libraryOpenInNewWindow(_:)):
            return !selection.isEmpty
        case #selector(newCollectionWithSelection(_:)):
            return libraryEditable && !selection.isEmpty
        case #selector(renameCollection(_:)), #selector(deleteCollection(_:)):
            return libraryEditable && library?.selectedCollectionID != nil
        case #selector(addToCollection(_:)):
            return libraryEditable && !selection.isEmpty
        case #selector(removeFromCollection(_:)):
            return libraryEditable && library?.selectedCollectionID != nil && !selection.isEmpty
        case #selector(removeFromLibrary(_:)):
            return libraryEditable && !selection.isEmpty
        case #selector(locateShow(_:)):
            return selection.count == 1 && selection[0].status.remedies.contains(.locate)
        case #selector(grantAccess(_:)):
            return selection.count == 1 && selection[0].status.remedies.contains(.grantAccess)
        case #selector(tryAgain(_:)):
            return selection.count == 1 && selection[0].status.remedies.contains(.tryAgain)
        case #selector(deleteSelection(_:)):
            if isEditingText { return false }
            if let keyLibrary {
                item.title = keyLibrary.deleteTitle ?? "Delete"
                return libraryEditable && keyLibrary.deleteTitle != nil
            }
            item.title = show?.selectedEpisodeID != nil ? "Delete Episode…" : "Delete"
            return show?.canEdit == true && show?.selectedEpisodeID != nil
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let offset = item.action == #selector(moveUp(_:)) ? -1 : 1
            let direction = offset < 0 ? "Up" : "Down"
            if let keyLibrary {
                let noun = keyLibrary.moveNoun
                item.title = noun.isEmpty ? "Move \(direction)" : "Move \(noun) \(direction)"
                return libraryEditable && keyLibrary.canMove(by: offset)
            }
            if let show, show.selectedEpisodeID != nil {
                item.title = "Move Episode \(direction)"
                return show.canMoveSelectedEpisode(by: offset)
            }
            item.title = "Move \(direction)"
            return false
        case #selector(toggleWWSidebar(_:)):
            if let keyLibrary {
                item.title = keyLibrary.isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
                return true
            }
            item.title = show?.isSidebarShown == false ? "Show Sidebar" : "Hide Sidebar"
            return show != nil
        case #selector(toggleInspector(_:)):
            item.title = show?.inspectorPresented == false ? "Show Inspector" : "Hide Inspector"
            return show != nil
        case #selector(showSaveStatus(_:)):
            return show != nil
        case #selector(selectDestination(_:)):
            item.state = show?.destination == ShowDestination.allCases[safe: item.tag] ? .on : .off
            return show != nil
        case #selector(episodeInfo(_:)):
            return show.map { !$0.store.model.episodes.isEmpty } ?? false
        case #selector(renameEpisode(_:)), #selector(deleteEpisode(_:)):
            return show?.canEdit == true && show?.selectedEpisodeID != nil
        default:
            return true
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
