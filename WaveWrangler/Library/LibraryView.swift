import SwiftUI
import WWCore
import WWOrganizer

/// Library window content: two-level sidebar → entry list → entry detail (IA §3).
struct LibraryView: View {
    @Bindable var state: LibraryWindowState
    @FocusState private var focus: LibraryWindowState.Region?

    private var store: LibraryUIStore { state.store }

    var body: some View {
        splitView
            .onChange(of: focus) { _, region in
                // The AppKit entry outline reports its own focus; SwiftUI sees it as no focused region.
                if region != nil || !(state.window?.firstResponder is EntryOutlineView) { state.focusedRegion = region }
            }
            .onAppear { DispatchQueue.main.async { focus = .sidebar } }
            .task {
                if !store.isLoaded { await store.load() }
                Responsiveness.libraryReady(entryCount: store.library.entries.count)
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            LibrarySidebar(state: state, focus: $focus)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } content: {
            // #109: every column's content fits the window at any in-app text size. A column whose minimum height
            // exceeds the window (e.g. vertically fixed-size text, measured for the column's minimum at a tiny
            // width) makes the split view taller than the window, and its top overflows under the title bar
            // (`sizingOptions = []` keeps the window from resizing to SwiftUI's minimum). Column content that
            // can grow (empty states, details) scrolls instead.
            // #59: the opaque message bar sits at the top of the content column (IA reading order: message bar
            // first in the content). Above the whole split view, the column still reserved the toolbar's
            // scroll-edge pocket below the bar, which blurred the column headers and the first row.
            // #109: at large text sizes the bar scrolls within at most 40% of the column instead of pushing the
            // list out of the window (stateless layout, no geometry → state → layout feedback).
            MessageBarStack(maxBarFraction: 0.4, minBarCap: 120) {
                ViewThatFits(in: .vertical) {
                    LibraryMessageBar(state: state)
                    ScrollView { LibraryMessageBar(state: state) }
                        .scrollBounceBehavior(.basedOnSize)
                }
                LibraryEntryList(state: state)
            }
                .focused($focus, equals: .entries)
                .navigationSplitViewColumnWidth(min: 320, ideal: 520)
        } detail: {
            LibraryEntryDetail(state: state)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Show", systemImage: "plus") { CommandRouter.shared.newShow(nil) }
                    .help("New Show… (⌘N)")
                Button("Open…", systemImage: "folder") { CommandRouter.shared.openDocument(nil) }
                    .help("Open… (⌘O)")
            }
        }
    }
}

private struct LibrarySidebar: View {
    @Bindable var state: LibraryWindowState
    var focus: FocusState<LibraryWindowState.Region?>.Binding

