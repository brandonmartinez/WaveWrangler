import AppKit
import SwiftUI
import WWCore
import WWOrganizer

/// The Library entry list as an AppKit outline (#106). SwiftUI `Table` hosts every cell in its own
/// `NSHostingView` and measures automatic row heights for each inserted row, so switching the sidebar to a
/// long list (Shows, 100 rows) cost ~1.5 ms per row and exceeded the WW-007 100 ms interaction gate. Here
/// cells are frame-laid-out, reused, and rows have one fixed height derived from the in-app text size.
///
/// Same contract as the `Table` it replaces: an outline `ww.library.entries` labelled with the list title;
/// rows of static texts (name `ww.library.entry.<id>`, Status label + value); sortable Name/Location/Status;
/// multiple selection bound to `entrySelection`; context menu; Return/double-click opens; type-select by name.
struct LibraryEntryOutline: NSViewRepresentable {
    let state: LibraryWindowState
    let rows: [LibraryEntryRow]
    let title: String
    let selection: Set<ShowID>
    let pointSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = EntryOutlineView()
        for column in EntryColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.idealWidth
            tableColumn.resizingMask = .userResizingMask
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            outline.addTableColumn(tableColumn)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.indentationPerLevel = 0
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.allowsTypeSelect = true
        outline.autosaveTableColumns = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menu = context.coordinator.contextMenu
        outline.setAccessibilityIdentifier("ww.library.entries")
        outline.onReturn = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        outline.onFocus = { [weak coordinator = context.coordinator] in coordinator?.state.focusedRegion = .entries }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.state = state
        coordinator.apply(rows: rows, title: title, selection: selection, pointSize: pointSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var state: LibraryWindowState
        weak var outline: EntryOutlineView?
        let contextMenu = NSMenu()
        private var unsorted: [LibraryEntryRow] = []
        private(set) var items: [EntryItem] = []
        private var cache: [ShowID: EntryItem] = [:]
        private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private var syncingSelection = false

        init(state: LibraryWindowState) {
            self.state = state
            super.init()
            contextMenu.delegate = self
        }

        func apply(rows: [LibraryEntryRow], title: String, selection: Set<ShowID>, pointSize: CGFloat) {
            guard let outline else { return }
            outline.setAccessibilityLabel(title)
            var reload = false
            if font.pointSize != pointSize {
                font = NSFont.systemFont(ofSize: pointSize)
                outline.rowHeight = Self.rowHeight(for: font)
                outline.headerView?.needsDisplay = true
                reload = true
            }
            if rows != unsorted {
                unsorted = rows
                reload = true
            }
            if reload {
                resort()
                outline.reloadData()
            }
            syncSelection(selection)
        }

        static func rowHeight(for font: NSFont) -> CGFloat {
            (font.ascender - font.descender + font.leading).rounded(.up) + 8
        }

        private func resort() {
            let sorted = Self.sorted(unsorted, by: outline?.sortDescriptors ?? [])
            var next: [ShowID: EntryItem] = [:]
            items = sorted.map { row in
                let item = cache[row.showID] ?? EntryItem(row: row)
                item.row = row
                next[row.showID] = item
                return item
            }
            cache = next
        }

        static func sorted(_ rows: [LibraryEntryRow], by descriptors: [NSSortDescriptor]) -> [LibraryEntryRow] {
            let keys = descriptors.compactMap { descriptor in
                descriptor.key.flatMap(LibraryEntrySortKey.init(rawValue:)).map { (key: $0, ascending: descriptor.ascending) }
            }
            return LibraryPresentation.sorted(rows, by: keys)
        }

        private func syncSelection(_ selection: Set<ShowID>) {
            guard let outline else { return }
            let indexes = IndexSet(items.indices.filter { selection.contains(items[$0].row.showID) })
            guard indexes != outline.selectedRowIndexes else { return }
            syncingSelection = true
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
            if let first = indexes.first { outline.scrollRowToVisible(first) }
            syncingSelection = false
        }

        private var selectedIDs: [ShowID] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].row.showID : nil }
        }

        /// The rows a click or context menu applies to: the selection when the clicked row is in it, else that row.
        private var clickedIDs: [ShowID] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            guard clicked >= 0, items.indices.contains(clicked) else { return selectedIDs }
            return outline.selectedRowIndexes.contains(clicked) ? selectedIDs : [items[clicked].row.showID]
        }

        func openSelection() {
            for id in selectedIDs { state.open(id) }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0 else { return }
            for id in clickedIDs { state.open(id) }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? items.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selection = Set(selectedIDs)
            resort()
            outlineView.reloadData()
            syncSelection(selection)
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = EntryColumn(rawValue: identifier.rawValue),
                  let row = (item as? EntryItem)?.row else { return nil }
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? EntryCellView
                ?? EntryCellView(column: column)
            cell.configure(row, font: font)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            tableColumn?.identifier == EntryColumn.name.identifier ? (item as? EntryItem)?.row.name : nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection else { return }
            let selection = Set(selectedIDs)
            if state.entrySelection != selection { state.entrySelection = selection }
        }

        // MARK: Context menu (same items as the SwiftUI list's)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let ids = clickedIDs
            guard !ids.isEmpty else { return }
            let state = state
            menu.addItem(ClosureMenuItem("Open Show") { for id in ids { state.open(id) } })
            menu.addItem(.separator())
            let collections = state.store.library.collections
            if !collections.isEmpty {
                let add = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "Add to Collection")
                for collection in collections {
                    submenu.addItem(ClosureMenuItem(collection.name) { state.addShows(ids, to: collection.id) })
                }
                add.submenu = submenu
                menu.addItem(add)
            }
            menu.addItem(ClosureMenuItem("Show in Finder") {
                state.entrySelection = Set(ids)
                state.revealSelectedInFinder()
            })
            menu.addItem(.separator())
            if state.selectedCollectionID != nil {
                menu.addItem(ClosureMenuItem("Remove from Collection") {
                    state.entrySelection = Set(ids)
                    state.removeSelectedShowsFromCollection()
                })
            }
            menu.addItem(ClosureMenuItem("Remove from Library…") {
                state.entrySelection = Set(ids)
                state.removeSelectedShowsFromLibrary()
            })
        }
    }
}

