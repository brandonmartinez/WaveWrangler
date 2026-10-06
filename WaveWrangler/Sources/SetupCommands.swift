import AppKit
import SwiftUI
import WWCore
import WWEpisodeSetup

/// Menu actions for the Setup destination. Menu items use these selectors with a nil target, so they reach
/// the focused `EpisodeSetupViewController` through the responder chain (CMD-01).
@MainActor
@objc protocol SetupCommandActions {
    func importSources(_ sender: Any?)
    func relinkSource(_ sender: Any?)
    func grantSourceAccess(_ sender: Any?)
    func reviewChangedFile(_ sender: Any?)
    func newRecorderGroup(_ sender: Any?)
    func renameRecorderGroup(_ sender: Any?)
    func newSpeaker(_ sender: Any?)
    func renameSpeaker(_ sender: Any?)
    func deleteSpeaker(_ sender: Any?)
    func assignToRecorderGroup(_ sender: Any?)
    func assignSpeaker(_ sender: Any?)
    func setPrimaryForSpeaker(_ sender: Any?)
    func setEpoch(_ sender: Any?)
    func startNewEpoch(_ sender: Any?)
    func setChannel(_ sender: Any?)
    func useAsPrimary(_ sender: Any?)
    func useAsBackup(_ sender: Any?)
    func downloadSource(_ sender: Any?)
    func pauseSourceDownload(_ sender: Any?)
    func resumeSourceDownload(_ sender: Any?)
    func cancelSourceDownload(_ sender: Any?)
    func retrySourceDownload(_ sender: Any?)
    func showSourceInFinder(_ sender: Any?)
    func removeSourceFromEpisode(_ sender: Any?)
    func toggleSourcesNeedingAttention(_ sender: Any?)
    func toggleSetupDetails(_ sender: Any?)
    func sortSourcesBy(_ sender: Any?)
    func moveItemUp(_ sender: Any?)
    func moveItemDown(_ sender: Any?)
}

/// Command target for one window's Setup content. Menu items (via `SetupCommandProxy`) and the Commands
/// lane's `SourceCommandHandling` reach the Setup model through it. It holds no views: the Setup SwiftUI
/// is hosted directly in the workspace (no nested hosting view, so table clicks and keys work normally).
final class EpisodeSetupViewController: NSObject, SetupCommandActions, NSMenuItemValidation {
    let model: EpisodeSetupModel
    private(set) weak var window: NSWindow?

    init(model: EpisodeSetupModel) {
        self.model = model
        super.init()
    }

    /// Called when the Setup content appears in (or moves to) a window.
    func attach(to window: NSWindow?) {
        guard let window else { return }
        self.window = window
        model.window = { [weak window] in window }
        Self.register(self, for: window)
    }

    // MARK: Registry (one Setup controller per show window)

    private struct Weak { weak var controller: EpisodeSetupViewController? }
    private static var registry: [ObjectIdentifier: Weak] = [:]

    static func register(_ controller: EpisodeSetupViewController, for window: NSWindow) {
        registry = registry.filter { $0.value.controller != nil }
        registry[ObjectIdentifier(window)] = Weak(controller: controller)
    }

    /// The Setup controller hosted in `window`, if its Setup content is on screen.
    static func controller(for window: NSWindow?) -> EpisodeSetupViewController? {
        guard let window, let controller = registry[ObjectIdentifier(window)]?.controller,
              controller.window === window, controller.model.isOnScreen else { return nil }
        return controller
    }

    /// Whether the Sources or Speakers table has keyboard focus (Edit › Delete / Move act on the focused list).
    var hasKeyboardFocus: Bool { model.focusedTable != nil }

    // MARK: Edit › Delete / Move (SourceCommandHandling hooks)

    var deleteTitle: String? {
        guard hasKeyboardFocus else { return nil }
        if model.focusedTable == .speakers { return singleSpeaker == nil ? nil : "Delete Speaker…" }
        if !sources.isEmpty { return sources.count == 1 ? "Remove Source from Episode…" : "Remove \(sources.count) Sources from Episode…" }
        if groupID != nil { return "Delete Recorder Group…" }
        return nil
    }