    var body: some View {
        let snapshot = state.store.sidebar
        List(selection: $state.sidebarSelection) {
            Section("Library") {
                ForEach(snapshot.libraryRows) { row in
                    SidebarRowView(row: row, emphasized: isEmphasized(row.item)).tag(row.item)
                }
            }
            Section {
                ForEach(snapshot.collectionRows) { row in
                    SidebarRowView(row: row, emphasized: isEmphasized(row.item))
                        .tag(row.item)
                        .contextMenu { collectionMenu(row.item.collectionID) }
                }
                .onMove { source, destination in state.moveCollections(fromOffsets: source, toOffset: destination) }
            } header: {
                Text("Collections")
            }
        }
        .listStyle(.sidebar)
        .focused(focus, equals: .sidebar)
        .accessibilityLabel("Library sidebar")
        .accessibilityIdentifier("ww.library.sidebar")
        // #110: "New Collection" is a real button in a bar below the list. In a sidebar section header, the List
        // merged it into the heading's static text, so VoiceOver and Full Keyboard Access couldn't press it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    state.newCollection()
                } label: {
                    Label("New Collection", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Collection…")
                .accessibilityLabel("New Collection")
                .accessibilityHint("Creates a collection. Collections group shows without moving them.")
                .accessibilityIdentifier("ww.library.collections.add")
                Spacer(minLength: 0)
            }
            .wwFont(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// #139: the row is drawn on the accent-filled (emphasized) selection.
    private func isEmphasized(_ item: LibrarySidebarItem) -> Bool {
        state.sidebarSelection == item && focus.wrappedValue == .sidebar
    }

    @ViewBuilder
    private func collectionMenu(_ id: CollectionID?) -> some View {
        if let id {
            Button("Rename") { state.renameCollection(id) }
            Button("New Collection…") { state.newCollection() }
            Divider()
            Button("Delete Collection…") { state.deleteCollection(id) }
        }
    }
}

private struct SidebarRowView: View {
    let row: LibrarySidebarRow
    /// Selected while the sidebar has keyboard focus (#139).
    let emphasized: Bool

    var body: some View {
        HStack {
            Label(row.title, systemImage: row.symbolName)
                .wwFont(.body)
            Spacer(minLength: 4)
            if let count = row.countText {
                Text(count)
                    .wwFont(.body)
                    .monospacedDigit()
            }
        }
        .emphasizedSelectionForeground(selectedInFocusedList: emphasized)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(row.item.accessibilityIdentifier)
    }
}

private struct LibraryEntryList: View {
    @Bindable var state: LibraryWindowState
    @State private var sortOrder: [KeyPathComparator<LibraryEntryRow>] = []
    @Environment(\.wwTextSize) private var textSize

    /// Debug only: `-WWEntryListImplementation swiftui` restores the SwiftUI `Table` for A/B timing (#106).
    private static let usesSwiftUITable: Bool = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "WWEntryListImplementation") == "swiftui"
        #else
        false
        #endif
    }()

    var body: some View {
        let item = state.sidebarSelection ?? .shows
        let rows = sorted(state.store.rows(for: item))
        let title = LibraryPresentation.contentTitle(for: item, library: state.store.library, rowCount: rows.count)
        Group {
            if rows.isEmpty {
                // Same shape as ContentUnavailableView, but with primary-contrast text: its secondary description
                // failed the contrast audit, and it now scrolls when it doesn't fit (#109).
                CenteredScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: emptySymbol(item))
                            .wwFont(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(emptyTitle(item))
                            .wwFont(.title3)
                            .accessibilityAddTraits(.isHeader)
                        Text(emptyDescription(item))
                            .wwFont(.body)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if item == .shows {
                            HStack {
                                Button("New Show…") { CommandRouter.shared.newShow(nil) }
                                Button("Open…") { CommandRouter.shared.openDocument(nil) }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            } else if !Self.usesSwiftUITable {
                LibraryEntryOutline(
                    state: state,
                    list: item,
                    rows: state.store.rows(for: item),
                    title: title,
                    selection: state.entrySelection,
                    pointSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize))
                )
            } else {
                Table(rows, selection: $state.entrySelection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.name)
                            .accessibilityIdentifier(row.accessibilityIdentifier)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Episodes") { row in
                        Text(row.episodesText).monospacedDigit()
                            .accessibilityValue(row.episodeCount == nil ? "unknown" : row.episodesText)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Location", value: \.locationText) { row in
                        Text(row.locationText).lineLimit(1).truncationMode(.middle).help(row.locationText)
                    }
                    .width(min: 90, ideal: 150)
                    TableColumn("Last Opened") { row in
                        Text(row.lastOpened.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    }
                    .width(min: 90, ideal: 140)
                    TableColumn("Status", value: \.status.statusText) { row in
                        StatusLabel(text: row.status.statusText, symbolName: row.status.symbolName, tint: row.status.tint)
                            .help(row.status.explanation ?? row.status.statusText)
                    }
                    .width(min: 120, ideal: 170)
                }
                .contextMenu(forSelectionType: ShowID.self) { ids in
                    entryMenu(Array(ids))
                } primaryAction: { ids in
                    for id in ids { state.open(id) }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier("ww.library.entries")
            }
        }
    }

