import Foundation
import Observation
import WWCore
import WWPersistence

/// Observable per-document persistence status for the UI lane (show window status line, VoiceOver).
///
/// `saveStatus.state` maps one-to-one onto the library UI lane's `DocumentSaveState` names. It is never
/// "saved" without an independently verified read-back.
@MainActor
@Observable
final class DocumentStatusModel {
    private(set) var saveStatus = DocumentSaveStatus(state: .clean(revision: nil))
    /// C2b edit checkpoints offered since this show was opened ("Restore unsaved changes", "based on an older
    /// revision", or records that can't be used). `nil` when there is nothing to offer or report.
    private(set) var editCheckpointOffer: EditCheckpointOffer<ShowDocumentModel>?
    /// Non-nil when the document is read-only (e.g. recovered copy); edits and saves are refused.
    private(set) var readOnlyReason: String?
    /// ST-11: an automatic retry of a failed save is pending (the popover then says it will try again).
    private(set) var retryingAutomatically = false
    /// ST-16: after Save a Copy Elsewhere…, "You're now editing “<copy>” in <folder>. The original at <folder> wasn't
    /// changed." Shown in the message bar until dismissed.
    private(set) var copyNotice: String?
    /// #159: non-nil while an older-format show waits for, runs or failed its update (read-only until it publishes).
    private(set) var formatUpdate: FormatUpdateState?

    var accessibilityDescription: String { saveStatus.accessibilityDescription }

    func set(_ state: DocumentSaveState) {
        saveStatus.state = state
    }

    func setProviderConflicts(_ report: ProviderConflictReport) {
        saveStatus.providerConflicts = report
    }

    func setEditCheckpointOffer(_ value: EditCheckpointOffer<ShowDocumentModel>?) {
        editCheckpointOffer = value
    }

    func setRetryingAutomatically(_ value: Bool) {
        if retryingAutomatically != value { retryingAutomatically = value }
    }

    func setCopyNotice(_ notice: String?) {
        copyNotice = notice
    }

    func setFormatUpdate(_ value: FormatUpdateState?) {
        if formatUpdate != value { formatUpdate = value }
    }

    func setReadOnly(_ reason: String?) {
        readOnlyReason = reason
    }
}
