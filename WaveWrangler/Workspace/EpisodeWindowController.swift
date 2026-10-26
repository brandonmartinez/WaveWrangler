import AppKit
import SwiftUI
import WWCore

@MainActor
final class EpisodeWindowController: NSWindowController {
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
        coder.encode(state.boundEpisodeID?.description, forKey: "ww.episodeID")
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard let value = coder.decodeObject(of: NSString.self, forKey: "ww.episodeID") as String?,
              let id = EpisodeID(uuidString: value), id != state.boundEpisodeID else { return }
        state = ShowWindowState(store: state.store, episodeID: id)
        (window as? EpisodeEditorWindow)?.originatingState = state
        if let hosting = window?.contentViewController as? NSHostingController<ShowWorkspaceView> {
            hosting.rootView = ShowWorkspaceView(state: state)
        }
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
