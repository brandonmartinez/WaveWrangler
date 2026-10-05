import AppKit
import SwiftUI
import WWCore
import WWEpisodeSetup

/// Setup destination content for one episode: Sources (grouped) and Speakers, plus the selection-driven
/// details panel. This is the view the episode workspace hosts for the Setup destination (IA §4.3). Its
/// command target (`EpisodeSetupViewController`) is registered for the window so menu commands reach it.
struct EpisodeSetupContent: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    var showsInspector = true
    var textScale: CGFloat = 1
    @State private var controller: EpisodeSetupViewController?
    @State private var connecting = false

    var body: some View {
        Group {
            if let controller {
                EpisodeSetupView(model: controller.model, showsInspector: showsInspector)
                    .environment(\.setupTextScale, textScale)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowReader { window in
            // Watch for close synchronously, before any lease is taken in the Task below.
            if let window { SetupEngineProvider.watchClose(of: window) }
            Task { @MainActor in connect(to: window) }
        })
        .onAppear {
            controller?.model.isOnScreen = true
            controller?.model.startObserving()
        }
        .onDisappear {
            // The show's engine stays leased to the window (downloads keep running); only this view's
            // observation stops. The lease ends when the window closes.
            controller?.model.isOnScreen = false
            controller?.model.stopObserving()
        }
    }

    private func connect(to window: NSWindow?) {
        guard let window else { return }
        if let controller {
            controller.attach(to: window)
            return
        }
        guard !connecting else { return }
        connecting = true
        Task { @MainActor in
            let engine = await SetupEngineProvider.engine(for: window, show: store.model.show.id)
            let model = EpisodeSetupModel(store: store, episodeID: episodeID, engine: engine, preference: AppSettingsDownloadPreference.shared)
            if let real = engine as? WWSourcesSetupEngine {
                real.sourceNames = { [weak store] id in
                    store?.model.episodes.lazy.compactMap { $0.source(id)?.displayNameHint }.first ?? "another source"
                }
            }
            let controller = EpisodeSetupViewController(model: model)
            controller.attach(to: window)
            model.isOnScreen = true
            self.controller = controller
            connecting = false
            model.startObserving()
        }
    }
}

/// Reports the hosting window (and later window changes) without adding a view hierarchy of its own.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

struct EpisodeSetupView: View {
    @Bindable var model: EpisodeSetupModel
    var showsInspector: Bool
    @Environment(\.setupTextScale) private var textScale
    private var scale: Double { Double(textScale) }
    @FocusState private var focusedTable: EpisodeSetupModel.FocusedTable?

