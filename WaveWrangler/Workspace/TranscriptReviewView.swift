import AppKit
import Observation
import SwiftUI
import WWOrganizer

@MainActor
@Observable
final class TranscriptReviewState {
    var presentation: TranscriptReviewPresentation = .syntheticFixture
    var selectedOccurrenceID: String? = TranscriptReviewPresentation.syntheticFixture.occurrences.first?.id
    var selectedProposalID: String? = TranscriptReviewShellPresentation.proposals.first?.id
    var filterText = ""

    var visibleOccurrences: [TranscriptReviewPresentation.Occurrence] {
        guard !filterText.isEmpty else { return presentation.occurrences }
        return presentation.occurrences.filter {
            $0.text.localizedCaseInsensitiveContains(filterText)
        }
    }

    var selectedOccurrence: TranscriptReviewPresentation.Occurrence? {
        presentation.occurrences.first { $0.id == selectedOccurrenceID }
    }

    /// The existing inspector is a synthetic-shell safety surface. It must not receive supplied transcript text
    /// until it has its own evidence-only presentation contract.
    var selectedSyntheticOccurrence: TranscriptReviewShellOccurrence? {
        guard presentation.isSynthetic else { return nil }
        return TranscriptReviewShellPresentation.occurrences.first { $0.id == selectedOccurrenceID }
    }

    var selectedProposal: TranscriptReviewShellProposal? {
        TranscriptReviewShellPresentation.proposals.first { $0.id == selectedProposalID }
    }

    func present(_ presentation: TranscriptReviewPresentation) {
        self.presentation = presentation
        selectedOccurrenceID = presentation.occurrences.first?.id
        selectedProposalID = presentation.permitsProposals ? TranscriptReviewShellPresentation.proposals.first?.id : nil
        filterText = ""
    }
}

struct TranscriptReviewView: View {
    @Bindable var state: TranscriptReviewState
    @Environment(\.wwTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript and timeline review")
                    .wwFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("ww.review.heading")
                Text(state.presentation.notice)
                    .wwFont(.body)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("ww.review.provisionalNotice")
            }
            .accessibilityElement(children: .contain)

            Text(state.presentation.blockedReason)
                .wwFont(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityLabel("Review blocked")
                .accessibilityValue(state.presentation.blockedReason)
                .accessibilityIdentifier("ww.review.blockedReason")

            GeometryReader { geometry in
                if geometry.size.width < 620 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            transcriptPane
                                .fixedSize(horizontal: false, vertical: true)
                            timelinePane
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("ww.review.contentScroll")
                } else {
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 12) {
                            transcriptPane
                                .frame(minWidth: 230, maxWidth: .infinity)
                            timelinePane
                                .frame(minWidth: 250, maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .accessibilityIdentifier("ww.review.contentScroll")
                }
            }
        }
        .wwFont(.body)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var transcriptPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField(state.presentation.isSynthetic ? "Filter synthetic occurrences" : "Filter transcript segments", text: $state.filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(state.presentation.isSynthetic ? "Filter synthetic transcript" : "Filter supplied transcript")
                    .accessibilityHint("Filtering is local to the Review presentation.")
                    .accessibilityIdentifier("ww.review.filter")

                TranscriptOccurrenceTable(
                    state: state,
                    pointSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize))
                )
                .frame(minHeight: 120)

                if state.presentation.permitsProposals {
                    Text("Synthetic-only contextual filler proposals")
                        .wwFont(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ww.review.proposals.heading")

                    ProposalTable(
                        state: state,
                        pointSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize))
                    )
                    .frame(height: ProposalTable.contentHeight(
                        pointSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize))
                    ))
                } else {
                    Text("No filler or cut proposals are available for this transcript evidence.")
                        .wwFont(.body)
                        .accessibilityIdentifier("ww.review.noEditAuthority")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Transcript and proposals")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityIdentifier("ww.review.transcriptPane")
    }

    private var timelinePane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("List alternative; no waveform position is inferred.")
                    .wwFont(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(state.selectedOccurrence?.text ?? "No occurrence selected")
                    .wwFont(.body)
                    .accessibilityLabel("Timeline selection")
                    .accessibilityValue(state.selectedOccurrence?.text ?? "No occurrence selected")
                    .accessibilityIdentifier("ww.review.timeline.selectedOccurrence")

                ForEach(state.presentation.lanes) { lane in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lane.label)
                            .wwFont(.body)
                            .fontWeight(.medium)
                        Text(lane.state)
                            .wwFont(.caption)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(lane.label)
                    .accessibilityValue(lane.state)
                    .accessibilityIdentifier("ww.review.lane.\(lane.id)")
                }

                Divider()
                ForEach(TranscriptReviewShellPresentation.timeDomains, id: \.0) { domain in
                    LabeledContent(domain.1) {
                        Text(TranscriptReviewShellPresentation.timeNotEstablished)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(domain.1)
                    .accessibilityValue(TranscriptReviewShellPresentation.timeNotEstablished)
                    .accessibilityIdentifier("ww.review.timeline.domain.\(domain.0)")
                    .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Timeline and lane list")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityIdentifier("ww.review.timelinePane")
    }
}

