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
        if let candidate = offer.candidate {
            return candidate.relation == .basedOnCurrent
                ? .restore(createdAt: candidate.record.createdAt)
                : .olderRevision(createdAt: candidate.record.createdAt)
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