    var body: some View {
        // Plain stacks, not HSplitView/VSplitView: split views nested in an embedded hosting view
        // re-enter AppKit's constraint update pass (crash on macOS 27). Default sizes are usable (CMD §5).
        // The details panel sits beside the tables when there is room, otherwise below them, so the
        // content always fits its column (no clipped, unreachable rows).
        GeometryReader { geometry in
            let placement = SetupDetailsPlacement.plan(width: geometry.size.width, height: geometry.size.height, scale: scale, userExpanded: model.detailsExpanded)
            Group {
                switch placement {
                case let .beside(width):
                    HStack(spacing: 0) {
                        tables
                        if showsInspector {
                            Divider()
                            SetupInspectorView(model: model).frame(width: width).focusSection()
                        }
                    }
                case let .below(height):
                    VStack(spacing: 0) {
                        tables
                        if showsInspector {
                            Divider()
                            DetailsBar(model: model, expanded: true)
                            SetupInspectorView(model: model).frame(height: height).focusSection()
                        }
                    }
                case .collapsed:
                    VStack(spacing: 0) {
                        tables
                        if showsInspector {
                            Divider()
                            DetailsBar(model: model, expanded: false)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { publish(placement) }
            .onChange(of: placement) { publish(placement) }
            .onChange(of: model.inspectorFocusRequest) {
                // Return in a table opens the details when they are collapsed.
                if case .collapsed = placement { model.detailsExpanded = true }
            }
        }
        .transaction { $0.animation = nil }
        .onChange(of: focusedTable) { model.focusedTable = focusedTable }
        .onAppear { model.startObserving() }
        .onChange(of: model.episode?.sources.map(\.id)) { model.startObserving() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case let .importReview(review):
                ImportReviewSheet(model: model, review: review)
            case let .relink(context):
                RelinkSheet(model: model, context: context)
            case let .number(context):
                NumberSheet(model: model, context: context)
            case let .name(context):
                NameSheet(model: model, context: context)
            }
        }
        .alert(confirmationTitle, isPresented: confirmationBinding, presenting: model.confirmation) { confirmation in
            confirmationButtons(confirmation)
        }
    }

    /// Sources above Speakers. Speakers keeps a usable default share (about four rows minimum, scaled
    /// with text size) and grows with the window (#89); the handle resizes it (drag or VoiceOver adjust).
    private func publish(_ placement: SetupDetailsPlacement) {
        switch placement {
        case .beside: model.detailsShown = true; model.detailsCanCollapse = false
        case .below: model.detailsShown = true; model.detailsCanCollapse = true
        case .collapsed: model.detailsShown = false; model.detailsCanCollapse = true
        }
    }

    private var tables: some View {
        GeometryReader { geometry in
            let handle = 9.0 * scale
            let split = SetupSplitLayout.heights(total: geometry.size.height - handle, scale: scale, speakersFraction: model.speakersFraction)
            VStack(spacing: 0) {
                SourcesSection(model: model, focusedTable: $focusedTable)
                    .frame(height: split.sources)
                    .focusSection()
                SplitHandle(fraction: $model.speakersFraction, total: geometry.size.height, height: handle)
                SpeakersSection(model: model, focusedTable: $focusedTable)
                    .frame(height: split.speakers)
                    .focusSection()
            }
            .coordinateSpace(name: SplitHandle.space)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case let .removeSources(ids)?:
            if ids.count == 1, let name = model.episode?.source(ids[0])?.displayNameHint {
                return "Remove “\(name)” from this episode? The file itself isn't changed or deleted."
            }
            return "Remove \(ids.count) sources from this episode? The files themselves aren't changed or deleted."
        case let .deleteSpeaker(id)?:
            return "Delete speaker “\(model.speakerName(id))”? Its sources become Unassigned."
        case let .deleteGroup(id)?:
            return "Delete the recorder group “\(model.groupName(id))”? Its sources become Ungrouped. No files are changed."
        case let .cancelDownload(id)?:
            return TransferAction.cancelConfirmation(for: model.episode?.source(id)?.displayNameHint ?? "this source").message
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ confirmation: EpisodeSetupModel.Confirmation) -> some View {
        switch confirmation {
        case let .removeSources(ids):
            Button("Remove", role: .destructive) { model.removeSources(ids) }
            Button("Cancel", role: .cancel) {}
        case let .deleteSpeaker(id):
            Button("Delete", role: .destructive) { model.deleteSpeaker(id) }
            Button("Cancel", role: .cancel) {}
        case let .deleteGroup(id):
            Button("Delete", role: .destructive) { model.deleteGroup(id) }
            Button("Cancel", role: .cancel) {}
        case let .cancelDownload(id):
            Button("Cancel Download", role: .destructive) { model.performConfirmed(.cancel, on: id) }
            Button("Keep Downloading", role: .cancel) {}
        }
    }
}

// MARK: - Sources

private struct SourcesSection: View {
    @Bindable var model: EpisodeSetupModel
    var focusedTable: FocusState<EpisodeSetupModel.FocusedTable?>.Binding

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 6) {
            header(presentation)
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
            if let explanation = model.offExplanation {
                HStack(alignment: .firstTextBaseline) {
                    Label { Text(explanation).setupFont(.callout) } icon: { Image(systemName: "slash.circle") }
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Change…") { SetupSettingsLink.open() }
                        .accessibilityHint("Opens Settings › Sources")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ww.setup.downloadsOff")
            }
            if let progress = model.episodeProgress {
                EpisodeProgressView(progress: progress)
            }
            GeometryReader { geometry in
                SourcesTable(model: model, rows: presentation.sourceRows, width: geometry.size.width)
                    .focused(focusedTable, equals: .sources)
            }
                .overlay {
                    if model.episode?.sources.isEmpty ?? true {
                        VStack(spacing: 8) {
                            Label("No sources yet", systemImage: "waveform.path").setupFont(.title3)
                            Text("Import recordings to reference them in this episode. WaveWrangler never moves, renames or changes them.")
                                .setupFont(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Import Sources…") { model.beginImport() }
                        }
                        .padding()
                        .frame(maxWidth: 420)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ww.setup.empty")
                    }
                }
        }
        .padding([.horizontal, .top], 10)
    }

    private func header(_ presentation: SetupPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Sources")
                .setupFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("\(presentation.sourceCount)")
                .setupFont(.headline)
                
                .accessibilityLabel("\(presentation.sourceCount) sources")
            if presentation.needingAttentionCount > 0 || model.onlyNeedingAttention {
                Button {
                    model.onlyNeedingAttention.toggle()
                } label: {
                    Label(SetupPresentation.attentionText(presentation.needingAttentionCount), systemImage: model.onlyNeedingAttention ? "line.3.horizontal.decrease.circle.fill" : "exclamationmark.triangle")
                        .setupFont(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(SetupPresentation.attentionText(presentation.needingAttentionCount))
                .accessibilityValue(model.onlyNeedingAttention ? "showing only these sources" : "showing all sources")
                .accessibilityHint("Shows only sources needing attention, or all sources.")
                .accessibilityIdentifier("ww.setup.attentionFilter")
            }
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Looking at the chosen files…").setupFont(.callout)
            }
            Spacer()
            Button("Import Sources…") { model.beginImport() }
                .accessibilityIdentifier("ww.setup.import")
        }
    }
}

private struct EpisodeProgressView: View {
    let progress: EpisodeDownloadProgress

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 200)
            .accessibilityHidden(true)
            Text(progress.text).setupFont(.callout)
                .accessibilityLabel("Episode downloads")
                .accessibilityValue(progress.text)
                .accessibilityIdentifier("ww.setup.episodeProgress")
        }
    }
}

private struct SourcesTable: View {
    @Bindable var model: EpisodeSetupModel
    let rows: [SetupSourceRow]
    let width: Double
    @Environment(\.setupTextScale) private var textScale
    @State private var customization = TableColumnCustomization<SetupSourceRow>()

