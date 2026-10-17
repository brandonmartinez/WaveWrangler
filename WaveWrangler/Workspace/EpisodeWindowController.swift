import AppKit
import SwiftUI
import WWCore

@MainActor
final class EpisodeWindowController: NSWindowController {
    private(set) var state: ShowWindowState

    init(store: ShowDocumentStore, episodeID: EpisodeID) {
        state = ShowWindowState(store: store, episodeID: episodeID)
        let hosting = NSHostingController(rootView: ShowWorkspaceView(state: state))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
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
        if let hosting = window?.contentViewController as? NSHostingController<ShowWorkspaceView> {
            hosting.rootView = ShowWorkspaceView(state: state)
        }
    }
}
