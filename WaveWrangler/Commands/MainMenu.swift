import AppKit
import WWOrganizer

/// Programmatic main menu (commands-keyboard §2). Standard items target the responder chain so
/// NSDocument/NSDocumentController provide native Open/Open Recent/Save/Save As/Duplicate/Revert/Close and
/// Undo/Redo (with the action name in the title); WaveWrangler items target `CommandRouter`. Every item is
/// always present; unavailable ones are dimmed, never hidden (CMD-02). Shortcuts come from `MenuCommand`,
/// whose register is unit-tested (A-06).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(fileMenu()))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        main.addItem(submenuItem(episodeMenu()))
        main.addItem(submenuItem(sourceMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        let help = helpMenu()
        main.addItem(submenuItem(help))
        NSApplication.shared.windowsMenu = window
        NSApplication.shared.helpMenu = help
        return main
    }

    // MARK: - Builders

    private static var router: CommandRouter { CommandRouter.shared }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Standard responder-chain item.
    private static func standard(_ title: String, _ action: Selector?, _ command: MenuCommand? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let command { apply(command.shortcut, to: item) }
        return item
    }

    /// WaveWrangler item routed to `CommandRouter`.
    private static func routed(_ title: String, _ action: Selector, _ command: MenuCommand? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = router
        item.tag = tag
        if let command { apply(command.shortcut, to: item) }
        return item
    }

    static func apply(_ shortcut: KeyShortcut, to item: NSMenuItem) {
        item.keyEquivalent = shortcut.key
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let name = "WaveWrangler"
        let menu = NSMenu(title: name)
        menu.addItem(standard("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Settings…", #selector(CommandRouter.showSettings(_:)), .settings))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenuItem(services))
        NSApplication.shared.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(standard("Hide \(name)", #selector(NSApplication.hide(_:)), .hide))
        menu.addItem(standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), .hideOthers))
        menu.addItem(standard("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(standard("Quit \(name)", #selector(NSApplication.terminate(_:)), .quit))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(routed("New Show…", #selector(CommandRouter.newShow(_:)), .newShow))
        menu.addItem(routed("New Episode", #selector(CommandRouter.newEpisode(_:)), .newEpisode))
        menu.addItem(routed("New Window", #selector(CommandRouter.newWindowForShow(_:))))
        menu.addItem(routed("Open…", #selector(CommandRouter.openDocument(_:)), .open))
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(standard("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenuItem(recent))
        menu.addItem(.separator())
        menu.addItem(standard("Close", #selector(NSWindow.performClose(_:)), .close))
        menu.addItem(routed("Close Show", #selector(CommandRouter.closeShow(_:)), .closeShow))
        menu.addItem(routed("Save", #selector(CommandRouter.saveShow(_:)), .save))
        menu.addItem(routed("Duplicate", #selector(CommandRouter.duplicateShow(_:)), .duplicate))
        menu.addItem(routed("Save As…", #selector(CommandRouter.saveShowAs(_:)), .saveAs))
        menu.addItem(standard("Rename…", #selector(NSDocument.rename(_:))))
        menu.addItem(standard("Move To…", #selector(NSDocument.move(_:))))
        let revert = NSMenu(title: "Revert To")
        revert.addItem(standard("Last Saved Version", #selector(NSDocument.revertToSaved(_:))))
        revert.addItem(standard("Browse Saved Versions…", #selector(NSDocument.browseVersions(_:))))
        menu.addItem(submenuItem(revert))
        menu.addItem(.separator())
        menu.addItem(routed("Import Sources…", #selector(CommandRouter.importSources(_:)), .importSources))
        menu.addItem(routed("Relink Source…", #selector(CommandRouter.relinkSource(_:))))
        menu.addItem(.separator())
        menu.addItem(submenuItem(libraryMenu()))
        menu.addItem(routed("Show in Finder", #selector(CommandRouter.showInFinder(_:))))
        return menu
    }

    /// File › Library ▸ — acts on the Library window's selection.
    private static func libraryMenu() -> NSMenu {
        let menu = NSMenu(title: "Library")
        menu.addItem(routed("Open Show", #selector(CommandRouter.libraryOpenShow(_:))))
        menu.addItem(routed("Open in New Window", #selector(CommandRouter.libraryOpenInNewWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("New Collection…", #selector(CommandRouter.newCollection(_:))))
        menu.addItem(routed("Rename Collection", #selector(CommandRouter.renameCollection(_:))))
        menu.addItem(routed("Delete Collection…", #selector(CommandRouter.deleteCollection(_:))))
        menu.addItem(.separator())
        let add = NSMenu(title: "Add to Collection")
        add.delegate = CollectionMenuDelegate.shared
        let addItem = submenuItem(add)
        addItem.identifier = NSUserInterfaceItemIdentifier("ww.menu.addToCollection")
        menu.addItem(addItem)
        menu.addItem(routed("Remove from Collection", #selector(CommandRouter.removeFromCollection(_:))))
        menu.addItem(routed("Remove from Library…", #selector(CommandRouter.removeFromLibrary(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Locate Show…", #selector(CommandRouter.locateShow(_:))))
        menu.addItem(routed("Grant Access…", #selector(CommandRouter.grantAccess(_:))))
        menu.addItem(routed("Try Again", #selector(CommandRouter.tryAgain(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Rebuild Library Index…", #selector(CommandRouter.rebuildLibraryIndex(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(standard("Undo", Selector(("undo:")), .undo))
        menu.addItem(standard("Redo", Selector(("redo:")), .redo))
        menu.addItem(.separator())
        menu.addItem(standard("Cut", #selector(NSText.cut(_:)), .cut))
        menu.addItem(standard("Copy", #selector(NSText.copy(_:)), .copy))
        menu.addItem(standard("Paste", #selector(NSText.paste(_:)), .paste))
        menu.addItem(routed("Delete", #selector(CommandRouter.deleteSelection(_:)), .delete))
        menu.addItem(standard("Select All", #selector(NSText.selectAll(_:)), .selectAll))
        menu.addItem(.separator())
        menu.addItem(routed("Move Up", #selector(CommandRouter.moveUp(_:)), .moveUp))
        menu.addItem(routed("Move Down", #selector(CommandRouter.moveDown(_:)), .moveDown))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = standard("Find…", #selector(NSResponder.performTextFinderAction(_:)), .find)
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        find.addItem(findItem)
        menu.addItem(submenuItem(find))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(standard("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), .toggleToolbar))
        menu.addItem(standard("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Hide Sidebar", #selector(CommandRouter.toggleWWSidebar(_:)), .toggleSidebar))
        menu.addItem(routed("Hide Inspector", #selector(CommandRouter.toggleInspector(_:)), .toggleInspector))
        menu.addItem(routed("Show Save Status", #selector(CommandRouter.showSaveStatus(_:))))
        menu.addItem(.separator())
        let commands: [MenuCommand] = [.destinationSetup, .destinationAlignment, .destinationReview, .destinationExport]
        for (index, destination) in ShowDestination.allCases.enumerated() {
            menu.addItem(routed(destination.title, #selector(CommandRouter.selectDestination(_:)), commands[index], tag: index))
        }
        menu.addItem(.separator())
        let text = NSMenu(title: "Text Size")
        text.addItem(routed("Bigger", #selector(CommandRouter.textBigger(_:)), .textBigger))
        text.addItem(routed("Smaller", #selector(CommandRouter.textSmaller(_:)), .textSmaller))
        text.addItem(routed("Actual Size", #selector(CommandRouter.textActualSize(_:)), .textActual))
        menu.addItem(submenuItem(text))
        menu.addItem(.separator())
        menu.addItem(standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), .fullScreen))
        return menu
    }

    private static func episodeMenu() -> NSMenu {
        let menu = NSMenu(title: "Episode")
        menu.addItem(routed("Episode Info", #selector(CommandRouter.episodeInfo(_:)), .episodeInfo))
        menu.addItem(routed("Rename Episode", #selector(CommandRouter.renameEpisode(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Delete Episode…", #selector(CommandRouter.deleteEpisode(_:))))
        return menu
    }

    private static func sourceMenu() -> NSMenu {
        let menu = NSMenu(title: "Source")
        menu.delegate = SourceMenuDelegate.shared
        SourceMenuDelegate.shared.rebuild(menu)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize))
        menu.addItem(standard("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(routed("Library", #selector(CommandRouter.showLibrary(_:)), .library))
        menu.addItem(.separator())
        menu.addItem(standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(standard("WaveWrangler Help", #selector(NSApplication.showHelp(_:)), .help))
        return menu
    }
}

/// Builds File › Library › Add to Collection ▸ from the current collections when it opens.
@MainActor
final class CollectionMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = CollectionMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for collection in LibraryStore.shared.library.collections {
            let item = NSMenuItem(title: collection.name, action: #selector(CommandRouter.addToCollection(_:)), keyEquivalent: "")
            item.target = CommandRouter.shared
            item.representedObject = collection.id.rawValue
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title: "New Collection…", action: #selector(CommandRouter.newCollectionWithSelection(_:)), keyEquivalent: "")
        new.target = CommandRouter.shared
        menu.addItem(new)
    }
}

/// The Source menu: Relink Source… plus whatever the source UI lane contributes.
@MainActor
final class SourceMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = SourceMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = CommandRouter.shared.activeShowState
        let extra = SourceCommands.handler.sourceMenuItems(store: state?.store, episode: state?.selectedEpisodeID)
        for item in extra { menu.addItem(item) }
        if !extra.isEmpty { menu.addItem(.separator()) }
        let relink = NSMenuItem(title: "Relink Source…", action: #selector(CommandRouter.relinkSource(_:)), keyEquivalent: "")
        relink.target = CommandRouter.shared
        menu.addItem(relink)
    }
}
