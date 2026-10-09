import AppKit
import WWOrganizer
import WWPersistence

/// The C2b recovery offer of a show document, for the show window's message bar (#84).
@MainActor
protocol EditCheckpointOfferProviding: AnyObject {
    var editCheckpointOfferState: EditCheckpointOfferState? { get }
    func selectedEditCheckpointForDiscard() throws -> SelectedRecoveryRecord
    /// Performs an already-confirmed action (Discard and Dismiss are confirmed by the window first).
    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction, selected: SelectedRecoveryRecord?) throws
}

extension ShowDocument: EditCheckpointOfferProviding {
    var editCheckpointOfferState: EditCheckpointOfferState? {
        guard let offer = status.editCheckpointOffer else { return nil }
        if let candidate = offer.candidate, let mode = offer.candidateMode(restoreInEffect: isEditCheckpointRestoreInEffect) {
            let createdAt = candidate.record.createdAt
            if restoredOfferURLs.contains(candidate.url) { return .restored(createdAt: createdAt) }
            if !recoveryBaseVerified { return .unverified(createdAt: createdAt) }
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

    func selectedEditCheckpointForDiscard() throws -> SelectedRecoveryRecord {
        guard let offer = status.editCheckpointOffer else { throw CocoaError(.fileReadNoSuchFile) }
        if let candidate = offer.candidate {
            return try recovery.selectRecord(.offeredEditCheckpoint, at: candidate.url, for: documentKey)
        }
        guard let problem = offer.problems.first else { throw CocoaError(.fileReadNoSuchFile) }
        return try recovery.selectRecord(.offeredEditCheckpoint, at: problem.url, for: documentKey, allowingDamagedRecord: true)
    }

    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction, selected: SelectedRecoveryRecord?) throws {
        switch action {
        case .restore: try restoreOfferedEditCheckpoint()
        case .openAsCopy: try openOfferedEditCheckpointAsCopy()
        case .discard:
            guard let selected else { throw CocoaError(.fileReadNoSuchFile) }
            try discardOfferedEditCheckpoint(selected)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting(editCheckpointProblemURLs)
        case .checkAgain: refreshEditCheckpointOffer()
        case .dismiss: hideEditCheckpointProblems()
        }
    }
}
