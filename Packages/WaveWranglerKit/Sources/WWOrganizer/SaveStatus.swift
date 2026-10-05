import Foundation

/// Document save state reported by the persistence lane (states-and-recovery §2, D1–D16), plus the
/// honest pre-observation states required by ST-01. Only `.saved` means coherent disk truth.
public enum DocumentSaveState: Sendable, Equatable {
    /// ST-01: not observed yet.
    case checking
    /// ST-01: observation finished without an answer.
    case unknown(reason: String)
    /// D1. Latest edits confirmed on disk as one complete version.
    case saved(at: Date, folderDisplayName: String?)
    /// D2 (autosave On) / D3 (autosave Off). Edits exist and no save is in progress.
    case edited
    /// D4.
    case saving(cancellable: Bool)
    /// D5. Write finished but coherence/acknowledgement is uncertain.
    case notConfirmed
    /// D6.
    case conflict(changedAt: Date?)
    /// D7.
    case locationUnavailable
    /// D8.
    case diskFull(volumeName: String)
    /// D9. `reason` is plain language, e.g. "WaveWrangler doesn't have permission to save in this folder".
    case failed(reason: String)
    /// D10.
    case cancelled
    /// D11.
    case recovered(incompleteSaveAt: Date?, openedVersionAt: Date?)
    /// D12.
    case readOnlyNewerFormat
    /// D13.
    case readOnlyDamaged
    /// D14. The update sheet is shown on open; the window stays read-only until the user chooses.
    case updateNeeded
    /// D15.
    case updateFailed
    /// D16.
    case readOnlyLocation
}

/// One observation of a document's save status.
public struct DocumentSaveStatus: Sendable, Equatable {
    public var state: DocumentSaveState
    /// Whether the app autosaves this document (Settings › General › Save changes automatically).
    public var autosaveEnabled: Bool
    /// ST-11: a failed automatic save will be retried automatically.
    public var retryingAutomatically: Bool
    /// Whether the user has edits that are not coherently on disk. Only D1 may clear this (ST-10).
    public var hasUnsavedChanges: Bool

    public init(state: DocumentSaveState, autosaveEnabled: Bool, retryingAutomatically: Bool = false, hasUnsavedChanges: Bool? = nil) {
        self.state = state
        self.autosaveEnabled = autosaveEnabled
        self.retryingAutomatically = retryingAutomatically
        self.hasUnsavedChanges = hasUnsavedChanges ?? state.impliesUnsavedChanges
    }
}

extension DocumentSaveState {
    /// Dirty column of states-and-recovery §2. `.checking`/`.unknown` are treated as not confirmed saved
    /// by the presentation but carry no dirty claim on their own.
    public var impliesUnsavedChanges: Bool {
        switch self {
        case .edited, .saving, .notConfirmed, .conflict, .locationUnavailable, .diskFull, .failed, .cancelled: true
        case .checking, .unknown, .saved, .recovered, .readOnlyNewerFormat, .readOnlyDamaged, .updateNeeded,
             .updateFailed, .readOnlyLocation: false
        }
    }

    public var isReadOnly: Bool {
        switch self {
        case .readOnlyNewerFormat, .readOnlyDamaged, .updateNeeded, .updateFailed, .readOnlyLocation: true
        default: false
        }
    }

    /// ST-14: D12 also refuses Duplicate and Save As (no down-save).
    public var allowsDuplicateOrSaveAs: Bool { self != .readOnlyNewerFormat }

    /// ST-10: only D1 is coherent saved truth.
    public var isCoherentlySaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

/// Visual tint (ST-02); always paired with text and symbol shape, never the only signal.
public enum StatusTint: Sendable, Equatable {
    case none
    case attention
    case failed
}

public enum SaveStatusAction: String, Sendable, Equatable, CaseIterable {
    case showInFinder = "Show in Finder"
    case saveNow = "Save Now"
    case autosaveSettings = "Autosave Settings…"
    case cancelSave = "Cancel Save"
    case checkAgain = "Check Again"
    case saveACopy = "Save a Copy…"
    case resolve = "Resolve…"
    case tryAgain = "Try Again"
    case saveACopyElsewhere = "Save a Copy Elsewhere…"
    case details = "Details"
    case keepThisVersion = "Keep This Version"
    case showKeptFiles = "Show Kept Files in Finder"
    case closeShow = "Close Show"
    case revertToEarlierVersion = "Revert To an Earlier Version…"
    case showDetails = "Show Details"
    case duplicate = "Duplicate…"
}

/// Persistent message bar content (IA §6, ST-05: never time-boxed).
public struct MessageBarContent: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var actions: [SaveStatusAction]
}

