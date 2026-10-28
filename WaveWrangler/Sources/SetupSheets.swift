import AppKit
import SwiftUI
import WWCore
import WWEpisodeSetup

// MARK: - Import Review (IA §5)

/// Engine-agnostic Import Review. Suggestions are marked "suggested" until confirmed; unconfirmed ones are
/// discarded on Import. Space toggles Include, ⌫ excludes, Return imports. Nothing is copied or changed.
struct ImportReviewSheet: View {
    let model: EpisodeSetupModel
    @State private var review: ImportReview
    @State private var selection: Set<UUID> = []
    @FocusState private var tableFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.setupTextScale) private var scale

    private enum ChoiceTag: Hashable {
        case none, suggested, value(String), newGroup
    }

    private struct NewGroup: Identifiable {
        let id: UUID
    }

    @State private var newGroup: NewGroup?

    init(model: EpisodeSetupModel, review: ImportReview) {
        self.model = model
        _review = State(initialValue: review)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.title)
                .setupFont(.title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ww.import.title")
            Text(review.fromLine).setupFont(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Import authorizes WaveWrangler to use these recordings on this Mac after verifying their identities. Originals are never changed.")
                .setupFont(.callout).fixedSize(horizontal: false, vertical: true)
            Text(ImportReview.suggestionsCaption).setupFont(.callout).fixedSize(horizontal: false, vertical: true)

            Table(review.rows, selection: $selection) {
                TableColumn("Include") { row in
                    Toggle("Include \(row.candidate.displayName)", isOn: includeBinding(row.id))
                        .toggleStyle(.checkbox)
                        .checkboxTint(onSelectedRow: selection.contains(row.id))
                        .labelsHidden()
                        .accessibilityIdentifier("ww.import.row.\(index(of: row.id)).include")
                }
                .width(min: 50 * scale, ideal: 56 * scale)
                TableColumn("Name") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.candidate.displayName).setupFont(.body).lineLimit(2).truncationMode(.middle)
                        if let caption = row.caption {
                            Text(caption).setupFont(.caption1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ww.import.row.\(index(of: row.id))")
                }
                TableColumn("Folder") { row in
                    Text(row.candidate.details.folderName ?? "—").setupFont(.body).lineLimit(2)
                        .accessibilityValue(row.candidate.details.folderName ?? "none")
                }
                TableColumn("Recorder group") { row in
                    choicePicker(
                        label: "Recorder group for \(row.candidate.displayName)",
                        choice: row.group,
                        noneTitle: "Ungrouped",
                        options: review.groupOptions(existing: model.episode?.recorderGroups.map(\.name) ?? []),
                        identifier: "ww.import.row.\(index(of: row.id)).group",
                        set: { review.setGroup(row.id, $0) },
                        createGroup: { newGroup = NewGroup(id: row.id) }
                    )
                }
                .width(min: 130, ideal: 180)
                TableColumn("Speaker") { row in
                    choicePicker(
                        label: "Speaker for \(row.candidate.displayName)",
                        choice: row.speaker,
                        noneTitle: "Unassigned",
                        options: model.store.model.speakers.map(\.name),
                        identifier: "ww.import.row.\(index(of: row.id)).speaker",
                        set: { review.setSpeaker(row.id, $0) }
                    )
                }
                .width(min: 120, ideal: 160)
            }
            .frame(minHeight: 200)
            .focused($tableFocused)
            .accessibilityLabel("Files to import")
            .onKeyPress(.space) {
                guard !selection.isEmpty else { return .ignored }
                for id in selection { review.toggleInclude(id) }
                return .handled
            }
            .onDeleteCommand {
                for id in selection { review.setInclude(id, false) }
            }
            .environment(\.defaultMinListRowHeight, 24 * scale)

            if !review.skipped.isEmpty {
                DisclosureGroup("Skipped (\(review.skipped.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(review.skipped) { candidate in
                            Text("\(candidate.displayName) — \(review.skipReason(candidate))").setupFont(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .setupFont(.callout)
                .accessibilityIdentifier("ww.import.skipped")
            }

            if let line = review.downloadLine(downloadsOn: model.downloadsAutomatically) {
                HStack(alignment: .firstTextBaseline) {
                    Label { Text(line).setupFont(.callout).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "icloud") }
                    Button("Change…") { SetupSettingsLink.open() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ww.import.downloadLine")
            }
            if let confirmation = review.confirmationLine {
                Label { Text(confirmation).setupFont(.callout) } icon: { Image(systemName: "circle.dashed") }
                    .accessibilityIdentifier("ww.import.unapplied")
            }

            HStack {
                Button("Accept All Suggestions") { review.acceptAllSuggestions() }
                    .disabled(!review.hasSuggestions)
                Button("Clear Suggestions") { review.clearSuggestions() }
                    .disabled(!review.hasSuggestions)
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelImport(review); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(review.importButtonTitle) { model.commitImport(review) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!review.canImport)
                    .accessibilityIdentifier("ww.import.confirm")
            }
            .setupFont(.body)
        }
        .padding(16)
        .frame(minWidth: 760 * min(scale, 1.4), minHeight: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.title)
        .accessibilityIdentifier("ww.import.review")
        .sheet(item: $newGroup) { target in
            SetupNameForm(context: NameSheetContext(kind: .newGroup, initial: ""),
                cancel: { newGroup = nil },
                apply: { name in
                    review.setGroup(target.id, name)
                    newGroup = nil
                },
                validate: { name in
                    review.groupOptions(existing: model.episode?.recorderGroups.map(\.name) ?? []).contains(name)
                        ? "That name is already available in the group list. Choose it from the list instead."
                        : nil
                })
        }
        .onAppear {
            tableFocused = true
            if let first = review.rows.first { selection = [first.id] }
        }
    }

    private func index(of id: UUID) -> Int { review.rows.firstIndex { $0.id == id } ?? 0 }

    private func includeBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { review.rows.first { $0.id == id }?.include ?? false },
            set: { review.setInclude(id, $0) }
        )
    }

    private func choicePicker(label: String, choice: ImportReview.Choice, noneTitle: String, options: [String],
                              identifier: String, set: @escaping (String?) -> Void,
                              createGroup: (() -> Void)? = nil) -> some View {
        let suggestion: Suggestion? = {
            if case let .suggested(s) = choice { return s }
            return nil
        }()
        let selected: ChoiceTag = {
            switch choice {
            case .suggested: .suggested
            case let .confirmed(value?): .value(value)
            case .none, .confirmed(nil): .none
            }
        }()
        var names = options
        if case let .confirmed(value?) = choice { names.append(value) }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        return HStack(spacing: 4) {
            if suggestion != nil {
                Image(systemName: "circle.dashed").accessibilityHidden(true)
            }
            Picker(label, selection: Binding(get: { selected }, set: { tag in
                switch tag {
                case .suggested: set(suggestion?.value)
                case .none: set(nil)
                case let .value(value): set(value)
                case .newGroup: createGroup?()
                }
            })) {
                if let suggestion {
                    Text("\(suggestion.value) (suggested)").tag(ChoiceTag.suggested)
                    Divider()
                }
                Text(noneTitle).tag(ChoiceTag.none)
                ForEach(names, id: \.self) { name in
                    Text(name).tag(ChoiceTag.value(name))
                }
                if createGroup != nil {
                    Divider()
                    Text("New Recorder Group…").tag(ChoiceTag.newGroup)
                }
            }
            .labelsHidden()
            .setupFont(.body)
            .accessibilityIdentifier(identifier)
            .help(suggestion?.reason ?? "")
            .accessibilityValue(choice.accessibilityValue(none: noneTitle))
            .accessibilityHint(suggestion?.reason ?? "")
        }
    }
}

