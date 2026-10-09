import AppKit
import SwiftUI
import WWCore
import WWOrganizer

/// Trailing inspector (IA §4.4): selection-driven; heading names the kind.
struct InspectorContainer: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        if state.sidebarSelection != .showInfo && state.destination == .review {
            ReviewInspectorViewport(state: state, selectedOccurrence: state.reviewState.selectedOccurrence)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            InspectorScrollContent(state: state)
        }
    }
}

private struct InspectorScrollContent: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        ScrollView {
            Group {
                if state.sidebarSelection == .showInfo {
                    ShowInfoInspector(state: state)
                } else if state.destination == .alignment, let model = state.alignmentModel {
                    AlignmentInspectorView(model: model)
                } else if let episode = state.selectedEpisode {
                    EpisodeInspector(state: state, episodeID: episode.id)
                        .id(episode.id)
                } else {
                    Text("Nothing selected")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .wwFont(.body)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .accessibilityIdentifier("ww.inspector")
    }
}

private struct ReviewInspectorViewport: NSViewRepresentable {
    let state: ShowWindowState
    let selectedOccurrence: TranscriptReviewShellOccurrence?
    @Environment(\.wwTextSize) private var textSize

    func makeNSView(context: Context) -> ReviewInspectorPanel {
        ReviewInspectorPanel(state: state)
    }

    func updateNSView(_ view: ReviewInspectorPanel, context: Context) {
        view.update(selectedOccurrence: selectedOccurrence, textSize: textSize)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReviewInspectorPanel, context: Context) -> CGSize? {
        // Zero ideal height leaves the split free to allocate its real viewport; the document never sizes it.
        CGSize(width: proposal.width ?? 0, height: 0)
    }
}

private final class ReviewInspectorClipView: NSClipView {
    override func isAccessibilityElement() -> Bool { true }
}

private final class ReviewInspectorPanel: NSView {
    private weak var state: ShowWindowState?
    private let heading = EntryLabel(wrappingLabelWithString: "Review Inspector")
    private let setup = NSButton(title: "Go to Setup (⌘1)", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let document = ReviewInspectorDocument()
    private var textSize = TextSize.actual

    init(state: ShowWindowState) {
        self.state = state
        super.init(frame: .zero)
        setAccessibilityElement(false)
        heading.setAccessibilityIdentifier("ww.review.inspector.heading")
        heading.textColor = .labelColor
        heading.backgroundColor = .windowBackgroundColor
        heading.drawsBackground = true
        addSubview(heading)

        setup.target = self
        setup.action = #selector(showSetup(_:))
        setup.bezelStyle = .rounded
        setup.cell?.wraps = true
        setup.cell?.lineBreakMode = .byWordWrapping
        setup.setAccessibilityLabel("Go to Setup (⌘1)")
        setup.setAccessibilityHelp("Choose or confirm a Primary source in Setup. Keyboard alternative: View, Setup, Command-1.")
        setup.setAccessibilityIdentifier("ww.review.remedy.setup")
        addSubview(setup)

        scroll.contentView = ReviewInspectorClipView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.setAccessibilityLabel("Inspector")
        scroll.setAccessibilityIdentifier("ww.inspector")
        scroll.contentView.setAccessibilityElement(true)
        scroll.contentView.setAccessibilityRole(.group)
        scroll.contentView.setAccessibilityLabel("Inspector visible area")
        scroll.contentView.setAccessibilityIdentifier("ww.inspector.clip")
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var fittingSize: NSSize { .zero }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(selectedOccurrence: TranscriptReviewShellOccurrence?, textSize: TextSize) {
        self.textSize = textSize
        heading.font = .systemFont(ofSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.headline.baseSize)), weight: .semibold)
        setup.font = .systemFont(ofSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize)))
        document.update(selectedOccurrence: selectedOccurrence, textSize: textSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = max(1, bounds.width - 28)
        let headingHeight = ReviewInspectorDocument.textHeight(heading.stringValue, font: heading.font!, width: width)
        heading.frame = NSRect(x: 14, y: 14, width: width, height: headingHeight)
        let buttonHeight = max(30, ReviewInspectorDocument.textHeight(setup.title, font: setup.font!, width: width - 16) + 14)
        setup.frame = NSRect(x: 14, y: heading.frame.maxY + 8, width: width, height: buttonHeight)
        let top = setup.frame.maxY + 10
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        scroll.tile()
        document.layoutRows(width: scroll.contentView.bounds.width, minimumHeight: scroll.contentView.bounds.height)
    }

