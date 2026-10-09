import AppKit
import WWOrganizer
import WWPersistence

/// The C2b recovery offer of a show document, for the show window's message bar (#84).
@MainActor
protocol EditCheckpointOfferProviding: AnyObject {
    var editCheckpointOfferState: EditCheckpointOfferState? { get }
    /// Performs an already-confirmed action (Discard and Dismiss are confirmed by the window first).
    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction)
}

extension ShowDocument: EditCheckpointOfferProviding {
    var editCheckpointOfferState: EditCheckpointOfferState? {
        guard let offer = status.editCheckpointOffer else { return nil }
        if let candidate = offer.candidate, let mode = offer.candidateMode(restoreInEffect: isEditCheckpointRestoreInEffect) {
            let createdAt = candidate.record.createdAt
            if isEditCheckpointCopyOnly(candidate.url) { return .stale(createdAt: createdAt) }
            return switch mode {
            case .restore: .restore(createdAt: createdAt)
            case .copyOnlyWhileAnotherRestoreIsInEffect: .anotherSession(createdAt: createdAt)
            case .copyOnlyOlderRevision: .olderRevision(createdAt: createdAt)
            }
        }
        guard !offer.problems.isEmpty else { return nil }
        let newer = offer.problems.filter { if case .newerFormat = $0 { true } else { false } }.count
        return .unusable(damaged: offer.problems.count - newer, newerFormat: newer)
    }

    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction) {
        switch action {
        case .restore: restoreOfferedEditCheckpoint()
        case .openAsCopy: openOfferedEditCheckpointAsCopy()
        case .discard: discardOfferedEditCheckpoint()
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting(editCheckpointProblemURLs)
        case .dismiss: hideEditCheckpointProblems()
        }
    }
}
