import AppKit
import SwiftUI
import WWCore
import WWEpisodeSetup

/// Trailing inspector for the Setup destination (IA §4.4). Selection-driven: Source, Recorder Group or
/// Speaker. Every pointer action here also has a menu-bar path (Source/Episode menus).
struct SetupInspectorView: View {
    @Bindable var model: EpisodeSetupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch model.inspectorSubject {
                case let .source(id):
                    if let source = model.episode?.source(id) {
                        SourceInspector(model: model, source: source)
                    }
                case let .group(id):
                    GroupInspector(model: model, groupID: id)
                case let .speaker(id):
                    SpeakerInspector(model: model, speakerID: id)
                case .none:
                    Text("Episode").setupFont(.headline).accessibilityAddTraits(.isHeader)
                    Text("Select a source, recorder group or speaker to see its details.")
                        .setupFont(.callout)
                        
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The toolbar's top scroll-edge effect softens the first rows under it, which fails the contrast
        // audit for essential text; the details panel has its own opaque background instead.
        .scrollEdgeEffectHidden(true, for: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection details")
        .accessibilityIdentifier("ww.setup.inspector")
    }
}

private enum InspectorField: Hashable {
    case group
    case epoch
    case channel
    case name
}

// MARK: - Source

private struct SourceInspector: View {
    @Bindable var model: EpisodeSetupModel
    let source: SourceRecord
    @FocusState private var focus: InspectorField?
    @State private var epochDraft = ""
    @State private var channelDraft = ""
    @State private var epochError: String?
    @State private var channelError: String?

    private static let newGroupTag = "new-group"
    private static let ungroupedTag = "ungrouped"
    private static let newSpeakerTag = "new-speaker"
    private static let unassignedTag = "unassigned"

    private var episode: Episode? { model.episode }
    private var epoch: Int? { episode?.epochNumber(of: source.id) }
    private var statedChannel: Int? { episode?.statedChannel(of: source.id) }
    private var reference: SpeakerChannelReference? {
        let refs = episode?.references(to: source.id) ?? []
        if refs.count == 1 { return refs[0] }
        return model.selectedReference
    }