    func moveTitle(by offset: Int) -> String? {
        guard hasKeyboardFocus else { return nil }
        let direction = offset < 0 ? "Up" : "Down"
        if model.focusedTable == .speakers { return singleSpeaker == nil ? nil : "Move Speaker \(direction)" }
        return singleSource == nil ? nil : "Move Source \(direction)"
    }

    func canMove(by offset: Int) -> Bool {
        guard let episode = model.episode else { return false }
        if model.focusedTable == .speakers {
            guard let id = singleSpeaker, let index = episode.speakerAssignments.firstIndex(where: { $0.speakerID == id }) else { return false }
            return episode.speakerAssignments.indices.contains(index + offset)
        }
        guard let id = singleSource, let source = episode.source(id) else { return false }
        let peers = episode.sources(inRecorderGroup: source.placement.recorderGroupID).map(\.id)
        guard let index = peers.firstIndex(of: id) else { return false }
        return peers.indices.contains(index + offset)
    }

    func move(by offset: Int) {
        model.moveSelected(offset < 0 ? .up : .down)
    }

    // MARK: Command targets

    private var sources: [SourceID] { model.selectedSourceIDs }
    private var singleSource: SourceID? { model.singleSelectedSource?.id }
    private var singleSpeaker: SpeakerID? {
        model.speakerSelection.count == 1 ? model.speakerSelection.first : nil
    }
    private var groupID: RecorderGroupID? {
        if case let .some(.some(id)) = model.selectedGroupID { return id }
        return nil
    }

    func importSources(_ sender: Any?) { model.beginImport() }
    func relinkSource(_ sender: Any?) { if let id = singleSource { model.beginRelink(id) } }
    func grantSourceAccess(_ sender: Any?) { if let id = singleSource { model.beginRelink(id, mode: .grantAccess) } }
    func reviewChangedFile(_ sender: Any?) { if let id = singleSource { model.beginRelink(id, mode: .review) } }

    func newRecorderGroup(_ sender: Any?) {
        model.sheet = .name(NameSheetContext(kind: .newGroup, initial: "", assigning: (sender as? NSMenuItem)?.representedObject == nil ? [] : sources))
    }

    func renameRecorderGroup(_ sender: Any?) {
        guard let groupID else { return }
        model.sheet = .name(NameSheetContext(kind: .renameGroup, initial: model.groupName(groupID), groupID: groupID))
    }

    func newSpeaker(_ sender: Any?) {
        model.sheet = .name(NameSheetContext(kind: .newSpeaker, initial: "", assigning: (sender as? NSMenuItem)?.representedObject == nil ? [] : sources))
    }

    func renameSpeaker(_ sender: Any?) {
        guard let id = singleSpeaker else { return }
        model.sheet = .name(NameSheetContext(kind: .renameSpeaker, initial: model.speakerName(id), speakerID: id))
    }

    func deleteSpeaker(_ sender: Any?) {
        if let id = singleSpeaker { model.confirmation = .deleteSpeaker(id) }
    }

    func assignToRecorderGroup(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? SetupMenus.GroupChoice else { return }
        model.assign(sources, toGroup: choice.id)
    }

    func assignSpeaker(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? SetupMenus.SpeakerChoice else { return }
        model.assignSpeaker(choice.id, to: sources)
    }

    func setPrimaryForSpeaker(_ sender: Any?) {
        guard let id = singleSpeaker, let choice = (sender as? NSMenuItem)?.representedObject as? SetupMenus.PrimaryChoice else { return }
        model.setPrimary(choice.channel, for: id)
    }

    func setEpoch(_ sender: Any?) {
        guard !sources.isEmpty else { return }
        model.sheet = .number(NumberSheetContext(kind: .epoch, sourceIDs: sources, initial: singleSource.flatMap { model.episode?.epochNumber(of: $0) }))
    }

    func startNewEpoch(_ sender: Any?) { model.startNewEpoch() }

    func setChannel(_ sender: Any?) {
        guard !sources.isEmpty else { return }
        model.sheet = .number(NumberSheetContext(kind: .channel, sourceIDs: sources, initial: singleSource.flatMap { model.episode?.statedChannel(of: $0) }.map { $0 + 1 }))
    }

