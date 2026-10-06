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
        // #159: an older-format show is read-only until its update has published.
        guard FormatUpdatePolicy.allowsEdits(document?.status.formatUpdate) else { return false }
        do {
            let updated = try operation(model)
            lastError = nil
            guard updated != model else { return true }
            if let key, key == coalescingKey {
                model = updated
                // No new undo step, so AppKit won't reschedule autosaving: the quiescence timer must still move
                // to this edit, or a checkpoint/autosave taken mid-burst would miss the rest of it.
                document?.coalescedEditDidChangeModel()
            } else {
                replace(with: updated, actionName: actionName)
            }
            coalescingKey = key
            Responsiveness.interaction("show.edit")
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

    /// Applies a complete, already-validated model and runs `afterChange` for the initial edit and every
    /// undo/redo replacement. Alignment uses this to persist first, then activate the accepted map revision.
    @discardableResult
    func applyReplacement(
        _ actionName: String,
        model newModel: ShowDocumentModel,
        afterChange: @escaping @MainActor (ShowDocumentModel) -> Void
    ) -> Bool {
        guard FormatUpdatePolicy.allowsEdits(document?.status.formatUpdate) else { return false }
        guard newModel != model else { return true }
        lastError = nil
        replace(with: newModel, actionName: actionName, afterChange: afterChange)
        Responsiveness.interaction("show.edit")
        return true
    }

    private func replace(
        with newModel: ShowDocumentModel,
        actionName: String,
        afterChange: (@MainActor (ShowDocumentModel) -> Void)? = nil
    ) {
        let previous = model
        model = newModel
        coalescingKey = nil
        if let undoManager = document?.undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    store.replace(with: previous, actionName: actionName, afterChange: afterChange)
                }
            }
            undoManager.setActionName(actionName)
        }
        afterChange?(newModel)
    }
}