    var body: some View {
        Text("Source").setupFont(.headline).accessibilityAddTraits(.isHeader)
        // Plain label-colour text (not LabeledContent's secondary value, not a selectable field AppKit
        // dims): the file name is essential text.
        HStack(alignment: .firstTextBaseline) {
            Text("Name").setupFont(.body)
            Spacer()
            Text(source.displayNameHint).setupFont(.body).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ww.inspector.source.name")
        .setupFont(.body)

        Picker("Recorder group", selection: groupBinding) {
            ForEach(episode?.recorderGroups ?? []) { group in
                Text(group.name).tag(group.id.description)
            }
            Text("Ungrouped").tag(Self.ungroupedTag)
            Divider()
            Text("New Recorder Group…").tag(Self.newGroupTag)
        }
        .setupFont(.body)
        .focused($focus, equals: .group)
        .accessibilityIdentifier("ww.inspector.source.group")

        numericRow(
            title: "Epoch",
            draft: $epochDraft,
            error: epochError,
            field: .epoch,
            identifier: "ww.inspector.source.epoch",
            disabledReason: source.placement.recorderGroupID == nil ? "Choose a recorder group first. Epochs belong to a recorder group." : nil,
            value: epoch,
            commit: commitEpoch,
            step: { delta in model.setEpoch(max(1, (epoch ?? 1) + delta), for: [source.id]) }
        )
        .help("Start a new epoch when the recorder was stopped and started again, so its clock restarted.")

        VStack(alignment: .leading, spacing: 4) {
            numericRow(
                title: "Channel",
                draft: $channelDraft,
                error: channelError,
                field: .channel,
                identifier: "ww.inspector.source.channel",
                disabledReason: statedChannel == nil ? "Channel is Unknown. Turn off Unknown to enter one." : nil,
                value: statedChannel.map { $0 + 1 },
                commit: commitChannel,
                step: { delta in model.setChannel(max(1, (statedChannel ?? 0) + 1 + delta), for: [source.id]) }
            )
            Toggle("Unknown", isOn: Binding(
                get: { statedChannel == nil },
                set: { model.setChannel($0 ? nil : 1, for: [source.id]) }
            ))
            .checkboxTint()
            .setupFont(.body)
            .accessibilityLabel("Channel unknown")
            .accessibilityIdentifier("ww.inspector.source.channelUnknown")
            Text("Not checked against the file").setupFont(.callout)
        }

        Picker("Speaker", selection: speakerBinding) {
            ForEach(model.episodeSpeakers, id: \.id) { speaker in
                Text(speaker.name).tag(speaker.id.description)
            }
            Text("Unassigned").tag(Self.unassignedTag)
            Divider()
            Text("New Speaker…").tag(Self.newSpeakerTag)
        }
        .setupFont(.body)
        .accessibilityIdentifier("ww.inspector.source.speaker")

        roleRow

        Divider()
        RecordedFactsView(source: source)
        Divider()
        AvailabilitySection(model: model, source: source)

        HStack {
            Button("Show Source in Finder") { model.revealInFinder(source.id) }
            Button("Remove from Episode…") { model.confirmation = .removeSources([source.id]) }
        }
        .setupFont(.body)
        .onAppear(perform: resetDrafts)
        .onChange(of: source) { resetDrafts() }
        .onChange(of: model.store.model.episode(model.episodeID)?.epochNumber(of: source.id)) { resetDrafts() }
        .onChange(of: model.inspectorFocusRequest, initial: true) {
            // Also on first appearance: Return may have just opened the collapsed details.
            if model.consumeInspectorFocus(), let field = firstFocusableField { Task { @MainActor in focus = field } }
        }
    }

    /// The first editable field that can take keyboard focus. Pop-up menus take focus only with Full
    /// Keyboard Access (AppKit's rule); otherwise the first enabled number field. Nil leaves focus in the
    /// table, where the Source menu still edits everything.
    private var firstFocusableField: InspectorField? {
        if NSApp.isFullKeyboardAccessEnabled { return .group }
        if source.placement.recorderGroupID != nil { return .epoch }
        if statedChannel != nil { return .channel }
        return nil
    }

    private var roleRow: some View {
        let speakerless = reference == nil
        return VStack(alignment: .leading, spacing: 2) {
            Picker("Role", selection: Binding<String>(
                get: {
                    guard let reference else { return "none" }
                    return reference.isPrimary ? "primary" : "backup"
                },
                set: { value in
                    guard let reference else { return }
                    if value == "primary", !reference.isPrimary { model.useAsPrimary(reference) }
                    if value == "backup" { model.useAsBackup(reference) }
                }
            )) {
                Text("Primary").tag("primary")
                Text("Backup").tag("backup")
            }
            .pickerStyle(.radioGroup)
            .setupFont(.body)
            .disabled(speakerless)
            .accessibilityHint(speakerless ? "Choose a speaker first" : "Primary is the source used for this speaker; backups stay referenced.")
            .accessibilityIdentifier("ww.inspector.source.role")
            if speakerless {
                Text("Choose a speaker first").setupFont(.callout)
                    .accessibilityHidden(true)
            }
        }
    }

    private func numericRow(
        title: String,
        draft: Binding<String>,
        error: String?,
        field: InspectorField,
        identifier: String,
        disabledReason: String?,
        value: Int?,
        commit: @escaping () -> Void,
        step: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).setupFont(.body)
                TextField(title, text: draft, prompt: Text(value == nil ? "—" : ""))
                    .setupFont(.body)
                    .frame(maxWidth: 80)
                    .focused($focus, equals: field)
                    .onSubmit(commit)
                    .accessibilityLabel(title)
                    .accessibilityValue(value.map { title == "Channel" ? "\($0), not checked against the file" : "\($0)" } ?? (title == "Channel" ? "unknown" : "none"))
                    .accessibilityIdentifier(identifier)
                Stepper(title, onIncrement: { step(1) }, onDecrement: { step(-1) })
                    .labelsHidden()
                    .accessibilityLabel(title)
            }
            .disabled(disabledReason != nil)
            if let disabledReason {
                Text(disabledReason).setupFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).setupFont(.callout).foregroundStyle(.red)
                    .accessibilityLabel("\(title): \(error)")
            }
        }
        .onChange(of: focus) { old, new in
            if old == field && new != field { commit() }
        }
    }

    private var groupBinding: Binding<String> {
        Binding(
            get: { source.placement.recorderGroupID?.description ?? Self.ungroupedTag },
            set: { tag in
                switch tag {
                case Self.newGroupTag:
                    model.sheet = .name(NameSheetContext(kind: .newGroup, initial: "", assigning: [source.id]))
                case Self.ungroupedTag:
                    model.assign([source.id], toGroup: nil)
                default:
                    if let id = RecorderGroupID(uuidString: tag) { model.assign([source.id], toGroup: id) }
                }
            }
        )
    }

    private var speakerBinding: Binding<String> {
        Binding(
            get: { reference?.speakerID.description ?? Self.unassignedTag },
            set: { tag in
                switch tag {
                case Self.newSpeakerTag:
                    model.sheet = .name(NameSheetContext(kind: .newSpeaker, initial: "", assigning: [source.id]))
                case Self.unassignedTag:
                    model.assignSpeaker(nil, to: [source.id])
                default:
                    if let id = SpeakerID(uuidString: tag) { model.assignSpeaker(id, to: [source.id]) }
                }
            }
        )
    }

    private func resetDrafts() {
        epochDraft = epoch.map(String.init) ?? ""
        channelDraft = statedChannel.map { String($0 + 1) } ?? ""
        epochError = nil
        channelError = nil
    }

    private func commitEpoch() {
        guard source.placement.recorderGroupID != nil else { return }
        let trimmed = epochDraft.trimmingCharacters(in: .whitespaces)
        guard let number = Int(trimmed), number >= 1 else {
            epochError = "Enter a whole number"
            return
        }
        epochError = nil
        if number != epoch { model.setEpoch(number, for: [source.id]) }
    }

    private func commitChannel() {
        guard statedChannel != nil else { return }
        let trimmed = channelDraft.trimmingCharacters(in: .whitespaces)
        guard let number = Int(trimmed), number >= 1 else {
            channelError = "Enter a whole number"
            return
        }
        channelError = nil
        if number - 1 != statedChannel { model.setChannel(number, for: [source.id]) }
    }
}

