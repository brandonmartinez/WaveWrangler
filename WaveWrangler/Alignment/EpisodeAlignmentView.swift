import AppKit
import Foundation
import SwiftUI
import WWAlignPipeline
import WWCore

struct EpisodeAlignmentContent: View {
    @Bindable var state: ShowWindowState
    let episodeID: EpisodeID
    @State private var model: EpisodeAlignmentModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let model {
                AlignmentContentHost(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let startupError {
                ContentUnavailableView(
                    "Alignment unavailable",
                    systemImage: "waveform.badge.exclamationmark",
                    description: Text(startupError)
                )
                .accessibilityIdentifier("alignment.startupError")
            } else {
                ProgressView("Preparing Alignment")
                    .accessibilityIdentifier("alignment.preparing")
            }
        }
        .task(id: episodeID) {
            do {
                guard let document = state.store.document else { return }
                let runtime = try await AlignmentRuntimeProvider.runtime(
                    for: document,
                    episode: episodeID
                )
                let value = EpisodeAlignmentModel(document: document, episodeID: episodeID, runtime: runtime)
                model = value
                state.alignmentModel = value
                value.load()
            } catch {
                startupError = String(describing: error)
            }
        }
        .onDisappear {
            model?.stopAudition()
            if let model, state.alignmentModel === model { state.alignmentModel = nil }
        }
    }
}

private struct AlignmentContentHost: NSViewRepresentable {
    let model: EpisodeAlignmentModel

    func makeNSView(context: Context) -> HostedView {
        HostedView(model: model)
    }

    func updateNSView(_ nsView: HostedView, context: Context) {
        nsView.hostingView.rootView = AlignmentWorkspace(model: model)
    }

    final class HostedView: NSView {
        let hostingView: NSHostingView<AlignmentWorkspace>

