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

    private static let noneTag = "__none"
    private static let suggestedTag = "__suggested"

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
            Text(review.fromLine).setupFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(ImportReview.suggestionsCaption).setupFont(.callout).fixedSize(horizontal: false, vertical: true)

            Table(review.rows, selection: $selection) {
                TableColumn("Include") { row in
                    Toggle("Include \(row.candidate.displayName)", isOn: includeBinding(row.id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Include \(row.candidate.displayName)")
                        .accessibilityIdentifier("ww.import.row.\(index(of: row.id)).include")
                }
                .width(min: 50 * scale, ideal: 56 * scale)
                TableColumn("Name") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.candidate.displayName).setupFont(.body).lineLimit(2).truncationMode(.middle)
                        if let caption = row.caption {
                            Text(caption).setupFont(.caption1).foregroundStyle(.secondary)
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
                        set: { review.setGroup(row.id, $0) }
                    )
                }
                .width(min: 130, ideal: 180)
                TableColumn("Speaker") { row in
                    choicePicker(
                        label: "Speaker for \(row.candidate.displayName)",
                        choice: row.speaker,
                        noneTitle: "Unassigned",
                        options: model.store.model.speakers.map(\.name),
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
                            Text("\(candidate.displayName) — \(review.skipReason(candidate))").setupFont(.callout).foregroundStyle(.secondary)
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
                Button("Cancel", role: .cancel) { model.sheet = nil; dismiss() }
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

    private func choicePicker(label: String, choice: ImportReview.Choice, noneTitle: String, options: [String], set: @escaping (String?) -> Void) -> some View {
        let suggestion: Suggestion? = {
            if case let .suggested(s) = choice { return s }
            return nil
        }()
        let selected: String = {
            switch choice {
            case .suggested: Self.suggestedTag
            case let .confirmed(value?): value
            case .none, .confirmed(nil): Self.noneTag
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
                case Self.suggestedTag: set(suggestion?.value)
                case Self.noneTag: set(nil)
                default: set(tag)
                }
            })) {
                if let suggestion {
                    Text("\(suggestion.value) (suggested)").tag(Self.suggestedTag)
                    Divider()
                }
                Text(noneTitle).tag(Self.noneTag)
                ForEach(names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .setupFont(.body)
            .help(suggestion?.reason ?? "")
            .accessibilityLabel(label)
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
                .setupFont(.caption1).foregroundStyle(.secondary)

            if comparison.requiresAcknowledgement {
                Toggle(RelinkComparison.acknowledgementTitle, isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .setupFont(.body)
                    .accessibilityIdentifier("ww.relink.acknowledge")
            }

            HStack {
                if comparison.requiresAcknowledgement {
                    Button("Choose Another…") {
                        model.sheet = nil
                        model.beginRelink(context.sourceID, mode: context.mode)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if comparison.requiresAcknowledgement {
                    // No default button when details differ or are unknown (states §4 step 3).
                    Button(comparison.confirmTitle) { model.confirmRelink(context) }
                        .disabled(!acknowledged)
                        .accessibilityIdentifier("ww.relink.confirm")
                } else {
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

    private var title: String { context.kind == .epoch ? "Set Epoch" : "Set Channel" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).setupFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            TextField(context.kind == .epoch ? "Epoch" : "Channel", text: $draft)
                .setupFont(.body)
                .focused($focused)
                .disabled(unknown)
                .accessibilityIdentifier("ww.setup.numberField")
            if context.kind == .channel {
                Toggle("Unknown", isOn: $unknown).toggleStyle(.checkbox).setupFont(.body)
                Text("WaveWrangler doesn't check this against the file in this version.")
                    .setupFont(.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Start a new epoch when the recorder was stopped and started again, so its clock restarted.")
                    .setupFont(.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

struct NameSheet: View {
    let model: EpisodeSetupModel
    let context: NameSheetContext
    @State private var draft: String
    @FocusState private var focused: Bool

    init(model: EpisodeSetupModel, context: NameSheetContext) {
        self.model = model
        self.context = context
        _draft = State(initialValue: context.initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(context.title).setupFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            TextField("Name", text: $draft)
                .setupFont(.body)
                .focused($focused)
                .accessibilityIdentifier("ww.setup.nameField")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(context.confirmTitle, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 340)
        .onAppear { focused = true }
    }

    private func apply() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.sheet = nil
        switch context.kind {
        case .newGroup: model.createGroup(named: name, assigning: context.assigning)
        case .newSpeaker: model.createSpeaker(named: name, assigning: context.assigning)
        case .renameGroup: if let id = context.groupID { model.renameGroup(id, to: name) }
        case .renameSpeaker: if let id = context.speakerID { model.renameSpeaker(id, to: name) }
        }
    }
}
