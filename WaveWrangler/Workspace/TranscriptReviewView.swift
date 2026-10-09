import AppKit
import Observation
import SwiftUI
import WWOrganizer

@MainActor
@Observable
final class TranscriptReviewState {
    var selectedOccurrenceID: String? = TranscriptReviewShellPresentation.occurrences.first?.id
    var filterText = ""

    var visibleOccurrences: [TranscriptReviewShellOccurrence] {
        guard !filterText.isEmpty else { return TranscriptReviewShellPresentation.occurrences }
        return TranscriptReviewShellPresentation.occurrences.filter {
            $0.title.localizedCaseInsensitiveContains(filterText)
        }
    }

    var selectedOccurrence: TranscriptReviewShellOccurrence? {
        TranscriptReviewShellPresentation.occurrences.first { $0.id == selectedOccurrenceID }
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
                Text("Provisional UI shell · synthetic fixture only · no media read or speech analysis.")
                    .wwFont(.body)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("ww.review.provisionalNotice")
            }
            .accessibilityElement(children: .contain)

            Text(TranscriptReviewShellPresentation.noLiveSourceReason)
                .wwFont(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityLabel("Review blocked")
                .accessibilityValue(TranscriptReviewShellPresentation.noLiveSourceReason)
                .accessibilityIdentifier("ww.review.blockedReason")

            GeometryReader { geometry in
                if geometry.size.width < 620 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            transcriptPane
                                .frame(minHeight: 210, idealHeight: 250)
                            timelinePane
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        transcriptPane
                            .frame(minWidth: 230, maxWidth: .infinity)
                        timelinePane
                            .frame(minWidth: 250, maxWidth: .infinity)
                    }
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
                TextField("Filter synthetic occurrences", text: $state.filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter synthetic transcript")
                    .accessibilityHint("Filtering is local to this synthetic fixture.")
                    .accessibilityIdentifier("ww.review.filter")

                TranscriptOccurrenceTable(
                    state: state,
                    pointSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize))
                )
                .frame(minHeight: 160)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Transcript occurrences")
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

                Text(state.selectedOccurrence?.title ?? "No occurrence selected")
                    .wwFont(.body)
                    .accessibilityLabel("Timeline selection")
                    .accessibilityValue(state.selectedOccurrence?.title ?? "No occurrence selected")
                    .accessibilityIdentifier("ww.review.timeline.selectedOccurrence")

                ForEach(TranscriptReviewShellPresentation.lanes) { lane in
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
        table.setAccessibilityIdentifier("ww.review.occurrences")
        table.setAccessibilityLabel("Transcript occurrences")
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        private var rows: [TranscriptReviewShellOccurrence] = []
        private var syncingSelection = false
        private var pointSize: CGFloat = 0

        init(state: TranscriptReviewState) { self.state = state }

        func update(rows: [TranscriptReviewShellOccurrence], selectedID: String?, pointSize: CGFloat) {
            guard let table else { return }
            let changed = self.rows != rows || self.pointSize != pointSize
            self.rows = rows
            self.pointSize = pointSize
            table.setAccessibilityValue("\(rows.count) synthetic occurrences; none analyzed")
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

private final class OccurrenceCellView: NSTableCellView {
    private let title = EntryLabel(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("occurrence")
        title.lineBreakMode = .byTruncatingTail
        note.lineBreakMode = .byTruncatingTail
        note.setAccessibilityElement(false)
        addSubview(title)
        addSubview(note)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ occurrence: TranscriptReviewShellOccurrence, pointSize: CGFloat) {
        title.stringValue = occurrence.title
        title.font = NSFont.systemFont(ofSize: pointSize)
        title.setAccessibilityIdentifier("ww.review.occurrence.\(occurrence.id)")
        title.setAccessibilityLabel(occurrence.title)
        title.accessibilityValueOverride = occurrence.note
        note.stringValue = occurrence.note
        note.font = NSFont.systemFont(ofSize: max(10, pointSize * 0.85))
        note.textColor = .labelColor
        toolTip = occurrence.note
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
