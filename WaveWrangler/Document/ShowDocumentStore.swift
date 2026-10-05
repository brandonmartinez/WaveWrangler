import Foundation
import Observation
import WWCore

/// Main-actor view model for one open show. Every change goes through a pure WWCore operation and is
/// registered with the document's undo manager, which also drives NSDocument's honest dirty state.
@MainActor
@Observable
final class ShowDocumentStore {
    private(set) var model: ShowDocumentModel
    /// The most recent refused operation, shown to the user until the next successful change.
    private(set) var lastError: DomainError?

    @ObservationIgnored weak var document: ShowDocument?

    init(model: ShowDocumentModel) {
        self.model = model
    }

    /// Replaces the value after reading from disk; not an undoable edit.
    func replaceLoadedModel(_ model: ShowDocumentModel) {
        self.model = model
        lastError = nil
    }

    @discardableResult
    func apply(_ actionName: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool {
        do {
            let updated = try operation(model)
            guard updated != model else { return true }
            replace(with: updated, actionName: actionName)
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }

    private func replace(with newModel: ShowDocumentModel, actionName: String) {
        let previous = model
        model = newModel
        guard let undoManager = document?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.replace(with: previous, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