    func useAsPrimary(_ sender: Any?) { if let ref = model.selectedReference { model.useAsPrimary(ref) } }
    func useAsBackup(_ sender: Any?) { if let ref = model.selectedReference { model.useAsBackup(ref) } }
    func downloadSource(_ sender: Any?) { transfer(.download) }
    func pauseSourceDownload(_ sender: Any?) { transfer(.pause) }
    func resumeSourceDownload(_ sender: Any?) { transfer(.resume) }
    func cancelSourceDownload(_ sender: Any?) { transfer(.cancel) }
    func retrySourceDownload(_ sender: Any?) { transfer(.retry) }

    private func transfer(_ action: TransferAction) {
        for id in sources where model.availableActions(for: id).contains(action) {
            model.perform(action, on: id)
        }
    }

    func showSourceInFinder(_ sender: Any?) { if let id = singleSource { model.revealInFinder(id) } }

    func removeSourceFromEpisode(_ sender: Any?) {
        if !sources.isEmpty { model.confirmation = .removeSources(sources) }
    }

    @objc func delete(_ sender: Any?) {
        if model.focusedTable == .speakers || (model.focusedTable == nil && model.inspectorFollowsSpeakers) {
            deleteSpeaker(sender)
        } else {
            model.requestDeleteFromSources()
        }
    }

    func toggleSourcesNeedingAttention(_ sender: Any?) { model.onlyNeedingAttention.toggle() }

    /// View › Show/Hide Setup Details: keyboard path to the details panel when it is collapsed (#104).
    func toggleSetupDetails(_ sender: Any?) {
        model.detailsExpanded = !(model.detailsShown)
    }

    func sortSourcesBy(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let order = SourceSortOrder(rawValue: raw) else { return }
        model.sortOrder = order
    }

    func moveItemUp(_ sender: Any?) { model.moveSelected(.up) }
    func moveItemDown(_ sender: Any?) { model.moveSelected(.down) }

    // MARK: Validation (CMD-02: dimmed, never hidden)

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let hasEpisode = model.episode != nil
        let status = singleSource.map(model.status(of:))
        switch action {
        case #selector(importSources(_:)): return hasEpisode
        case #selector(relinkSource(_:)), #selector(showSourceInFinder(_:)): return singleSource != nil
        case #selector(grantSourceAccess(_:)):
            return status.map { $0.access == .needsPermission || $0.access == .denied } ?? false
        case #selector(reviewChangedFile(_:)):
            if case .changed(_, false)? = status?.identity { return true }
            return false
        case #selector(newRecorderGroup(_:)), #selector(newSpeaker(_:)): return hasEpisode
        case #selector(renameRecorderGroup(_:)): return groupID != nil
        case #selector(renameSpeaker(_:)), #selector(deleteSpeaker(_:)): return singleSpeaker != nil
        case #selector(assignToRecorderGroup(_:)), #selector(assignSpeaker(_:)), #selector(removeSourceFromEpisode(_:)):
            return !sources.isEmpty
        case #selector(setPrimaryForSpeaker(_:)): return singleSpeaker != nil
        case #selector(setEpoch(_:)):
            return !sources.isEmpty && sources.allSatisfy { model.episode?.source($0)?.placement.recorderGroupID != nil }
        case #selector(startNewEpoch(_:)):
            return (!sources.isEmpty && sources.allSatisfy { model.episode?.source($0)?.placement.recorderGroupID != nil }) || groupID != nil
        case #selector(setChannel(_:)): return !sources.isEmpty
        case #selector(useAsPrimary(_:)):
            return model.selectedReference.map { !$0.isPrimary } ?? false
        case #selector(useAsBackup(_:)): return model.selectedReference != nil
        case #selector(downloadSource(_:)): return canTransfer(.download)
        case #selector(pauseSourceDownload(_:)): return canTransfer(.pause)
        case #selector(resumeSourceDownload(_:)): return canTransfer(.resume)
        case #selector(cancelSourceDownload(_:)): return canTransfer(.cancel)
        case #selector(retrySourceDownload(_:)): return canTransfer(.retry)
        case #selector(toggleSetupDetails(_:)):
            item.title = model.detailsShown ? "Hide Setup Details" : "Show Setup Details"
            return hasEpisode && model.detailsCanCollapse
        case #selector(toggleSourcesNeedingAttention(_:)):
            item.state = model.onlyNeedingAttention ? .on : .off
            return hasEpisode
        case #selector(sortSourcesBy(_:)):
            item.state = (item.representedObject as? String) == model.sortOrder.rawValue ? .on : .off
            return hasEpisode
        case #selector(delete(_:)):
            return model.inspectorFollowsSpeakers ? singleSpeaker != nil : (!sources.isEmpty || groupID != nil)
        case #selector(moveItemUp(_:)), #selector(moveItemDown(_:)):
            let speakers = model.inspectorFollowsSpeakers
            item.title = "Move \(speakers ? "Speaker" : "Source") \(action == #selector(moveItemUp(_:)) ? "Up" : "Down")"
            return speakers ? singleSpeaker != nil : singleSource != nil
        default:
            return responds(to: action)
        }
    }

    private func canTransfer(_ action: TransferAction) -> Bool {
        sources.contains { model.availableActions(for: $0).contains(action) }
    }
}

