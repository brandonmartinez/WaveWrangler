import AppKit
import OSLog
import SwiftUI
import WWCore

@MainActor
final class EpisodeWindowController: NSWindowController {
    static let episodeStateKey = "ww.episodeID"
    private static let showStateKey = "ww.showID"
    private static let restorationLog = Logger(
        subsystem: "com.brandonmartinez.wavewrangler", category: "episode.restoration")
    private(set) var state: ShowWindowState

    convenience init(store: ShowDocumentStore, episodeID: EpisodeID) {
        self.init(state: ShowWindowState(store: store, episodeID: episodeID))
    }

    init(state: ShowWindowState) {
        self.state = state
        let hosting = NSHostingController(rootView: ShowWorkspaceView(state: state))
        hosting.sizingOptions = []
        let window = EpisodeEditorWindow(contentViewController: hosting)
        window.originatingState = state
        window.identifier = NSUserInterfaceItemIdentifier(
            "ww.episode.\(state.store.model.show.id).\(UUID().uuidString)")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 760, height: 440)
        #if DEBUG
        let minimum = UserDefaults.standard.bool(forKey: "WWUITestMinimumShowWindow")
        window.setContentSize(NSSize(width: minimum ? 760 : 1030, height: minimum ? 440 : 520))
        #else
        window.setContentSize(NSSize(width: 1030, height: 520))
        #endif
        window.tabbingMode = .disallowed
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func synchronizeWindowTitleWithDocumentName() {
        state.updateSubtitle()
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(state.store.model.show.id.description, forKey: Self.showStateKey)
        coder.encode(state.boundEpisodeID?.description, forKey: Self.episodeStateKey)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard let id = Self.restoredEpisode(from: coder, in: state.store.model),
              id != state.boundEpisodeID else { return }
        state.reviewWindowDidClose()
        state = ShowWindowState(store: state.store, episodeID: id)
        (window as? EpisodeEditorWindow)?.originatingState = state
        if let hosting = window?.contentViewController as? NSHostingController<ShowWorkspaceView> {
            hosting.rootView = ShowWorkspaceView(state: state)
        }
    }

    static func restoredEpisode(from coder: NSCoder, in model: ShowDocumentModel) -> EpisodeID? {
        if coder.containsValue(forKey: showStateKey) {
            guard let value = coder.decodeObject(of: NSString.self, forKey: showStateKey) as String?,
                  ShowID(uuidString: value) == model.show.id else {
                restorationLog.warning("Ignored episode restoration for a different or invalid show identity.")
                return nil
            }
        }
        guard coder.containsValue(forKey: episodeStateKey),
              let value = coder.decodeObject(of: NSString.self, forKey: episodeStateKey) as String?,
              let id = EpisodeID(uuidString: value), model.episode(id) != nil else {
            restorationLog.warning("Ignored episode restoration for an episode absent from the loaded show.")
            return nil
        }
        return id
    }
}

@MainActor
private final class EpisodeEditorWindow: NSWindow {
    weak var originatingState: ShowWindowState?

    override func performClose(_ sender: Any?) {
        guard let document = originatingState?.store.document,
              document.mixerTransactions.needsBarrier else { super.performClose(sender); return }
        Task {
            do { try await document.mixerTransactions.barrier { self.performCloseCaptured(sender) } }
            catch { document.mixerTransactions.report(error) }
        }
    }

    override func close() {
        if originatingState?.mixerPresentation.isClosed == true { super.close(); return }
        guard let document = originatingState?.store.document,
              document.mixerTransactions.needsBarrier else { super.close(); return }
        Task {
            do { try await document.mixerTransactions.barrier { self.closeCaptured() } }
            catch { document.mixerTransactions.report(error) }
        }
    }

    private func performCloseCaptured(_ sender: Any?) { super.performClose(sender) }
    private func closeCaptured() { super.close() }
}
