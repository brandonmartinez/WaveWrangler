import AppKit
import SwiftUI
import WWCore
import WWEpisodeSetup
import WWOrganizer

/// Connects the Setup content to the Workspace and Commands seams: the `SetupSourcesContent` factory,
/// `SourceCommandHandling` (File › Import Sources…, Source menu, Relink Source…, Edit › Delete/Move) and
/// the Setup items of the Episode and View menus. Called once at launch.
@MainActor
enum EpisodeSetupIntegration {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        SetupSourcesContent.makeView = { store, episodeID in
            AnyView(SetupHostView(store: store, episodeID: episodeID))
        }
        SourceCommands.handler = SetupSourceCommandHandler.shared
        SetupMenus.installIfNeeded()
    }
}

/// Hosts the Setup content with the app's in-app text size (CMD-20).
private struct SetupHostView: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    @Environment(\.wwTextSize) private var textSize

    var body: some View {
        EpisodeSetupContent(store: store, episodeID: episodeID, textScale: CGFloat(textSize.scale))
    }
}

/// "Download sources automatically" (Settings › Sources), read live from the app's settings.
@MainActor
final class AppSettingsDownloadPreference: @MainActor SourceDownloadPreference {
    static let shared = AppSettingsDownloadPreference()

    var downloadsAutomatically: Bool {
        get { AppSettings.shared.downloadSourcesAutomatically }
        set { AppSettings.shared.downloadSourcesAutomatically = newValue }
    }
}

/// `SourceCommandHandling` for the Commands lane's router. Acts on the Setup content in the command's
/// window; when Setup isn't shown, it switches the window to Setup first (never acting invisibly).
@MainActor
final class SetupSourceCommandHandler: SourceCommandHandling {
    static let shared = SetupSourceCommandHandler()

    private func controller(_ window: NSWindow?, _ episode: EpisodeID) -> EpisodeSetupViewController? {
        guard let controller = EpisodeSetupViewController.controller(for: window ?? NSApp.keyWindow),
              controller.model.episodeID == episode else { return nil }
        return controller
    }

    /// Shows Setup in `window`, then runs `body` once the Setup content is on screen.
    private func withSetup(_ window: NSWindow?, _ episode: EpisodeID, _ body: @escaping (EpisodeSetupViewController) -> Void) {
        if let controller = controller(window, episode) {
            body(controller)
            return
        }
        ShowWindowRegistry.state(for: window ?? NSApp.keyWindow)?.select(.setup)
        Task { @MainActor in
            for _ in 0..<20 {
                if let controller = self.controller(window, episode) {
                    body(controller)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func canImportSources(store: ShowDocumentStore, episode: EpisodeID) -> Bool {
        store.model.episode(episode) != nil
    }

    func importSources(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {
        withSetup(window, episode) { $0.model.beginImport() }
    }

    func canRelinkSource(store: ShowDocumentStore, episode: EpisodeID) -> Bool {
        guard let controller = SetupCommandProxy.shared.controller, controller.model.episodeID == episode else { return false }
        return controller.model.singleSelectedSource != nil
    }

    func relinkSource(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {
        guard let controller = controller(window, episode), let source = controller.model.singleSelectedSource else { return }
        controller.model.beginRelink(source.id)
    }

    func sourceMenuItems(store: ShowDocumentStore?, episode: EpisodeID?) -> [NSMenuItem] {
        SetupMenus.makeSourceMenuItems()
    }

    func deleteSelectionTitle(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String? {
        controller(window, episode)?.deleteTitle
    }

    func deleteSelection(store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {
        guard let controller = controller(window, episode), controller.deleteTitle != nil else { return }
        controller.delete(nil)
    }

    func moveSelectionTitle(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> String? {
        controller(window, episode)?.moveTitle(by: offset)
    }

    func canMoveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) -> Bool {
        controller(window, episode)?.canMove(by: offset) ?? false
    }

    func moveSelection(by offset: Int, store: ShowDocumentStore, episode: EpisodeID, window: NSWindow?) {
        guard let controller = controller(window, episode), controller.canMove(by: offset) else { return }
        controller.move(by: offset)
    }
}