/// Builds the Setup menu-bar items and installs any that the app's main menu doesn't already provide.
/// The Commands lane may call the `make…` factories directly instead; installation de-duplicates by title.
@MainActor
enum SetupMenus {
    final class GroupChoice: NSObject {
        let id: RecorderGroupID?
        init(_ id: RecorderGroupID?) { self.id = id }
    }

    final class SpeakerChoice: NSObject {
        let id: SpeakerID?
        init(_ id: SpeakerID?) { self.id = id }
    }

    final class PrimaryChoice: NSObject {
        let channel: ChannelReference?
        init(_ channel: ChannelReference?) { self.channel = channel }
    }

    /// Marker so New Recorder Group…/New Speaker… from the Source submenus assign the selected sources.
    static let assignSelectionMarker = NSString(string: "assign-selection")

    private final class DynamicMenuDelegate: NSObject, NSMenuDelegate {
        enum Kind { case groups, speakers, primary }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        func menuNeedsUpdate(_ menu: NSMenu) {
            MainActor.assumeIsolated {
                menu.removeAllItems()
                guard let model = SetupCommandProxy.shared.controller?.model else {
                    let item = NSMenuItem(title: "Select sources in an episode's Setup", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                    return
                }
                switch kind {
                case .groups:
                    for group in model.episode?.recorderGroups ?? [] {
                        menu.addItem(SetupMenus.item(group.name, #selector(SetupCommandActions.assignToRecorderGroup(_:)), represented: GroupChoice(group.id)))
                    }
                    menu.addItem(SetupMenus.item("Ungrouped", #selector(SetupCommandActions.assignToRecorderGroup(_:)), represented: GroupChoice(nil)))
                    menu.addItem(.separator())
                    menu.addItem(SetupMenus.item("New Recorder Group…", #selector(SetupCommandActions.newRecorderGroup(_:)), represented: SetupMenus.assignSelectionMarker))
                case .speakers:
                    for speaker in model.episodeSpeakers {
                        menu.addItem(SetupMenus.item(speaker.name, #selector(SetupCommandActions.assignSpeaker(_:)), represented: SpeakerChoice(speaker.id)))
                    }
                    menu.addItem(SetupMenus.item("Unassigned", #selector(SetupCommandActions.assignSpeaker(_:)), represented: SpeakerChoice(nil)))
                    menu.addItem(.separator())
                    menu.addItem(SetupMenus.item("New Speaker…", #selector(SetupCommandActions.newSpeaker(_:)), represented: SetupMenus.assignSelectionMarker))
                case .primary:
                    guard model.speakerSelection.count == 1, let id = model.speakerSelection.first else { return }
                    for choice in model.channelChoices(for: id) {
                        menu.addItem(SetupMenus.item(choice.title, #selector(SetupCommandActions.setPrimaryForSpeaker(_:)), represented: PrimaryChoice(choice.channel)))
                    }
                    menu.addItem(SetupMenus.item("None", #selector(SetupCommandActions.setPrimaryForSpeaker(_:)), represented: PrimaryChoice(nil)))
                }
            }
        }
    }

    private static let groupsDelegate = DynamicMenuDelegate(.groups)
    private static let speakersDelegate = DynamicMenuDelegate(.speakers)
    private static let primaryDelegate = DynamicMenuDelegate(.primary)

    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = SetupCommandProxy.shared
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.representedObject = represented
        return item
    }

    private static func submenu(_ title: String, delegate: NSMenuDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = delegate
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        item.submenu = menu
        return item
    }

    /// File menu: Import Sources… (⇧⌘I) and Relink Source….
    static func makeFileItems() -> [NSMenuItem] {
        [
            item("Import Sources…", #selector(SetupCommandActions.importSources(_:)), "i", [.command, .shift]),
            item("Relink Source…", #selector(SetupCommandActions.relinkSource(_:))),
        ]
    }

    /// Episode menu items owned by Setup (commands §2 Episode).
    static func makeEpisodeItems() -> [NSMenuItem] {
        [
            item("New Recorder Group…", #selector(SetupCommandActions.newRecorderGroup(_:))),
            item("New Speaker…", #selector(SetupCommandActions.newSpeaker(_:))),
            item("Rename Recorder Group", #selector(SetupCommandActions.renameRecorderGroup(_:))),
            item("Rename Speaker", #selector(SetupCommandActions.renameSpeaker(_:))),
            submenu("Set Primary for Speaker", delegate: primaryDelegate),
            item("Delete Speaker…", #selector(SetupCommandActions.deleteSpeaker(_:))),
        ]
    }

    static func makeSourceMenu() -> NSMenu {
        let menu = NSMenu(title: "Source")
        menu.addItem(submenu("Assign to Recorder Group", delegate: groupsDelegate))
        menu.addItem(item("Set Epoch…", #selector(SetupCommandActions.setEpoch(_:))))
        menu.addItem(item("Start New Epoch", #selector(SetupCommandActions.startNewEpoch(_:))))
        menu.addItem(item("Set Channel…", #selector(SetupCommandActions.setChannel(_:))))
        menu.addItem(submenu("Assign Speaker", delegate: speakersDelegate))
        menu.addItem(item("Use as Primary", #selector(SetupCommandActions.useAsPrimary(_:))))
        menu.addItem(item("Use as Backup", #selector(SetupCommandActions.useAsBackup(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Download", #selector(SetupCommandActions.downloadSource(_:))))
        menu.addItem(item("Pause Download", #selector(SetupCommandActions.pauseSourceDownload(_:))))
        menu.addItem(item("Resume Download", #selector(SetupCommandActions.resumeSourceDownload(_:))))
        menu.addItem(item("Cancel Download", #selector(SetupCommandActions.cancelSourceDownload(_:))))
        menu.addItem(item("Retry Download", #selector(SetupCommandActions.retrySourceDownload(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Relink Source…", #selector(SetupCommandActions.relinkSource(_:))))
        menu.addItem(item("Grant Access…", #selector(SetupCommandActions.grantSourceAccess(_:))))
        menu.addItem(item("Review Changed File…", #selector(SetupCommandActions.reviewChangedFile(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Source in Finder", #selector(SetupCommandActions.showSourceInFinder(_:))))
        menu.addItem(item("Remove from Episode…", #selector(SetupCommandActions.removeSourceFromEpisode(_:))))
        #if DEBUG
        // UI-test fixture only (F-OFFLINE, simulated): absent from Release builds and from normal runs.
        if SetupFixtures.isActive {
            menu.addItem(.separator())
            for (title, key, offline) in [("Simulate Network Offline", "o", true), ("Simulate Network Reconnect", "r", false)] {
                let simulate = NSMenuItem(title: title, action: #selector(SimulatedNetworkTarget.simulate(_:)), keyEquivalent: key)
                simulate.keyEquivalentModifierMask = [.control, .option, .command]
                simulate.target = SimulatedNetworkTarget.shared
                simulate.representedObject = offline
                menu.addItem(simulate)
            }
        }
        #endif
        return menu
    }

    static func makeViewItems() -> [NSMenuItem] {
        let sort = NSMenuItem(title: "Sort Sources By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort Sources By")
        for order in SourceSortOrder.allCases {
            sortMenu.addItem(item(order.title, #selector(SetupCommandActions.sortSourcesBy(_:)), represented: order.rawValue))
        }
        sort.submenu = sortMenu
        return [
            item("Show Only Sources Needing Attention", #selector(SetupCommandActions.toggleSourcesNeedingAttention(_:))),
            sort,
            item("Show Setup Details", #selector(SetupCommandActions.toggleSetupDetails(_:))),
        ]
    }

    static func makeEditItems() -> [NSMenuItem] {
        [
            item("Delete", #selector(EpisodeSetupViewController.delete(_:))),
            item("Move Up", #selector(SetupCommandActions.moveItemUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Move Down", #selector(SetupCommandActions.moveItemDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
        ]
    }

    /// Adds Setup's Episode and View items to the app's main menu (File, Edit and Source items are
    /// provided by the Commands lane through `SourceCommandHandling`).
    static func installIfNeeded(in mainMenu: NSMenu? = NSApp.mainMenu) {
        guard let mainMenu else { return }
        if let view = topMenu("View", in: mainMenu) { append(makeViewItems(), to: view) }
        if let episode = topMenu("Episode", in: mainMenu) { append(makeEpisodeItems(), to: episode) }
    }

    /// Source menu items (without Relink Source…, which the Commands lane appends).
    static func makeSourceMenuItems() -> [NSMenuItem] {
        makeSourceMenu().items.filter { $0.title != "Relink Source…" }.map { item in
            item.menu?.removeItem(item)
            return item
        }.dropLastSeparators()
    }

    private static func topMenu(_ title: String, in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.first { $0.submenu?.title == title }?.submenu
    }

    @discardableResult
    private static func insertTopMenu(_ menu: NSMenu, after title: String, in mainMenu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        let index = mainMenu.items.firstIndex { $0.submenu?.title == title }.map { $0 + 1 } ?? max(mainMenu.items.count - 2, 0)
        mainMenu.insertItem(item, at: index)
        return menu
    }

    /// Adds items whose title (and key equivalent) aren't already present, after a separator.
    private static func append(_ items: [NSMenuItem], to menu: NSMenu) {
        let missing = items.filter { candidate in
            !menu.items.contains { existing in
                existing.title == candidate.title
                    || (!candidate.keyEquivalent.isEmpty && existing.keyEquivalent == candidate.keyEquivalent && existing.keyEquivalentModifierMask == candidate.keyEquivalentModifierMask)
            }
        }
        guard !missing.isEmpty else { return }
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        missing.forEach(menu.addItem)
    }
}

extension Array where Element == NSMenuItem {
    fileprivate func dropLastSeparators() -> [NSMenuItem] {
        var items = self
        while items.last?.isSeparatorItem == true { items.removeLast() }
        while items.first?.isSeparatorItem == true { items.removeFirst() }
        return items
    }
}

/// Menu target for Setup commands. Forwards to the Setup controller of the key (or main) show window,
/// so commands work from the menu bar whichever list has focus, and are dimmed with a reason in the
/// window when no Setup content is shown.
@MainActor
final class SetupCommandProxy: NSObject, NSMenuItemValidation {
    static let shared = SetupCommandProxy()

    var controller: EpisodeSetupViewController? {
        EpisodeSetupViewController.controller(for: NSApp.keyWindow) ?? EpisodeSetupViewController.controller(for: NSApp.mainWindow)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return EpisodeSetupViewController.instancesRespond(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        controller
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let controller else { return false }
        return controller.validateMenuItem(item)
    }
}

#if DEBUG
/// Menu target for the fixture-only network simulation items.
@MainActor
final class SimulatedNetworkTarget: NSObject {
    static let shared = SimulatedNetworkTarget()

    @objc func simulate(_ sender: NSMenuItem) {
        if sender.representedObject as? Bool == true { SimulatedNetwork.goOffline() } else { SimulatedNetwork.reconnect() }
    }
}
#endif
