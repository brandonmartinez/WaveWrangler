import WWOrganizer
import WWPersistence

/// Maps the persistence lane's per-document state onto the design lane's save-status vocabulary. Pure, so the
/// unhosted unit tests compile it (see `ShowDocumentStatusMappingTests`).
enum ShowDocumentStatusMapping {
    static func map(
        _ state: WWPersistence.DocumentSaveState,
        readOnlyReason: String?,
        autosaveEnabled: Bool,
        folderDisplayName: String?,
        providerConflictVersions: Int = 0,
        retryingAutomatically: Bool = false,
        formatUpdate: FormatUpdateState? = nil
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
        let final: WWOrganizer.DocumentSaveState = if let formatUpdate {
            // #159: until the update publishes, the show is read-only whatever the persistence state says (D14/D15).
            switch formatUpdate {
            case .needed: .updateNeeded
            // No actions while the update runs: Update… would be a dead button.
            case .updating: .updatingFormat
            case .failed: .updateFailed
            case .interrupted(let reason): .readOnly(reason: reason)
            }
        } else if let readOnlyReason, !mapped.isReadOnly {
            .readOnly(reason: readOnlyReason)
        } else {
            mapped
        }
        return DocumentSaveStatus(
            state: final,
            autosaveEnabled: autosaveEnabled,
            // ST-11: only while ShowDocument really has a retry pending.
            retryingAutomatically: retryingAutomatically && autosaveEnabled && state.isAutomaticallyRetryable,
            hasUnsavedChanges: formatUpdate == nil && state.hasUnsavedWork,
            providerConflictVersions: providerConflictVersions
        )
    }
}
