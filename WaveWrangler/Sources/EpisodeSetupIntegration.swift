import AppKit
import OSLog
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
        SetupReturnKey.install()
    }
}

/// Keeps keyboard focus with the table whose selection just changed. Selecting a row in the SwiftUI
/// Table can leave the show sidebar as first responder, so Return, arrows and Delete would act on the
/// sidebar instead of the row the user picked. Never takes focus from text editing.
@MainActor
enum SetupTableFocus {
    static func focus(_ identifier: String, in window: NSWindow?) {
        DispatchQueue.main.async {
            guard let window, window.attachedSheet == nil, let responder = window.firstResponder,
                  !(responder is NSText) else { return }
            guard let table = find(identifier, in: window.contentView) else {
                #if DEBUG
                SetupReturnKey.log.notice("Focus: no table \(identifier, privacy: .public)")
                #endif
                return
            }
            if let view = responder as? NSView, view === table || view.isDescendant(of: table) { return }
            let moved = window.makeFirstResponder(table)
            #if DEBUG
            SetupReturnKey.log.notice("Focus: \(identifier, privacy: .public) from \(String(describing: type(of: responder)), privacy: .public) moved \(moved)")
            #endif
        }
    }

    /// Gives a programmatic multi-selection the same keyboard anchor as a click on its first row, without
    /// changing the selected rows. This makes the next ↓ select the following imported source (#196).
    static func anchorSelection(_ identifier: String, in window: NSWindow?) {
        DispatchQueue.main.async {
            guard let window, let table = find(identifier, in: window.contentView),
                  !table.selectedRowIndexes.isEmpty else { return }
            // Extending the existing selection establishes AppKit's anchor without emitting the interim
            // single-row selection that a replace-then-extend sequence sends back through SwiftUI.
            table.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: true)
        }
    }

    /// After the width plan shows or hides columns, AppKit keeps a re-shown column's old width and
    /// doesn't re-fit, which can push Status past the table's edge (#129). Re-fit asynchronously (never
    /// inside a layout pass) when the visible columns overflow the table.
    ///
    /// Can't loop: it's triggered only by the container's width or column-tier changes, which
    /// `sizeToFit` doesn't change (it only resizes columns inside the table); it acts only while the
    /// columns overflow, which `sizeToFit` ends; and one pending fit per table at a time.
    static func fitColumns(_ identifier: String, in window: NSWindow?) {
        guard !pendingFits.contains(identifier) else { return }
        pendingFits.insert(identifier)
        DispatchQueue.main.async {
            defer { pendingFits.remove(identifier) }
            guard let window, let table = find(identifier, in: window.contentView),
                  let clip = table.enclosingScrollView?.contentView else { return }
            let widths = table.tableColumns.filter { !$0.isHidden }.map { Double($0.width) }
            let available = Double(clip.bounds.width)
            guard SetupColumnPlan.columnsOverflow(widths: widths, spacing: Double(table.intercellSpacing.width), available: available) else { return }
            table.sizeToFit()
            #if DEBUG
            SetupReturnKey.log.notice("Fit columns: \(identifier, privacy: .public) \(widths.reduce(0, +)) > \(available)")
            #endif
        }
    }

    private static var pendingFits: Set<String> = []

    static func find(_ identifier: String, in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.accessibilityIdentifier() == identifier { return table }
        for subview in view.subviews {
            if let table = find(identifier, in: subview) { return table }
        }
        return nil
    }
}

/// Return (or keypad Enter) in the Setup Sources or Speakers table moves to the details' first editable
/// field, opening them when collapsed (K08/K09, #104). An explicit AppKit handler, because the SwiftUI
/// Table doesn't deliver Return to `onKeyPress` or its primary action. It acts only when one of those two
/// tables is the first responder of a show window with no sheet, so Return keeps its meaning everywhere
/// else (default buttons, text fields, Import Review).
@MainActor
enum SetupReturnKey {
    static let tableIdentifiers: Set<String> = ["ww.setup.sources", "ww.setup.speakers"]
    private static var monitor: Any?
    #if DEBUG
    static let log = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "setup.keys")
    #endif

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil,
              let controller = EpisodeSetupViewController.controller(for: window) else { return false }
        let responder = window.firstResponder
        let inTable = isSetupTable(responder)
        #if DEBUG
        log.notice("Return: responder \(String(describing: responder.map { type(of: $0) }), privacy: .public) id \((responder as? NSView)?.accessibilityIdentifier() ?? "-", privacy: .public) handled \(inTable)")
        #endif
        guard inTable else { return false }
        controller.model.requestInspectorFocus()
        return true
    }

    /// Whether `responder` is (inside) the Sources or Speakers table: identified by accessibility
    /// identifier, or as a non-sidebar table in a show window hosting Setup (the show sidebar is the only
    /// other table there, and it is a source list).
    static func isSetupTable(_ responder: NSResponder?) -> Bool {
        if let table = responder as? NSTableView, table.style != .sourceList,
           table.selectionHighlightStyle != .sourceList,
           !table.accessibilityIdentifier().hasPrefix("ww.show.") {
            return true
        }
        var view = responder as? NSView
        var depth = 0
        while let current = view, depth < 4 {
            if tableIdentifiers.contains(current.accessibilityIdentifier()) { return true }
            view = current.superview
            depth += 1
        }
        return false
    }
}

/// Hosts the Setup content with the app's in-app text size (CMD-20).
private struct SetupHostView: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    @Environment(\.wwTextSize) private var textSize

    var body: some View {
        EpisodeSetupContent(store: store, episodeID: episodeID, textScale: CGFloat(textSize.scale))
            .id(episodeID)
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
