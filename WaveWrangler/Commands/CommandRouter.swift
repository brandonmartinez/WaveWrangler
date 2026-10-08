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

    /// Text-like responders keep ⌫ and arrows for themselves (CMD-06), including date pickers.
    private var isEditingText: Bool {
        Self.isTextLike(NSApp.keyWindow?.firstResponder)
    }

    static func isTextLike(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return responder is NSText || responder is NSTextField || responder is NSDatePicker
            || responder is NSComboBox || responder is NSTokenField || responder is NSStepper
    }

    /// The show window's episode list is the focused list (and no text-like control has focus).
    private func episodeListActive(_ show: ShowWindowState?) -> Bool {
        guard let show, show.episodeListFocused, show.selectedEpisodeID != nil else { return false }
        return !isEditingText
    }

    private var libraryEditable: Bool {
        LibraryUIStore.shared.services.location.libraryState.allowsEdits
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
        let existingWindows = document.windowControllers.compactMap(\.window)
        let before = Set(document.windowControllers.map(ObjectIdentifier.init))
        document.makeWindowControllers()
        for controller in document.windowControllers where !before.contains(ObjectIdentifier(controller)) {
            // IA-02: File › New Window opens another window, not a tab.
            controller.window?.tabbingMode = .disallowed
            controller.showWindow(nil)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "WWUITestOffsetNewWindows"),
               let window = controller.window, let original = existingWindows.last,
               let visible = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame {
                var frame = window.frame
                frame.origin.x = min(max(visible.minX, original.frame.origin.x + 48), visible.maxX - frame.width)
                frame.origin.y = min(max(visible.minY, original.frame.origin.y - 48), visible.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
            #endif
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

    /// File › Save (⌘S). Always available for a writable show, also with Autosave On (ST-14 disables it
    /// in read-only states). Records the explicit save so "Saved" is announced afterwards (states §7).
    @objc func saveShow(_ sender: Any?) {
        guard let state = activeShowState, let document = state.store.document else { return }
        state.explicitSavePending = true
        document.save(sender)
    }

    @objc func duplicateShow(_ sender: Any?) { activeShowState?.store.document?.duplicate(sender) }
    @objc func saveShowAs(_ sender: Any?) { activeShowState?.store.document?.saveAs(sender) }

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
        guard !isEditingText else { return }
        if let state = keyLibraryState {
            state.deleteFocused()
        } else if let show = activeShowState {
            if show.destination == .alignment, let alignment = show.alignmentModel,
               alignment.anchorSelection != nil {
                alignment.requestDeleteSelectedAnchor()
            } else if episodeListActive(show) {
                show.deleteSelectedEpisode()
            } else if let episode = show.selectedEpisodeID {
                SourceCommands.handler.deleteSelection(store: show.store, episode: episode, window: show.window)
            }
        }
    }

    @objc func moveUp(_ sender: Any?) { move(by: -1) }
    @objc func moveDown(_ sender: Any?) { move(by: 1) }

    private func move(by offset: Int) {
        guard !isEditingText else { return }
        if let state = keyLibraryState {
            state.move(by: offset)
        } else if let show = activeShowState {
            if episodeListActive(show) {
                show.moveSelectedEpisode(by: offset)
            } else if let episode = show.selectedEpisodeID {
                SourceCommands.handler.moveSelection(by: offset, store: show.store, episode: episode, window: show.window)
            }
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
    @objc func analyseAlignment(_ sender: Any?) { activeShowState?.alignmentModel?.analyse() }
    @objc func acceptAlignmentProposal(_ sender: Any?) { activeShowState?.alignmentModel?.acceptProposal() }
    @objc func rejectAlignmentProposal(_ sender: Any?) { activeShowState?.alignmentModel?.rejectProposal() }
    @objc func editAlignmentTiming(_ sender: Any?) { activeShowState?.alignmentModel?.requestNumericEditor() }
    @objc func placeAlignmentAnchorAtPlayhead(_ sender: Any?) { activeShowState?.alignmentModel?.placeAnchorAtPlayhead() }
    @objc func placeAlignmentAnchors(_ sender: Any?) { activeShowState?.alignmentModel?.requestAnchorEditor() }
    @objc func editAlignmentAnchor(_ sender: Any?) { activeShowState?.alignmentModel?.requestSelectedAnchorEditor() }
    @objc func startNewEpochAtAnchor(_ sender: Any?) { activeShowState?.alignmentModel?.startNewEpochAtSelectedAnchor() }
    @objc func auditionAlignmentSelection(_ sender: Any?) { activeShowState?.alignmentModel?.auditionSelection() }
    @objc func stopAlignmentAudition(_ sender: Any?) { activeShowState?.alignmentModel?.stopAudition() }
    @objc func goToAlignmentSetup(_ sender: Any?) { activeShowState?.select(.setup) }

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
        case #selector(saveShow(_:)):
            return show?.isReadOnly == false
        case #selector(duplicateShow(_:)), #selector(saveShowAs(_:)):
            guard let show else { return false }
            // #159: Save As would make another file this older show's revision before its update; Duplicate stays.
            if item.action == #selector(saveShowAs(_:)), show.store.document?.isAwaitingFormatUpdate == true { return false }
            return show.saveStatus.state.allowsDuplicateOrSaveAs && show.store.document?.isInViewingMode != true
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
            guard let show, show.canEdit, let episode = show.selectedEpisodeID else {
                item.title = "Delete"
                return false
            }
            if show.destination == .alignment, show.alignmentModel?.anchorSelection != nil {
                item.title = "Delete Anchor"
                return true
            }
            if episodeListActive(show) {
                item.title = "Delete Episode…"
                return true
            }
            if let title = SourceCommands.handler.deleteSelectionTitle(store: show.store, episode: episode, window: show.window) {
                item.title = title
                return true
            }
            item.title = "Delete"
            return false
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let offset = item.action == #selector(moveUp(_:)) ? -1 : 1
            let direction = offset < 0 ? "Up" : "Down"
            if isEditingText {
                item.title = "Move \(direction)"
                return false
            }
            if let keyLibrary {
                let noun = keyLibrary.moveNoun
                item.title = noun.isEmpty ? "Move \(direction)" : "Move \(noun) \(direction)"
                return libraryEditable && keyLibrary.canMove(by: offset)
            }
            if let show, episodeListActive(show) {
                item.title = "Move Episode \(direction)"
                return show.canMoveSelectedEpisode(by: offset)
            }
            if let show, show.canEdit, let episode = show.selectedEpisodeID,
               let title = SourceCommands.handler.moveSelectionTitle(by: offset, store: show.store, episode: episode, window: show.window) {
                item.title = title
                return SourceCommands.handler.canMoveSelection(by: offset, store: show.store, episode: episode, window: show.window)
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
        case #selector(analyseAlignment(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.isWorking == false
        case #selector(acceptAlignmentProposal(_:)), #selector(rejectAlignmentProposal(_:)):
            return show?.destination == .alignment
                && show?.alignmentModel?.selectedRow?.state.heading.hasPrefix("Proposed") == true
        case #selector(editAlignmentTiming(_:)), #selector(placeAlignmentAnchors(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.canCorrect == true
        case #selector(placeAlignmentAnchorAtPlayhead(_:)):
            return show?.destination == .alignment
                && show?.alignmentModel?.canPlaceAnchorAtPlayhead == true
        case #selector(editAlignmentAnchor(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.anchorSelection != nil
        case #selector(startNewEpochAtAnchor(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.canStartNewEpoch == true
        case #selector(auditionAlignmentSelection(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.canAudition == true
        case #selector(stopAlignmentAudition(_:)):
            return show?.destination == .alignment && show?.alignmentModel?.canStopAudition == true
        case #selector(goToAlignmentSetup(_:)):
            return show?.destination == .alignment
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
