import SwiftUI
import WWCore
import WWOrganizer

/// Trailing inspector (IA §4.4): selection-driven; heading names the kind.
struct InspectorContainer: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        ScrollView {
            Group {
                if state.sidebarSelection == .showInfo {
                    ShowInfoInspector(state: state)
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

/// Episode metadata (title, number, recording date, notes). Edits apply live (so Save, autosave, Close
/// and Quit never miss typed text) and each field's editing burst is one named undo step ("Undo Edit Title").
struct EpisodeInspector: View {
    @Bindable var state: ShowWindowState
    let episodeID: EpisodeID

    @State private var titleDraft = ""
    @State private var numberDraft = ""
    @State private var notesDraft = ""
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
    }

    /// Undo/redo or another window changed the model: refresh fields that aren't being edited.
    private func syncFromModel() {
        guard let episode else { return }
        if focused != .title, Self.trim(titleDraft) != episode.title { titleDraft = episode.title; titleError = nil }
        if focused != .number, numberError == nil, (try? EpisodeNumberInput.parse(numberDraft).get()) != episode.number {
            numberDraft = episode.number.map(String.init) ?? ""
        }
        if focused != .notes, notesDraft != episode.notes { notesDraft = episode.notes }
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
        store.apply(UndoActionName.editTitle, coalescing: "episode-title-\(episodeID)") { model throws(DomainError) in
            try model.renamingEpisode(episodeID, to: title)
        }
    }

    private func applyNumber(_ draft: String) {
        switch EpisodeNumberInput.parse(draft) {
        case .success(let number):
            numberError = nil
            guard number != episode?.number else { return }
            store.apply(UndoActionName.editNumber, coalescing: "episode-number-\(episodeID)") { model throws(DomainError) in
                try model.settingEpisodeNumber(episodeID, to: number)
            }
        case .failure(let error):
            numberError = error.message
        }
    }

    private func applyNotes(_ draft: String) {
        guard draft != episode?.notes else { return }
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
        .onAppear {
            titleDraft = store.model.show.title
            notesDraft = store.model.show.notes
        }
        .onChange(of: titleDraft) { _, value in applyTitle(value) }
        .onChange(of: notesDraft) { _, value in
            guard value != store.model.show.notes else { return }
            store.apply(UndoActionName.editShowInfo, coalescing: "show-notes") { model throws(DomainError) in model.settingShowNotes(value) }
        }
        .onChange(of: store.model.show) { _, show in
            if focused != .title, Self.trim(titleDraft) != show.title { titleDraft = show.title }
            if focused != .notes, notesDraft != show.notes { notesDraft = show.notes }
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
