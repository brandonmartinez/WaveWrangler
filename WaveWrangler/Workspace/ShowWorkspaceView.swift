import AppKit
import SwiftUI
import WWCore
import WWOrganizer

/// One episode's editor. Browsing and episode management live in Library.
struct ShowWorkspaceView: View {
    @Bindable var state: ShowWindowState

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
            // The hand-built split keeps content and inspector reachable in a 760-wide window (T-M2-01).
            // Switching this branch on the destination re-enters AppKit's constraint update and aborts,
            // so every destination uses it, and the inspector stays narrow enough for the Sources table
            // to keep its columns' minimum width at the default size (#129).
            if geometry.size.width < 900 {
                HStack(spacing: 0) {
                    core
                    if state.inspectorPresented {
                        Divider()
                        InspectorContainer(state: state)
                            .frame(width: state.compactInspectorWidth)
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
        .sheet(isPresented: $state.recordingsPresented) {
            if let episode = state.selectedEpisode {
                VStack(spacing: 0) {
                    HStack {
                        Text("Recordings & Speakers").font(.headline)
                        Spacer()
                        Button("Done") { state.recordingsPresented = false }
                            .keyboardShortcut(.defaultAction)
                    }.padding(12)
                    SetupContainerView(state: state, episode: episode)
                }
                .frame(minWidth: 760, idealWidth: 1000, minHeight: 540, idealHeight: 680)
                .wwAppEnvironment()
            }
        }
    }

    private var core: some View {
        ShowDetailContent(state: state)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            ShowMessageBar(state: state)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Library", systemImage: "books.vertical") {
                    if let document = state.store.document {
                        LibraryWindowController.show(document: document)
                    }
                }
                .accessibilityIdentifier("ww.show.library")
                SaveStatusItem(state: state)
                if state.destination == .alignment, state.selectedEpisode != nil {
                    WorkspaceInspectorToggles(state: state)
                } else {
                    Button {
                        state.toggleInspector()
                    } label: {
                        Label(state.inspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                    }
                    .help(state.inspectorPresented ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
                }
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

struct LibraryEpisodeList: View {
    @Bindable var state: ShowWindowState
    let openEpisode: (EpisodeID) -> Void
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
        .onChange(of: state.renamingEpisodeID) { previous, current in
            if previous != nil, current == nil { listFocused = true }
        }
        .accessibilityLabel("Episodes")
        .accessibilityValue(ShowSidebarPresentation.episodesValue(episodes.count))
        .accessibilityIdentifier("ww.library.episodes")
        .contextMenu(forSelectionType: ShowWindowState.SidebarSelection.self) { selections in
            if selections.count == 1, let selection = selections.first, case .episode(let id) = selection,
               let episode = state.store.model.episode(id) {
                episodeMenu(episode)
            }
        } primaryAction: { selections in
            for case .episode(let id) in selections { openEpisode(id) }
        }
    }

    @ViewBuilder
    private func episodeMenu(_ episode: Episode) -> some View {
        Button("Open Episode") { openEpisode(episode.id) }
        Divider()
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
        if state.boundEpisodeID != nil, state.selectedEpisode == nil {
            ContentUnavailableView {
                Label("Episode Unavailable", systemImage: "music.mic")
            } description: {
                Text("This episode is no longer in the show. Undo its deletion or return to Library to open another episode.")
            } actions: {
                Button("Library") { LibraryWindowController.show() }
            }
        } else if state.sidebarSelection == .showInfo && state.boundEpisodeID == nil {
            ShowInfoSummary(state: state)
        } else if state.destination == .review {
            if let episode = state.selectedEpisode {
                EpisodeCleanupContent(state: state, episodeID: episode.id)
                    .id(episode.id)
            } else {
                ContentUnavailableView("No Episode Selected", systemImage: "music.mic")
            }
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
                VStack(spacing: 0) {
                    if !episode.recorderGroups.isEmpty {
                        EpisodeAlignmentContent(state: state, episodeID: episode.id)
                            .id(episode.id)
                    } else {
                        ContentUnavailableView {
                            Label {
                                Text("Add recordings to begin").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "waveform").foregroundStyle(.primary)
                            }
                        } description: {
                            Text("Organize recordings into recorder groups and confirm their originals in Setup.")
                                .foregroundStyle(.primary)
                        } actions: {
                            Button("Add recordings…", systemImage: "plus") { state.recordingsPresented = true }
                        }
                    }
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
                    .accessibilityIdentifier("ww.show.showInfoSummary.title")
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

struct ShowMessageBar: View {
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
        nsView.bind(state)
    }

    final class BinderView: NSView {
        var state: ShowWindowState?
        private weak var attachedWindow: NSWindow?

        func bind(_ state: ShowWindowState) {
            guard self.state !== state else { return }
            self.state?.reviewWindowDidClose()
            self.state = state
            attachedWindow = nil
            if let window {
                attachedWindow = window
                state.attach(to: window)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let state, window !== attachedWindow else { return }
            attachedWindow = window
            state.attach(to: window)
        }
    }
}
