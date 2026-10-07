import AppKit
import SwiftUI
import WWCore
import WWOrganizer

/// Show window content (IA §4): two-level sidebar (Episodes, Show Info) → destination content →
/// selection-driven inspector. `ShowDocument` hosts this view; each window gets its own `ShowWindowState`
/// while the document, its undo history and save state are shared (IA-02).
struct ShowWorkspaceView: View {
    let store: ShowDocumentStore

    @State private var state: ShowWindowState

    init(store: ShowDocumentStore) {
        self.store = store
        _state = State(initialValue: ShowWindowState(store: store))
    }

    var body: some View {
        ShowWindowContent(state: state)
            .wwAppEnvironment()
    }
}

private struct ShowWindowContent: View {
    @Bindable var state: ShowWindowState

    private var store: ShowDocumentStore { state.store }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 900 {
                HStack(spacing: 0) {
                    core
                    if state.inspectorPresented {
                        Divider()
                        InspectorContainer(state: state)
                            .frame(width: 260)
                    }
                }
            } else {
                core
                    // No inspectorColumnWidth(min:ideal:max:): inside an AppKit-hosted window it caused a
                    // re-entrant constraint-update loop (crash) on macOS 27; the default inspector width is used.
                    .inspector(isPresented: $state.inspectorPresented) {
                        InspectorContainer(state: state)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show content and inspector")
        .accessibilityIdentifier("ww.show.contentInspector")
        .toolbar {
            ToolbarItem(placement: .principal) {
                DestinationControl(state: state)
            }
        }
    }

    private var core: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            ShowSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 380)
        } detail: {
            // The message bar is a top safe-area inset of the detail content: the content's own (possibly very tall)
            // ideal height can't push the bar out of the window.
            ShowDetailContent(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ShowMessageBar(state: state)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SaveStatusItem(state: state)
                Button {
                    state.toggleInspector()
                } label: {
                    Label(state.inspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
                .help(state.inspectorPresented ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
            }
        }
        // The NSWindow owns the complete 760×440 minimum. A content-driven minimum here is only for
        // the pre-inspector split and can re-enter AppKit constraint updates when the inspector is
        // visible; let the sidebar, detail and inspector lay out inside the window instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBinder(state: state))
        .onChange(of: store.model.episodes.map(\.id)) { old, _ in
            state.reconcileSelection(previousOrder: old)
        }
        .onChange(of: store.model) { _, _ in state.updateSubtitle() }
        .onChange(of: state.sidebarSelection) { _, _ in state.updateSubtitle() }
        .onChange(of: state.saveStatus.state) { old, new in state.saveStateDidChange(from: old, to: new) }
    }
}

// MARK: - Sidebar

private struct ShowSidebar: View {
    @Bindable var state: ShowWindowState
    @FocusState private var listFocused: Bool

    var body: some View {
        let episodes = state.store.model.episodes
        List(selection: $state.sidebarSelection) {
            Section {
                HStack {
                    Text("Episodes")
                    Spacer()
                    Button {
                        state.newEpisode()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Episode (⇧⌘N)")
                    .disabled(!state.canEdit)
                    .accessibilityLabel("New Episode")
                    .accessibilityIdentifier("ww.show.sidebar.newEpisode")
                }
                .listRowSeparator(.hidden)

                ForEach(episodes) { episode in
                    EpisodeSidebarRow(state: state, episode: episode)
                        .tag(ShowWindowState.SidebarSelection.episode(episode.id))
                        .contextMenu { episodeMenu(episode) }
                }
                .onMove { source, destination in state.moveEpisodes(fromOffsets: source, toOffset: destination) }
            }
            Section {
                Text("Show")
                    .listRowSeparator(.hidden)
                Label("Show Info", systemImage: "info.circle")
                    .wwFont(.body)
                    .emphasizedSelectionForeground(selectedInFocusedList: state.episodeListFocused
                        && state.sidebarSelection == .showInfo)
                    .tag(ShowWindowState.SidebarSelection.showInfo)
                    .accessibilityIdentifier("ww.show.sidebar.showInfo")
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .onChange(of: listFocused, initial: true) { _, focused in state.episodeListFocused = focused }
        .accessibilityLabel("Episodes")
        .accessibilityValue(ShowSidebarPresentation.episodesValue(episodes.count))
        .accessibilityIdentifier("ww.show.sidebar.episodes")
    }

    @ViewBuilder
    private func episodeMenu(_ episode: Episode) -> some View {
        Button("Rename") {
            state.sidebarSelection = .episode(episode.id)
            state.renameSelectedEpisode()
        }
        .disabled(!state.canEdit)
        Button("Episode Info") {
            state.sidebarSelection = .episode(episode.id)
            state.showEpisodeInfo()
        }
        Divider()
        if state.store.model.canMoveEpisode(episode.id, by: -1) {
            Button("Move Up") {
                state.sidebarSelection = .episode(episode.id)
                state.moveSelectedEpisode(by: -1)
            }
        }
        if state.store.model.canMoveEpisode(episode.id, by: 1) {
            Button("Move Down") {
                state.sidebarSelection = .episode(episode.id)
                state.moveSelectedEpisode(by: 1)
            }
        }
        Divider()
        Button("Delete Episode…") {
            state.sidebarSelection = .episode(episode.id)
            state.deleteSelectedEpisode()
        }
        .disabled(!state.canEdit)
    }
}

private struct EpisodeSidebarRow: View {
    @Bindable var state: ShowWindowState
    let episode: Episode
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if state.renamingEpisodeID == episode.id {
            TextField("Episode title", text: $draft)
                .focused($fieldFocused)
                .accessibilityLabel("Episode title")
                .accessibilityIdentifier("ww.show.sidebar.rename")
                .onAppear {
                    draft = episode.title
                    fieldFocused = true
                }
                .onSubmit { commit() }
                .onExitCommand { state.renamingEpisodeID = nil }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused, state.renamingEpisodeID == episode.id { commit() }
                }
        } else {
            Label {
                Text(ShowSidebarPresentation.episodeRowTitle(episode))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(ShowSidebarPresentation.episodeRowTitle(episode))
            } icon: {
                Image(systemName: "music.mic").accessibilityHidden(true)
            }
            .wwFont(.body)
            .emphasizedSelectionForeground(selectedInFocusedList: state.episodeListFocused
                && state.sidebarSelection == .episode(episode.id))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ShowSidebarPresentation.episodeRowTitle(episode))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier(ShowSidebarPresentation.episodeIdentifier(episode.id))
        }
    }

    private func commit() {
        if !state.commitRename(episode.id, to: draft) {
            // Refused (e.g. empty title): keep editing; the reason is announced.
            state.announce("A title can't be empty.")
            fieldFocused = true
        }
    }
}

// MARK: - Content

private struct ShowDetailContent: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        let model = state.store.model
        if state.sidebarSelection == .showInfo {
            ShowInfoSummary(state: state)
        } else if model.episodes.isEmpty {
            ContentUnavailableView {
                Label("No episodes yet", systemImage: "music.mic")
            } description: {
                Text("Add an episode to start organizing its sources and speakers.")
            } actions: {
                Button("New Episode") { state.newEpisode() }
                    .disabled(!state.canEdit)
                    .accessibilityIdentifier("ww.show.empty.newEpisode")
            }
            .wwFont(.body)
        } else if let panel = state.destination.blockedPanel {
            BlockedDestinationView(destination: state.destination, panel: panel) { state.select(.setup) }
        } else if let episode = state.selectedEpisode {
            if state.destination == .alignment {
                if episode.recorderGroups.isEmpty {
                    BlockedDestinationView(
                        destination: .alignment,
                        panel: BlockedPanel(
                            heading: "Alignment isn't available yet",
                            body: "Set up at least one recorder group in Setup first. WaveWrangler hasn't read or analysed any audio."
                        )
                    ) { state.select(.setup) }
                } else {
                    EpisodeAlignmentContent(state: state, episodeID: episode.id)
                }
            } else {
                SetupContainerView(state: state, episode: episode)
            }
        } else {
            ContentUnavailableView("No Episode Selected", systemImage: "music.mic", description: Text("Select an episode in the sidebar."))
                .wwFont(.body)
        }
    }
}