    @objc private func showSetup(_ sender: Any?) {
        state?.showReviewSetup()
    }
}

private final class ReviewInspectorDocument: NSView {
    private let selected = ReviewInspectorDocument.makeLabel("Selected occurrence: No occurrence selected")
    private let occurrenceID = ReviewInspectorDocument.makeLabel("Occurrence ID: None", identifier: "ww.review.inspector.occurrenceID", label: "Occurrence ID")
    private let tokenID = ReviewInspectorDocument.makeLabel("Token stub ID: None", identifier: "ww.review.inspector.tokenID", label: "Token stub ID")
    private let rows: [(NSView, CGFloat)]
    private var textSize = TextSize.actual

    init() {
        var content: [(NSView, CGFloat)] = []
        func append(_ view: NSView, spacing: CGFloat = 10) { content.append((view, spacing)) }
        append(selected)
        append(Self.makeLabel("Analysis state: None", identifier: "ww.review.inspector.analysisState",
                              label: "Analysis state", value: "None — this shell contains no analysis"), spacing: 12)
        func action(_ title: String, id: String, reason: String) {
            let button = NSButton(title: title, target: nil, action: nil)
            button.isEnabled = false
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byWordWrapping
            button.setAccessibilityLabel(title)
            button.setAccessibilityValue(reason)
            button.setAccessibilityHelp(reason)
            button.setAccessibilityIdentifier("ww.review.action.\(id)")
            append(button, spacing: 4)
            append(Self.makeLabel(reason, identifier: "ww.review.action.\(id).reason",
                                  label: "\(title) blocked", value: reason), spacing: 10)
        }
        action("Accept Shorten when safe", id: "acceptShorten", reason: TranscriptReviewShellPresentation.acceptBlockedReason)
        action("Lift — preserve timing", id: "lift", reason: TranscriptReviewShellPresentation.liftBlockedReason)
        action("Reject proposal", id: "reject", reason: TranscriptReviewShellPresentation.rejectBlockedReason)
        append(occurrenceID)
        append(tokenID)
        append(Self.makeLabel("Proposal selection: \(TranscriptReviewShellPresentation.noProposalState)",
                              identifier: "ww.review.inspector.proposal", label: "Proposal selection",
                              value: TranscriptReviewShellPresentation.noProposalState))
        append(Self.makeLabel("Primary role: synthetic example, not analyzed", identifier: "ww.review.inspector.primaryState"))
        append(Self.makeLabel("Backup role: synthetic example, not analyzed; no transcript",
                              identifier: "ww.review.inspector.backupState"))
        for domain in TranscriptReviewShellPresentation.timeDomains {
            append(Self.makeLabel("\(domain.1): \(TranscriptReviewShellPresentation.timeNotEstablished)",
                                  identifier: "ww.review.inspector.domain.\(domain.0)", label: domain.1,
                                  value: TranscriptReviewShellPresentation.timeNotEstablished))
        }
        append(Self.makeLabel("Default proposal mode: Shorten when safe. No proposal is active.",
                              identifier: "ww.review.inspector.defaultMode"))
        action("Single-lane audition — not a full preview", id: "singleLaneAudition",
               reason: TranscriptReviewShellPresentation.singleLaneAuditionBlockedReason)
        action("Preview complete episode", id: "fullPreview",
               reason: TranscriptReviewShellPresentation.fullPreviewBlockedReason)
        append(Self.makeLabel(TranscriptReviewShellPresentation.fullPreviewBlockedReason,
                              identifier: "ww.review.inspector.previewBlockedReason", label: "Complete preview blocked",
                              value: TranscriptReviewShellPresentation.fullPreviewBlockedReason))
        rows = content
        super.init(frame: .zero)
        setAccessibilityElement(false)
        for (view, _) in rows { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(selectedOccurrence: TranscriptReviewShellOccurrence?, textSize: TextSize) {
        self.textSize = textSize
        selected.stringValue = "Selected occurrence: \(selectedOccurrence?.title ?? "No occurrence selected")"
        occurrenceID.stringValue = "Occurrence ID: \(selectedOccurrence?.id ?? "None")"
        occurrenceID.accessibilityValueOverride = selectedOccurrence?.id ?? "None"
        tokenID.stringValue = "Token stub ID: \(selectedOccurrence?.tokenStubID ?? "None")"
        tokenID.accessibilityValueOverride = selectedOccurrence?.tokenStubID ?? "None"
        let regular = NSFont.systemFont(ofSize: CGFloat(textSize.pointSize(forBase: WWTextStyle.body.baseSize)))
        for (view, _) in rows {
            if let label = view as? NSTextField {
                label.font = label.accessibilityIdentifier() == "ww.review.inspector.analysisState"
                    ? .systemFont(ofSize: regular.pointSize, weight: .semibold) : regular
            } else if let button = view as? NSButton {
                button.font = regular
            }
        }
    }

    func layoutRows(width: CGFloat, minimumHeight: CGFloat) {
        guard width > 0 else { return }
        let contentWidth = max(1, width - 28)
        var y: CGFloat = 14
        for (view, spacing) in rows {
            let text: String
            let font: NSFont
            if let label = view as? NSTextField {
                text = label.stringValue
                font = label.font!
                label.preferredMaxLayoutWidth = contentWidth
            } else if let button = view as? NSButton {
                text = button.title
                font = button.font!
            } else { continue }
            let isButton = view is NSButton
            let height = Self.textHeight(text, font: font, width: contentWidth - (isButton ? 16 : 0))
                + (isButton ? 14 : 0)
            view.frame = NSRect(x: 14, y: y, width: contentWidth, height: max(isButton ? 30 : 18, height))
            y = view.frame.maxY + spacing
        }
        let frame = NSRect(x: 0, y: 0, width: width, height: max(minimumHeight, y + 14))
        if self.frame != frame { self.frame = frame }
    }

    static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height) + 4
    }

