import Foundation

/// #159 (D14/D15): an older-format show (schema 1) is shown upgraded in memory and stays read-only until the C5
/// migration has published its update. Pure, so the unhosted unit tests compile it (see `FormatUpdateTests`).
enum FormatUpdateState: Equatable, Sendable {
    /// D14: waiting for the user to update (the sheet, or Open Read-Only).
    case needed
    /// The migration is running (off the main thread).
    case updating
    /// D15: the update failed and the original file was verified unchanged afterwards.
    case failed(detail: String)
    /// The file on disk is neither the original nor a valid update of this show (another writer changed it): the
    /// window stays read-only and says so, without claiming the original is unchanged.
    case interrupted(reason: String)
}

/// Guards for a show whose format update hasn't completed. Every refusal keeps the original file untouched.
enum FormatUpdatePolicy {
    /// No edit is accepted until the update has published: the in-memory upgrade is for viewing only.
    static func allowsEdits(_ state: FormatUpdateState?) -> Bool {
        state == nil
    }

    /// Refuses any save that would write the show's own file, or make another file this document's revision (Save,
    /// Save As, autosave in place). Writes to other locations that the document doesn't adopt (File › Duplicate,
    /// Save To) stay allowed: they create separate current-format files and never touch the original.
    static func allowsSave(_ state: FormatUpdateState?, adoptsPublication: Bool, toOwnFile: Bool) -> Bool {
        state == nil || (!adoptsPublication && !toOwnFile)
    }

    /// Update (D14) and Try Again (D15) start a migration; nothing starts while one runs or after an interruption.
    static func allowsUpdateAttempt(_ state: FormatUpdateState?) -> Bool {
        switch state {
        case .needed, .failed: true
        case .updating, .interrupted, nil: false
        }
    }
}

/// Where the D14 sheet could appear: a window of the show, as AppKit reports it right now.
struct FormatUpdatePromptWindow: Equatable, Sendable {
    var isVisible: Bool
    var isMiniaturized: Bool
    /// False for a tab that isn't the selected tab of its window (it isn't on screen). True for an untabbed window.
    var isSelectedTab: Bool

    /// Only a window the user can see gets the sheet; anywhere else it would be lost or appear unseen.
    var canShowPrompt: Bool { isVisible && !isMiniaturized && isSelectedTab }
}

extension FormatUpdatePolicy {
    /// The D14 sheet is asked once per open (or per Update… from the status item) and only while the update is still
    /// needed. It's consumed only when it's actually shown on a window the user can see; otherwise it stays pending
    /// and is asked again when a window of the show becomes key (tab selected, un-minimized) or is shown.
    static func shouldPresentPrompt(pending: Bool, state: FormatUpdateState?, window: FormatUpdatePromptWindow?) -> Bool {
        guard pending, state == .needed, let window else { return false }
        return window.canShowPrompt
    }
}

/// What the file on disk shows after an update attempt, read back independently of the migration's own result.
enum FormatUpdateOutcome: Equatable {
    /// A valid current-format revision of this show is on disk: adopt it (even if the attempt reported an error after
    /// publishing, e.g. a failed acknowledgement).
    case updated
    /// Exactly the original bytes are still on disk (D15: "The original is unchanged").
    case unchanged(detail: String)
    /// Something else is on disk, or it couldn't be read: never claim the original is unchanged.
    case changedElsewhere

    static func classify(errorDetail: String?, original: Data, onDiskNow: Data?, onDiskIsCurrentFormatOfThisShow: Bool) -> FormatUpdateOutcome {
        guard let onDiskNow else { return .changedElsewhere }
        if onDiskNow != original, onDiskIsCurrentFormatOfThisShow { return .updated }
        if onDiskNow == original {
            return .unchanged(detail: errorDetail ?? "The update didn't replace the file.")
        }
        return .changedElsewhere
    }
}