        init(model: EpisodeAlignmentModel) {
            hostingView = NSHostingView(rootView: AlignmentWorkspace(model: model))
            hostingView.sizingOptions = []
            // The hosting view is the single labelled container for the workspace. Labelling it on the
            // AppKit side keeps the SwiftUI tree untouched: `accessibilityElement(children: .contain)`
            // on the SwiftUI root absorbed the scroll area's identifier and hid it from assistive
            // clients entirely (#219). `HostedView` itself stays a pass-through so only one group exists.
            hostingView.setAccessibilityElement(true)
            hostingView.setAccessibilityRole(.group)
            hostingView.setAccessibilityLabel("Alignment workspace")
            hostingView.setAccessibilityIdentifier("ww.alignment.workspaceRoot")
            super.init(frame: .zero)
            setAccessibilityElement(false)
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
}

private struct AlignmentWorkspace: View {
    @Bindable var model: EpisodeAlignmentModel

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alignment")
                        .font(.title2.weight(.semibold))
                    Text("Inspect recorder clocks, place manual corrections and audition source regions. Acoustic consistency is evidence, never probability or clock approval.")
                        .foregroundStyle(.secondary)
                }
                Button(model.isWorking ? "Analysing…" : "Analyse Available Sources") {
                    model.analyse()
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("alignment.analyse")

                AlignmentOutlineTable(model: model)
                    .id("ww.alignment.groupSection")
                    .frame(minHeight: 180, idealHeight: 240)

                GroupBox("Anchors for \(model.selectedRow?.epochLabel ?? "selected epoch")") {
                    Table(model.selectedAnchors, selection: $model.anchorSelection) {
                        TableColumn("Source time") { anchor in
                            Text(AlignmentPresentation.formatTime(anchor.sourceSeconds))
                                .accessibilityLabel("Source time")
                                .accessibilityValue(AlignmentPresentation.formatTime(anchor.sourceSeconds))
                                .accessibilityIdentifier("ww.alignment.anchor.\(anchor.id).sourceTime")
                        }
                        .width(ideal: 130)
                        TableColumn("Group time") { anchor in
                            Text(AlignmentPresentation.formatTime(anchor.groupSeconds))
                                .accessibilityLabel("Group time")
                                .accessibilityValue(AlignmentPresentation.formatTime(anchor.groupSeconds))
                                .accessibilityIdentifier("ww.alignment.anchor.\(anchor.id).groupTime")
                        }
                        .width(ideal: 130)
                        TableColumn("Aligned time") { anchor in
                            Text(AlignmentPresentation.formatTime(anchor.alignedSeconds))
                                .accessibilityLabel("Aligned time")
                                .accessibilityValue(AlignmentPresentation.formatTime(anchor.alignedSeconds))
                                .accessibilityIdentifier("ww.alignment.anchor.\(anchor.id).alignedTime")
                        }
                        .width(ideal: 130)
                    }
                    .frame(minHeight: 90, idealHeight: 120, maxHeight: 160)
                    .accessibilityIdentifier("ww.alignment.anchors")
                }
                .id("ww.alignment.anchorSection")

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    Button("Accept as Manual") { model.acceptProposal() }
                        .disabled(model.selectedRow?.state.heading.hasPrefix("Proposed") != true)
                        .help(model.selectedRow?.state.heading.hasPrefix("Proposed") == true
                              ? "Accept this acoustic proposal as a manual decision."
                              : "Select an unconfirmed proposal.")
                        .accessibilityIdentifier("alignment.acceptProposal")
                    Button("Reject") { model.rejectProposal() }
                        .disabled(model.selectedRow?.state.heading.hasPrefix("Proposed") != true)
                        .help(model.selectedRow?.state.heading.hasPrefix("Proposed") == true
                              ? "Reject this proposal and leave the epoch unsupported."
                              : "Select an unconfirmed proposal.")
                        .accessibilityIdentifier("alignment.rejectProposal")
                    Button("Edit Numerically…") { model.requestNumericEditor() }
                        .disabled(!model.canCorrect)
                        .help(model.canCorrect ? "Type a signed rate and offset correction." : "Select an epoch that can be timed manually.")
                        .accessibilityIdentifier("alignment.editNumeric")
                    Button("Place Anchors…") { model.requestAnchorEditor() }
                        .disabled(!model.canCorrect)
                        .help(model.canCorrect ? "Type source and aligned time anchors." : "Select an epoch that can be timed manually.")
                        .accessibilityIdentifier("alignment.placeAnchors")
                    Button("Place Anchor at Playhead") { model.placeAnchorAtPlayhead() }
                        .disabled(!model.canPlaceAnchorAtPlayhead)
                        .help(
                            model.canPlaceAnchorAtPlayhead
                                ? "Append an anchor at the stopped audition position."
                                : "Stop audition on an epoch that already has a persisted anchor map."
                        )
                        .accessibilityIdentifier("alignment.placeAnchorAtPlayhead")
                    Button("Delete Anchor") { model.requestDeleteSelectedAnchor() }
                        .disabled(model.anchorSelection == nil)
                        .help(model.anchorSelection == nil ? "Select an anchor first." : "Delete the selected anchor.")
                        .accessibilityIdentifier("alignment.deleteAnchor")
                    Button("Edit Anchor…") { model.requestSelectedAnchorEditor() }
                        .disabled(model.anchorSelection == nil)
                        .help(model.anchorSelection == nil
                              ? "Select an anchor first."
                              : "Type the selected anchor's aligned time.")
                        .accessibilityIdentifier("alignment.editAnchor")
                    Button("Start New Epoch at Anchor") { model.startNewEpochAtSelectedAnchor() }
                        .disabled(!model.canStartNewEpoch)
                        .help(model.canStartNewEpoch
                              ? "Split this occurrence at the selected anchor."
                              : "Select an anchor inside an accepted map's recorded span, not at either end.")
                        .accessibilityIdentifier("alignment.startNewEpoch")
                }

