import AppKit
import WWCore

/// Seam for source commands the source UI lane implements (File › Import Sources…, Source › Relink
/// Source…, and the Source menu items). The Commands layer only routes; it never touches source files.
@MainActor
protocol SourceCommandHandling: AnyObject {
    func canImportSources(store: ShowDocumentStore, episode: EpisodeID) -> Bool
    func importSources(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?)
    func canRelinkSource(store: ShowDocumentStore, episode: EpisodeID) -> Bool
    func relinkSource(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?)
    /// Extra items for the Source menu (rebuilt when the menu opens).
    func sourceMenuItems(store: ShowDocumentStore?, episode: EpisodeID?) -> [NSMenuItem]
    // Optional (default implementations below): Delete / Move for the Sources and Speakers tables.
    func deleteSelectionTitle(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String?
    func deleteSelection(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?)
    func moveSelectionTitle(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String?
    func canMoveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> Bool
    func moveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?)
}

/// Edit › Delete and Move Up/Down for the Sources/Speakers tables. The source lane returns a menu title
/// (e.g. "Remove Source from Episode…", "Move Source Up") only while its own table has keyboard focus and
/// a selection; `nil` means "not mine". Defaults: not handled.
extension SourceCommandHandling {
    func deleteSelectionTitle(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String? { nil }
    func deleteSelection(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {}
    func moveSelectionTitle(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String? { nil }
    func canMoveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> Bool { false }
    func moveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {}
}

enum SourceCommands {
    @MainActor static var handler: SourceCommandHandling = PlaceholderSourceCommands()
}

/// Until the source UI lands: Import explains that it isn't available yet; Relink stays dimmed (no source
/// can be selected), with the reason shown in the Setup content.
@MainActor
final class PlaceholderSourceCommands: SourceCommandHandling {
    func canImportSources(store: ShowDocumentStore, episode: EpisodeID) -> Bool { true }

    func importSources(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {
        Task {
            await Dialogs.inform(
                in: window,
                message: "Importing sources isn't available in this version yet",
                informative: "WaveWrangler hasn't opened, read or changed any files."
            )
        }
    }

    func canRelinkSource(store: ShowDocumentStore, episode: EpisodeID) -> Bool { false }

    func relinkSource(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {}

    func sourceMenuItems(store: ShowDocumentStore?, episode: EpisodeID?) -> [NSMenuItem] { [] }
}
