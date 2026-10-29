import AppKit
import SwiftUI
import WWCore

enum FillerReviewFilter: String, CaseIterable {
    case all = "All statuses"
    case pending = "Needs review"
    case reviewed = "Reviewed"
    case rejected = "Not a filler"
    case cut = "Cut"
    case inactive = "Inactive"
}

struct FillerReviewRow: Identifiable, Equatable {
    let id: UUID
    let speakerID: SpeakerID
    let speaker: String
    let phrase: String
    let status: String
    let category: FillerReviewFilter
    let start: Double
    let end: Double
    let issue: String?
    let cutID: UUID?

    var time: String { AlignmentPresentation.formatTime(start) }
    var duration: String { String(format: "%.2f s", end - start) }
}

extension EpisodeCleanupModel {
    var reviewRows: [FillerReviewRow] {
        let generation = state.store.modelGeneration
        if let reviewRowsSnapshot, reviewRowsSnapshot.generation == generation { return reviewRowsSnapshot.rows }
        let rows = fillerReviews.map { review in
            let issue = fillerIssue(review)
            let cut = cut(for: review)
            let category: FillerReviewFilter = issue != nil ? .inactive : cut != nil ? .cut
                : review.decision == .rejected ? .rejected : review.decision == .pending ? .pending : .reviewed
            return FillerReviewRow(id: review.id, speakerID: review.speaker,
                speaker: state.store.model.speaker(review.speaker)?.name ?? "Removed speaker",
                phrase: review.word?.text ?? "Manual interval",
                status: category == .reviewed && review.isAdjusted ? "Adjusted" : category.rawValue,
                category: category, start: review.bounds.alignedStart, end: review.bounds.alignedEnd,
                issue: issue, cutID: cut?.id)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.speaker != $1.speaker { return $0.speaker.localizedStandardCompare($1.speaker) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        reviewRowsSnapshot = (generation, rows)
        return rows
    }

    var selectedReviewRowID: UUID? { selectedFillerID ?? selectedManualCut?.markerID }

    func requestReviewRowFocus(_ id: UUID) {
        pendingReviewFocus = id
        Task { @MainActor [weak self] in
            guard let self, self.pendingReviewFocus == id else { return }
            self.focusReviewRow(id)
        }
    }

    func focusReviewRow(_ id: UUID) {
        pendingReviewFocus = nil
        guard let review = fillerReviews.first(where: { $0.id == id }) else {
            error = "This review is no longer available."
            return
        }
        listening.selectedTranscriptText = nil
        state.workspaceInspector = .transcript
        state.inspectorPresented = true
        if let issue = fillerIssue(review) {
            selectFiller(id, reveal: false, movePlayhead: false)
            listening.selection = nil
            error = issue
            return
        }
        if let alignment = workspaceAlignment,
           let track = alignment.waveformTracks.first(where: { $0.id == review.primary.sourceID }) {
            alignment.selectWaveform(track)
            alignment.listening.collapsedRecorders.remove(track.group)
            alignment.listening.collapsedSpeakers.remove(review.speaker)
            alignment.requestedWaveformFocus = .init(source: track.id, speaker: review.speaker)
        }
        selectedSpeaker = review.speaker
        selectedWord = review.word
        error = nil
        if let cut = cut(for: review) {
            showManualCut(cut.id, expanded: true)
            zoomToManualCut(cut.id, zoomOutSteps: 3)
            seek(to: cutTimeline.editedTime(forAlignedTime: cut.alignedStart))
        } else {
            selectFiller(id)
            listening.selection = displayRange(start: review.bounds.alignedStart, end: review.bounds.alignedEnd)
            zoomToFiller(id, zoomOutSteps: 3)
        }
    }

    func autoCutReviewRow(_ id: UUID) {
        guard canEditManualCuts, canReviewFillers,
              let review = fillerReviews.first(where: { $0.id == id }) else {
            error = "Verify source access and accepted timing before cutting a review interval."
            return
        }
        if let issue = fillerIssue(review) { error = issue; return }
        guard cut(for: review) == nil else { error = "This review interval is already cut."; return }
        focusReviewRow(id)
        applyManualCut()
    }

    func auditionReviewRow(_ id: UUID) {
        pendingReviewFocus = nil
        guard canReviewFillers else {
            error = "Filler timing review is unavailable while the document is read-only, busy or unverified."
            return
        }
        focusReviewRow(id)
        guard let review = fillerReviews.first(where: { $0.id == id }), fillerIssue(review) == nil else { return }
        if let cut = cut(for: review) {
            auditionManualCut(cut.id, mode: .removed)
        } else {
            auditionFiller(id, context: 0)
        }
    }

    func resizedReviewBounds(_ id: UUID, expanding: Bool, seconds: Double = 0.01) -> FillerTimingBounds? {
        guard seconds.isFinite, seconds > 0, canReviewFillers,
              let review = fillerReviews.first(where: { $0.id == id }),
              fillerIssue(review) == nil else { return nil }
        if cut(for: review) != nil, !canEditManualCuts { return nil }
        let delta = expanding ? seconds : -seconds
        return mappedFillerBounds(review,
            start: review.bounds.alignedStart - delta, end: review.bounds.alignedEnd + delta)
    }

    func resizeReviewInterval(_ id: UUID, expanding: Bool, seconds: Double = 0.01) {
        guard let bounds = resizedReviewBounds(id, expanding: expanding, seconds: seconds) else {
            error = "The interval cannot be resized beyond its supported source region or episode boundaries, or contracted to an empty interval."
            return
        }
        if selectedReviewRowID != id { focusReviewRow(id) }
        if let review = fillerReviews.first(where: { $0.id == id }), let cut = cut(for: review) {
            _ = adjustManualCut(cut, start: bounds.alignedStart, end: bounds.alignedEnd)
        } else {
            setFillerBounds(id, start: bounds.alignedStart, end: bounds.alignedEnd)
        }
    }
}

struct ReviewPanelSplitState: NSViewRepresentable {
    @Binding var height: Double

    func makeNSView(context: Context) -> MonitorView { MonitorView(height: $height) }
    func updateNSView(_ view: MonitorView, context: Context) { view.height = $height }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var height: Binding<Double>
        private weak var splitView: NSSplitView?
        private var observation: NotificationObservation?
        private var restored = false
        private var restoreScheduled = false
        private var saveScheduled = false

        init(height: Binding<Double>) {
            self.height = height
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { scheduleRestore() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleRestore()
        }

        private func scheduleRestore() {
            guard window != nil, !restored, !restoreScheduled else { return }
            restoreScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.restoreScheduled = false }
                guard self.window != nil, !self.restored else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, !split.isVertical,
                       split.arrangedSubviews.count == 2,
                       split.bounds.height - split.dividerThickness > 64 {
                        self.splitView = split
                        self.observation = NotificationObservation(NotificationCenter.default.addObserver(
                            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
                        ) { [weak self] _ in
                            MainActor.assumeIsolated { self?.scheduleSave() }
                        })
                        let available = split.bounds.height - split.dividerThickness
                        let height = min(max(140, self.height.wrappedValue), available - 64)
                        split.setPosition(available - height, ofDividerAt: 0)
                        self.restored = true
                        self.scheduleSave()
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        private func scheduleSave() {
            guard restored, !saveScheduled else { return }
            saveScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.saveScheduled = false }
                guard self.window != nil, self.restored, let split = self.splitView else { return }
                let value = split.arrangedSubviews[1].frame.height
                if (140...1200).contains(value), abs(value - self.height.wrappedValue) > 0.5 {
                    self.height.wrappedValue = value
                }
            }
        }

        func stop() {
            observation = nil
            splitView = nil
            restored = false
        }
    }
}

struct FillerIntervalSizeControls: View {
    @Bindable var model: EpisodeCleanupModel
    let reviewID: UUID
    var prefix = "ww.review.size"

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.resizeReviewInterval(reviewID, expanding: false)
            } label: {
                Image(systemName: "minus").frame(width: 12, height: 12)
            }
            .accessibilityLabel("Contract word interval")
            .disabled(model.resizedReviewBounds(reviewID, expanding: false) == nil)
            .help("Move both boundaries inward by 10 ms. Undo restores the previous interval.")
            .accessibilityIdentifier("\(prefix).contract")
            Button {
                model.resizeReviewInterval(reviewID, expanding: true)
            } label: {
                Image(systemName: "plus").frame(width: 12, height: 12)
            }
            .accessibilityLabel("Expand word interval")
            .disabled(model.resizedReviewBounds(reviewID, expanding: true) == nil)
            .help("Move both boundaries outward by 10 ms within supported audio. Undo restores the previous interval.")
            .accessibilityIdentifier("\(prefix).expand")
        }
        .labelStyle(.iconOnly)
        .controlSize(.mini)
    }
}

