import AppKit
import Foundation
import Observation
import WWCore
import WWOrganizer

/// Main-actor model behind the Library window. Library edits (collections, order, removal) use the
/// Library window's own undo history and never mark a show as edited (IA-03).
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore(services: LibraryServices.current)

    private(set) var library = LibraryModel()
    private(set) var isLoaded = false
    /// ST-32: a library write failure; shown in the Library window's message bar until dismissed.
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

    init(services: LibraryServices) {
        self.services = services
    }

    var details: [ShowID: LibraryEntryDetails] { services.entries.details }
    var isDurable: Bool { services.persistence.isDurable }

    func load() async {
        do {
            library = try await services.persistence.loadLibrary()
            isLoaded = true
            await services.entries.refresh(library.entries.map(\.showID))
        } catch {
            persistenceFailure = "Couldn't read the library: \(error.localizedDescription). Your shows aren't affected."
        }
    }

    // MARK: - Undoable edits

    @discardableResult
    func apply(_ actionName: String, _ operation: (LibraryModel) throws(LibraryError) -> LibraryModel) -> Bool {
        guard services.location.libraryState.allowsEdits else {
            lastError = "The library can't be changed right now. The reason is shown at the top of the Library window."
            return false
        }
        do {
            let updated = try operation(library)
            lastError = nil
            guard updated != library else { return true }
            replace(with: updated, actionName: actionName)
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    private func replace(with newValue: LibraryModel, actionName: String) {
        let previous = library
        library = newValue
        persist()
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.replace(with: previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Non-undoable bookkeeping (reconciliation, recents)

    /// Called when a show window opens: adds/refreshes the entry and records it as recent.
    func showDidOpen(id: ShowID, model: ShowDocumentModel, fileURL: URL?) {
        services.entries.noteOpenShow(id: id, model: model, fileURL: fileURL)
        services.entries.noteOpened(id: id)
        let updated = library.upsertingEntry(showID: id, title: model.show.title).recordingOpened(id)
        if updated != library {
            library = updated
            persist()
        }
    }

    /// Called when an open show's content changes, so "as of last open" details stay current.
    func showDidChange(id: ShowID, model: ShowDocumentModel, fileURL: URL?) {
        services.entries.noteOpenShow(id: id, model: model, fileURL: fileURL)
        guard library.entry(id) != nil else { return }
        let updated = library.upsertingEntry(showID: id, title: model.show.title)
        if updated != library {
            library = updated
            persist()
        }
    }

    private func persist() {
        let snapshot = library
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