                GroupBox("Audition") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 240), alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        LabeledContent("Start") {
                            TextField("Start", value: $model.auditionStartSeconds, format: .number.precision(.fractionLength(3)))
                                .frame(width: 100)
                                .accessibilityValue("\(AlignmentPresentation.formatTime(model.auditionStartSeconds))")
                                .accessibilityIdentifier("ww.alignment.audition.range.start")
                        }
                        LabeledContent("Duration") {
                            TextField("Duration", value: $model.auditionDurationSeconds, format: .number.precision(.fractionLength(3)))
                                .frame(width: 100)
                                .accessibilityValue("\(AlignmentPresentation.formatTime(model.auditionDurationSeconds))")
                                .accessibilityIdentifier("ww.alignment.audition.range.duration")
                        }
                        Button(model.canStopAudition ? "Stop" : "Play") {
                            model.canStopAudition ? model.stopAudition() : model.auditionSelection()
                        }
                        .disabled(!model.canAudition && !model.canStopAudition)
                        .help(model.canAudition ? "Play the selected source range. Nothing is exported." : "Select a mapped epoch with an available source.")
                        .accessibilityIdentifier("ww.alignment.audition.play")
                    }
                }
                .accessibilityIdentifier("ww.alignment.audition")

                if let region = model.selectedRegion {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(region.copy.heading, systemImage: region.copy.symbol)
                            .font(.callout.weight(.semibold))
                            .accessibilityLabel("Audition position state")
                            .accessibilityValue(region.copy.heading)
                            .accessibilityIdentifier("ww.alignment.region.heading")
                        Text(region.copy.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ww.alignment.region.evidence")
                        HStack {
                            ForEach(region.copy.remedies, id: \.self) { remedy in
                                Button(remedy) { model.goToRegionRemedy(remedy) }
                                    .accessibilityIdentifier(
                                        "ww.alignment.region.remedy.\(remedy.replacingOccurrences(of: " ", with: "-"))"
                                    )
                            }
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ww.alignment.region")
                }

                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("alignment.status")
                Text(model.dependents)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ww.alignment.dependents")
                Text(model.auditionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("alignment.auditionStatus")
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("alignment.error")
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .accessibilityLabel("Alignment workspace scroll area")
            .accessibilityIdentifier("ww.alignment.workspace")
            .onAppear {
                AlignmentKeyHandler.install()
            }
            .onChange(of: model.requestedAnchorFocus) { _, anchor in
                guard let anchor else { return }
                scrollProxy.scrollTo("ww.alignment.anchorSection", anchor: .center)
                AlignmentAnchorFocus.focus(anchor: anchor, model: model, in: NSApp.keyWindow)
            }
            .onChange(of: model.requestedEpochFocus) { _, epoch in
                guard let epoch else { return }
                scrollProxy.scrollTo("ww.alignment.groupSection", anchor: .top)
                AlignmentEpochFocus.focus(epoch: epoch, model: model, in: NSApp.keyWindow)
            }
            .sheet(item: $model.editorRequest) { request in
                switch request {
                case .numeric:
                    NumericTimingSheet(model: model)
                case .anchors:
                    AnchorTimingSheet(model: model)
                case let .anchor(anchorID):
                    EditAnchorSheet(model: model, anchorID: anchorID)
                }
            }
        }
    }

}

private struct AlignmentOutlineTable: View {
    @Bindable var model: EpisodeAlignmentModel
    @State private var selection: AlignmentOutlineRow.ID?
    @State private var collapsedGroups: Set<AlignmentOutlineRow.ID> = []