    private static func makeLabel(_ text: String, identifier: String? = nil,
                                  label: String? = nil, value: String? = nil) -> EntryLabel {
        let field = EntryLabel(wrappingLabelWithString: text)
        field.isEnabled = true
        field.isEditable = false
        field.isSelectable = false
        field.textColor = .labelColor
        field.backgroundColor = .windowBackgroundColor
        field.drawsBackground = true
        field.lineBreakMode = .byWordWrapping
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        if let label { field.setAccessibilityLabel(label) }
        field.accessibilityValueOverride = value
        return field
    }
}

/// Episode metadata (title, number, recording date, notes). Edits apply live (so Save, autosave, Close
/// and Quit never miss typed text) and each field's editing burst is one named undo step ("Undo Edit Title").
struct EpisodeInspector: View {
    @Bindable var state: ShowWindowState
    let episodeID: EpisodeID

    @State private var titleDraft = ""
    @State private var numberDraft = ""
    @State private var notesDraft = ""
    /// The values this inspector last wrote to the model. A model value that differs from them came from
    /// elsewhere (Revert, undo, another window) and replaces the draft even while the field has focus (#86).
    @State private var appliedTitle: String?
    @State private var appliedNumber: Int??
    @State private var appliedNotes: String?
    @State private var titleError: String?
    @State private var numberError: String?
    @FocusState private var focused: Field?

    enum Field: Hashable { case title, number, notes }

    private var store: ShowDocumentStore { state.store }
    private var episode: Episode? { store.model.episode(episodeID) }

