import AppKit
import WWOrganizer
import WWPersistence

/// Makes the persistence lane's per-document status (`ShowDocument.status`, a `DocumentStatusModel`) available
/// to the show window through `DocumentStatusProviding`. Mapping only; "Saved" appears only for states
/// persistence verified on disk (`isVerifiedOnDisk`).
extension ShowDocument: DocumentStatusProviding {
    var saveStatus: WWOrganizer.DocumentSaveStatus {
        ShowDocumentStatusMapping.map(
            status.saveStatus.state,
            readOnlyReason: status.readOnlyReason,
            autosaveEnabled: AutosavePolicyController.shared.isEnabled,
            folderDisplayName: fileURL?.deletingLastPathComponent().lastPathComponent,
            providerConflictVersions: status.saveStatus.providerConflicts.unresolvedVersionCount,
            retryingAutomatically: status.retryingAutomatically,
            formatUpdate: status.formatUpdate
        )
    }
}