private struct RecordedFactsView: View {
    let source: SourceRecord

    var body: some View {
        let facts = SetupPresentation.recordedFacts(for: source)
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording").setupFont(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
            HStack { Text("Duration"); Spacer(); Text(facts.duration.text).foregroundStyle(.primary) }.accessibilityElement(children: .combine)
            HStack { Text("Channels"); Spacer(); Text(facts.channelCount.text).foregroundStyle(.primary) }.accessibilityElement(children: .combine)
            HStack { Text("Sample rate"); Spacer(); Text(facts.sampleRate.text).foregroundStyle(.primary) }.accessibilityElement(children: .combine)
            Text("WaveWrangler doesn't read audio in this version, so these stay Unknown.")
                .setupFont(.callout)
                
                .fixedSize(horizontal: false, vertical: true)
        }
        .setupFont(.body)
    }
}

private struct AvailabilitySection: View {
    let model: EpisodeSetupModel
    let source: SourceRecord

    var body: some View {
        let status = model.status(of: source.id)
        VStack(alignment: .leading, spacing: 8) {
            Text("Availability").setupFont(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
            ForEach(status.dimensions, id: \.dimension) { dimension in
                DimensionRow(model: model, source: source, presentation: dimension, checkedAt: status.checkedAt[dimension.dimension])
            }
            if SetupFixtures.isActive {
                Text("Simulated provider state").setupFont(.callout)
            }
        }
    }
}

private struct DimensionRow: View {
    let model: EpisodeSetupModel
    let source: SourceRecord
    let presentation: DimensionPresentation
    let checkedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusIndicator(indicator: presentation.indicator, tint: presentation.tint)
                    .frame(minWidth: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(presentation.dimension.title): \(presentation.inspectorText)")
                        .setupFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(presentation.dimension.title)
                        .accessibilityValue(presentation.inspectorText + (checkedAt.map { ". Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .accessibilityIdentifier("ww.inspector.\(presentation.dimension.rawValue)")
                    if let checkedAt {
                        Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .setupFont(.callout)
                            
                            .accessibilityHidden(true)
                    }
                }
            }
            remedies
        }
    }

