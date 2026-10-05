import AppKit
import Foundation
import Observation
import WWCore
import WWOrganizer

/// Main-actor model behind the Library window. Library edits (collections, order, removal) use the
/// Library window's own undo history and never mark a show as edited (IA-03).
///
/// Ordering rules (pure logic in `LibrarySession`, unit-tested): the library is loaded at launch; nothing
/// is written before it has loaded, after a failed load, or while it is read-only (L4/L5); show-open
/// bookkeeping that arrives earlier is queued; undo reverts only what the action changed.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore(services: LibraryServices.current)

    private(set) var session = LibrarySession()
    /// ST-32: a library read/write failure; shown in the Library window's message bar until dismissed.
    var persistenceFailure: String?
    /// The most recent refused operation, explained inline.
    private(set) var lastError: String?

    /// The Library window's own undo history (IA-03). The window controller points this at the undo
    /// manager the window actually validates Edit › Undo against.
    @ObservationIgnored var undoManagerProvider: (() -> UndoManager?)?
    @ObservationIgnored private let fallbackUndoManager = UndoManager()
    var undoManager: UndoManager { undoManagerProvider?() ?? fallbackUndoManager }

    @ObservationIgnored let services: LibraryServices
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(services: LibraryServices) {
        self.services = services
    }

    var library: LibraryModel { session.library }
    var isLoaded: Bool { session.isLoaded }
    var details: [ShowID: LibraryEntryDetails] { services.entries.details }
    var isDurable: Bool { services.persistence.isDurable }
    private var allowsEdits: Bool { services.location.libraryState.allowsEdits }

    /// Loads the canonical library once (called at launch, before any window needs it).
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await services.persistence.loadLibrary()
                if session.didLoad(model, allowsEdits: allowsEdits) { persist() }
                await services.entries.refresh(session.library.entries.map(\.showID))
            } catch {
                session.didFailLoad(reason: error.localizedDescription)
                persistenceFailure = "Couldn't read the library: \(error.localizedDescription). Your shows aren't affected, and the library won't be changed until it can be read."
            }
        }
        loadTask = task
        await task.value
    }

    // MARK: - Undoable edits

    @discardableResult
    func apply(_ actionName: String, _ operation: (LibraryModel) throws(LibraryError) -> LibraryModel) -> Bool {
        do {
            guard let change = try session.apply(allowsEdits: allowsEdits, operation) else {
                lastError = nil
                return true
            }
            lastError = nil
            persist()
            registerUndo(change, actionName: actionName, isUndo: true)
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    private func registerUndo(_ change: LibrarySession.Change, actionName: String, isUndo: Bool) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard store.allowsEdits, store.isLoaded else { return }
                if isUndo { store.session.undo(change) } else { store.session.redo(change) }
                store.persist()
                store.registerUndo(change, actionName: actionName, isUndo: !isUndo)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Non-undoable bookkeeping (reconciliation, recents)

    /// Called when a show window opens: adds/refreshes the entry and records it as recent. Queued until
    /// the library has loaded and is editable.
    func showDidOpen(id: ShowID, model: ShowDocumentModel, fileURL: URL?) {
        services.entries.noteOpenShow(id: id, model: model, fileURL: fileURL)
        services.entries.noteOpened(id: id)
        if session.record(.opened(id, title: model.show.title), allowsEdits: allowsEdits) { persist() }
    }

    /// Called only after a coherent save (D1) so the library never runs ahead of the show on disk (P6).
    func showDidSaveCoherently(id: ShowID, model: ShowDocumentModel, fileURL: URL?) {
        services.entries.noteOpenShow(id: id, model: model, fileURL: fileURL)
        if session.record(.confirmedTitle(id, title: model.show.title), allowsEdits: allowsEdits) { persist() }
    }

    private func persist() {
        guard session.canPersist(allowsEdits: allowsEdits) else { return }
        let snapshot = session.library
        let previous = saveChain
        let persistence = services.persistence
        saveChain = Task { [weak self] in
            await previous?.value
            do {
                try await persistence.saveLibrary(snapshot)
            } catch {
                self?.persistenceFailure = "Couldn't update the library: \(error.localizedDescription). Your shows aren't affected."
            }
        }
    }

    static func message(for refusal: LibrarySession.EditRefusal) -> String {
        switch refusal {
        case .notLoaded: "The library is still loading. Try again in a moment."
        case .loadFailed: "The library couldn't be read, so it can't be changed right now. Your shows aren't affected."
        case .readOnly: "The library can't be changed right now. The reason is shown at the top of the Library window."
        case .invalid(let error): message(for: error)
        }
    }

    static func message(for error: LibraryError) -> String {
        switch error {
        case .emptyName: "A collection name can't be empty."
        case .collectionNotFound: "That collection no longer exists."
        case .duplicateCollection: "That collection already exists."
        case .entryNotFound: "That show is no longer in the library."
        }
    }

    // MARK: - Presentation

    var sidebar: LibrarySidebarSnapshot {
        LibraryPresentation.sidebar(library: library, details: details)
    }

    func rows(for item: LibrarySidebarItem) -> [LibraryEntryRow] {
        LibraryPresentation.entries(for: item, library: library, details: details)
    }
}
