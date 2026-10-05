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
    /// Set one main-queue turn after the window is attached. A message bar present at the window's very first
    /// layout (the C2b offer exists before the window does) broke the split view's layout; it appears after.
    var isWindowAttached = false
    /// The C2b offer heading already announced in this window (announced once, never moving focus).
    @ObservationIgnored private var announcedEditCheckpointHeading: String?
    /// Whether the Episodes list has keyboard focus (Edit › Delete / Move act on the focused list only).
    var episodeListFocused = false
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

    // MARK: - Unsaved-changes recovery offer (C2b, #84)

    var editCheckpointOffer: (state: EditCheckpointOfferState, presentation: EditCheckpointOfferPresentation)? {
        guard let provider: EditCheckpointOfferProviding = store.document, let state = provider.editCheckpointOfferState else { return nil }
        return (state, EditCheckpointOfferPresentation(state, showName: store.model.show.title))
    }

    /// Discard and Dismiss ask first (Cancel on Esc, no destructive default); the others act directly.
    func performEditCheckpointAction(_ action: EditCheckpointAction) {
        guard let provider: EditCheckpointOfferProviding = store.document, let state = provider.editCheckpointOfferState else { return }
        guard let wording = EditCheckpointOfferPresentation.confirmation(for: action, state: state) else {
            provider.performConfirmedEditCheckpointAction(action)
            if action == .restore { announce("Restored unsaved changes") }
            return
        }
        Task {
            guard await Dialogs.confirm(in: window, message: wording.message, informative: wording.informative, confirmTitle: wording.button,
                                        destructive: action == .discard, destructiveIsDefault: false) else { return }
            provider.performConfirmedEditCheckpointAction(action)
        }
    }

    func editCheckpointOfferDidAppear(_ presentation: EditCheckpointOfferPresentation) {
        guard announcedEditCheckpointHeading != presentation.heading else { return }
        announcedEditCheckpointHeading = presentation.heading
        announce(presentation.announcement)
    }

    /// Announces save-state changes per states §7 (first failure once, explicit/after-retry "Saved").
    func saveStateDidChange(from old: DocumentSaveState, to new: DocumentSaveState) {
        if let text = SaveStatusPresentation.announcement(from: old, to: new, showName: store.model.show.title, explicitSave: explicitSavePending) {
            announce(text)
        }
        if new.isCoherentlySaved || new.announcementIsTerminalFailure { explicitSavePending = false }
        // P6 ordering: the library learns a show's new title only after coherent disk truth (D1).
        if new.isCoherentlySaved {
            let model = store.model
            LibraryUIStore.shared.showDidSaveCoherently(id: model.show.id, model: model, fileURL: store.document?.fileURL)
        }
    }

    func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Window

    func attach(to window: NSWindow) {
        self.window = window
        ShowWindowRegistry.register(self, for: window)
        // Window chrome and bridging must not change while AppKit/SwiftUI are attaching and laying out the
        // view (re-entrant constraint updates); apply them on the next main-queue turn.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.isWindowAttached = true
            if let hosting = window.contentViewController as? NSHostingController<ShowWorkspaceView> {
                hosting.sceneBridgingOptions = [.toolbars]
            }
            window.contentView?.setAccessibilityLabel("Show")
            window.toolbarStyle = .unified
            LaunchFixtures.placeForTesting(window)
            window.setAccessibilityIdentifier("ww.show.window")
            self.updateSubtitle()
            let model = self.store.model
            LibraryUIStore.shared.showDidOpen(
                id: model.show.id, model: model, fileURL: self.store.document?.fileURL,
                hasUnsavedChanges: self.saveStatus.hasUnsavedChanges || self.store.document?.isDocumentEdited == true
            )
        }
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
