import Foundation

/// The unpublished edit checkpoint (contracts C2b) found when a show was opened, as the show window presents it
/// in its message bar (`ww.show.messageBar`, #84). Pure: no clocks, no I/O.
public enum EditCheckpointOfferState: Sendable, Equatable {
    /// Based on exactly the version on disk: offer to restore as unsaved changes (dirty, never "Saved").
    case restore(createdAt: Date)
    /// Based on another (older) version: open only as a separate untitled copy; never merged or published.
    case olderRevision(createdAt: Date)
    /// Records that can't be used (damaged/unreadable, or written by a newer WaveWrangler). Reported, kept,
    /// never applied.
    case unusable(damaged: Int, newerFormat: Int)
}

public enum EditCheckpointAction: String, Sendable, Equatable, CaseIterable {
    case restore = "Restore Unsaved Changes"
    case openAsCopy = "Open as Separate Copy"
    case discard = "Discard…"
    case showInFinder = "Show in Finder"
    case dismiss = "Dismiss…"
}

public struct EditCheckpointOfferPresentation: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var symbolName: String
    public var actions: [EditCheckpointAction]

    /// VoiceOver (ST-03): the bar's label is its heading; its value is the visible body text.
    public var accessibilityValue: String { body }
    /// Announced once when the bar first appears (states §7, "Recovered … on open"); never moves focus.
    public var announcement: String { heading }

    public init(_ state: EditCheckpointOfferState, showName: String, formatTime: (Date) -> String = SaveStatusPresentation.defaultTime) {
        switch state {
        case let .restore(createdAt):
            heading = "Restore unsaved changes from \(formatTime(createdAt))?"
            body = "WaveWrangler kept changes to “\(showName)” on this Mac that were never saved. "
                + "If you restore them, they appear in this window as unsaved changes that you can save or undo. "
                + "The saved show hasn't been changed."
            symbolName = "clock.arrow.circlepath"
            actions = [.restore, .discard]
        case let .olderRevision(createdAt):
            heading = "Unsaved changes based on an older revision"
            body = "WaveWrangler kept changes to “\(showName)” from \(formatTime(createdAt)) on this Mac that were never saved, "
                + "but the show has been saved since then. So that neither version is overwritten, they can only be opened "
                + "as a separate untitled copy, which you can compare with this show."
            symbolName = "exclamationmark.triangle"
            actions = [.openAsCopy, .discard]
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
            actions = [.showInFinder, .dismiss]
        }
    }

    /// Confirmation for the bar's destructive or dismissing actions (Dismiss/Discard need an explicit
    /// confirmation). Cancel is never the destructive default (A13).
    public static func confirmation(
        for action: EditCheckpointAction,
        state: EditCheckpointOfferState,
        formatTime: (Date) -> String = SaveStatusPresentation.defaultTime
    ) -> (message: String, informative: String, button: String)? {
        switch (action, state) {
        case let (.discard, .restore(createdAt)), let (.discard, .olderRevision(createdAt)):
            ("Discard unsaved changes from \(formatTime(createdAt))?",
             "These changes were never saved. If you discard them, they can't be restored.",
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