    var body: some View {
        Table(of: AlignmentOutlineRow.self, selection: $selection) {
            // The first column's cell is collapsed into a single described element: the container SwiftUI
            // wraps outline cells in is otherwise left without a description, which the audit flags (#219).
            // The labels stay equal to the text itself so assertions can match a cell by its epoch name.
            TableColumn("Recorder Group") { row in
                Text(row.groupName)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.groupName)
            }
            .width(ideal: 170)
            TableColumn("Epoch") { row in
                Text(row.epochLabel)
            }
            .width(ideal: 80)
            TableColumn("Sources") { row in
                Text(row.sourceNames)
            }
            .width(ideal: 210)
            TableColumn("State") { row in
                AlignmentStateCell(row: row)
            }
            .width(ideal: 150)
            TableColumn("Rate") { row in
                Text(row.rateText)
                    .accessibilityLabel("Rate correction")
                    .accessibilityIdentifier(row.rateIdentifier)
            }
            .width(ideal: 100)
            TableColumn("Offset") { row in
                Text(row.offsetText)
                    .accessibilityLabel("Offset")
                    .accessibilityIdentifier(row.offsetIdentifier)
            }
            .width(ideal: 100)
        } rows: {
            ForEach(outlineRows) { group in
                DisclosureTableRow(group, isExpanded: expansionBinding(for: group.id)) {
                    ForEach(group.children ?? []) { epoch in
                        TableRow(epoch)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("Recorder groups and alignment epochs")
        .accessibilityIdentifier("ww.alignment.groups")
        .onAppear {
            selection = model.selection.map(AlignmentOutlineRow.ID.epoch)
        }
        .onChange(of: selection) { _, value in
            model.selection = value?.epochID
        }
        .onChange(of: model.selection) { _, value in
            selection = value.map(AlignmentOutlineRow.ID.epoch)
        }
    }

    private var outlineRows: [AlignmentOutlineRow] {
        var order: [RecorderGroupID] = []
        var grouped: [RecorderGroupID: [AlignmentRow]] = [:]
        for row in model.rows {
            if grouped[row.groupID] == nil { order.append(row.groupID) }
            grouped[row.groupID, default: []].append(row)
        }
        return order.compactMap { groupID in
            guard let epochs = grouped[groupID], let first = epochs.first else { return nil }
            return AlignmentOutlineRow(
                id: .group(groupID),
                groupName: first.groupName,
                epochLabel: "\(epochs.count) epoch\(epochs.count == 1 ? "" : "s")",
                sourceNames: "\(Set(epochs.flatMap { $0.sourceNames.split(separator: ",").map(String.init) }).count) sources",
                state: nil,
                ratePPM: nil,
                offsetMilliseconds: nil,
                children: epochs.map(AlignmentOutlineRow.init)
            )
        }
    }

    private func expansionBinding(for id: AlignmentOutlineRow.ID) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { expanded in
                if expanded { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
            }
        )
    }
}

@MainActor
private enum AlignmentEpochFocus {
    static func focus(epoch: RecordingEpochID, model: EpisodeAlignmentModel, in window: NSWindow?) {
        DispatchQueue.main.async {
            attempt(epoch: epoch, model: model, in: window, remaining: 30)
        }
    }

    private static func attempt(
        epoch: RecordingEpochID,
        model: EpisodeAlignmentModel,
        in window: NSWindow?,
        remaining: Int
    ) {
        guard model.requestedEpochFocus == epoch else { return }
        guard let window, window.attachedSheet == nil,
              let table = AlignmentTableLookup.table(identifier: "ww.alignment.groups", in: window.contentView),
              table.selectedRow >= 0
        else {
            guard remaining > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                attempt(epoch: epoch, model: model, in: window, remaining: remaining - 1)
            }
            return
        }
        table.scrollRowToVisible(table.selectedRow)
        _ = window.makeFirstResponder(table)
        if window.firstResponder === table {
            model.requestedEpochFocus = nil
            return
        }
        guard remaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            attempt(epoch: epoch, model: model, in: window, remaining: remaining - 1)
        }
    }
}

@MainActor
private enum AlignmentTableLookup {
    static func table(identifier: String, in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            if let table = view as? NSTableView { return table }
            if let table = firstTable(in: view) { return table }
        }
        for child in view.subviews {
            if let table = table(identifier: identifier, in: child) { return table }
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }
}

private struct AlignmentStateCell: View {
    let row: AlignmentOutlineRow

    var body: some View {
        if let state = row.state, let epochID = row.epochID {
            Label(state.heading, systemImage: state.symbol)
                .accessibilityLabel("\(state.heading). \(state.evidence)")
                .accessibilityIdentifier("ww.alignment.epoch.\(epochID).state")
        } else {
            Text("—").accessibilityLabel("Group summary")
        }
    }
}

