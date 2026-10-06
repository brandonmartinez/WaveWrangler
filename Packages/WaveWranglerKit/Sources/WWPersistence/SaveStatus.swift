import Foundation
import WWCore

/// Honest per-document persistence status (C3 acknowledgement states). Every state has distinct accessible
/// text; none is conveyed by colour alone, and no state implies provider sync.
///
/// Mirrors the library UI lane's `DocumentSaveState` names so it can be mapped one-to-one once that module
/// lands; persistence never shows "saved" without an independently verified read-back.
public enum DocumentSaveState: Sendable, Equatable {
    /// Opened or created and not yet changed. `revision` is `nil` for a never-saved document.
    case clean(revision: Int?)
    /// Edited (unsaved). `crashProtected` is false while autosave is OFF.
    case edited(autosaveEnabled: Bool)
    case saving
    /// Saved on this Mac: verified coherent disk truth at `revision`.
    case saved(revision: Int, at: Date)
    /// Verified on disk, but a dependant acknowledgement (library/index) or post-publication step did not complete.
    case savedFollowUpIncomplete(revision: Int, at: Date)
    /// Save failed; the prior revision is unchanged on disk and the document stays dirty.
    case saveFailed(retainedRevision: Int?, kind: WriteFailureKind, message: String)
    /// Another revision is on disk; nothing was overwritten and this candidate is preserved on this Mac.
    case conflict(onDiskRevision: Int?, missing: Bool)
    /// Publication may have happened but was not verified. Reopen to verify.
    case acknowledgementUncertain(message: String)
    /// A C2b unpublished edit checkpoint (not a save) protects the unsaved edits on this Mac.
    case recoveryCheckpoint(at: Date)
    /// An automatic save was skipped because autosave is OFF; edits remain open and unsaved.
    case autosaveSkipped
    /// Written by a newer WaveWrangler; edit/save/downsave refused.
    case readOnlyNewerFormat(found: Int, supported: Int)
    /// Showing a recovered checkpoint read-only; save it as a new copy to keep it.
    case recoveredReadOnly(revision: Int)
    case cancelled

    /// Short, accessible status text.
    public var title: String {
        switch self {
        case .clean(nil): "Not saved yet"
        case .clean: "Saved"
        case let .edited(enabled): enabled ? "Edited (unsaved)" : "Edited (unsaved) — autosave is off"
        case .saving: "Saving…"
        case let .saved(revision, at): "Saved on this Mac — revision \(revision) at \(at.formatted(date: .omitted, time: .standard))"
        case let .savedFollowUpIncomplete(revision, _): "Saved on this Mac — revision \(revision); library not yet updated"
        case let .saveFailed(retained, _, _): "Save failed — revision \(retained.map(String.init) ?? "on disk") retained"
        case let .conflict(_, missing): missing ? "Conflict — the document was moved or deleted" : "Conflict — another revision is on disk"
        case .acknowledgementUncertain: "Save may have completed — reopen to verify"
        case let .recoveryCheckpoint(at): "Unsaved changes protected on this Mac (checkpoint \(at.formatted(date: .omitted, time: .standard))) — not saved"
        case .autosaveSkipped: "Not saved — autosave is off"
        case .readOnlyNewerFormat: "Read-only — newer format"
        case let .recoveredReadOnly(revision): "Recovered revision \(revision) — read-only"
        case .cancelled: "Saving cancelled — changes not saved"
        }
    }

    /// True only for states backed by an independently verified read-back of this document's bytes.
    public var isVerifiedOnDisk: Bool {
        switch self {
        case .saved, .savedFollowUpIncomplete, .clean(.some): true
        default: false
        }
    }

    /// ST-11: whether this failed save is retried automatically while autosave is on. D5 (acknowledgement uncertain)
    /// and the D7–D9 failures are; a cancelled save (D10), a conflict (D6) and every non-failure state are not.
    public var isAutomaticallyRetryable: Bool {
        switch self {
        case .acknowledgementUncertain: true
        case let .saveFailed(_, kind, _): kind != .cancelled
        default: false
        }
    }

    /// Whether unsaved work may exist (drives "unsaved" indicators; never cleared by skipped/failed saves).
    public var hasUnsavedWork: Bool {
        switch self {
        case .edited, .saveFailed, .conflict, .acknowledgementUncertain, .recoveryCheckpoint, .autosaveSkipped, .cancelled, .saving: true
        case .clean, .saved, .savedFollowUpIncomplete, .readOnlyNewerFormat, .recoveredReadOnly: false
        }
    }

    public static func from(_ error: PublicationError, retainedRevision: Int?) -> DocumentSaveState {
        switch error {
        case let .readOnly(reason): .saveFailed(retainedRevision: retainedRevision, kind: .permissionDenied, message: reason)
        case let .invalidCandidate(error): .saveFailed(retainedRevision: retainedRevision, kind: .other, message: error.errorDescription ?? "\(error)")
        case let .conflict(conflict): .conflict(onDiskRevision: conflict.onDisk?.revision, missing: conflict.onDisk == nil)
        case let .failed(_, kind, _): .saveFailed(retainedRevision: retainedRevision, kind: kind, message: error.errorDescription ?? "")
        case .cancelled: .cancelled
        case let .acknowledgementUncertain(message): .acknowledgementUncertain(message: message)
        }
    }
}

/// Provider sync state is reported separately and stays `unknown` unless a provider tells us otherwise.
public enum ProviderSyncState: String, Sendable, Equatable {
    case unknown
    case notApplicable
}

public struct DocumentSaveStatus: Sendable, Equatable {
    public var state: DocumentSaveState
    public var providerSync: ProviderSyncState
    public var providerConflicts: ProviderConflictReport

    public init(state: DocumentSaveState, providerSync: ProviderSyncState = .unknown, providerConflicts: ProviderConflictReport = .none) {
        self.state = state
        self.providerSync = providerSync
        self.providerConflicts = providerConflicts
    }

    /// Full accessible description, e.g. for VoiceOver.
    public var accessibilityDescription: String {
        var parts = [state.title]
        if providerSync == .unknown { parts.append("Provider sync: unknown") }
        if providerConflicts.hasUnresolvedConflicts {
            parts.append("\(providerConflicts.unresolvedVersionCount) unresolved provider conflict version(s)")
        }
        return parts.joined(separator: ". ")
    }
}
