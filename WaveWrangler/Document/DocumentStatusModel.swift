import Foundation
import Observation
import WWPersistence

/// Observable per-document persistence status for the UI lane (show window status line, VoiceOver).
///
/// `saveStatus.state` maps one-to-one onto the library UI lane's `DocumentSaveState` names. It is never
/// "saved" without an independently verified read-back.
@MainActor
@Observable
final class DocumentStatusModel {
    private(set) var saveStatus = DocumentSaveStatus(state: .clean(revision: nil))
    /// A C2b edit checkpoint found when opening, with how it relates to the on-disk publication.
    private(set) var pendingEditCheckpoint: (record: EditCheckpointRecord, relation: EditCheckpointRecord.Relation)?
    /// Non-nil when the document is read-only (e.g. recovered copy); edits and saves are refused.
    private(set) var readOnlyReason: String?

    var accessibilityDescription: String { saveStatus.accessibilityDescription }

    func set(_ state: DocumentSaveState) {
        saveStatus.state = state
    }

    func setProviderConflicts(_ report: ProviderConflictReport) {
        saveStatus.providerConflicts = report
    }

    func setPendingEditCheckpoint(_ value: (record: EditCheckpointRecord, relation: EditCheckpointRecord.Relation)?) {
        pendingEditCheckpoint = value
    }

    func setReadOnly(_ reason: String?) {
        readOnlyReason = reason
    }
}