    var body: some View {
        if let episode {
            VStack(alignment: .leading, spacing: 10) {
                Text("Episode")
                    .wwFont(.headline)
                    .accessibilityAddTraits(.isHeader)

                field("Title", error: titleError) {
                    TextField("Title", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .title)
                        .accessibilityIdentifier("ww.inspector.episode.title")
                }

                field("Number", error: numberError) {
                    TextField("Number", text: $numberDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .number)
                        .accessibilityHint("A whole number. Leave empty for none.")
                        .accessibilityIdentifier("ww.inspector.episode.number")
                }

                recordingDate(episode)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                    TextEditor(text: $notesDraft)
                        .focused($focused, equals: .notes)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .accessibilityLabel("Notes")
                        .accessibilityIdentifier("ww.inspector.episode.notes")
                }
            }
            .disabled(!state.canEdit)
            .onAppear(perform: loadDrafts)
            .onChange(of: titleDraft) { _, value in applyTitle(value) }
            .onChange(of: numberDraft) { _, value in applyNumber(value) }
            .onChange(of: notesDraft) { _, value in applyNotes(value) }
            .onChange(of: focused) { old, _ in endBurst(old) }
            .onChange(of: episode) { _, _ in syncFromModel() }
            .onChange(of: state.titleFocusRequest, initial: true) { _, request in
                if request > 0 { focused = .title }
            }
            .onDisappear { store.endCoalescing() }
        }
    }

    @ViewBuilder
    private func field(_ label: String, error: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            content()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(label): \(error)")
            }
        }
    }

    @ViewBuilder
    private func recordingDate(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording date")
            if let day = episode.recordedOn, let date = DayConversion.date(from: day) {
                DatePicker(
                    "Recording date",
                    selection: Binding(get: { date }, set: { applyDate(DayConversion.day(from: $0)) }),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .accessibilityLabel("Recording date")
                .accessibilityIdentifier("ww.inspector.episode.recordingDate")
                Button("Remove Recording Date") { applyDate(nil) }
            } else {
                Text("Not set")
                Button("Add Recording Date") { applyDate(DayConversion.day(from: Date())) }
                    .accessibilityIdentifier("ww.inspector.episode.addRecordingDate")
            }
        }
    }

    // MARK: - Editing

    private func loadDrafts() {
        guard let episode else { return }
        titleDraft = episode.title
        numberDraft = episode.number.map(String.init) ?? ""
        notesDraft = episode.notes
        appliedTitle = episode.title
        appliedNumber = .some(episode.number)
        appliedNotes = episode.notes
    }

    /// Undo/redo, Revert or another window changed the model: refresh fields that aren't being edited, and
    /// discard a focused field's draft when the change didn't come from that field, so the next keystroke can't
    /// re-apply a discarded edit (#86). The field's own live edits leave its draft alone (no lost keystrokes).
    private func syncFromModel() {
        guard let episode else { return }
        let externalTitle = episode.title != appliedTitle
        if focused != .title || externalTitle, Self.trim(titleDraft) != episode.title {
            titleDraft = episode.title
            titleError = nil
        }
        if externalTitle { appliedTitle = episode.title }
        let externalNumber = appliedNumber.map { $0 != episode.number } ?? true
        if (focused != .number && numberError == nil) || externalNumber,
           (try? EpisodeNumberInput.parse(numberDraft).get()) != episode.number {
            numberDraft = episode.number.map(String.init) ?? ""
            numberError = nil
        }
        if externalNumber { appliedNumber = .some(episode.number) }
        let externalNotes = episode.notes != appliedNotes
        if focused != .notes || externalNotes, notesDraft != episode.notes { notesDraft = episode.notes }
        if externalNotes { appliedNotes = episode.notes }
    }

    private func applyTitle(_ draft: String) {
        let title = Self.trim(draft)
        guard let episode else { return }
        if title.isEmpty {
            titleError = "A title can't be empty."
            return
        }
        titleError = nil
        guard title != episode.title else { return }
        appliedTitle = title
        store.apply(UndoActionName.editTitle, coalescing: "episode-title-\(episodeID)") { model throws(DomainError) in
            try model.renamingEpisode(episodeID, to: title)
        }
    }

    private func applyNumber(_ draft: String) {
        switch EpisodeNumberInput.parse(draft) {
        case .success(let number):
            numberError = nil
            guard number != episode?.number else { return }
            appliedNumber = .some(number)
            store.apply(UndoActionName.editNumber, coalescing: "episode-number-\(episodeID)") { model throws(DomainError) in
                try model.settingEpisodeNumber(episodeID, to: number)
            }
        case .failure(let error):
            numberError = error.message
        }
    }

    private func applyNotes(_ draft: String) {
        guard draft != episode?.notes else { return }
        appliedNotes = draft
        store.apply(UndoActionName.editNotes, coalescing: "episode-notes-\(episodeID)") { model throws(DomainError) in
            try model.settingEpisodeNotes(episodeID, to: draft)
        }
    }

    private func applyDate(_ day: CalendarDay?) {
        guard day != episode?.recordedOn else { return }
        store.apply(UndoActionName.editRecordingDate) { model throws(DomainError) in
            try model.settingEpisodeRecordedOn(episodeID, to: day)
        }
    }

    private func endBurst(_ field: Field?) {
        guard field != nil else { return }
        store.endCoalescing()
        if field == .title, titleError != nil, let episode {
            // The last non-empty title stays in the model; restore it when editing ends.
            titleDraft = episode.title
            titleError = nil
        }
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Show-level metadata (IA §4.4 "Show"): title and notes, location display and save status details.
struct ShowInfoInspector: View {
    @Bindable var state: ShowWindowState
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    /// Values this inspector last wrote; a different model value came from elsewhere (#86).
    @State private var appliedTitle: String?
    @State private var appliedNotes: String?
    @State private var titleError: String?
    @FocusState private var focused: Field?

    enum Field: Hashable { case title, notes }

    private var store: ShowDocumentStore { state.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .title)
                    .accessibilityLabel("Show title")
                    .accessibilityIdentifier("ww.inspector.show.title")
                    .onSubmit { store.endCoalescing() }
                if let titleError {
                    Label(titleError, systemImage: "exclamationmark.triangle")
                        .accessibilityLabel("Title: \(titleError)")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                TextEditor(text: $notesDraft)
                    .focused($focused, equals: .notes)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .accessibilityLabel("Notes")
                    .accessibilityIdentifier("ww.inspector.show.notes")
            }
            Divider()
            LabeledContent("Location") { Text(Self.locationText(store.document?.fileURL)) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Save status")
                Text(state.presentation.popoverText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!state.canEdit)
        .accessibilityIdentifier("ww.inspector.showInfo")
        .onAppear {
            titleDraft = store.model.show.title
            notesDraft = store.model.show.notes
            appliedTitle = store.model.show.title
            appliedNotes = store.model.show.notes
        }
        .onChange(of: titleDraft) { _, value in applyTitle(value) }
        .onChange(of: notesDraft) { _, value in
            guard value != store.model.show.notes else { return }
            appliedNotes = value
            store.apply(UndoActionName.editShowInfo, coalescing: "show-notes") { model throws(DomainError) in model.settingShowNotes(value) }
        }
        .onChange(of: store.model.show) { _, show in
            // Refresh fields that aren't being edited; a change that didn't come from the focused field (Revert,
            // undo, another window) also replaces its draft, so a discarded edit can't come back (#86).
            let externalTitle = show.title != appliedTitle
            if focused != .title || externalTitle, Self.trim(titleDraft) != show.title {
                titleDraft = show.title
                titleError = nil
            }
            if externalTitle { appliedTitle = show.title }
            let externalNotes = show.notes != appliedNotes
            if focused != .notes || externalNotes, notesDraft != show.notes { notesDraft = show.notes }
            if externalNotes { appliedNotes = show.notes }
        }
        .onChange(of: focused) { old, _ in
            guard old != nil else { return }
            store.endCoalescing()
            if old == .title {
                titleDraft = store.model.show.title
                titleError = nil
            }
        }
        .onDisappear { store.endCoalescing() }
    }

    /// Live title with one coalesced undo step per editing burst; an empty draft is never applied.
    private func applyTitle(_ draft: String) {
        let title = Self.trim(draft)
        guard !title.isEmpty else {
            titleError = "A title can't be empty."
            return
        }
        titleError = nil
        guard title != store.model.show.title else { return }
        appliedTitle = title
        store.apply(UndoActionName.editShowInfo, coalescing: "show-title") { model throws(DomainError) in try model.renamingShow(to: title) }
    }

    /// Folder display name only, never a full path (IA §3.2).
    static func locationText(_ url: URL?) -> String {
        guard let url else { return "Not saved yet" }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// `CalendarDay` ↔ `Date` in the user's current calendar day (no time-zone shifting of the day).
enum DayConversion {
    static func date(from day: CalendarDay) -> Date? {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }

    static func day(from date: Date) -> CalendarDay? {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }
}