private struct ReviewRowCell: View {
    let model: EpisodeCleanupModel
    let reviewID: UUID
    let text: String

    var body: some View {
        Button {
            // Embedded controls consume the table's primary action.
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown || event.type == .leftMouseUp,
               event.clickCount == 2 {
                model.auditionReviewRow(reviewID)
            } else {
                model.requestReviewRowFocus(reviewID)
            }
        } label: {
            Text(text).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to center and zoom this interval. Double-click to play its current segment.")
    }
}

struct FillerReviewPanel: View {
    @Bindable var model: EpisodeCleanupModel
    var detached = false
    @State private var selection: UUID?

    private var rows: [FillerReviewRow] {
        model.reviewRows.filter {
            (model.reviewSpeakerFilter == nil || $0.speakerID == model.reviewSpeakerFilter)
                && (model.reviewStatusFilter == .all || $0.category == model.reviewStatusFilter)
                && (model.reviewSearch.isEmpty || $0.phrase.localizedStandardContains(model.reviewSearch)
                    || $0.speaker.localizedStandardContains(model.reviewSearch))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heading; filters; Spacer(minLength: 0); closeButton }
                VStack(spacing: 6) {
                    HStack { heading; Spacer(); closeButton }
                    filters
                }
            }
            .padding(8)
            .controlSize(.small)
            Divider()
            Table(rows, selection: $selection) {
                TableColumn("Speaker") { row in
                    ReviewRowCell(model: model, reviewID: row.id, text: row.speaker)
                }.width(min: 70, ideal: 80, max: 160)
                TableColumn("Phrase") { row in
                    ReviewRowCell(model: model, reviewID: row.id, text: row.phrase)
                        .accessibilityIdentifier("ww.cleanup.filler.review.\(row.id)")
                }.width(min: 70, ideal: 120)
                TableColumn("Status") { row in
                    ReviewRowCell(model: model, reviewID: row.id, text: row.status)
                        .foregroundStyle(row.issue == nil ? Color.primary : .orange)
                        .help(row.issue ?? row.status)
                }.width(min: 80, ideal: 90, max: 160)
                TableColumn("Aligned time") { row in
                    ReviewRowCell(model: model, reviewID: row.id, text: row.time).monospacedDigit()
                }.width(min: 95, ideal: 105, max: 135)
                TableColumn("Length") { row in
                    ReviewRowCell(model: model, reviewID: row.id, text: row.duration).monospacedDigit()
                }.width(min: 55, ideal: 55, max: 85)
                TableColumn("Adjust") { row in
                    FillerIntervalSizeControls(model: model, reviewID: row.id, prefix: "ww.review.size.\(row.id)")
                }.width(60)
                TableColumn("Cut") { row in
                    if let cut = row.cutID {
                        Button("Restore", systemImage: "arrow.uturn.backward") { model.restoreManualCut(cut) }
                            .disabled(!model.canEditManualCuts)
                            .accessibilityIdentifier("ww.review.restore.\(row.id)")
                    } else {
                        Button("Auto Cut", systemImage: "scissors") { model.autoCutReviewRow(row.id) }
                            .disabled(row.issue != nil || !model.canEditManualCuts || !model.canReviewFillers)
                            .help(row.issue ?? "Cut this row's current interval across every aligned track. Originals stay unchanged; Undo restores the audio.")
                            .accessibilityIdentifier("ww.review.cut.\(row.id)")
                    }
                }.width(min: 80, ideal: 85, max: 120)
            }
            .controlSize(.small)
            .contextMenu(forSelectionType: UUID.self) { selection in
                if let id = selection.first {
                    Button("Center on waveform") { model.requestReviewRowFocus(id) }
                }
            } primaryAction: { selection in
                if let id = selection.first { model.auditionReviewRow(id) }
            }
            .accessibilityIdentifier("ww.review.table")
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No matching reviews", systemImage: "text.bubble",
                        description: Text(model.reviewRows.isEmpty
                            ? "Find fillers in the saved transcript or mark a missed interval."
                            : "Change the phrase, speaker, or status filter."))
                        .allowsHitTesting(false)
                }
            }
            Divider()
            HStack {
                Button("Find in saved transcript") { model.proposeFillers() }.disabled(!model.canReviewFillers)
                Button("Mark missed filler") { model.markMissedFiller() }.disabled(!model.canReviewFillers)
                Text("Select to center and zoom; double-click to play. Auto Cut uses the current boundaries on all tracks.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .controlSize(.small)
            .padding(6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.review.panel")
        .onAppear { selection = model.selectedReviewRowID }
        .onChange(of: selection) { _, id in
            if let id, id != model.selectedReviewRowID { model.requestReviewRowFocus(id) }
        }
        .onChange(of: model.selectedReviewRowID) { _, id in selection = id }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text("Transcript & Review").font(.headline)
            Text("\(rows.count) of \(model.reviewRows.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            TextField("Filter phrases or speakers", text: $model.reviewSearch)
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 240)
                .accessibilityIdentifier("ww.review.search")
            Picker("Speaker", selection: $model.reviewSpeakerFilter) {
                Text("All speakers").tag(Optional<SpeakerID>.none)
                ForEach(model.state.store.model.speakers) { speaker in
                    Text(speaker.name).tag(Optional(speaker.id))
                }
            }
            .labelsHidden().accessibilityIdentifier("ww.review.speaker")
            Picker("Status", selection: $model.reviewStatusFilter) {
                ForEach(FillerReviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().accessibilityIdentifier("ww.review.status")
        }
    }

    private var closeButton: some View {
        Button(detached ? "Close review window" : "Hide review panel", systemImage: "xmark") {
            if detached { model.state.reviewPresentation.closeDetached() }
            else { model.state.reviewPanelPresented = false }
        }
            .labelStyle(.iconOnly).accessibilityIdentifier("ww.review.close")
    }

}
