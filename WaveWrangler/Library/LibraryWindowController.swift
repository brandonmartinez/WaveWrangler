import AppKit
import SwiftUI

/// The single Library window (IA §2: app window, not a document; Window › Library ⇧⌘L).
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration {
    static let restorationIdentifier = NSUserInterfaceItemIdentifier("ww.library.window")
    private static var instance: LibraryWindowController?

    let state: LibraryWindowState

    static var shared: LibraryWindowController {
        if let instance { return instance }
        let controller = LibraryWindowController(store: .shared)
        instance = controller
        return controller
    }

    static var isOpen: Bool { instance?.window?.isVisible == true }

    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
    }

    private init(store: LibraryStore) {
        state = LibraryWindowState(store: store)
        let hosting = NSHostingController(rootView: LibraryView(state: state).wwAppEnvironment())
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Library"
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1_000, height: 600))
        window.contentMinSize = NSSize(width: 720, height: 400)
        window.identifier = Self.restorationIdentifier
        window.setAccessibilityIdentifier("ww.library.window")
        window.isRestorable = true
        window.restorationClass = LibraryWindowController.self
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("WaveWranglerLibraryWindow")
        state.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Library edits use the Library window's own undo history (IA-03).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        state.store.undoManager
    }

    nonisolated static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard identifier == restorationIdentifier else {
                completionHandler(nil, nil)
                return
            }
            completionHandler(shared.window, nil)
        }
    }
}