private struct TranscriptOccurrenceTable: NSViewRepresentable {
    let state: TranscriptReviewState
    let pointSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = OccurrenceTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("occurrence"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.backgroundColor = .controlBackgroundColor
        table.setAccessibilityIdentifier("ww.review.occurrences")
        table.setAccessibilityLabel("Transcript occurrences")
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.state = state
        context.coordinator.update(rows: state.visibleOccurrences, selectedID: state.selectedOccurrenceID, pointSize: pointSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var state: TranscriptReviewState
        weak var table: NSTableView?
        private var rows: [TranscriptReviewPresentation.Occurrence] = []
        private var syncingSelection = false
        private var pointSize: CGFloat = 0

        init(state: TranscriptReviewState) { self.state = state }

        func update(rows: [TranscriptReviewPresentation.Occurrence], selectedID: String?, pointSize: CGFloat) {
            guard let table else { return }
            let changed = self.rows != rows || self.pointSize != pointSize
            self.rows = rows
            self.pointSize = pointSize
            table.setAccessibilityValue("\(rows.count) review transcript segments; no edit authority")
            syncingSelection = true
            defer { syncingSelection = false }
            if changed {
                table.rowHeight = max(50, (pointSize * 2.5).rounded(.up) + 12)
                table.reloadData()
            }
            let selectedRow = rows.firstIndex { $0.id == selectedID } ?? -1
            guard table.selectedRow != selectedRow else { return }
            table.selectRowIndexes(selectedRow < 0 ? [] : IndexSet(integer: selectedRow), byExtendingSelection: false)
            if selectedRow >= 0 { table.scrollRowToVisible(selectedRow) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OccurrenceRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("occurrence")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? OccurrenceCellView
                ?? OccurrenceCellView()
            cell.configure(rows[row], pointSize: pointSize)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection, let table else { return }
            let row = table.selectedRow
            state.selectedOccurrenceID = rows.indices.contains(row) ? rows[row].id : nil
        }
    }
}

private final class OccurrenceTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class OccurrenceRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

private final class OccurrenceCellView: NSTableCellView {
    private let title = EntryLabel(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("occurrence")
        title.lineBreakMode = .byTruncatingTail
        note.lineBreakMode = .byTruncatingTail
        title.backgroundColor = .controlBackgroundColor
        title.drawsBackground = true
        note.backgroundColor = .controlBackgroundColor
        note.drawsBackground = true
        note.setAccessibilityElement(false)
        addSubview(title)
        addSubview(note)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ occurrence: TranscriptReviewPresentation.Occurrence, pointSize: CGFloat) {
        title.stringValue = occurrence.text
        title.font = NSFont.systemFont(ofSize: pointSize)
        title.textColor = .labelColor
        title.setAccessibilityIdentifier("ww.review.occurrence.\(occurrence.id)")
        title.setAccessibilityLabel(occurrence.text)
        title.accessibilityValueOverride = "\(occurrence.detail). \(occurrence.wordTiming)"
        note.stringValue = "\(occurrence.detail) · \(occurrence.wordTiming)"
        note.font = NSFont.systemFont(ofSize: max(10, pointSize * 0.85))
        note.textColor = .labelColor
        toolTip = "\(occurrence.detail). \(occurrence.wordTiming)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 12)
        let titleHeight = title.intrinsicContentSize.height
        let noteHeight = note.intrinsicContentSize.height
        let top = max(0, (bounds.height - titleHeight - noteHeight - 3) / 2)
        title.frame = NSRect(x: 6, y: top, width: width, height: titleHeight)
        note.frame = NSRect(x: 6, y: top + titleHeight + 3, width: width, height: noteHeight)
    }
}

private struct ProposalTable: NSViewRepresentable {
    let state: TranscriptReviewState
    let pointSize: CGFloat

    static func rowHeight(pointSize: CGFloat) -> CGFloat {
        max(70, (pointSize * 3.5).rounded(.up) + 16)
    }

    static func contentHeight(pointSize: CGFloat) -> CGFloat {
        CGFloat(TranscriptReviewShellPresentation.proposals.count) * rowHeight(pointSize: pointSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ProposalTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("proposal"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.backgroundColor = .controlBackgroundColor
        table.setAccessibilityIdentifier("ww.review.proposals")
        table.setAccessibilityLabel("Synthetic-only contextual filler proposals")
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.state = state
        context.coordinator.update(selectedID: state.selectedProposalID, pointSize: pointSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var state: TranscriptReviewState
        weak var table: NSTableView?
        private var rows = TranscriptReviewShellPresentation.proposals
        private var syncingSelection = false
        private var pointSize: CGFloat = 0

        init(state: TranscriptReviewState) { self.state = state }

        func update(selectedID: String?, pointSize: CGFloat) {
            guard let table else { return }
            let changed = self.pointSize != pointSize
            self.pointSize = pointSize
            table.setAccessibilityValue("\(rows.count) provisional synthetic proposals; none verified or actionable")
            syncingSelection = true
            defer { syncingSelection = false }
            if changed {
                table.rowHeight = ProposalTable.rowHeight(pointSize: pointSize)
                table.reloadData()
            }
            let selectedRow = rows.firstIndex { $0.id == selectedID } ?? -1
            guard table.selectedRow != selectedRow else { return }
            table.selectRowIndexes(selectedRow < 0 ? [] : IndexSet(integer: selectedRow), byExtendingSelection: false)
            if selectedRow >= 0 { table.scrollRowToVisible(selectedRow) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OccurrenceRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("proposal")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ProposalCellView
                ?? ProposalCellView()
            cell.configure(rows[row], pointSize: pointSize)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection, let table else { return }
            let row = table.selectedRow
            state.selectedProposalID = rows.indices.contains(row) ? rows[row].id : nil
        }
    }
}

private final class ProposalTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class ProposalCellView: NSTableCellView {
    private let title = EntryLabel(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("proposal")
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        title.lineBreakMode = .byTruncatingTail
        note.lineBreakMode = .byTruncatingTail
        title.backgroundColor = .controlBackgroundColor
        title.drawsBackground = true
        title.setAccessibilityElement(false)
        note.backgroundColor = .controlBackgroundColor
        note.drawsBackground = true
        note.setAccessibilityElement(false)
        addSubview(title)
        addSubview(note)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ proposal: TranscriptReviewShellProposal, pointSize: CGFloat) {
        let details = "\(proposal.rationale) \(proposal.timingState) \(proposal.sourceState) \(proposal.protectionState) \(proposal.status)"
        title.stringValue = "\(proposal.title) — Provisional"
        title.font = NSFont.systemFont(ofSize: pointSize)
        title.textColor = .labelColor
        setAccessibilityIdentifier("ww.review.proposal.\(proposal.id)")
        setAccessibilityLabel("Candidate \(proposal.id): \(proposal.title) — Provisional")
        setAccessibilityValue(details)
        note.isHidden = true
        toolTip = details
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 12)
        let titleHeight = title.intrinsicContentSize.height
        let top = max(0, (bounds.height - titleHeight) / 2)
        title.frame = NSRect(x: 6, y: top, width: width, height: titleHeight)
        note.frame = .zero
    }
}
