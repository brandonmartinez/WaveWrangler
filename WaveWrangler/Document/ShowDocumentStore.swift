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
    private(set) var lastEditMapError: EditMapPublicationError?
    /// Changes on every live replacement, including reload, undo/redo and an ABA edit sequence.
    private(set) var mutationSerial: UInt64 = 0

    /// No production source/protection authority is wired yet. A saved choice or a caller-supplied
    /// map cannot make one; until a live organizer-owned verifier exists, all admission refuses.
    @ObservationIgnored private let proveEditMap: EditMapPublication.Proof? = nil

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
        lastEditMapError = nil
        coalescingKey = nil
        mutationSerial &+= 1
    }

    func editSnapshot() -> EditMapSnapshot { EditMapSnapshot(model: model, serial: mutationSerial) }

    /// The only native route for a selected provisional plan. The proof provider must independently
    /// check current device access, source revisions and every protected decision at this serial.
    /// It is deliberately absent in production until those upstream interfaces are qualified.
    @discardableResult
    func publishEditMap(
        _ version: EditMapVersion, in episodeID: EpisodeID,
        expecting snapshot: EditMapSnapshot, actionName: String
    ) -> Bool {
        guard FormatUpdatePolicy.allowsEdits(document?.status.formatUpdate) else {
            lastEditMapError = .unauthorizedMutation
            return false
        }
        do {
            let successor = try EditMapPublication.recording(
                version, in: episodeID, actionName: actionName,
                expecting: snapshot, current: { self.editSnapshot() }, prove: proveEditMap
            )
            lastEditMapError = nil
            guard replace(with: successor, actionName: actionName, selectionAlreadyProven: true) else { return false }
            Responsiveness.interaction("show.edit")
            return true
        } catch {
            lastEditMapError = error
            return false
        }
    }

    @discardableResult
    func selectEditMap(
        _ revision: Int, in episodeID: EpisodeID, expecting snapshot: EditMapSnapshot
    ) -> Bool {
        guard FormatUpdatePolicy.allowsEdits(document?.status.formatUpdate) else {
            lastEditMapError = .unauthorizedMutation
            return false
        }
        do {
            let successor = try EditMapPublication.selecting(
                revision, in: episodeID, expecting: snapshot,
                current: { self.editSnapshot() }, prove: proveEditMap
            )
            lastEditMapError = nil
            guard replace(with: successor, actionName: "Select Edit Map", selectionAlreadyProven: true) else { return false }
            Responsiveness.interaction("show.edit")
            return true
        } catch {
            lastEditMapError = error
            return false
        }
    }

    /// Never return a saved selection as active authority without a new live proof, even after Restore.
    func selectedEditMap(in episodeID: EpisodeID) throws(EditMapPublicationError) -> EditMapVersion {
        try EditMapPublication.selected(
            in: episodeID, current: { self.editSnapshot() }, prove: proveEditMap
        )
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
            guard updated.editMaps == model.editMaps else {
                lastEditMapError = .unauthorizedMutation
                return false
            }
            guard updated != model else { return true }
            let serial = mutationSerial
            let safe = revalidated(updated.invalidatingChangedEditMaps(from: model))
            guard serial == mutationSerial else {
                lastEditMapError = .superseded
                return false
            }
            if let key, key == coalescingKey {
                model = safe
                mutationSerial &+= 1
                // No new undo step, so AppKit won't reschedule autosaving: the quiescence timer must still move
                // to this edit, or a checkpoint/autosave taken mid-burst would miss the rest of it.
                document?.coalescedEditDidChangeModel()
            } else {
                guard replace(with: safe, actionName: actionName, selectionAlreadyProven: true) else { return false }
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
        guard newModel.editMaps == model.editMaps else {
            lastEditMapError = .unauthorizedMutation
            return false
        }
        guard newModel != model else { return true }
        lastError = nil
        guard replace(with: newModel.invalidatingChangedEditMaps(from: model), actionName: actionName, afterChange: afterChange)
        else { return false }
        Responsiveness.interaction("show.edit")
        return true
    }

    /// Applies a replacement that was computed from `expected`, but only while the live model is still
    /// exactly that snapshot.
    ///
    /// Windows share one store, so a replacement prepared across awaits can arrive after another window has
    /// edited the show; publishing it then would discard that edit. Returns false without touching the model
    /// when the snapshot has been superseded (#219).
    @discardableResult
    func applyReplacement(
        _ actionName: String,
        expecting expected: ShowDocumentModel,
        model newModel: ShowDocumentModel,
        afterChange: @escaping @MainActor (ShowDocumentModel) -> Void
    ) -> Bool {
        guard SharedModelPublication.decide(live: model, expected: expected) == .publish else { return false }
        return applyReplacement(actionName, model: newModel, afterChange: afterChange)
    }

    private func replace(
        with newModel: ShowDocumentModel,
        actionName: String,
        afterChange: (@MainActor (ShowDocumentModel) -> Void)? = nil,
        selectionAlreadyProven: Bool = false
    ) -> Bool {
        let previous = model
        let serial = mutationSerial
        let safe = selectionAlreadyProven ? newModel : revalidated(newModel.invalidatingChangedEditMaps(from: previous))
        guard serial == mutationSerial else {
            lastEditMapError = .superseded
            return false
        }
        model = safe
        mutationSerial &+= 1
        coalescingKey = nil
        if let undoManager = document?.undoManager {
            AppUndoRegistration.register(
                with: undoManager,
                target: self,
                actionName: actionName
            ) { store in
                _ = store.replace(with: previous, actionName: actionName, afterChange: afterChange)
            }
        }
        afterChange?(safe)
        return true
    }

    private func revalidated(_ candidate: ShowDocumentModel) -> ShowDocumentModel {
        let result = EditMapPublication.revalidated(
            candidate, replacing: model, current: { self.editSnapshot() }, prove: proveEditMap
        )
        lastEditMapError = result.refusal
        return result.model
    }
}
