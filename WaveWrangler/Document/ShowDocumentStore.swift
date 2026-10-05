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
    /// Key of the edit burst currently being coalesced into a single undo step (e.g. live title typing).
    @ObservationIgnored private var coalescingKey: String?

    init(model: ShowDocumentModel) {
        self.model = model
    }

    /// Replaces the value after reading from disk; not an undoable edit.
    func replaceLoadedModel(_ model: ShowDocumentModel) {
        self.model = model
        lastError = nil
        coalescingKey = nil
    }

    /// Applies a pure operation immediately so the model (and therefore Save, autosave, Close and Quit)
    /// always sees the latest edit.
    ///
    /// Successive applies with the same non-nil `coalescing` key form one undo step: the first registers
    /// undo (which marks the document dirty), later ones in the burst only update the model. A burst ends
    /// on `endCoalescing()`, on any other edit, on undo/redo, and when a save begins, so an edit made after
    /// a save always registers new undo and makes the document dirty again.
    @discardableResult
    func apply(
        _ actionName: String,
        coalescing key: String? = nil,
        _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel
    ) -> Bool {
        do {
            let updated = try operation(model)
            lastError = nil
            guard updated != model else { return true }
            if let key, key == coalescingKey {
                model = updated
            } else {
                replace(with: updated, actionName: actionName)
            }
            coalescingKey = key
            return true
        } catch {
            lastError = error
            coalescingKey = nil
            return false
        }
    }

    func endCoalescing() {
        coalescingKey = nil
    }

    private func replace(with newModel: ShowDocumentModel, actionName: String) {
        let previous = model
        model = newModel
        coalescingKey = nil
        guard let undoManager = document?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.replace(with: previous, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
