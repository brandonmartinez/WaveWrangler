import Foundation

/// Close/Quit decision for one show (states-and-recovery §2.3). Pure wording + button set; the persistence
/// lane owns the mechanism (waiting for D4, attempting D2's save first, never closing silently while dirty).
public enum CloseDecision: Sendable, Equatable {
    /// D1 and read-only states.
    case closeImmediately
    /// D2: save first; close only after D1.
    case saveFirst
    /// D4: wait for the in-flight save, then decide again.
    case waitForSave
    case sheet(CloseSheet)
}

public enum CloseSheetButton: String, Sendable, Equatable {
    case save = "Save"
    case saveACopyElsewhere = "Save a Copy Elsewhere…"
    case saveMineAsACopy = "Save Mine as a Copy…"
    case cancel = "Cancel"
    case dontSave = "Don't Save"
}

public struct CloseSheet: Sendable, Equatable {
    public var message: String
    public var informative: String
    /// Default first; Escape = Cancel; ⌘⌫ = Don't Save.
    public var buttons: [CloseSheetButton]
}

extension CloseDecision {
    public init(state: DocumentSaveState, autosaveEnabled: Bool, showName: String, shortReason: String? = nil) {
        switch state {
        case .saved, .readOnlyNewerFormat, .readOnlyDamaged, .updateNeeded, .updateFailed, .readOnlyLocation,
             .recovered, .checking, .unknown:
            self = .closeImmediately
        case .edited where autosaveEnabled:
            self = .saveFirst
        case .saving:
            self = .waitForSave
        case .edited, .cancelled:
            self = .sheet(CloseSheet(
                message: "Do you want to save the changes you made to “\(showName)”?",
                informative: "Your changes will be lost if you don't save them.",
                buttons: [.save, .cancel, .dontSave]
            ))
        case .notConfirmed, .locationUnavailable, .diskFull, .failed:
            let reason = shortReason ?? Self.defaultReason(state)
            self = .sheet(CloseSheet(
                message: "“\(showName)” couldn't be saved: \(reason).",
                informative: "Save a copy somewhere else, or your changes will be lost. The last saved version hasn't been changed.",
                buttons: [.saveACopyElsewhere, .cancel, .dontSave]
            ))
        case .conflict:
            self = .sheet(CloseSheet(
                message: "“\(showName)” was changed somewhere else. Choose how to keep your changes before closing.",
                informative: "",
                buttons: [.saveMineAsACopy, .cancel, .dontSave]
            ))
        }
    }

    static func defaultReason(_ state: DocumentSaveState) -> String {
        switch state {
        case .notConfirmed: "the save couldn't be confirmed"
        case .locationUnavailable: "the folder can't be reached"
        case .diskFull(let volume): "“\(volume)” is full"
        case .failed(let reason): reason
        default: "an unknown problem"
        }
    }
}
