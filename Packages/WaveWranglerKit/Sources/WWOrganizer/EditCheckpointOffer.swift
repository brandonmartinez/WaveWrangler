import Foundation

/// The unpublished edit checkpoint (contracts C2b) found when a show was opened, as the show window presents it
/// in its message bar (`ww.show.messageBar`, #84). Pure: no clocks, no I/O.
public enum EditCheckpointOfferState: Sendable, Equatable {
    /// Based on exactly the version on disk: offer to restore as unsaved changes (dirty, never "Saved").
    case restore(createdAt: Date)
    /// Restored in memory; its device-local recovery copy remains offerable after any save.
    case restored(createdAt: Date)
    /// The file's current base cannot be verified, so in-place restore is refused.
    case unverified(createdAt: Date)
    /// Based on another (older) version: open only as a separate untitled copy; never merged or published.
    case olderRevision(createdAt: Date)
    /// Another session's unsaved changes, while a restore is already in effect in this window: open only as a
    /// separate untitled copy, so a second restore never replaces the first.
    case anotherSession(createdAt: Date)
    /// Records that can't be used (damaged/unreadable, or written by a newer WaveWrangler). Reported, kept,
    /// never applied.
    case unusable(damaged: Int, newerFormat: Int)
}

public enum EditCheckpointAction: String, Sendable, Equatable, CaseIterable {
    case restore = "Restore Unsaved Changes"
    case openAsCopy = "Open as Separate Copy"
    case discard = "Discard…"
    case showInFinder = "Show in Finder"
    case checkAgain = "Check Again"
    case dismiss = "Dismiss…"
}

public struct EditCheckpointOfferPresentation: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var symbolName: String
    public var actions: [EditCheckpointAction]

    /// Announced once when the bar first appears (states §7, "Recovered … on open"); never moves focus.
    public var announcement: String { heading }

    public init(_ state: EditCheckpointOfferState, showName: String, formatTime: (Date) -> String = SaveStatusPresentation.defaultTime) {
        switch state {
        case let .restore(createdAt):
            heading = "Restore unsaved changes from \(formatTime(createdAt))?"
            body = "WaveWrangler kept a recovery copy of changes to “\(showName)” on this Mac. "
                + "If you restore them, they appear in this window as unsaved changes that you can save or undo. "
                + "Restoring does not remove this recovery copy."
            symbolName = "clock.arrow.circlepath"
            actions = [.restore, .discard]
        case let .restored(createdAt):
            heading = "Recovery copy kept from \(formatTime(createdAt))"
            body = "WaveWrangler kept this recovery copy of “\(showName)” on this Mac, even after restoring or saving. "
                + "Review it as a separate copy or choose Discard to remove only this record."
            symbolName = "clock.arrow.circlepath"
            actions = [.openAsCopy, .discard]
        case let .olderRevision(createdAt):
            heading = "Unsaved changes based on an older revision"
            body = "WaveWrangler kept a recovery copy of changes to “\(showName)” from \(formatTime(createdAt)) on this Mac, "
                + "but the show's on-disk revision differs from its base. So neither version is overwritten, it can only be opened "
                + "as a separate untitled copy, which you can compare with this show."
            symbolName = "exclamationmark.triangle"
            actions = [.openAsCopy, .discard]
        case let .anotherSession(createdAt):
            heading = "More unsaved changes from \(formatTime(createdAt))"
            body = "WaveWrangler kept another recovery copy of changes to “\(showName)” from \(formatTime(createdAt)) on this Mac. "
                + "You've already restored unsaved changes in this window, so these can only be opened as a separate untitled copy. "
                + "That way neither set is lost."
            symbolName = "exclamationmark.triangle"
            actions = [.openAsCopy, .discard]
        case let .unverified(createdAt):
            heading = "Recovery copy kept — file could not be checked"
            body = "WaveWrangler couldn't check whether the recovery copy from \(formatTime(createdAt)) matches “\(showName)” on disk. "
                + "It has been kept on this Mac. Check Again or open it as a separate untitled copy; in-place restore is unavailable."
            symbolName = "exclamationmark.triangle"
            actions = [.checkAgain, .openAsCopy, .discard]
        case let .unusable(damaged, newerFormat):
            heading = "Unsaved changes couldn't be restored"
            let reason = switch (damaged > 0, newerFormat > 0) {
            case (true, true): "Some couldn't be read and some were kept by a newer version of WaveWrangler."
            case (false, true): "They were kept by a newer version of WaveWrangler."
            default: "They couldn't be read."
            }
            body = "WaveWrangler found unsaved changes to “\(showName)” on this Mac that it can't use. \(reason) "
                + "They weren't applied, and they've been kept on this Mac."
            symbolName = "exclamationmark.triangle"
            actions = [.showInFinder, .discard, .dismiss]
        }
        body += " Recovery copies use local storage without a limit until you discard them individually."
    }

    /// Confirmation for the bar's destructive or dismissing actions (Dismiss/Discard need an explicit
    /// confirmation). Cancel is never the destructive default (A13).
    public static func confirmation(
        for action: EditCheckpointAction,
        state: EditCheckpointOfferState,
        formatTime: (Date) -> String = SaveStatusPresentation.defaultTime
    ) -> (message: String, informative: String, button: String)? {
        switch (action, state) {
        case let (.discard, .restore(createdAt)), let (.discard, .restored(createdAt)),
             let (.discard, .olderRevision(createdAt)), let (.discard, .anotherSession(createdAt)),
             let (.discard, .unverified(createdAt)):
            ("Discard unsaved changes from \(formatTime(createdAt))?",
             "This recovery copy stays on this Mac until you discard it. If you discard it, it can't be restored.",
             "Discard")
        case (.discard, .unusable):
            ("Discard this unusable recovery record?",
             "Only the selected record will be removed. It can't be restored afterward; other recovery records stay on this Mac.",
             "Discard")
        case (.dismiss, .unusable):
            ("Hide this message?",
             "The unsaved changes that couldn't be restored stay on this Mac. WaveWrangler reports them again the next time you open this show.",
             "Hide")
        default:
            nil
        }
    }
}
