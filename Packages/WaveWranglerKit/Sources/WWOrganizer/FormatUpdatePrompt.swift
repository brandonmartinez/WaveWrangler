import Foundation

/// D14 "Update needed" (states-and-recovery §2, accessibility-acceptance T21): the sheet shown when a show in an older
/// supported format is opened, before anything can be edited.
public struct FormatUpdatePrompt: Equatable, Sendable {
    public enum Button: String, CaseIterable, Sendable {
        /// The default (Return): updates the file through the C5 migration.
        case update = "Update"
        /// Shows the older show upgraded in memory only; nothing is written.
        case openReadOnly = "Open Read-Only"
        /// Escape: closes the show without changing anything.
        case cancel = "Cancel"
    }

    /// The migration keeps its non-overwriting backup in this Mac's recovery store, not in the show's folder.
    public static let body = "WaveWrangler needs to update this show before you can edit it. The original is kept unchanged as a backup on this Mac."

    public let title: String
    public let body: String
    /// In order: the first is the default button.
    public let buttons: [Button]

    public init(showName: String) {
        title = "Update “\(showName)” to the current format?"
        body = Self.body
        buttons = [.update, .openReadOnly, .cancel]
    }
}
