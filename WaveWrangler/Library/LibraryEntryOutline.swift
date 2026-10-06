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
    let list: LibrarySidebarItem
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
            // Widths come from LibraryEntryColumnPlan (#140); a low minimum keeps AppKit from overriding them.
            tableColumn.minWidth = 20
            tableColumn.width = column.kind.baseWidth
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
        // The column plan sizes every column to the outline's width; AppKit mustn't redistribute it.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
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
        outline.onResign = { [weak coordinator = context.coordinator] in coordinator?.resignEntriesFocus() }

        let scroll = EntryScrollView()
        scroll.onTile = { [weak coordinator = context.coordinator] width in coordinator?.applyColumnPlan(availableWidth: width) }
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
        coordinator.apply(list: list, rows: rows, title: title, selection: selection, pointSize: pointSize)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.resignEntriesFocus()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var state: LibraryWindowState
        weak var outline: EntryOutlineView?
        let contextMenu = NSMenu()
        private var list: LibrarySidebarItem = .shows
        private var unsorted: [LibraryEntryRow] = []
        private(set) var items: [EntryItem] = []
        private var cache: [ShowID: EntryItem] = [:]
        private var reconciler = LibraryEntryListReconciler()
        private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private var lineCounts: [StatusLineKey: Int] = [:]
        private var syncingSelection = false
        private var columnPlan: LibraryEntryColumnPlan.Plan?
        private var applyingColumnPlan = false
        /// Columns the plan hides (#140); their values go into the Name cell's accessibility help.
        private(set) var hiddenColumns: Set<EntryColumn> = []

        init(state: LibraryWindowState) {
            self.state = state
            super.init()
            contextMenu.delegate = self
        }

        func apply(list: LibrarySidebarItem, rows: [LibraryEntryRow], title: String, selection: Set<ShowID>, pointSize: CGFloat) {
            guard let outline else { return }
            outline.setAccessibilityLabel(title)
            var force = false
            if font.pointSize != pointSize {
                font = NSFont.systemFont(ofSize: pointSize)
                outline.rowHeight = Self.rowHeight(for: font, lines: 1)
                outline.headerView?.needsDisplay = true
                lineCounts = [:]
                force = true
                columnPlan = nil
                if let scroll = outline.enclosingScrollView { applyColumnPlan(availableWidth: scroll.contentView.bounds.width) }
            }
            self.list = list
            unsorted = rows
            reconcile(selection: selection, forceReload: force)
        }

        /// Applies the model to the outline: reloads only what changed, restores the selection after a reload
        /// without moving the scroll position, and scrolls only for model-originated selection changes.
        private func reconcile(selection: Set<ShowID>, forceReload: Bool = false) {
            guard let outline else { return }
            let sorted = Self.sorted(unsorted, by: outline.sortDescriptors)
            let plan = reconciler.reconcile(rows: sorted, list: list, selection: selection, forceReload: forceReload)
            switch plan.update {
            case .none:
                break
            case .reloadAll:
                rebuildItems(sorted)
                syncingSelection = true
                outline.reloadData()
                syncingSelection = false
            case .reloadRows(let indexes):
                rebuildItems(sorted)
                outline.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(0..<outline.numberOfColumns))
                outline.noteHeightOfRows(withIndexesChanged: indexes)
            }
            if outline.selectedRowIndexes != plan.selection {
                syncingSelection = true
                outline.selectRowIndexes(plan.selection, byExtendingSelection: false)
                syncingSelection = false
            }
            if let row = plan.scrollToRow {
                outline.scrollRowToVisible(row)
            } else if plan.scrollToTop, let clip = outline.enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -clip.contentInsets.top))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        /// #140: shows and sizes the columns for the outline's width and the text size. Called when the scroll
        /// view tiles (window resize, zoom, split-view drag) and when the text size changes. The column set is fixed;
        /// columns are hidden, never added or removed, and every width is finite.
        func applyColumnPlan(availableWidth: CGFloat) {
            guard let outline, !applyingColumnPlan, availableWidth.isFinite, availableWidth > 0 else { return }
            let scale = Double(font.pointSize) / Double(NSFont.systemFontSize)
            let plan = LibraryEntryColumnPlan.plan(availableWidth: Double(availableWidth), scale: scale)
            guard plan != columnPlan else { return }
            applyingColumnPlan = true
            defer { applyingColumnPlan = false }
            columnPlan = plan
            for tableColumn in outline.tableColumns {
                guard let column = EntryColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                if let width = plan.widths[column.kind] {
                    tableColumn.isHidden = false
                    if tableColumn.width != CGFloat(width) { tableColumn.width = CGFloat(width) }
                } else {
                    tableColumn.isHidden = true
                }
            }
            let hidden = Set(plan.hidden.compactMap { EntryColumn(rawValue: $0.rawValue) })
            let hiddenChanged = hidden != hiddenColumns
            hiddenColumns = hidden
            guard outline.numberOfRows > 0 else { return }
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(0..<outline.numberOfRows))
            if hiddenChanged, let name = outline.tableColumns.firstIndex(where: { $0.identifier == EntryColumn.name.identifier }) {
                outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [name])
            }
        }

        func resignEntriesFocus() {
            if state.focusedRegion == .entries { state.focusedRegion = nil }
        }

        static func rowHeight(for font: NSFont, lines: Int) -> CGFloat {
            (font.ascender - font.descender + font.leading).rounded(.up) * CGFloat(lines) + 8
        }

        private func rebuildItems(_ sorted: [LibraryEntryRow]) {
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
            reconcile(selection: state.entrySelection)
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = EntryColumn(rawValue: identifier.rawValue),
                  let row = (item as? EntryItem)?.row else { return nil }
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? EntryCellView
                ?? EntryCellView(column: column)
            cell.configure(row, font: font, hidden: hiddenColumns)
            return cell
        }

        /// Rows are one line, or two when the Status text wraps at the column's width and the text size
        /// (IA §3.2, CMD-20: status wraps to two lines, then truncates; the tooltip has the full text).
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let row = (item as? EntryItem)?.row else { return outlineView.rowHeight }
            return Self.rowHeight(for: font, lines: statusLines(row.status.statusText, in: outlineView))
        }

        func outlineViewColumnDidResize(_ notification: Notification) {
            guard let outline, outline.numberOfRows > 0,
                  (notification.userInfo?["NSTableColumn"] as? NSTableColumn)?.identifier == EntryColumn.status.identifier else { return }
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(0..<outline.numberOfRows))
        }

        private func statusLines(_ text: String, in outlineView: NSOutlineView) -> Int {
            let column = outlineView.column(withIdentifier: EntryColumn.status.identifier)
            guard column >= 0 else { return 1 }
            // The cell can be a little narrower than the column (inset style); measure conservatively so text
            // that wraps in the cell never gets a one-line row.
            let cellWidth = outlineView.tableColumns[column].width - outlineView.intercellSpacing.width - 4
            let key = StatusLineKey(text: text, width: cellWidth, pointSize: font.pointSize)
            if let lines = lineCounts[key] { return lines }
            let lines = EntryCellView.statusLineCount(text, font: font, cellWidth: cellWidth)
            lineCounts[key] = lines
            return lines
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            tableColumn?.identifier == EntryColumn.name.identifier ? (item as? EntryItem)?.row.name : nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection else { return }
            let selection = Set(selectedIDs)
            reconciler.noteUserSelection(selection)
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

private struct StatusLineKey: Hashable {
    let text: String
    let width: CGFloat
    let pointSize: CGFloat
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

    /// The column plan's kind (#140).
    var kind: LibraryEntryColumnKind { LibraryEntryColumnKind(rawValue: rawValue)! }

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
    private let label = EntryLabel(labelWithString: "")
    private var symbol: NSImageView?
    private var spinner: NSProgressIndicator?

    init(column: EntryColumn) {
        self.column = column
        super.init(frame: NSRect(x: 0, y: 0, width: column.kind.baseWidth, height: 24))
        identifier = column.identifier
        if column == .status {
            Self.configureWrapping(label)
        } else {
            label.lineBreakMode = column == .name || column == .location ? .byTruncatingMiddle : .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
        }
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

    func configure(_ row: LibraryEntryRow, font: NSFont, hidden: Set<EntryColumn> = []) {
        label.font = font
        switch column {
        case .name:
            label.stringValue = row.name
            label.setAccessibilityIdentifier(row.accessibilityIdentifier)
            toolTip = row.name
            // #140: values of columns hidden at this width, for VoiceOver (they're also in the detail pane).
            let extra = Self.hiddenValues(row, hidden: hidden)
            label.setAccessibilityHelp(extra.isEmpty ? nil : extra)
        case .episodes:
            label.stringValue = row.episodesText
            label.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            label.accessibilityValueOverride = row.episodeCount == nil ? "unknown" : row.episodesText
        case .location:
            label.stringValue = row.locationText
            toolTip = row.locationText
        case .lastOpened:
            label.stringValue = row.lastOpened.map { $0.formatted(Self.dateStyle) } ?? "—"
        case .status:
            label.stringValue = row.status.statusText
            label.accessibilityValueOverride = row.status.statusText
            toolTip = [row.status.statusText, row.status.explanation].compactMap { $0 }.joined(separator: "\n")
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

    /// "5 episodes. Location: iCloud Drive › Podcasts. Last opened: Sep 21, 2026 at 10:00 AM."
    static func hiddenValues(_ row: LibraryEntryRow, hidden: Set<EntryColumn>) -> String {
        var parts: [String] = []
        if hidden.contains(.episodes) {
            parts.append(row.episodeCount.map { $0 == 1 ? "1 episode" : "\($0) episodes" } ?? "Episodes unknown")
        }
        if hidden.contains(.location) { parts.append("Location: \(row.locationText)") }
        if hidden.contains(.lastOpened) {
            parts.append("Last opened: \(row.lastOpened.map { $0.formatted(dateStyle) } ?? "not yet")")
        }
        return parts.map { $0 + "." }.joined(separator: " ")
    }

    override func layout() {
        super.layout()
        guard column == .status, let font = label.font else {
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: 2, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - 4), height: height)
            return
        }
        let side = Self.iconSide(font)
        let iconFrame = NSRect(x: 2, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        symbol?.frame = iconFrame
        spinner?.frame = iconFrame
        let width = Self.statusTextWidth(cellWidth: bounds.width, font: font)
        let height = min(bounds.height, label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
        label.frame = NSRect(x: iconFrame.maxX + 4, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }

    // MARK: Status text metrics (shared with the row-height calculation)

    private static let measuringLabel: EntryLabel = {
        let label = EntryLabel(labelWithString: "")
        configureWrapping(label)
        return label
    }()

    private static func configureWrapping(_ label: NSTextField) {
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
    }

    private static func iconSide(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender).rounded(.up)
    }

    private static func statusTextWidth(cellWidth: CGFloat, font: NSFont) -> CGFloat {
        max(0, cellWidth - (2 + iconSide(font) + 4) - 2)
    }

    /// 1 or 2: the lines the Status text takes at this cell width (more than two are truncated).
    static func statusLineCount(_ text: String, font: NSFont, cellWidth: CGFloat) -> Int {
        let label = measuringLabel
        label.font = font
        label.stringValue = text
        let width = statusTextWidth(cellWidth: cellWidth, font: font)
        let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        let line = (font.ascender - font.descender + font.leading).rounded(.up)
        return height > line * 1.5 ? 2 : 1
    }
}

/// The entry outline: Return opens the selection (like the `Table`'s primary action) and focus is reported
/// to the window state so Delete/Move commands target the entries.
final class EntryOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onFocus: (() -> Void)?
    var onResign: (() -> Void)?

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

    /// Delete/Move must not keep targeting the entries once focus has left the list (or the list is gone).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    /// Prepare (and so expose to accessibility) only the rows in view. AppKit's responsive-scrolling overdraw
    /// realizes rows beyond the window edge, which assistive technology and audits then report as on-screen
    /// text that was never drawn.
    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: visibleRect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onResign?() }
    }
}

/// A label whose accessibility value can differ from its text (e.g. "unknown" for "—"); `NSTextField`
/// ignores `setAccessibilityValue(_:)` and reports its string value.
final class EntryLabel: NSTextField {
    var accessibilityValueOverride: String?

    override func accessibilityValue() -> String? {
        accessibilityValueOverride ?? super.accessibilityValue()
    }
}

/// Reports its content width whenever it tiles (resize, zoom, split-view drag), so the column plan follows it.
final class EntryScrollView: NSScrollView {
    var onTile: ((CGFloat) -> Void)?

    override func tile() {
        super.tile()
        onTile?(contentView.bounds.width)
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
