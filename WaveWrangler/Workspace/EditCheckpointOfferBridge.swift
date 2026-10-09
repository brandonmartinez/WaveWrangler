import AppKit
import WWCore
import WWOrganizer
import WWPersistence

/// The C2b recovery offer of a show document, for the show window's message bar (#84).
@MainActor
protocol EditCheckpointOfferProviding: AnyObject {
    var editCheckpointOfferState: EditCheckpointOfferState? { get }
    var editCheckpointOfferPosition: (index: Int, total: Int)? { get }
    var editCheckpointOfferChoice: RecoveryChoicePresentation.Choice? { get }
    func selectedEditCheckpointForDiscard() throws -> SelectedRecoveryRecord
    /// Performs an already-confirmed action (Discard and Dismiss are confirmed by the window first).
    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction, selected: SelectedRecoveryRecord?) throws
}

extension ShowDocument: EditCheckpointOfferProviding {
    var editCheckpointOfferPosition: (index: Int, total: Int)? { selectedEditCheckpointPosition }
    var editCheckpointOfferChoice: RecoveryChoicePresentation.Choice? { selectedEditCheckpointChoice }

    var editCheckpointOfferState: EditCheckpointOfferState? {
        guard let offer = status.editCheckpointOffer else { return nil }
        let choice: RecoveryChoicePresentation.Choice? = editCheckpointOfferChoice
        if let selectedOfferURL, choice?.record.recordID != selectedOfferURL.path { return .selectionChanged }
        if let candidate = selectedEditCheckpointCandidate {
            let mode = offer.mode(for: candidate, restoreInEffect: isEditCheckpointRestoreInEffect)
            let createdAt = candidate.record.createdAt
            if restoredOfferURLs.contains(candidate.url) { return .restored(createdAt: createdAt) }
            if !recoveryBaseVerified { return .unverified(createdAt: createdAt) }
            return switch mode {
            case .restore: .restore(createdAt: createdAt)
            case .copyOnlyWhileAnotherRestoreIsInEffect: .anotherSession(createdAt: createdAt)
            case .copyOnlyOlderRevision: .olderRevision(createdAt: createdAt)
            }
        }
        if let selectedOfferURL, let problem = offer.problems.first(where: { $0.url == selectedOfferURL }) {
            let newer: Int = if case .newerFormat = problem { 1 } else { 0 }
            return .unusable(damaged: 1 - newer, newerFormat: newer)
        }
        return offer.isEmpty ? nil : .selectionChanged
    }

    func selectedEditCheckpointForDiscard() throws -> SelectedRecoveryRecord {
        guard let offer = status.editCheckpointOffer else { throw CocoaError(.fileReadNoSuchFile) }
        if selectedEditCheckpointCandidate != nil {
            _ = try checkSelectedEditCheckpoint()
            guard let selectedOfferRecord else { throw CocoaError(.fileReadUnknown) }
            return selectedOfferRecord
        }
        guard let selectedOfferURL, offer.problems.contains(where: { $0.url == selectedOfferURL }),
              let selectedOfferRecord, selectedOfferRecord.url == selectedOfferURL,
              selectedOfferRecord.key == documentKey, selectedOfferRecord.kind == .offeredEditCheckpoint
        else { throw CocoaError(.fileReadNoSuchFile) }
        _ = try recovery.readSelectedRecord(selectedOfferRecord)
        return selectedOfferRecord
    }

    func performConfirmedEditCheckpointAction(_ action: EditCheckpointAction, selected: SelectedRecoveryRecord?) throws {
        switch action {
        case .restore: try restoreOfferedEditCheckpoint()
        case .openAsCopy: try openOfferedEditCheckpointAsCopy()
        case .discard:
            guard let selected else { throw CocoaError(.fileReadNoSuchFile) }
            try discardOfferedEditCheckpoint(selected)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting(editCheckpointProblemURLs)
        case .checkAgain: reselectEditCheckpointAfterChange()
        case .dismiss: hideEditCheckpointProblems()
        case .previous: try advanceEditCheckpointOffer(by: -1)
        case .next: try advanceEditCheckpointOffer(by: 1)
        }
    }
}
