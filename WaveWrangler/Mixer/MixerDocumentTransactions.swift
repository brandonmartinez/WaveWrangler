import AppKit
import Observation
import WWCore
import WWMix

@MainActor @Observable
final class MixerDocumentTransactions {
    private struct WeakController {
        weak var value: EpisodeMixerController?
    }

    private weak var document: ShowDocument?
    @ObservationIgnored private var controllers: [WeakController] = []
    @ObservationIgnored private let operations = MixerOperationQueue()
    private(set) var isBusy = false
    private(set) var isInsideBarrier = false
    private(set) var isClosed = false
    var error: String?

    init(document: ShowDocument) { self.document = document }

    func register(_ controller: EpisodeMixerController) {
        controllers.removeAll { $0.value == nil }
        controllers.append(WeakController(value: controller))
    }

    private var liveControllers: [EpisodeMixerController] { controllers.compactMap(\.value) }
    var needsBarrier: Bool {
        operations.pending > 0 || liveControllers.contains(where: \.hasObservedState)
    }

    func refusesReplacement(from prior: ShowDocumentModel, to next: ShowDocumentModel) -> Bool {
        guard !isInsideBarrier else { return false }
        return liveControllers.contains { controller in
            guard controller.hasObservedState else { return false }
            let id = controller.episodeID
            guard let old = prior.episode(id), let new = next.episode(id) else { return true }
            let a = old.mix ?? EpisodeMixState(), b = new.mix ?? EpisodeMixState()
            return !next.hasSameMediaInputs(as: prior, in: id)
                || old.activeManualCuts != new.activeManualCuts
                || a.master.inserts != b.master.inserts
                || old.speakerAssignments.contains {
                    a.state(for: $0.speakerID).inserts != b.state(for: $0.speakerID).inserts
                }
        }
    }

    func edit(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await operations.run { [self] in
            guard !isClosed else { throw MixerFailure.staleDependencies }
            isBusy = true
            defer { isBusy = false }
            try await operation()
            error = nil
        }
    }

    /// Hide native editors before capture so no UI knob can race the document operation.
    func barrier(
        replacingInstances: Bool = false,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await operations.run { [self] in
            guard !isClosed else { throw MixerFailure.staleDependencies }
            isBusy = true
            isInsideBarrier = true
            let presentations = document.map { ShowWindowRegistry.states(for: $0.store).map(\.mixerPresentation) } ?? []
            let controllers = liveControllers
            let observing = controllers.map { ($0, $0.editorObservationKey) }
            presentations.forEach { $0.hideEditorsForBarrier() }
            defer { isBusy = false; isInsideBarrier = false }
            do {
                for controller in controllers { await controller.suspendEditorObservation() }
                for (controller, key) in observing where controller.hasObservedState {
                    try await controller.captureAndPersist(coalescing: key)
                }
                document?.store.endCoalescing()
                if replacingInstances {
                    presentations.forEach { $0.dismissEditorsAfterCapture() }
                    for state in document.map({ ShowWindowRegistry.states(for: $0.store) }) ?? [] {
                        state.alignmentModel?.stopAudition()
                    }
                    controllers.forEach { $0.invalidatePreparedInstance() }
                }
                try await operation()
                if !replacingInstances {
                    for (controller, key) in observing {
                        if let key, controller.processor != nil {
                            try await controller.beginEditorObservation(coalescing: key)
                        }
                    }
                    presentations.forEach { $0.restoreEditorsAfterBarrier() }
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
                presentations.forEach { $0.restoreEditorsAfterBarrier() }
                throw error
            }
        }
    }

    func report(_ error: Error) {
        self.error = error.localizedDescription
    }

    func finishClosingAfterCapture() {
        isClosed = true
        liveControllers.forEach { $0.invalidatePreparedInstance() }
    }
}

@MainActor
final class MixerUndoManager: UndoManager {
    weak var document: ShowDocument?

    override func undo() {
        guard let document, document.mixerTransactions.needsBarrier else { super.undo(); return }
        Task {
            do {
                try await document.mixerTransactions.barrier(replacingInstances: true) { [self] in undoCaptured() }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    override func redo() {
        guard let document, document.mixerTransactions.needsBarrier else { super.redo(); return }
        Task {
            do {
                try await document.mixerTransactions.barrier(replacingInstances: true) { [self] in redoCaptured() }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    private func undoCaptured() { super.undo() }
    private func redoCaptured() { super.redo() }
}