/// IA-12: blocked, not hidden, not dead. Heading role; the text is the full accessible content.
struct BlockedDestinationView: View {
    let destination: ShowDestination
    let panel: BlockedPanel
    let goToSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .wwFont(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(panel.heading)
                    .wwFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("ww.show.blocked.heading")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(panel.body)
                    .wwFont(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                Button(panel.buttonTitle, action: goToSetup)
                    .accessibilityIdentifier("ww.show.blocked.goToSetup")
                    .help("Go to Setup (⌘1)")
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.heading)
        .accessibilityIdentifier("ww.show.blocked.\(destination.rawValue)")
    }
}

private struct ShowInfoSummary: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        let model = state.store.model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.show.title)
                    .wwFont(.title)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Episodes") { Text("\(model.episodes.count)") }
                LabeledContent("Speakers") { Text("\(model.speakers.count)") }
                LabeledContent("Location") { Text(ShowInfoInspector.locationText(state.store.document?.fileURL)) }
                LabeledContent("Save status") { Text(state.presentation.itemText) }
                Text("Edit the show's title and notes in the inspector (View › Show Inspector, ⌃⌘I).")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .wwFont(.body)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ShowMessageBar: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        let presentation = state.presentation
        // The unsaved-changes offer (C2b) takes the bar first; save-state messages follow once it is resolved.
        if state.isWindowAttached, let offer = state.editCheckpointOffer {
            MessageBar(
                heading: offer.presentation.heading,
                message: offer.presentation.body,
                symbolName: offer.presentation.symbolName,
                actions: offer.presentation.actions.map { action in (action.rawValue, { state.performEditCheckpointAction(action) }) }
            )
            .onAppear { state.editCheckpointOfferDidAppear(offer.presentation) }
            .onChange(of: offer.presentation.heading) { _, _ in state.editCheckpointOfferDidAppear(offer.presentation) }
        } else if let bar = presentation.messageBar, state.dismissedMessageBar != bar.heading {
            MessageBar(
                heading: bar.heading,
                message: bar.body,
                symbolName: presentation.symbolName ?? "info.circle",
                actions: bar.actions.map { action in (action.rawValue, { state.perform(action) }) }
            )
        } else if let document = state.store.document, let notice = document.status.copyNotice {
            // ST-16: after Save a Copy Elsewhere…, until dismissed.
            MessageBar(heading: notice, message: "", symbolName: "doc.on.doc",
                       actions: [("Dismiss", { document.status.setCopyNotice(nil) })])
        }
    }
}

// MARK: - Window binding

/// Connects the SwiftUI content to its NSWindow: registers per-window state for menu routing, enables
/// toolbar bridging, keeps the subtitle current and tells the library the show is open.
private struct WindowBinder: NSViewRepresentable {
    let state: ShowWindowState

    func makeNSView(context: Context) -> BinderView {
        let view = BinderView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: BinderView, context: Context) {
        nsView.state = state
    }

    final class BinderView: NSView {
        var state: ShowWindowState?
        private weak var attachedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let state, window !== attachedWindow else { return }
            attachedWindow = window
            state.attach(to: window)
        }
    }
}