private struct AlignmentOutlineRow: Identifiable {
        enum ID: Hashable {
            case group(RecorderGroupID)
            case epoch(RecordingEpochID)

            var epochID: RecordingEpochID? {
                guard case let .epoch(id) = self else { return nil }
                return id
            }
        }

        var id: ID
        var groupName: String
        var epochLabel: String
        var sourceNames: String
        var state: AlignmentStateCopy?
        var ratePPM: Double?
        var offsetMilliseconds: Double?
        var children: [AlignmentOutlineRow]?

        var epochID: RecordingEpochID? { id.epochID }
        var rateIdentifier: String {
            epochID.map { "ww.alignment.epoch.\($0).rate" } ?? "ww.alignment.group.rate"
        }
        var offsetIdentifier: String {
            epochID.map { "ww.alignment.epoch.\($0).offset" } ?? "ww.alignment.group.offset"
        }
        var rateText: String {
            guard let ratePPM else { return "—" }
            return String(format: "%+.3f ppm", ratePPM)
        }
        var offsetText: String {
            guard let offsetMilliseconds else { return "—" }
            return String(format: "%+.3f ms", offsetMilliseconds)
        }

        init(
            id: ID,
            groupName: String,
            epochLabel: String,
            sourceNames: String,
            state: AlignmentStateCopy?,
            ratePPM: Double?,
            offsetMilliseconds: Double?,
            children: [AlignmentOutlineRow]?
        ) {
            self.id = id
            self.groupName = groupName
            self.epochLabel = epochLabel
            self.sourceNames = sourceNames
            self.state = state
            self.ratePPM = ratePPM
            self.offsetMilliseconds = offsetMilliseconds
            self.children = children
        }

        init(_ row: AlignmentRow) {
            id = .epoch(row.epochID)
            groupName = ""
            epochLabel = row.epochLabel
            sourceNames = row.sourceNames
            state = row.state
            ratePPM = row.ratePPM
            offsetMilliseconds = row.offsetMilliseconds
            children = nil
    }
}

@MainActor
private enum AlignmentAnchorFocus {
    static func focus(anchor: Int, model: EpisodeAlignmentModel, in window: NSWindow?) {
        DispatchQueue.main.async {
            attempt(anchor: anchor, model: model, in: window, remaining: 30)
        }
    }

    private static func attempt(
        anchor: Int,
        model: EpisodeAlignmentModel,
        in window: NSWindow?,
        remaining: Int
    ) {
        guard model.requestedAnchorFocus == anchor else { return }
        if let window, window.attachedSheet == nil,
           let table = AlignmentTableLookup.table(identifier: "ww.alignment.anchors", in: window.contentView),
           let row = model.selectedAnchors.firstIndex(where: { $0.id == anchor }),
           row < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            _ = window.makeFirstResponder(table)
            if window.firstResponder === table {
                model.requestedAnchorFocus = nil
                return
            }
        }
        guard remaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            attempt(anchor: anchor, model: model, in: window, remaining: remaining - 1)
        }
    }
}

@MainActor
private enum AlignmentKeyHandler {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow,
              window.attachedSheet == nil,
              let state = ShowWindowRegistry.state(for: window),
              state.destination == .alignment,
              let model = state.alignmentModel
        else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty, model.canStopAudition {
            model.stopAudition()
            return true
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            model.auditionSelection()
            return true
        }
        guard modifiers.isEmpty else { return false }
        guard !(window.firstResponder is NSTextView) else { return false }
        if event.keyCode == 51, isInside("ww.alignment.anchors", responder: window.firstResponder) {
            model.requestDeleteSelectedAnchor()
            return true
        }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        if isInside("ww.alignment.anchors", responder: window.firstResponder) {
            model.requestSelectedAnchorEditor()
            return true
        }
        if isInside("ww.alignment.groups", responder: window.firstResponder) {
            model.requestNumericEditor()
            return true
        }
        if model.anchorSelection != nil {
            model.requestSelectedAnchorEditor()
            return true
        }
        return false
    }

    private static func isInside(_ identifier: String, responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current.accessibilityIdentifier() == identifier { return true }
            view = current.superview
        }
        return false
    }
}

