import AppKit
import Observation
import SwiftUI
import WWCore
import WWOrganizer

/// Per-window state of a show window (IA-02: each window keeps its own selection, destination, sidebar
/// and inspector visibility; the document, undo history and save state are shared). Menu commands route
/// here through `CommandRouter`.
@MainActor
@Observable
final class ShowWindowState {
    enum SidebarSelection: Hashable {
        case episode(EpisodeID)
        case showInfo
    }

    var sidebarSelection: SidebarSelection?
    var destination: ShowDestination = .setup
    var inspectorPresented = true
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var renamingEpisodeID: EpisodeID?
    /// Incremented to ask the episode inspector to focus its Title field (⌘I).
    var titleFocusRequest = 0
    var saveStatusPopoverShown = false
    var dismissedMessageBar: String?
    /// Set by File › Save so the following "Saved" is announced (states §7).
    @ObservationIgnored var explicitSavePending = false

    let store: ShowDocumentStore
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var fallbackStatus: NativeDocumentStatusObserver?

    init(store: ShowDocumentStore) {
        self.store = store
        sidebarSelection = store.model.episodes.first.map { .episode($0.id) }
    }

    // MARK: - Status

    var statusProvider: DocumentStatusProviding {
        if let provider = store.document as? DocumentStatusProviding { return provider }
        if let fallbackStatus { return fallbackStatus }
        let observer = NativeDocumentStatusObserver(document: store.document)
        fallbackStatus = observer
        return observer
    }

    var saveStatus: DocumentSaveStatus { statusProvider.saveStatus }

    var presentation: SaveStatusPresentation {
        SaveStatusPresentation(saveStatus, showName: store.model.show.title)
    }

    /// ST-14: read-only states disable every editing command.
    var isReadOnly: Bool {
        saveStatus.state.isReadOnly || store.document?.isInViewingMode == true
    }

    // MARK: - Selection

    var selectedEpisodeID: EpisodeID? {
        if case .episode(let id) = sidebarSelection { return id }
        return nil
    }

    var selectedEpisode: Episode? { selectedEpisodeID.flatMap { store.model.episode($0) } }

    /// Keeps the selection valid after undo/redo or deletion elsewhere (IA §9: fall back to the first).
    func reconcileSelection(previousOrder: [EpisodeID]) {
        guard case .episode(let id) = sidebarSelection, store.model.episode(id) == nil else {
            if sidebarSelection == nil, let first = store.model.episodes.first { sidebarSelection = .episode(first.id) }
            return
        }
        let episodes = store.model.episodes
        if let oldIndex = previousOrder.firstIndex(of: id), !episodes.isEmpty {
            sidebarSelection = .episode(episodes[min(oldIndex, episodes.count - 1)].id)
        } else {
            sidebarSelection = episodes.first.map { .episode($0.id) }
        }
    }

    // MARK: - Episode commands

    var canEdit: Bool { !isReadOnly }

    func newEpisode() {
        guard canEdit else { return }
        let episode = store.model.nextNewEpisode()
        if store.apply(UndoActionName.newEpisode, { model throws(DomainError) in try model.addingEpisode(episode) }) {
            sidebarSelection = .episode(episode.id)
            renamingEpisodeID = episode.id
        }
    }

    func renameSelectedEpisode() {
        guard canEdit, let id = selectedEpisodeID else { return }
        renamingEpisodeID = id
    }

    @discardableResult
    func commitRename(_ id: EpisodeID, to title: String) -> Bool {
        renamingEpisodeID = nil
        guard let episode = store.model.episode(id), title != episode.title else { return true }
        return store.apply(UndoActionName.renameEpisode) { model throws(DomainError) in try model.renamingEpisode(id, to: title) }
    }

