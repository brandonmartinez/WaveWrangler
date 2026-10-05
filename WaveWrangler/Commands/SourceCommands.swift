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