struct AlignmentInspectorView: View {
    @Bindable var model: EpisodeAlignmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alignment Evidence")
                .font(.headline)
            if let row = model.selectedRow {
                Text(row.state.heading)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("ww.inspector.alignment.state")
                Text(row.state.evidence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ww.inspector.alignment.evidence")
                Text(row.state.basis ?? "No manual basis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ww.inspector.alignment.basis")
                if let details = row.state.details {
                    DisclosureGroup("Details") {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !row.state.remedies.isEmpty {
                    Text("Available: \(row.state.remedies.joined(separator: ", "))")
                        .font(.caption)
                }
                Text("Rate: \(AlignmentPresentation.rateLabel(row.ratePPM ?? 0))")
                    .accessibilityIdentifier("ww.inspector.alignment.rate")
                Text("Offset: \(AlignmentPresentation.offsetLabel(row.offsetMilliseconds ?? 0))")
                    .accessibilityIdentifier("ww.inspector.alignment.offset")
            } else {
                Text("Select an epoch to inspect its evidence and correction.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NumericTimingSheet: View {
    @Bindable var model: EpisodeAlignmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Double
    @State private var offset: Double

    init(model: EpisodeAlignmentModel) {
        self.model = model
        let initial = model.numericEditorDefaults
        _rate = State(initialValue: initial.ratePPM)
        _offset = State(initialValue: initial.offsetMilliseconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Epoch Timing")
                .font(.title2.weight(.semibold))
            LabeledContent("Rate correction (ppm)") {
                TextField("Rate", value: $rate, format: .number.precision(.fractionLength(3)))
                    .frame(width: 140)
                    .accessibilityIdentifier("alignment.numeric.rate")
            }
            Text("Positive means this recorder clock runs slow.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Offset (ms)") {
                TextField("Offset", value: $offset, format: .number.precision(.fractionLength(3)))
                    .frame(width: 140)
                    .accessibilityIdentifier("alignment.numeric.offset")
            }
            Text("Positive moves this recorder later on the aligned timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let previewEnd = max(60, model.selectedAnchors.last?.sourceSeconds ?? 60)
            let scale = 1 + rate / 1_000_000
            Text(
                "Preview: first \(AlignmentPresentation.formatTime(offset / 1_000)); " +
                "last \(AlignmentPresentation.formatTime(scale * previewEnd + offset / 1_000))."
            )
            .font(.caption)
            .accessibilityIdentifier("alignment.numeric.preview")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyNumeric(ratePPM: rate, offsetMilliseconds: offset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("alignment.numeric.apply")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct AnchorTimingSheet: View {
    @Bindable var model: EpisodeAlignmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var anchors: [AlignmentAnchor]

    init(model: EpisodeAlignmentModel) {
        self.model = model
        _anchors = State(initialValue: model.anchorEditorDefaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Place Anchors")
                .font(.title2.weight(.semibold))
            Text("Edit the complete source/aligned anchor list. Untouched pairs are preserved.")
                .foregroundStyle(.secondary)
            ForEach(anchors.indices, id: \.self) { index in
                anchorRow(
                    "Anchor \(index + 1)",
                    source: $anchors[index].sourceSeconds,
                    aligned: $anchors[index].alignedSeconds,
                    identifier: index == 0 ? "first" : index == 1 ? "second" : "\(index + 1)"
                )
            }
            Button("Add Pair") {
                let last = anchors.last ?? AlignmentAnchor(sourceSeconds: 0, alignedSeconds: 0)
                anchors.append(AlignmentAnchor(
                    sourceSeconds: last.sourceSeconds + 1,
                    alignedSeconds: last.alignedSeconds + 1
                ))
            }
            .accessibilityIdentifier("alignment.anchors.addPair")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.placeAnchors(anchors)
                    dismiss()
                }
                .disabled(anchors.count < 2)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("alignment.anchors.apply")
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func anchorRow(
        _ title: String,
        source: Binding<Double>,
        aligned: Binding<Double>,
        identifier: String
    ) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            TextField("Source seconds", value: source, format: .number)
                .accessibilityIdentifier("alignment.anchors.\(identifier).source")
            TextField("Aligned seconds", value: aligned, format: .number)
                .accessibilityIdentifier("alignment.anchors.\(identifier).aligned")
        }
    }
}

/// Focused single-anchor editor (#219). The Anchors table is read-only because an inline editor inside
/// the clipped native table could not reliably take keyboard focus; this sheet is the keyboard path for
/// T-M2-02 and T-M2-03. Return applies one undoable edit, Escape cancels, and either way focus returns
/// to the anchor's row in the table.
private struct EditAnchorSheet: View {
    @Bindable var model: EpisodeAlignmentModel
    let anchorID: Int
    @Environment(\.dismiss) private var dismiss
    @FocusState private var alignedTimeFocused: Bool
    /// The field is bound to text, not to a `Double` through a formatter: a formatter-bound field only
    /// writes back when it resigns first responder, so Return would apply the pre-edit value (#219).
    @State private var alignedText: String

    init(model: EpisodeAlignmentModel, anchorID: Int) {
        self.model = model
        self.anchorID = anchorID
        let seconds = model.selectedAnchors.first { $0.id == anchorID }?.alignedSeconds ?? 0
        _alignedText = State(initialValue: Self.text(for: seconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Anchor")
                .font(.title2.weight(.semibold))
            LabeledContent("Source time") {
                Text(AlignmentPresentation.formatTime(anchor?.sourceSeconds ?? 0))
                    .accessibilityLabel("Source time")
                    .accessibilityValue(AlignmentPresentation.formatTime(anchor?.sourceSeconds ?? 0))
                    .accessibilityIdentifier("alignment.anchor.sourceTime")
            }
            LabeledContent("Group time") {
                Text(AlignmentPresentation.formatTime(anchor?.groupSeconds ?? 0))
                    .accessibilityLabel("Group time")
                    .accessibilityValue(AlignmentPresentation.formatTime(anchor?.groupSeconds ?? 0))
                    .accessibilityIdentifier("alignment.anchor.groupTime")
            }
            LabeledContent("Aligned time (seconds)") {
                TextField("Aligned time", text: $alignedText)
                .frame(width: 140)
                .focused($alignedTimeFocused)
                .accessibilityLabel("Aligned time")
                .accessibilityIdentifier("alignment.anchor.alignedTime")
                .onKeyPress(.upArrow) { nudge(by: 1) }
                .onKeyPress(.downArrow) { nudge(by: -1) }
                .onSubmit(apply)
            }
            Text("↑ and ↓ nudge by one output frame; hold Shift to nudge by 100 ms.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("alignment.anchor.nudgeHint")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("alignment.anchor.cancel")
                Button("Apply", action: apply)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("alignment.anchor.apply")
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await takeFocus() }
        .onDisappear { model.restoreAnchorFocus(to: anchorID) }
    }

    private var anchor: AlignmentAnchorRow? {
        model.selectedAnchors.first { $0.id == anchorID }
    }

    private var alignedSeconds: Double? { Double(alignedText.trimmingCharacters(in: .whitespaces)) }

    private static func text(for seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private func apply() {
        guard let alignedSeconds else { return }
        model.editAnchor(id: anchorID, alignedSeconds: alignedSeconds)
        dismiss()
    }

    /// AppKit mounts the sheet's field editor a frame or two after the sheet appears, so request focus
    /// until it sticks rather than once on appear.
    private func takeFocus() async {
        for _ in 0..<40 {
            alignedTimeFocused = true
            try? await Task.sleep(for: .milliseconds(50))
            if alignedTimeFocused { return }
        }
    }

    private func nudge(by steps: Double) -> KeyPress.Result {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let step = shift ? 0.1 : model.alignedNudgeSeconds
        guard let current = alignedSeconds else { return .ignored }
        alignedText = Self.text(for: current + steps * step)
        return .handled
    }
}