    func deleteSelectedEpisode() {
        guard canEdit, let episode = selectedEpisode else { return }
        let wording = ConfirmationWording.deleteEpisode(episode.title)
        let order = store.model.episodes.map(\.id)
        Task {
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button) else { return }
            if store.apply(UndoActionName.deleteEpisode, { model throws(DomainError) in try model.removingEpisode(episode.id) }) {
                reconcileSelection(previousOrder: order)
                announce("Deleted \(episode.title)")
            }
        }
    }

    func canMoveSelectedEpisode(by offset: Int) -> Bool {
        guard canEdit, let id = selectedEpisodeID else { return false }
        return store.model.canMoveEpisode(id, by: offset)
    }

    func moveSelectedEpisode(by offset: Int) {
        guard canMoveSelectedEpisode(by: offset), let id = selectedEpisodeID else { return }
        store.apply(UndoActionName.moveEpisode) { model throws(DomainError) in try model.movingEpisode(id, by: offset) }
    }

    func moveEpisodes(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard canEdit else { return }
        store.apply(UndoActionName.moveEpisode) { model throws(DomainError) in
            model.movingEpisodes(fromOffsets: source, toOffset: destination)
        }
    }

    /// Episode › Episode Info (⌘I): show the inspector and focus Title (a user-initiated focus move).
    func showEpisodeInfo() {
        if selectedEpisodeID == nil, let first = store.model.episodes.first { sidebarSelection = .episode(first.id) }
        guard selectedEpisodeID != nil else { return }
        inspectorPresented = true
        titleFocusRequest += 1
    }

    // MARK: - View commands

    func select(_ destination: ShowDestination) {
        let changed = self.destination != destination
        self.destination = destination
        if changed, let panel = destination.blockedPanel {
            announce(panel.heading)
        }
    }

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    var isSidebarShown: Bool { sidebarVisibility != .detailOnly }

    func toggleInspector() { inspectorPresented.toggle() }

    func showSaveStatus() { saveStatusPopoverShown = true }

    // MARK: - Save-status actions

    func perform(_ action: SaveStatusAction) {
        if let handler = store.document as? DocumentStatusActionHandling, handler.performSaveStatusAction(action, from: window) {
            return
        }
        guard let document = store.document else { return }
        switch action {
        case .saveNow, .tryAgain, .checkAgain:
            document.save(nil)
        case .saveACopy, .saveACopyElsewhere, .duplicate:
            document.duplicate(nil)
        case .showInFinder, .showKeptFiles:
            if let url = document.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .autosaveSettings:
            SettingsWindowController.show(pane: .general)
        case .closeShow:
            CommandRouter.closeAllWindows(of: document)
        case .keepThisVersion:
            dismissedMessageBar = presentation.messageBar?.heading
        case .revertToEarlierVersion:
            document.browseVersions(nil)
        case .cancelSave, .resolve, .details, .showDetails:
            break
        }
    }

    /// Announces save-state changes per states §7 (first failure once, explicit/after-retry "Saved").
    func saveStateDidChange(from old: DocumentSaveState, to new: DocumentSaveState) {
        if let text = SaveStatusPresentation.announcement(from: old, to: new, showName: store.model.show.title, explicitSave: explicitSavePending) {
            announce(text)
        }
        if new.isCoherentlySaved || new.announcementIsTerminalFailure { explicitSavePending = false }
    }

    func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Window

    func attach(to window: NSWindow) {
        self.window = window
        ShowWindowRegistry.register(self, for: window)
        if let hosting = window.contentViewController as? NSHostingController<ShowWorkspaceView> {
            hosting.sceneBridgingOptions = [.toolbars]
        }
        window.toolbarStyle = .unified
        window.setAccessibilityIdentifier("ww.show.window")
        updateSubtitle()
        let model = store.model
        LibraryStore.shared.showDidOpen(id: model.show.id, model: model, fileURL: store.document?.fileURL)
    }

    /// IA-06: subtitle = selected episode's title.
    func updateSubtitle() {
        window?.subtitle = ShowSidebarPresentation.windowSubtitle(model: store.model, selectedEpisode: selectedEpisodeID)
    }
}

extension DocumentSaveState {
    fileprivate var announcementIsTerminalFailure: Bool {
        switch self {
        case .notConfirmed, .locationUnavailable, .diskFull, .failed, .cancelled, .conflict: true
        default: false
        }
    }
}

/// Finds the per-window state for the key/main show window (menu routing).
@MainActor
enum ShowWindowRegistry {
    private static var states: [ObjectIdentifier: WeakState] = [:]

    private struct WeakState {
        weak var state: ShowWindowState?
    }

    static func register(_ state: ShowWindowState, for window: NSWindow) {
        states = states.filter { $0.value.state != nil }
        states[ObjectIdentifier(window)] = WeakState(state: state)
    }

    static func state(for window: NSWindow?) -> ShowWindowState? {
        guard let window else { return nil }
        return states[ObjectIdentifier(window)]?.state
    }

    static func states(for document: NSDocument) -> [ShowWindowState] {
        document.windowControllers.compactMap { state(for: $0.window) }
    }
}