    private func sorted(_ rows: [LibraryEntryRow]) -> [LibraryEntryRow] {
        sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    @ViewBuilder
    private func entryMenu(_ ids: [ShowID]) -> some View {
        if !ids.isEmpty {
            Button("Open Show") { for id in ids { state.open(id) } }
            Divider()
            let collections = state.store.library.collections
            if !collections.isEmpty {
                Menu("Add to Collection") {
                    ForEach(collections) { collection in
                        Button(collection.name) { state.addShows(ids, to: collection.id) }
                    }
                }
            }
            Button("Show in Finder") {
                state.entrySelection = Set(ids)
                state.revealSelectedInFinder()
            }
            Divider()
            if state.selectedCollectionID != nil {
                Button("Remove from Collection") {
                    state.entrySelection = Set(ids)
                    state.removeSelectedShowsFromCollection()
                }
            }
            Button("Remove from Library…") {
                state.entrySelection = Set(ids)
                state.removeSelectedShowsFromLibrary()
            }
        }
    }

    private func emptyTitle(_ item: LibrarySidebarItem) -> String {
        switch item {
        case .shows: "No shows yet"
        case .recent: "No recent shows"
        case .unavailable: "Nothing needs attention"
        case .collection: "This collection is empty"
        }
    }

    private func emptySymbol(_ item: LibrarySidebarItem) -> String {
        switch item {
        case .shows: "books.vertical"
        case .recent: "clock"
        case .unavailable: "checkmark.circle"
        case .collection: "rectangle.stack"
        }
    }

    private func emptyDescription(_ item: LibrarySidebarItem) -> String {
        switch item {
        case .shows: "Create a show with File › New Show… or open one with File › Open…."
        case .recent: "Shows you open appear here, newest first."
        case .unavailable: "Shows that can't be opened appear here with the reason and what you can do."
        case .collection: "Select shows, then choose File › Library › Add to Collection."
        }
    }
}

/// Text + symbol shape + optional system tint (ST-02); the text alone carries the meaning.
struct StatusLabel: View {
    let text: String
    let symbolName: String?
    let tint: StatusTint

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(2)
                .accessibilityLabel("Status")
                .accessibilityValue(text)
        }
    }

    private var color: Color {
        switch tint {
        case .none: .secondary
        case .attention: .orange
        case .failed: .red
        }
    }
}

private struct LibraryEntryDetail: View {
    @Bindable var state: LibraryWindowState

