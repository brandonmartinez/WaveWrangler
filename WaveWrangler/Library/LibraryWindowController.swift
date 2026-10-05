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
        guard let window = shared.window else { return }
        // Keep a restored/autosaved frame on screen and within the visible height.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, !visible.contains(window.frame) {
            var frame = window.frame
            frame.size.height = min(frame.height, visible.height)
            frame.size.width = min(frame.width, visible.width)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        LaunchFixtures.placeForTesting(window)
        window.makeKeyAndOrderFront(nil)
    }

    private init(store: LibraryUIStore) {
        state = LibraryWindowState(store: store)
        let hosting = NSHostingController(rootView: LibraryView(state: state).wwAppEnvironment())
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        hosting.view.setAccessibilityLabel("Library")
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
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("WaveWranglerLibraryWindow")
        state.window = window
        store.undoManagerProvider = { [weak window] in window?.undoManager }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        guard identifier == restorationIdentifier else {
            completionHandler(nil, nil)
            return
        }
        completionHandler(shared.window, nil)
    }
}