/// Exact user-facing presentation of a save status (A-02). Pure: no clocks, no I/O.
public struct SaveStatusPresentation: Sendable, Equatable {
    public var itemText: String
    /// `nil` means an inline indeterminate spinner (D4, checking).
    public var symbolName: String?
    public var tint: StatusTint
    public var popoverText: String
    public var actions: [SaveStatusAction]
    public var showsEditedSuffix: Bool
    /// Close-button / Window-menu dot: only with Autosave Off and unsaved changes (A4).
    public var showsDirtyDot: Bool
    public var isReadOnly: Bool
    public var messageBar: MessageBarContent?
    public var accessibilityLabel: String { "Save status" }
    public var accessibilityValue: String
    public var accessibilityHint: String { "Shows details and actions." }

    public init(_ status: DocumentSaveStatus, showName: String, formatTime: (Date) -> String = SaveStatusPresentation.defaultTime) {
        let dirty = status.hasUnsavedChanges
        let dot = dirty && !status.autosaveEnabled
        let retry = status.retryingAutomatically && status.autosaveEnabled ? " WaveWrangler will try again automatically." : ""
        var message: MessageBarContent?
        var suffix = dirty
        let text: String
        let symbol: String?
        var tint = StatusTint.none
        var popover: String
        var actions: [SaveStatusAction]

        switch status.state {
        case .checking:
            text = "Checking…"
            symbol = nil
            popover = "WaveWrangler is checking whether “\(showName)” is saved."
            actions = []
        case .unknown(let reason):
            text = "Unknown"
            symbol = "questionmark.circle"
            popover = "WaveWrangler can't confirm whether “\(showName)” is saved: \(reason)."
            actions = [.saveNow]
        case .saved(let at, let folder):
            text = "Saved"
            symbol = "checkmark.circle"
            let place = folder.map { " in \($0)" } ?? ""
            popover = "Saved at \(formatTime(at)) to “\(showName)”\(place). WaveWrangler saved this Mac's copy. If this folder syncs, your cloud service uploads it separately."
            actions = [.showInFinder]
            suffix = false
        case .edited:
            if status.autosaveEnabled {
                text = "Edited"
                popover = "You have changes that haven't been saved yet. WaveWrangler saves automatically; you can also choose File › Save (⌘S)."
                actions = [.saveNow]
            } else {
                text = "Not saved"
                popover = "Autosave is off. Your changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing."
                actions = [.saveNow, .autosaveSettings]
            }
            symbol = "pencil.circle"
        case .saving(let cancellable):
            text = "Saving…"
            symbol = nil
            popover = "Saving your changes…"
            actions = cancellable ? [.cancelSave] : []
        case .notConfirmed:
            text = "Not confirmed"
            symbol = "questionmark.circle"
            tint = .attention
            popover = "WaveWrangler wrote your changes but couldn't confirm the saved show is complete. Your changes are still open and still count as unsaved. The previous saved version is kept." + retry
            actions = [.checkAgain, .saveACopy]
        case .conflict:
            text = "Conflict"
            symbol = "arrow.triangle.branch"
            tint = .attention
            popover = "“\(showName)” was changed somewhere else (another Mac or app) since you opened it. WaveWrangler hasn't overwritten either version."
            actions = [.resolve]
        case .locationUnavailable:
            text = "Can't reach"
            symbol = "icloud.slash"
            tint = .attention
            popover = "WaveWrangler can't reach the folder where this show is saved. Your changes are still open in this window, and the last saved version hasn't been changed. WaveWrangler will try again when the folder is available." + retry
            actions = [.tryAgain, .saveACopyElsewhere]
        case .diskFull(let volume):
            text = "Not saved"
            symbol = "xmark.octagon"
            tint = .failed
            popover = "Couldn't save because “\(volume)” is full. Your changes are still open, and the last saved version hasn't been changed. Free up space, then choose Try Again." + retry
            actions = [.tryAgain, .saveACopyElsewhere]
        case .failed(let reason):
            text = "Not saved"
            symbol = "xmark.octagon"
            tint = .failed
            popover = "Couldn't save: \(reason). Your changes are still open, and the last saved version hasn't been changed." + retry
            actions = [.tryAgain, .saveACopyElsewhere, .details]
        case .cancelled:
            text = "Not saved"
            symbol = "pencil.circle"
            popover = "Save cancelled. Your changes are still open; the last saved version hasn't been changed."
            actions = [.saveNow]
        case .recovered(let incomplete, let opened):
            text = "Recovered"
            symbol = "clock.arrow.circlepath"
            let incompleteText = incomplete.map(formatTime) ?? "an unknown time"
            let openedText = opened.map(formatTime) ?? "an unknown time"
            popover = "The most recent save of this show (\(incompleteText)) didn't finish, so WaveWrangler opened the version saved at \(openedText). The incomplete save wasn't used and has been kept aside."
            actions = [.keepThisVersion, .showKeptFiles]
            message = MessageBarContent(heading: "Opened the last complete version", body: popover, actions: actions)
        case .readOnlyNewerFormat:
            text = "Read-only"
            symbol = "lock.fill"
            popover = "“\(showName)” was saved by a newer version of WaveWrangler. You can look at it, but editing and saving are turned off so its newer information isn't lost."
            actions = [.closeShow, .showInFinder]
            message = MessageBarContent(heading: "This show needs a newer WaveWrangler", body: popover, actions: actions)
            suffix = false
        case .readOnlyDamaged:
            text = "Read-only"
            symbol = "exclamationmark.lock"
            tint = .attention
            popover = "WaveWrangler could only partly read “\(showName)”. It opened what it could, read-only, and hasn't changed the file."
            actions = [.revertToEarlierVersion, .showInFinder]
            message = MessageBarContent(heading: "This show is damaged", body: popover, actions: actions)
            suffix = false
        case .updateNeeded:
            text = "Read-only"
            symbol = "lock.fill"
            popover = "WaveWrangler needs to update this show before you can edit it. The original is kept unchanged as a backup next to it."
            actions = []
            suffix = false
        case .updateFailed:
            text = "Read-only"
            symbol = "xmark.octagon"
            tint = .failed
            popover = "The original is unchanged. You can view it read-only."
            actions = [.tryAgain, .showDetails]
            message = MessageBarContent(heading: "Couldn't update this show", body: popover, actions: actions)
            suffix = false
        case .readOnlyLocation:
            text = "Read-only"
            symbol = "lock.fill"
            popover = "You can view this show but WaveWrangler can't save in its folder. Use File › Duplicate to save a copy somewhere you can write."
            actions = [.duplicate]
            suffix = false
        }

        itemText = text
        symbolName = symbol
        self.tint = tint
        popoverText = popover
        self.actions = actions
        showsEditedSuffix = suffix
        showsDirtyDot = dot && !status.state.isReadOnly
        isReadOnly = status.state.isReadOnly
        messageBar = message
        accessibilityValue = "\(text). \(Self.firstSentence(of: popover))"
    }

    /// VoiceOver value = item text + first sentence of the popover (states §2).
    static func firstSentence(of text: String) -> String {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "“" { depth += 1 }
            if character == "”" { depth -= 1 }
            if character == ".", depth == 0 {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    return String(text[...index])
                }
            }
            index = text.index(after: index)
        }
        return text
    }

    public static func defaultTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Announcement for state changes (states §7). `explicitSave` is true after ⌘S.
    public static func announcement(for state: DocumentSaveState, showName: String, explicitSave: Bool) -> String? {
        switch state {
        case .saved: explicitSave ? "Saved" : nil
        case .notConfirmed: "Couldn't save “\(showName)”. The save couldn't be confirmed."
        case .locationUnavailable: "Couldn't save “\(showName)”. The folder can't be reached."
        case .diskFull(let volume): "Couldn't save “\(showName)”. “\(volume)” is full."
        case .failed(let reason): "Couldn't save “\(showName)”. \(reason)."
        case .conflict: "“\(showName)” was changed somewhere else. Your changes are kept."
        default: nil
        }
    }
}