    var body: some View {
        let rows = state.selectedRows
        if rows.count == 1, let row = rows.first {
            detail(row)
        } else {
            CenteredScrollView {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .wwFont(.largeTitle)
                    .accessibilityHidden(true)
                Text(rows.isEmpty ? "No Show Selected" : "\(rows.count) Shows Selected")
                    .wwFont(.title3)
                    .accessibilityAddTraits(.isHeader)
                Text(rows.isEmpty ? "Select a show to see its details." : "Use the File › Library menu to add them to a collection.")
                    .wwFont(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    private func detail(_ row: LibraryEntryRow) -> some View {
        let details = state.store.details[row.showID]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(row.name)
                    .wwFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Location") { Text(row.locationText) }
                LabeledContent("Last opened") {
                    Text(row.lastOpened.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                }
                LabeledContent("Status") {
                    StatusLabel(text: row.status.statusText, symbolName: row.status.symbolName, tint: row.status.tint)
                }
                if let explanation = row.status.explanation {
                    Text(explanation)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    ForEach(row.status.remedies.filter { $0 != .openShow }, id: \.self) { remedy in
                        Button(remedy.rawValue) { state.perform(remedy, for: row.showID) }
                    }
                }
                if let message = state.actionMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Couldn't complete: \(message)")
                }
                Divider()
                Text("Episodes (as of last open)")
                    .wwFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let episodes = details?.episodes {
                    if episodes.isEmpty {
                        Text("No episodes")
                    } else {
                        ForEach(episodes) { episode in
                            Text(episode.displayTitle).lineLimit(2)
                        }
                    }
                } else {
                    Text("Unknown until the show is opened")
                }
                Divider()
                HStack {
                    Button("Open Show") { state.open(row.showID) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("ww.library.detail.open")
                    Button("Show in Finder") { state.revealSelectedInFinder() }
                        .disabled(!state.store.services.entries.canRevealShow(row.showID))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .wwFont(.body)
    }
}

/// Library-window message bar (ST-32 and the honest in-memory notice). Persistent until dismissed.
private struct LibraryMessageBar: View {
    @Bindable var state: LibraryWindowState

    var body: some View {
        VStack(spacing: 0) {
            let location = state.store.services.location
            if let level = LibraryLevelPresentation(location.libraryState) {
                MessageBar(
                    heading: level.heading,
                    message: [level.body, location.pendingEditsStatus ?? level.pendingText].compactMap { $0 }.joined(separator: " "),
                    symbolName: level.symbolName,
                    actions: level.actions.map { action in (action.rawValue, { state.perform(action) }) },
                    identifier: "ww.library.messageBar"
                )
            } else if let pending = location.pendingEditsStatus {
                MessageBar(
                    heading: "Edits waiting",
                    message: pending,
                    symbolName: "clock",
                    actions: [("Try Again", { state.perform(.tryAgain) })],
                    identifier: "ww.library.messageBar"
                )
            }
            if let conflicts = location.providerConflictNotice {
                // #117: informational and persistent while the unusable versions exist (nothing to do in M1; the
                // versions are kept, never applied). Text, not colour, carries the meaning.
                MessageBar(
                    heading: "Other copies of your library weren't used",
                    message: conflicts,
                    symbolName: "doc.on.doc",
                    actions: [],
                    identifier: "ww.library.messageBar.providerConflicts"
                )
            }
            if let result = location.resultMessage {
                MessageBar(
                    heading: "Library",
                    message: result,
                    symbolName: "info.circle",
                    actions: [("Dismiss", { location.dismissResultMessage() })],
                    identifier: "ww.library.messageBar.result"
                )
            }
            if let failure = state.store.persistenceFailure {
                MessageBar(
                    heading: "Couldn't update the library",
                    message: failure,
                    symbolName: "exclamationmark.triangle",
                    actions: [("Dismiss", { state.store.persistenceFailure = nil })],
                    identifier: "ww.library.messageBar"
                )
            }
            if !state.store.isDurable, !state.inMemoryNoticeDismissed {
                MessageBar(
                    heading: "The library isn't saved yet in this version",
                    message: "Collections and recent shows are kept only while WaveWrangler is open. Your shows aren't affected.",
                    symbolName: "info.circle",
                    actions: [("Dismiss", { state.inMemoryNoticeDismissed = true })],
                    identifier: "ww.library.messageBar.inMemory"
                )
            }
        }
    }
}

/// #109: content that is centred when it fits and scrolls when it doesn't (large in-app text, short windows),
/// so it never raises its split-view column's minimum height above the window.
struct CenteredScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// #109: a message bar above the main content. The bar gets its natural height (0 pt when it shows nothing), at
/// most `maxBarFraction` of the height (but at least `minBarCap`); the content gets the rest. The bar subview is
/// proposed its capped height, so a `ViewThatFits` bar switches to scrolling when it doesn't fit.
struct MessageBarStack: Layout {
    let maxBarFraction: CGFloat
    let minBarCap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let barHeight = Self.barHeight(
            natural: subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height,
            available: bounds.height, maxBarFraction: maxBarFraction, minBarCap: minBarCap
        )
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: barHeight))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + barHeight), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height - barHeight)
        )
    }

    static func barHeight(natural: CGFloat, available: CGFloat, maxBarFraction: CGFloat, minBarCap: CGFloat) -> CGFloat {
        let cap = min(available, max(minBarCap, available * maxBarFraction))
        return max(0, min(natural, cap))
    }
}