/// Outline item: a stable object per show so AppKit keeps row identity across reloads.
final class EntryItem: NSObject {
    var row: LibraryEntryRow
    init(row: LibraryEntryRow) { self.row = row }
}

enum EntryColumn: String, CaseIterable {
    case name, episodes, location, lastOpened, status

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    var title: String {
        switch self {
        case .name: "Name"
        case .episodes: "Episodes"
        case .location: "Location"
        case .lastOpened: "Last Opened"
        case .status: "Status"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: 120
        case .episodes: 60
        case .location, .lastOpened: 90
        case .status: 120
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 200
        case .episodes: 70
        case .location: 150
        case .lastOpened: 140
        case .status: 170
        }
    }

    var sortKey: String? {
        switch self {
        case .name: LibraryEntrySortKey.name.rawValue
        case .location: LibraryEntrySortKey.location.rawValue
        case .status: LibraryEntrySortKey.status.rawValue
        case .episodes, .lastOpened: nil
        }
    }
}

/// Frame-laid-out, reusable cell: one label, plus a status symbol or progress indicator in the Status column.
final class EntryCellView: NSTableCellView {
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    let column: EntryColumn
    private let label = NSTextField(labelWithString: "")
    private var symbol: NSImageView?
    private var spinner: NSProgressIndicator?

    init(column: EntryColumn) {
        self.column = column
        super.init(frame: NSRect(x: 0, y: 0, width: column.idealWidth, height: 24))
        identifier = column.identifier
        label.lineBreakMode = column == .name || column == .location ? .byTruncatingMiddle : .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        if column == .status {
            label.setAccessibilityLabel("Status")
            let symbol = NSImageView()
            symbol.setAccessibilityElement(false)
            addSubview(symbol)
            self.symbol = symbol
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.setAccessibilityElement(false)
            addSubview(spinner)
            self.spinner = spinner
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: LibraryEntryRow, font: NSFont) {
        label.font = font
        switch column {
        case .name:
            label.stringValue = row.name
            label.setAccessibilityIdentifier(row.accessibilityIdentifier)
            toolTip = row.name
        case .episodes:
            label.stringValue = row.episodesText
            label.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            label.setAccessibilityValue(row.episodeCount == nil ? "unknown" : row.episodesText)
        case .location:
            label.stringValue = row.locationText
            toolTip = row.locationText
        case .lastOpened:
            label.stringValue = row.lastOpened.map { $0.formatted(Self.dateStyle) } ?? "—"
        case .status:
            label.stringValue = row.status.statusText
            label.setAccessibilityValue(row.status.statusText)
            toolTip = row.status.explanation ?? row.status.statusText
            if let name = row.status.symbolName {
                symbol?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
                symbol?.contentTintColor = switch row.status.tint {
                case .none: .secondaryLabelColor
                case .attention: .systemOrange
                case .failed: .systemRed
                }
                symbol?.isHidden = false
                spinner?.stopAnimation(nil)
            } else {
                symbol?.isHidden = true
                if MotionPolicy.reduceMotion { spinner?.stopAnimation(nil) } else { spinner?.startAnimation(nil) }
                spinner?.isHidden = MotionPolicy.reduceMotion
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        var leading: CGFloat = 2
        if column == .status {
            let side = min(bounds.height, height)
            let iconFrame = NSRect(x: 2, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            symbol?.frame = iconFrame
            spinner?.frame = iconFrame
            leading = iconFrame.maxX + 4
        }
        label.frame = NSRect(x: leading, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - leading - 2), height: height)
    }
}

/// The entry outline: Return opens the selection (like the `Table`'s primary action) and focus is reported
/// to the window state so Delete/Move commands target the entries.
final class EntryOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onFocus: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// Menu item that runs a closure (context menus built on demand).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
