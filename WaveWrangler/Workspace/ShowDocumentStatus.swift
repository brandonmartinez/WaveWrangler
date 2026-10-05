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
            providerConflictVersions: status.saveStatus.providerConflicts.unresolvedVersionCount
        )
    }
}

enum ShowDocumentStatusMapping {
    static func map(
        _ state: WWPersistence.DocumentSaveState,
        readOnlyReason: String?,
        autosaveEnabled: Bool,
        folderDisplayName: String?,
        providerConflictVersions: Int = 0
    ) -> WWOrganizer.DocumentSaveStatus {
        let mapped: WWOrganizer.DocumentSaveState = switch state {
        case .clean(nil):
            .unknown(reason: "it hasn't been saved yet")
        case .clean:
            .saved(at: nil, folderDisplayName: folderDisplayName)
        case .edited, .recoveryCheckpoint, .autosaveSkipped:
            .edited
        case .saving:
            .saving(cancellable: false)
        case .saved(_, let at), .savedFollowUpIncomplete(_, let at):
            .saved(at: at, folderDisplayName: folderDisplayName)
        case .saveFailed(_, let kind, let message):
            switch kind {
            case .diskFull: .diskFull(volumeName: folderDisplayName ?? "the disk")
            case .unavailable: .locationUnavailable
            case .cancelled: .cancelled
            case .permissionDenied: .failed(reason: "WaveWrangler doesn't have permission to save in this folder")
            case .other: .failed(reason: message.isEmpty ? "an unknown problem" : message)
            @unknown default: .failed(reason: message.isEmpty ? "an unknown problem" : message)
            }
        case .conflict:
            .conflict(changedAt: nil)
        case .acknowledgementUncertain:
            .notConfirmed
        case .readOnlyNewerFormat:
            .readOnlyNewerFormat
        case .recoveredReadOnly:
            .readOnly(reason: "it's a recovered earlier version")
        case .cancelled:
            .cancelled
        @unknown default:
            .unknown(reason: "the save state isn't recognized")
        }
        let final: WWOrganizer.DocumentSaveState = if let readOnlyReason, !mapped.isReadOnly {
            .readOnly(reason: readOnlyReason)
        } else {
            mapped
        }
        return DocumentSaveStatus(
            state: final,
            autosaveEnabled: autosaveEnabled,
            hasUnsavedChanges: state.hasUnsavedWork,
            providerConflictVersions: providerConflictVersions
        )
    }
}
