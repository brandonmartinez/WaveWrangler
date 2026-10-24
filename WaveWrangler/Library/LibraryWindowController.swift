import AppKit
import SwiftUI

/// The single Library window (IA §2: app window, not a document; Window › Library ⇧⌘L).
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowRestoration {
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

    static func show(document: ShowDocument) {
        show()
        shared.state.sidebarSelection = .shows
        shared.state.browse(document)
    }

    static func documentDidClose(_ document: ShowDocument) {
        instance?.state.documentDidClose(document)
    }

    private init(store: LibraryUIStore) {
        state = LibraryWindowState(store: store)
        let hosting = NSHostingController(rootView: LibraryView(state: state).wwAppEnvironment())
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        hosting.view.setAccessibilityLabel("Library")
        let window = LibraryWindow(contentViewController: hosting)
        window.state = state
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Library"
        window.subtitle = AppBuildIdentity.current.subtitle()
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1_000, height: 600))
        // Wide enough for the three columns' minimum widths (180 + 320 + 240) and dividers (#109).
        window.contentMinSize = NSSize(width: 760, height: 400)
        window.identifier = Self.restorationIdentifier
        window.setAccessibilityIdentifier("ww.library.window")
        window.isRestorable = true
        window.restorationClass = LibraryWindowController.self
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.setFrameAutosaveName("WaveWranglerLibraryWindow")
        state.window = window
        store.undoManagerProvider = { [weak window] in window?.collectionsUndoManager }
        #if DEBUG
        SidebarSwitchBenchmark.startIfRequested(state: state)
        #endif
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

private final class LibraryWindow: NSWindow {
    weak var state: LibraryWindowState?
    let collectionsUndoManager = UndoManager()

    // NSWindow caches its delegate's manager; this window must follow the focused show and column.
    override var undoManager: UndoManager? {
        if state?.focusedRegion == .episodes { return state?.selectedShow?.undoManager }
        return collectionsUndoManager
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("undo:")):
            item.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        case Selector(("redo:")):
            item.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        default:
            return super.validateMenuItem(item)
        }
    }
}