// MARK: - Relink / Grant Access (states §4)

struct RelinkSheet: View {
    let model: EpisodeSetupModel
    let context: RelinkContext
    @State private var acknowledged = false
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch context.mode {
        case .relink: "Relink “\(context.displayName)”"
        case .grantAccess: "Grant Access to “\(context.displayName)”"
        case .review: "Review Changed File “\(context.displayName)”"
        }
    }

    var body: some View {
        let comparison = context.comparison
        VStack(alignment: .leading, spacing: 12) {
            Text(title).setupFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text(comparison.headline)
                .setupFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ww.relink.headline")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Detail"); Text("Recorded"); Text("Chosen"); Text("Result")
                }
                .setupFont(.callout, weight: .semibold)
                .accessibilityHidden(true)
                Divider()
                ForEach(comparison.rows) { row in
                    GridRow {
                        Text(row.field)
                        Text(row.recorded)
                        Text(row.chosen)
                        Label(row.result.rawValue, systemImage: Self.symbol(row.result))
                    }
                    .setupFont(.body)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityIdentifier("ww.relink.compare.\(row.field.lowercased())")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comparison of recorded and chosen file details")
            .accessibilityIdentifier("ww.relink.compare")

            Text("WaveWrangler never moves, renames, copies over or changes either file.")
                .setupFont(.caption1)

            if comparison.requiresAcknowledgment && comparison.canConfirm {
                Toggle(RelinkComparison.acknowledgmentTitle, isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .checkboxTint()
                    .setupFont(.body)
                    .accessibilityIdentifier("ww.relink.acknowledge")
            }

            HStack {
                if comparison.requiresAcknowledgment {
                    Button("Choose Another…") {
                        model.sheet = nil
                        model.beginRelink(context.sourceID, mode: context.mode)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if comparison.requiresAcknowledgment && comparison.canConfirm {
                    // No default button when details differ or are unknown (states §4 step 3).
                    Button(comparison.confirmTitle) { model.confirmRelink(context) }
                        .disabled(!acknowledged)
                        .accessibilityIdentifier("ww.relink.confirm")
                } else if comparison.canConfirm {
                    Button(comparison.confirmTitle) { model.confirmRelink(context) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("ww.relink.confirm")
                }
            }
            .setupFont(.body)
        }
        .padding(16)
        .frame(minWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("ww.relink.sheet")
    }

    static func symbol(_ result: RelinkComparison.Result) -> String {
        switch result {
        case .same: "checkmark.circle"
        case .different: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }
}

// MARK: - Numeric and name sheets

struct NumberSheet: View {
    let model: EpisodeSetupModel
    let context: NumberSheetContext
    @State private var draft: String
    @State private var unknown: Bool
    @State private var error: String?
    @FocusState private var focused: Bool

    init(model: EpisodeSetupModel, context: NumberSheetContext) {
        self.model = model
        self.context = context
        _draft = State(initialValue: context.initial.map(String.init) ?? "")
        _unknown = State(initialValue: context.kind == .channel && context.initial == nil)
    }

    private var title: String { context.kind == .epoch ? "Set Recording Segment" : "Set Channel" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).setupFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            TextField(context.kind == .epoch ? "Recording Segment" : "Channel", text: $draft)
                .setupFont(.body)
                .focused($focused)
                .disabled(unknown)
                .accessibilityIdentifier("ww.setup.numberField")
            if context.kind == .channel {
                Toggle("Unknown", isOn: $unknown).toggleStyle(.checkbox).checkboxTint().setupFont(.body)
                    .accessibilityIdentifier("ww.setup.numberUnknown")
                Text("WaveWrangler doesn't check this against the file in this version.")
                    .setupFont(.caption1).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A recording segment is one continuous-clock span of a recorder group. Start a new segment when that recorder stops and restarts.")
                    .setupFont(.caption1).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).setupFont(.caption1).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 340)
        .onAppear { focused = true }
    }

    private func apply() {
        if context.kind == .channel && unknown {
            model.sheet = nil
            model.setChannel(nil, for: context.sourceIDs)
            return
        }
        guard let number = Int(draft.trimmingCharacters(in: .whitespaces)), number >= 1 else {
            error = "Enter a whole number"
            return
        }
        model.sheet = nil
        if context.kind == .epoch {
            model.setEpoch(number, for: context.sourceIDs)
        } else {
            model.setChannel(number, for: context.sourceIDs)
        }
    }
}

struct OriginalAuthorizationSheet: View {
    let model: EpisodeSetupModel
    let sources: [SourceRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve Older Recordings").setupFont(.title3, weight: .semibold)
            Text("These recordings were added before import included authorization. Approve them together to allow audio use on this Mac. WaveWrangler verifies each unchanged identity with a read-only witness; a changed or unavailable recording stays unauthorized. Originals are never changed.")
                .setupFont(.body).fixedSize(horizontal: false, vertical: true)
            List(sources) { source in
                VStack(alignment: .leading) {
                    Text(source.displayNameHint)
                    Text(source.id.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 140, idealHeight: 240)
            .accessibilityIdentifier("ww.setup.originalAuthorization.list")
            HStack {
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve \(sources.count) Recordings") { model.authorizeOriginals(sources) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ww.setup.originalAuthorization.approve")
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

struct NameSheet: View {
    let model: EpisodeSetupModel
    let context: NameSheetContext

    var body: some View {
        SetupNameForm(context: context, cancel: { model.sheet = nil }, apply: apply)
    }

    private func apply(_ name: String) {
        model.sheet = nil
        switch context.kind {
        case .newGroup: model.createGroup(named: name, assigning: context.assigning)
        case .newSpeaker: model.createSpeaker(named: name, assigning: context.assigning)
        case .renameGroup: if let id = context.groupID { model.renameGroup(id, to: name) }
        case .renameSpeaker: if let id = context.speakerID { model.renameSpeaker(id, to: name) }
        }
    }
}

struct SetupNameForm: View {
    let context: NameSheetContext
    let cancel: () -> Void
    let apply: (String) -> Void
    let validate: (String) -> String?
    @State private var draft: String
    @FocusState private var focused: Bool

    init(context: NameSheetContext, cancel: @escaping () -> Void, apply: @escaping (String) -> Void,
         validate: @escaping (String) -> String? = { _ in nil }) {
        self.context = context
        self.cancel = cancel
        self.apply = apply
        self.validate = validate
        _draft = State(initialValue: context.initial)
    }

    var body: some View {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = validate(name)
        VStack(alignment: .leading, spacing: 10) {
            Text(context.title).setupFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            TextField("Name", text: $draft)
                .setupFont(.body)
                .focused($focused)
                .accessibilityIdentifier("ww.setup.nameField")
            if let issue {
                Text(issue).setupFont(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("ww.setup.nameValidation")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(context.confirmTitle) {
                    apply(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || issue != nil)
            }
        }
        .padding(16)
        .frame(minWidth: 340)
        .onAppear { focused = true }
    }
}