    private var scale: Double { Double(textScale) }
    /// Columns that fit (#104): Status always; Name truncates first; hidden values stay in the details
    /// panel and the row's VoiceOver value.
    private var columns: [SetupSourceColumn] { SetupColumnPlan.columns(forWidth: width, scale: scale) }

    var body: some View {
        let shown = columns
        let hidden = Set(SetupSourceColumn.allCases).subtracting(shown)
        Table(of: SetupSourceRow.self, selection: $model.selection, columnCustomization: $customization) {
            TableColumn("Name") { row in
                NameCell(row: row, hidden: hidden)
            }
            .width(min: SetupSourceColumn.nameMinimum(scale: scale), ideal: SetupColumnPlan.nameWidth(shown, tableWidth: width, scale: scale))
            .customizationID(SetupSourceColumn.name.rawValue)
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Epoch") { row in SourceCell(row: row, cell: row.epoch, label: "Epoch", column: "epoch") }
                .width(min: 36 * scale, ideal: SetupSourceColumn.epoch.width(scale: scale))
                .customizationID(SetupSourceColumn.epoch.rawValue)
            TableColumn("Ch") { row in SourceCell(row: row, cell: row.channel, label: "Channel", column: "channel") }
                .width(min: 28 * scale, ideal: SetupSourceColumn.channel.width(scale: scale))
                .customizationID(SetupSourceColumn.channel.rawValue)
            TableColumn("Speaker") { row in SourceCell(row: row, cell: row.speaker, label: "Speaker", column: "speaker") }
                .width(min: 56 * scale, ideal: SetupSourceColumn.speaker.width(scale: scale))
                .customizationID(SetupSourceColumn.speaker.rawValue)
            TableColumn("Role") { row in SourceCell(row: row, cell: row.role, label: "Role", column: "role") }
                .width(min: 56 * scale, ideal: SetupSourceColumn.role.width(scale: scale))
                .customizationID(SetupSourceColumn.role.rawValue)
            TableColumn("Status") { row in
                if let status = row.status, case let .source(id) = row.id {
                    StatusCell(summary: status, identifier: "ww.setup.source.\(id).status")
                }
            }
            .width(min: 100 * scale, ideal: SetupSourceColumn.status.width(scale: scale))
            .customizationID(SetupSourceColumn.status.rawValue)
            .disabledCustomizationBehavior(.visibility)
        } rows: {
            ForEach(rows) { group in
                DisclosureTableRow(group, isExpanded: Binding(
                    get: { !model.collapsedRows.contains(group.id) },
                    set: { expanded in
                        if expanded { model.collapsedRows.remove(group.id) } else { model.collapsedRows.insert(group.id) }
                    }
                )) {
                    ForEach(Self.flattened(group.children ?? [])) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .accessibilityLabel("Sources")
        .accessibilityValue(model.selection.isEmpty ? "No selection" : "\(model.selection.count) selected")
        .accessibilityIdentifier("ww.setup.sources")
        .contextMenu(forSelectionType: SetupRowID.self) { ids in
            SourceContextMenu(model: model, ids: ids)
        } primaryAction: { _ in
            model.inspectorFocusRequest += 1
        }
        .onDeleteCommand { model.requestDeleteFromSources() }
        .onChange(of: model.selection) { model.inspectorFollowsSpeakers = false }
        .environment(\.defaultMinListRowHeight, 22 * scale)
        .onAppear { apply(shown) }
        .onChange(of: shown) { apply(shown) }
    }

    private func apply(_ shown: [SetupSourceColumn]) {
        for column in SetupSourceColumn.allCases where column != .name && column != .status {
            customization[visibility: column.rawValue] = shown.contains(column) ? .visible : .hidden
        }
    }

    static func flattened(_ rows: [SetupSourceRow]) -> [SetupSourceRow] {
        rows.flatMap { [$0] + ($0.children ?? []) }
    }
}

private struct NameCell: View {
    let row: SetupSourceRow
    var hidden: Set<SetupSourceColumn> = []

    var body: some View {
        Group {
            switch row.id {
            case .group:
                Text(row.name).setupFont(.body, weight: .semibold)
            case .channel:
                Label(row.name, systemImage: "arrow.turn.down.right").setupFont(.callout)
            case .source:
                Text(row.name).setupFont(.body)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(hiddenSummary)
        .accessibilityIdentifier(row.id.accessibilityIdentifier)
    }

    /// Values of columns hidden for width, so VoiceOver users don't lose them.
    private var hiddenSummary: String {
        guard case .source = row.id else { return "" }
        var parts: [String] = []
        if hidden.contains(.epoch) { parts.append("epoch \(row.epoch.accessibilityValue)") }
        if hidden.contains(.channel) { parts.append("channel \(row.channel.accessibilityValue)") }
        if hidden.contains(.speaker) { parts.append("speaker \(row.speaker.accessibilityValue)") }
        if hidden.contains(.role) { parts.append("role \(row.role.accessibilityValue)") }
        return parts.joined(separator: ", ")
    }
}

/// A Sources-outline cell. Group rows have no epoch/channel/speaker/role, so those cells are empty (the
/// group row's own label carries its meaning).
private struct SourceCell: View {
    let row: SetupSourceRow
    let cell: CellText
    let label: String
    let column: String

    var body: some View {
        if case .group = row.id {
            EmptyView()
        } else {
            CellView(cell: cell, label: label, identifier: "\(row.id.accessibilityIdentifier).\(column)")
        }
    }
}

private struct CellView: View {
    let cell: CellText
    let label: String
    let identifier: String

    static func isPlaceholder(_ cell: CellText) -> Bool { cell == .none || cell == .unknown }

    var body: some View {
        Text(cell.text)
            .setupFont(.body)
            // Single-glyph placeholders ("—" none, "?" unknown) are drawn bold so their thin strokes keep
            // full label-colour contrast (#100); the VoiceOver value says "none" / "unknown".
            .fontWeight(Self.isPlaceholder(cell) ? .bold : nil)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .accessibilityLabel(label)
            .accessibilityValue(cell.accessibilityValue)
            .accessibilityIdentifier(identifier)
    }
}

struct StatusCell: View {
    let summary: SourceStatusSummary
    let identifier: String

    var body: some View {
        HStack(spacing: 4) {
            StatusIndicator(indicator: summary.indicator, tint: summary.tint)
            Text(summary.displayText)
                .setupFont(.body)
                .lineLimit(2)
                .accessibilityLabel("Status")
                .accessibilityValue(summary.accessibilityValue)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// Symbol/spinner/bar for a state. Shape always carries meaning; tint is optional (ST-02).
struct StatusIndicator: View {
    let indicator: DimensionPresentation.Indicator
    let tint: StatusTint

    var body: some View {
        switch indicator {
        case let .symbol(name):
            Image(systemName: name)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        case .spinner:
            ProgressView().controlSize(.mini).accessibilityHidden(true)
        case let .determinate(value):
            ProgressView(value: value).frame(width: 40).accessibilityHidden(true)
        case .indeterminate:
            ProgressView().progressViewStyle(.linear).frame(width: 40).accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }

    private var color: Color {
        switch tint {
        case .none: .secondary
        case .attention: .orange
        case .failed: .red
        case .secondary: .secondary
        }
    }
}

struct InlineMessage: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label { Text(text).setupFont(.callout).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change not applied")
        .accessibilityIdentifier("ww.setup.message")
    }
}

// MARK: - Speakers

private struct SpeakersSection: View {
    @Bindable var model: EpisodeSetupModel
    var focusedTable: FocusState<EpisodeSetupModel.FocusedTable?>.Binding
    @Environment(\.setupTextScale) private var scale

    var body: some View {
        let rows = model.presentation.speakerRows
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speakers").setupFont(.headline).accessibilityAddTraits(.isHeader)
                Text("\(rows.count)").setupFont(.headline)
                    .accessibilityLabel(rows.count == 1 ? "1 speaker" : "\(rows.count) speakers")
                Spacer()
                Button("New Speaker…") { model.sheet = .name(NameSheetContext(kind: .newSpeaker, initial: "")) }
                    .accessibilityIdentifier("ww.setup.newSpeaker")
            }
            Table(rows, selection: $model.speakerSelection) {
                TableColumn("Speaker") { row in
                    Text(row.name).setupFont(.body).lineLimit(2)
                        .accessibilityLabel(row.name)
                        .accessibilityValue(row.accessibilityValue)
                        .accessibilityIdentifier(row.accessibilityIdentifier)
                }
                TableColumn("Primary") { row in CellView(cell: row.primary, label: "Primary", identifier: "\(row.accessibilityIdentifier).primary") }
                TableColumn("Backups") { row in
                    Text("\(row.backupCount)").setupFont(.body).monospacedDigit()
                        .accessibilityLabel("Backups")
                        .accessibilityValue("\(row.backupCount)")
                }
                .width(min: 50 * scale, ideal: 64 * scale)
                TableColumn("Status") { row in
                    HStack(spacing: 4) {
                        Image(systemName: row.status.symbolName)
                            .foregroundStyle(row.status == .primaryChosen ? Color.secondary : Color.orange)
                            .accessibilityHidden(true)
                        Text(row.status.text).setupFont(.body).lineLimit(2)
                            .accessibilityLabel("Status")
                            .accessibilityValue(row.status.text)
                    }
                }
            }
            .focused(focusedTable, equals: .speakers)
            .accessibilityLabel("Speakers")
            .accessibilityIdentifier("ww.setup.speakers")
            .contextMenu(forSelectionType: SpeakerID.self) { ids in
                SpeakerContextMenu(model: model, ids: ids)
            } primaryAction: { _ in
                model.inspectorFocusRequest += 1
            }
            .onDeleteCommand {
                if let id = model.speakerSelection.first { model.confirmation = .deleteSpeaker(id) }
            }
            .onChange(of: model.speakerSelection) { model.inspectorFollowsSpeakers = !model.speakerSelection.isEmpty }
            .environment(\.defaultMinListRowHeight, 22 * scale)
        }
        .padding(10)
    }
}

// MARK: - Context menus (CMD-03: applicable items only, ≤3 groups, no shortcuts)

private struct SourceContextMenu: View {
    let model: EpisodeSetupModel
    let ids: Set<SetupRowID>

    var body: some View {
        let sources = ids.compactMap(\.sourceID)
        if ids.count == 1, case let .group(groupID?) = ids.first {
            Button("Rename") { model.sheet = .name(NameSheetContext(kind: .renameGroup, initial: model.groupName(groupID), groupID: groupID)) }
            Button("Start New Epoch") { model.selection = [.group(groupID)]; model.startNewEpoch() }
            Divider()
            Button("New Recorder Group…") { model.sheet = .name(NameSheetContext(kind: .newGroup, initial: "")) }
        } else if !sources.isEmpty {
            Menu("Assign to Recorder Group") { GroupChoices(model: model, sources: sources) }
            Menu("Assign Speaker") { SpeakerChoices(model: model, sources: sources) }
            if let ref = model.selectedReference {
                if !ref.isPrimary { Button("Use as Primary") { model.useAsPrimary(ref) } }
                Button("Use as Backup") { model.useAsBackup(ref) }
            }
            if sources.count == 1, let id = sources.first {
                Divider()
                ForEach(model.availableActions(for: id), id: \.self) { action in
                    Button(action.menuTitle) { model.perform(action, on: id) }
                }
                Button("Relink Source…") { model.beginRelink(id) }
                if model.status(of: id).access == .needsPermission || model.status(of: id).access == .denied {
                    Button("Grant Access…") { model.beginRelink(id, mode: .grantAccess) }
                }
            }
            Divider()
            Button(sources.count == 1 ? "Remove from Episode…" : "Remove \(sources.count) Sources from Episode…") { model.confirmation = .removeSources(sources) }
        }
    }
}

struct GroupChoices: View {
    let model: EpisodeSetupModel
    let sources: [SourceID]

    var body: some View {
        ForEach(model.episode?.recorderGroups ?? []) { group in
            Button(group.name) { model.assign(sources, toGroup: group.id) }
        }
        Button("Ungrouped") { model.assign(sources, toGroup: nil) }
        Divider()
        Button("New Recorder Group…") { model.sheet = .name(NameSheetContext(kind: .newGroup, initial: "", assigning: sources)) }
    }
}

struct SpeakerChoices: View {
    let model: EpisodeSetupModel
    let sources: [SourceID]

    var body: some View {
        ForEach(model.episodeSpeakers, id: \.id) { speaker in
            Button(speaker.name) { model.assignSpeaker(speaker.id, to: sources) }
        }
        Button("Unassigned") { model.assignSpeaker(nil, to: sources) }
        Divider()
        Button("New Speaker…") { model.sheet = .name(NameSheetContext(kind: .newSpeaker, initial: "", assigning: sources)) }
    }
}

private struct SpeakerContextMenu: View {
    let model: EpisodeSetupModel
    let ids: Set<SpeakerID>

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Rename") { model.sheet = .name(NameSheetContext(kind: .renameSpeaker, initial: model.speakerName(id), speakerID: id)) }
            Menu("Set Primary") { PrimaryChoices(model: model, speakerID: id) }
            Divider()
            Button("Delete Speaker…") { model.confirmation = .deleteSpeaker(id) }
        }
    }
}

struct PrimaryChoices: View {
    let model: EpisodeSetupModel
    let speakerID: SpeakerID

    var body: some View {
        ForEach(model.channelChoices(for: speakerID), id: \.channel) { choice in
            Button(choice.title) { model.setPrimary(choice.channel, for: speakerID) }
        }
        Button("None") { model.setPrimary(nil, for: speakerID) }
    }
}

extension EpisodeSetupModel {
    struct ChannelChoice {
        var channel: ChannelReference
        var title: String
    }

    /// The speaker's assigned source/channels, for the Primary pop-up and Set Primary menus.
    func channelChoices(for speakerID: SpeakerID) -> [ChannelChoice] {
        guard let episode, let assignment = episode.assignment(for: speakerID) else { return [] }
        let channels = (assignment.primary.map { [$0] } ?? []) + assignment.backups
        return channels.compactMap { channel in
            guard let source = episode.source(channel.sourceID) else { return nil }
            let words = episode.statedChannel(of: source.id).map { "channel \($0 + 1)" } ?? "channel unknown"
            return ChannelChoice(channel: channel, title: "\(source.displayNameHint) · \(words)")
        }
    }

    func requestDeleteFromSources() {
        let sources = selectedSourceIDs
        if !sources.isEmpty {
            confirmation = .removeSources(sources)
        } else if case let .some(.some(groupID)) = selectedGroupID {
            confirmation = .deleteGroup(groupID)
        }
    }
}

enum SetupSettingsLink {
    @MainActor
    static func open() {
        SettingsWindowController.show(pane: .sources)
    }
}

/// Resize handle between the Sources and Speakers tables. Default sizes are usable without it (CMD §5);
/// VoiceOver users adjust it with increment/decrement.
private struct SplitHandle: View {
    static let space = "ww.setup.tables"
    @Binding var fraction: Double
    let total: Double
    let height: Double
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    fraction = SetupSplitLayout.fraction(forHandleAt: value.location.y, total: total)
                }
        )
        // Exposed as a slider (increment/decrement by 5%), so assistive tech gets a real role and value.
        .accessibilityRepresentation {
            Slider(value: $fraction, in: SetupSplitLayout.fractionRange, step: 0.05) {
                Text("Speakers table height")
            }
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            .accessibilityIdentifier("ww.setup.split")
        }
    }
}

/// The details panel's header bar in narrow windows: names the selection and shows or hides the details
/// (#104). Collapsed by default when the window is short, so the tables keep their rows.
private struct DetailsBar: View {
    @Bindable var model: EpisodeSetupModel
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).setupFont(.headline).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(expanded ? "Hide Details" : "Show Details") { model.detailsExpanded = !expanded }
                .accessibilityIdentifier("ww.setup.detailsToggle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.setup.detailsBar")
    }

    private var title: String {
        switch model.inspectorSubject {
        case let .source(id): "Details — \(model.episode?.source(id)?.displayNameHint ?? "Source")"
        case let .group(id): "Details — \(model.groupName(id))"
        case let .speaker(id): "Details — \(model.speakerName(id))"
        case .none: "Details"
        }
    }
}
