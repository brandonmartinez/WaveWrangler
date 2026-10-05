import SwiftUI
import WWCore
import WWOrganizer

/// Library window content: two-level sidebar → entry list → entry detail (IA §3).
struct LibraryView: View {
    @Bindable var state: LibraryWindowState
    @FocusState private var focus: LibraryWindowState.Region?

    private var store: LibraryUIStore { state.store }

    var body: some View {
        VStack(spacing: 0) {
            // Opaque bar above the split view (not an inset over translucent sidebar material) for contrast.
            LibraryMessageBar(state: state)
            splitView
        }
        .onChange(of: focus) { _, region in state.focusedRegion = region }
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
            LibraryEntryList(state: state)
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
                    SidebarRowView(row: row).tag(row.item)
                }
            }
            Section {
                ForEach(snapshot.collectionRows) { row in
                    SidebarRowView(row: row)
                        .tag(row.item)
                        .contextMenu { collectionMenu(row.item.collectionID) }
                }
                .onMove { source, destination in state.moveCollections(fromOffsets: source, toOffset: destination) }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button {
                        state.newCollection()
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("New Collection")
                    }
                    .buttonStyle(.borderless)
                    .help("New Collection…")
                    .accessibilityIdentifier("ww.library.sidebar.newCollection")
                }
            }
        }
        .listStyle(.sidebar)
        .focused(focus, equals: .sidebar)
        .accessibilityLabel("Library sidebar")
        .accessibilityIdentifier("ww.library.sidebar")
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

    var body: some View {
        let item = state.sidebarSelection ?? .shows
        let rows = sorted(state.store.rows(for: item))
        let title = LibraryPresentation.contentTitle(for: item, library: state.store.library, rowCount: rows.count)
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle(item), systemImage: emptySymbol(item))
                } description: {
                    Text(emptyDescription(item))
                } actions: {
                    if item == .shows {
                        Button("New Show…") { CommandRouter.shared.newShow(nil) }
                        Button("Open…") { CommandRouter.shared.openDocument(nil) }
                    }
                }
                .wwFont(.body)
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
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var inMemoryNoticeDismissed = false

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
            if !state.store.isDurable, !inMemoryNoticeDismissed {
                MessageBar(
                    heading: "The library isn't saved yet in this version",
                    message: "Collections and recent shows are kept only while WaveWrangler is open. Your shows aren't affected.",
                    symbolName: "info.circle",
                    actions: [("Dismiss", { inMemoryNoticeDismissed = true })],
                    identifier: "ww.library.messageBar.inMemory"
                )
            }
        }
    }
}