    @ViewBuilder
    private var remedies: some View {
        let status = model.status(of: source.id)
        HStack {
            switch presentation.dimension {
            case .location:
                switch status.location {
                case .unknown:
                    Button("Try Again") { model.tryAgain(source.id) }
                    Button("Relink…") { model.beginRelink(source.id) }
                case .missing, .moved:
                    Button("Relink…") { model.beginRelink(source.id) }
                default: EmptyView()
                }
            case .access:
                switch status.access {
                case .needsPermission, .denied:
                    Button("Grant Access…") { model.beginRelink(source.id, mode: .grantAccess) }
                case .unknown:
                    Button("Try Again") { model.tryAgain(source.id) }
                default: EmptyView()
                }
            case .identity:
                switch status.identity {
                case .changed(_, false):
                    Button("Review…") { model.beginRelink(source.id, mode: .review) }
                case .mismatch:
                    Button("Relink…") { model.beginRelink(source.id) }
                default: EmptyView()
                }
            case .transfer:
                ForEach(model.availableActions(for: source.id), id: \.self) { action in
                    Button(action.buttonTitle(for: status.transfer)) { model.perform(action, on: source.id) }
                        .accessibilityLabel("\(action.menuTitle), \(source.displayNameHint)")
                        .accessibilityIdentifier("ww.inspector.transfer.\(action.rawValue)")
                }
                if status.transfer == .downloadsOff {
                    Button("Settings…") { SetupSettingsLink.open() }
                }
            case .residency:
                EmptyView()
            }
        }
        .setupFont(.body)
        .padding(.leading, 22)
    }
}

// MARK: - Recorder group

private struct GroupInspector: View {
    @Bindable var model: EpisodeSetupModel
    let groupID: RecorderGroupID?
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Text("Recorder Group").setupFont(.headline).accessibilityAddTraits(.isHeader)
        let count = model.episode?.sources(inRecorderGroup: groupID).count ?? 0
        if let groupID {
            TextField("Name", text: $nameDraft)
                .setupFont(.body)
                .focused($nameFocused)
                .onSubmit { commit(groupID) }
                .onChange(of: nameFocused) { _, focused in if !focused { commit(groupID) } }
                .accessibilityLabel("Recorder group name")
                .accessibilityIdentifier("ww.inspector.group.name")
            Text(count == 1 ? "1 source" : "\(count) sources").setupFont(.body)
            Button("New Epoch for Selected Sources") { model.startNewEpoch() }
                .disabled(count == 0)
                .help("Start a new epoch when the recorder was stopped and started again, so its clock restarted.")
            Button("Delete Recorder Group…") { model.confirmation = .deleteGroup(groupID) }
            Text("Deleting a recorder group never removes its sources; they become Ungrouped.")
                .setupFont(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Ungrouped").setupFont(.body)
            Text(count == 1 ? "1 source isn't in a recorder group." : "\(count) sources aren't in a recorder group.")
                .setupFont(.body)
            Button("New Recorder Group…") { model.sheet = .name(NameSheetContext(kind: .newGroup, initial: "")) }
        }
        EmptyView()
            .onAppear { nameDraft = model.groupName(groupID) }
            .onChange(of: groupID) { nameDraft = model.groupName(groupID) }
            .onChange(of: model.inspectorFocusRequest, initial: true) {
                if model.consumeInspectorFocus() { Task { @MainActor in nameFocused = true } }
            }
    }

    private func commit(_ id: RecorderGroupID) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == model.groupName(id) {
            nameDraft = model.groupName(id)
            return
        }
        model.renameGroup(id, to: trimmed)
    }
}

// MARK: - Speaker

private struct SpeakerInspector: View {
    @Bindable var model: EpisodeSetupModel
    let speakerID: SpeakerID
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    private static let noneTag = "none"

    var body: some View {
        Text("Speaker").setupFont(.headline).accessibilityAddTraits(.isHeader)
        TextField("Name", text: $nameDraft)
            .setupFont(.body)
            .focused($nameFocused)
            .onSubmit(commit)
            .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
            .accessibilityLabel("Speaker name")
            .accessibilityIdentifier("ww.inspector.speaker.name")

        let choices = model.channelChoices(for: speakerID)
        let assignment = model.episode?.assignment(for: speakerID)
        Picker("Primary", selection: Binding<String>(
            get: { assignment?.primary.map(Self.tag) ?? Self.noneTag },
            set: { tag in
                model.setPrimary(choices.first { Self.tag($0.channel) == tag }?.channel, for: speakerID)
            }
        )) {
            ForEach(choices, id: \.channel) { choice in
                Text(choice.title).tag(Self.tag(choice.channel))
            }
            Text("None").tag(Self.noneTag)
        }
        .setupFont(.body)
        .accessibilityIdentifier("ww.inspector.speaker.primary")
        if choices.isEmpty {
            Text("Assign this speaker to a source first (Source › Assign Speaker).")
                .setupFont(.callout).fixedSize(horizontal: false, vertical: true)
        }

        Text("Backups").setupFont(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
        let backups = choices.filter { $0.channel != assignment?.primary }
        if backups.isEmpty {
            Text("None").setupFont(.body)
        }
        ForEach(backups, id: \.channel) { choice in
            HStack {
                Text(choice.title).setupFont(.body).lineLimit(2)
                Spacer()
                Button("Make Primary") { model.setPrimary(choice.channel, for: speakerID) }
                    .accessibilityLabel("Make \(choice.title) primary")
            }
        }
        Text("Backups stay referenced. Later steps use only the primary.")
            .setupFont(.callout).fixedSize(horizontal: false, vertical: true)
        Button("Delete Speaker…") { model.confirmation = .deleteSpeaker(speakerID) }
            .setupFont(.body)
        EmptyView()
            .onAppear { nameDraft = model.speakerName(speakerID) }
            .onChange(of: speakerID) { nameDraft = model.speakerName(speakerID) }
            .onChange(of: model.store.model.speaker(speakerID)?.name) { nameDraft = model.speakerName(speakerID) }
            .onChange(of: model.inspectorFocusRequest, initial: true) {
                if model.consumeInspectorFocus() { Task { @MainActor in nameFocused = true } }
            }
    }

    /// `<source>#<index>` or `<source>#unknown` (schema 2: an unknown channel is never tagged as index 0).
    private static func tag(_ channel: ChannelReference) -> String { channel.description }

    private func commit() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == model.speakerName(speakerID) {
            nameDraft = model.speakerName(speakerID)
            return
        }
        model.renameSpeaker(speakerID, to: trimmed)
    }
}

extension EpisodeSetupModel {
    /// Reveals the original in Finder (never changes it). Needs a location from the engine.
    func revealInFinder(_ sourceID: SourceID) {
        Task { [engine] in
            guard let folder = await engine.lastKnownFolder(for: sourceID) else {
                self.message = "WaveWrangler doesn't know where this source is on this Mac. Use Relink Source… to choose it."
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
