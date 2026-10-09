import AppKit
import OSLog
import Observation
import SwiftUI
import WWCore
import WWEpisodeSetup

/// Main-actor view model for one episode's Setup content in one window.
///
/// Canonical edits go through `ShowDocumentStore.apply` with the exact undo names from commands §3, so
/// they share the document's undo history and honest dirty state. Device-local engine work (scan, access
/// records, relink, downloads) goes through `SourceSetupEngine` and never runs provider I/O on the main
/// actor. Nothing here writes, moves, renames or substitutes a referenced original.
@MainActor
@Observable
final class EpisodeSetupModel {
    enum InspectorSubject: Equatable {
        case none
        case group(RecorderGroupID?)
        case source(SourceID)
        case speaker(SpeakerID)
    }

    enum Sheet: Identifiable {
        case importReview(ImportReview)
        case relink(RelinkContext)
        case number(NumberSheetContext)
        case name(NameSheetContext)

        var id: String {
            switch self {
            case .importReview: "import"
            case .relink: "relink"
            case let .number(context): "number-\(context.kind)"
            case let .name(context): "name-\(context.kind)"
            }
        }
    }

    enum Confirmation: Identifiable {
        case removeSources([SourceID])
        case deleteSpeaker(SpeakerID)
        case deleteGroup(RecorderGroupID)
        case cancelDownload(SourceID)

        var id: String {
            switch self {
            case let .removeSources(ids): "remove-\(ids.map(\.description).joined())"
            case let .deleteSpeaker(id): "speaker-\(id)"
            case let .deleteGroup(id): "group-\(id)"
            case let .cancelDownload(id): "cancel-\(id)"
            }
        }

        var kind: SetupConfirmationKind {
            switch self {
            case .removeSources: .removeSources
            case .deleteSpeaker: .deleteSpeaker
            case .deleteGroup: .deleteGroup
            case .cancelDownload: .cancelDownload
            }
        }

        /// Return confirms (default button, no destructive role) when the user chose this destruction.
        var isChosenDestruction: Bool { kind.isChosenDestruction }
    }

    let store: ShowDocumentStore
    let episodeID: EpisodeID
    @ObservationIgnored let engine: any SourceSetupEngine
    @ObservationIgnored let preference: any SourceDownloadPreference
    /// Window used to present native open panels as sheets.
    @ObservationIgnored var window: () -> NSWindow? = { nil }

    var statuses: [SourceID: SourceStatusSnapshot] = [:]
    var selection: Set<SetupRowID> = [] {
        didSet {
            if selection != oldValue {
                pendingInspectorFocus = false
                selectionGeneration = UUID()
                primaryOpenRequests.cancelAll()
            }
        }
    }
    var speakerSelection: Set<SpeakerID> = [] {
        didSet {
            if speakerSelection != oldValue {
                pendingInspectorFocus = false
                selectionGeneration = UUID()
                primaryOpenRequests.cancelAll()
            }
        }
    }
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var relinkGeneration = UUID()
    @ObservationIgnored private var relinkPending = false
    @ObservationIgnored private let primaryOpenRequests = PrimaryOpenRequestGate()
    var onlyNeedingAttention = false
    enum FocusedTable: Hashable { case sources, speakers }
    /// Which Setup table has keyboard focus (nil = neither).
    var focusedTable: FocusedTable?
    /// Whether the Setup content is currently shown in a window.
    var isOnScreen = false
    /// Narrow windows: the user's choice to show (true) or hide (false) the details; nil = automatic (#104).
    var detailsExpanded: Bool?
    /// Set by the layout: whether the details are on screen, and whether the current layout can collapse
    /// them (narrow windows only).
    /// (Read by menu validation only; not observed, so layout publishing never re-renders views.)
    @ObservationIgnored var detailsShown = true
    @ObservationIgnored var detailsCanCollapse = false
    /// Share of the tables' height given to Speakers (#89).
    var speakersFraction = SetupSplitLayout.defaultSpeakersFraction
    /// Recorder group rows the user collapsed (all start expanded).
    var collapsedRows: Set<SetupRowID> = []
    var sortOrder: SourceSortOrder = .manual
    var sheet: Sheet?
    var confirmation: Confirmation?
    /// Inline, persistent explanation of the last refused or failed action (not time-boxed).
    var message: String?
    /// Which table the user last selected in; drives the inspector (IA §4.4).
    var inspectorFollowsSpeakers = false
    /// Incremented to ask the inspector to focus its first editable field (Return in the tables).
    var inspectorFocusRequest = 0
    /// A focus request not yet honoured (the details may still be appearing). Consumed once.
    @ObservationIgnored private var pendingInspectorFocus = false

    /// Return in a table: move focus to the details' first editable field, opening them if collapsed.
    func requestInspectorFocus() {
        // Only when the details show something editable (not for a multi-row selection), so a stale
        // request can never pull focus out of the table later.
        pendingInspectorFocus = inspectorSubject != .none
        if !detailsShown { detailsExpanded = true }
        inspectorFocusRequest += 1
    }

    /// True once per request, for whichever details view is on screen to take focus.
    func consumeInspectorFocus() -> Bool {
        defer { pendingInspectorFocus = false }
        return pendingInspectorFocus
    }
    var isScanning = false

    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var observedIDs: Set<SourceID> = []

    init(store: ShowDocumentStore, episodeID: EpisodeID, engine: any SourceSetupEngine, preference: any SourceDownloadPreference) {
        self.store = store
        self.episodeID = episodeID
        self.engine = engine
        self.preference = preference
    }

    // MARK: Derived state

    var episode: Episode? { store.model.episode(episodeID) }

    var presentation: SetupPresentation {
        SetupPresentation(model: store.model, episodeID: episodeID, statuses: statuses, onlyNeedingAttention: onlyNeedingAttention, sortOrder: sortOrder)
    }

    var downloadsAutomatically: Bool { preference.downloadsAutomatically }

    var episodeProgress: EpisodeDownloadProgress? {
        EpisodeDownloadProgress(statuses: (episode?.sources ?? []).map { status(of: $0.id) })
    }

    var offExplanation: String? {
        guard !downloadsAutomatically else { return nil }
        let count = (episode?.sources ?? []).filter { status(of: $0.id).residency == .cloudOnly }.count
        return EpisodeDownloadProgress.offExplanation(notDownloadedCount: count)
    }

    func status(of id: SourceID) -> SourceStatusSnapshot { statuses[id] ?? .checking }

    var selectedSourceIDs: [SourceID] {
        let selected = Set(selection.compactMap(\.sourceID))
        return (episode?.sources ?? []).map(\.id).filter(selected.contains)
    }

    var selectedGroupID: RecorderGroupID?? {
        for case let .group(id) in selection { return .some(id) }
        return nil
    }

    var singleSelectedSource: SourceRecord? {
        let ids = selectedSourceIDs
        guard ids.count == 1 else { return nil }
        return episode?.source(ids[0])
    }

    /// The single speaker reference of a selected source row (or a channel row).
    var selectedReference: SpeakerChannelReference? {
        guard selection.count == 1, let row = selection.first, let episode else { return nil }
        switch row {
        case let .channel(sourceID, speakerID):
            return episode.references(to: sourceID).first { $0.speakerID == speakerID }
        case let .source(sourceID):
            let refs = episode.references(to: sourceID)
            return refs.count == 1 ? refs[0] : nil
        case .group:
            return nil
        }
    }

    var inspectorSubject: InspectorSubject {
        if inspectorFollowsSpeakers, speakerSelection.count == 1, let id = speakerSelection.first { return .speaker(id) }
        guard selection.count == 1, let row = selection.first else { return .none }
        switch row {
        case let .group(id): return .group(id)
        case let .source(id), let .channel(id, _): return .source(id)
        }
    }

    func speakerName(_ id: SpeakerID) -> String { store.model.speaker(id)?.name ?? "Unknown speaker" }

    func groupName(_ id: RecorderGroupID?) -> String {
        guard let id else { return "Ungrouped" }
        return episode?.recorderGroup(id)?.name ?? "Recorder group"
    }

    var episodeSpeakers: [(id: SpeakerID, name: String)] {
        (episode?.speakerAssignments ?? []).map { ($0.speakerID, speakerName($0.speakerID)) }
    }

    // MARK: Observation

    func startObserving() {
        let ids = Set(episode?.sources.map(\.id) ?? [])
        guard ids != observedIDs || observation == nil else { return }
        observedIDs = ids
        observation?.cancel()
        let stream = engine.observe(ids)
        observation = Task { [weak self] in
            for await update in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(update, for: ids)
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        observedIDs = []
        primaryOpenRequests.cancelAll()
    }

    /// The real device store cannot yet supply a durable record generation, so this refuses rather than
    /// converting selected-primary metadata or an in-app confirmation into permission to read audio.
    func beginPrimaryContentOpen(speakerID: SpeakerID, channel: ChannelReference) throws -> PrimaryOpenRequestID {
        try primaryOpenRequests.begin(speakerID: speakerID, channel: channel, state: primaryOpenState())
    }

    func primaryOpenState() -> PrimaryOpenState {
        let selectedSpeaker = speakerSelection.count == 1 ? speakerSelection.first : nil
        return PrimaryOpenState(model: store.model, episodeID: episodeID,
                                documentGeneration: store.modelGeneration,
                                selectionGeneration: selectionGeneration,
                                relinkGeneration: relinkGeneration,
                                accessRecordGeneration: nil,
                                outstandingRelink: relinkPending || sheet != nil,
                                selectedSpeakerID: selectedSpeaker,
                                selectedChannel: selectedReference?.channel)
    }

    private func receive(_ update: [SourceID: SourceStatusSnapshot], for ids: Set<SourceID>) {
        let before = presentation.needingAttentionCount
        let focused = singleSelectedSource?.id
        let previousFocused = focused.flatMap { statuses[$0] }
        for id in ids { statuses[id] = update[id] ?? statuses[id] }
        let after = presentation.needingAttentionCount
        if after != before {
            let text = switch after {
            case 0: "No sources need attention"
            case 1: "1 source needs attention"
            default: "\(after) sources need attention"
            }
            announce(text)
        }
        if let focused, let now = statuses[focused], let name = episode?.source(focused)?.displayNameHint {
            announceTransferChange(from: previousFocused, to: now, name: name)
        }
    }

    @ObservationIgnored private var lastProgressAnnouncement: Date?

    /// Announces the focused source's transfer changes (states §7): progress at most every 10 s.
    private func announceTransferChange(from old: SourceStatusSnapshot?, to new: SourceStatusSnapshot, name: String) {
        guard let event = TransferAnnouncement.decide(from: old, to: new) else { return }
        if case .progress = event {
            if let last = lastProgressAnnouncement, Date().timeIntervalSince(last) < 10 { return }
            lastProgressAnnouncement = Date()
        }
        announce(event.text(for: name))
    }

    func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        #if DEBUG
        // UI tests can't hear announcements; the runner's host counts these lines (T30 "announced once").
        Self.announcementLog.notice("WWANNOUNCE \(text, privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let announcementLog = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "announce")
    #endif

    // MARK: Canonical edits (named undo, via SetupEditCommands)

    var commands: SetupEditCommands { SetupEditCommands(editor: store, episodeID: episodeID) }

    /// Runs one named edit; a refusal shows a persistent inline reason instead of a silent no-op.
    @discardableResult
    private func edit(_ body: (SetupEditCommands) -> Bool) -> Bool {
        let applied = body(commands)
        message = applied ? nil : store.lastError.map(Self.describe)
        if applied { startObserving() }
        return applied
    }

    func assign(_ sourceIDs: [SourceID], toGroup groupID: RecorderGroupID?) {
        edit { $0.assign(sourceIDs, toGroup: groupID) }
    }

    func createGroup(named name: String, assigning sourceIDs: [SourceID]) {
        let group = RecorderGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if edit({ $0.createGroup(group, assigning: sourceIDs) }), sourceIDs.isEmpty {
            selection = [.group(group.id)]
        }
    }

    func renameGroup(_ groupID: RecorderGroupID, to name: String) {
        edit { $0.renameGroup(groupID, to: name) }
    }

    func deleteGroup(_ groupID: RecorderGroupID) {
        if edit({ $0.deleteGroup(groupID) }) { selection = [.group(nil)] }
    }

    func setEpoch(_ number: Int, for sourceIDs: [SourceID]) {
        edit { $0.setEpoch(number, for: sourceIDs) }
    }

    func startNewEpoch() {
        var ids = selectedSourceIDs
        if ids.isEmpty, case let .some(.some(groupID)) = selectedGroupID {
            ids = episode?.sources(inRecorderGroup: groupID).map(\.id) ?? []
        }
        edit { $0.startNewEpoch(for: ids) }
    }

    /// `channel` is 1-based as typed by the user; nil = Unknown.
    func setChannel(_ channel: Int?, for sourceIDs: [SourceID]) {
        edit { $0.setChannel(channel, for: sourceIDs) }
    }

    func assignSpeaker(_ speakerID: SpeakerID?, to sourceIDs: [SourceID]) {
        edit { $0.assignSpeaker(speakerID, to: sourceIDs) }
    }

    func createSpeaker(named name: String, assigning sourceIDs: [SourceID]) {
        let speaker = Speaker(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if edit({ $0.createSpeaker(speaker, assigning: sourceIDs) }), sourceIDs.isEmpty {
            speakerSelection = [speaker.id]
            inspectorFollowsSpeakers = true
        }
    }

    func renameSpeaker(_ id: SpeakerID, to name: String) {
        edit { $0.renameSpeaker(id, to: name) }
    }

    func deleteSpeaker(_ id: SpeakerID) {
        let rows = presentation.speakerRows.map(\.id)
        if edit({ $0.deleteSpeaker(id) }) {
            speakerSelection = Self.neighbour(of: id, in: rows).map { [$0] } ?? []
            announce(speakerSelection.first.map { "Selected \(speakerName($0))" } ?? "No speakers")
        }
    }

    func useAsPrimary(_ ref: SpeakerChannelReference) {
        edit { $0.useAsPrimary(ref) }
    }

    func useAsBackup(_ ref: SpeakerChannelReference) {
        edit { $0.useAsBackup(ref) }
    }

    func setPrimary(_ channel: ChannelReference?, for speakerID: SpeakerID) {
        edit { $0.setPrimary(channel, for: speakerID) }
    }

    func removeSources(_ ids: [SourceID]) {
        let order = presentation.orderedSourceIDs
        if edit({ $0.removeSources(ids) }) {
            let remaining = order.filter { !ids.contains($0) }
            let next = ids.last.flatMap { last in Self.neighbour(of: last, in: order).flatMap { remaining.contains($0) ? $0 : nil } } ?? remaining.last
            selection = next.map { [.source($0)] } ?? []
            if let next, let name = episode?.source(next)?.displayNameHint { announce("Selected \(name)") }
        }
    }

    func moveSelected(_ direction: MoveDirection) {
        if focusedTable == .speakers || (focusedTable == nil && inspectorFollowsSpeakers), let id = speakerSelection.first, speakerSelection.count == 1 {
            edit { $0.moveSpeaker(id, direction) }
        } else if let source = singleSelectedSource {
            edit { $0.moveSource(source.id, direction) }
        }
    }

    // MARK: Import (IA §5)

    func beginImport() {
        if SetupFixtures.isActive {
            // UI-test fixture: the scripted engine supplies a synthetic scan; no panel, no files.
            scan([])
            return
        }
        guard let window = window(), episode != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose recordings or folders to add to “\(episode?.title ?? "")”"
        let accessory = NSTextField(wrappingLabelWithString: "WaveWrangler adds references to these files. It never moves, renames or changes them.")
        accessory.frame.size.width = 420
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.scan(panel.urls)
        }
    }

    func scan(_ urls: [URL]) {
        guard let episode else { return }
        isScanning = true
        let ids = episode.sources.map(\.id)
        let speakers = store.model.speakers.map(\.name)
        let title = episode.title
        Task { [engine] in
            do {
                let result = try await engine.scanForImport(urls, episodeSourceIDs: ids)
                self.isScanning = false
                self.sheet = .importReview(ImportReview(scan: result, episodeTitle: title, knownSpeakerNames: speakers))
            } catch {
                self.isScanning = false
                self.message = "Couldn't look at the chosen files: \(Self.reason(error)). Nothing was imported."
            }
        }
    }

    /// Confirms an Import Review: one undoable "Import N Sources" action, then device-local records.
    func commitImport(_ review: ImportReview) {
        let pairs = review.importItems()
        guard !pairs.isEmpty else { cancelImport(review); return }
        let items = pairs.map(\.item)
        sheet = nil
        guard edit({ $0.importSources(items) }) else { return }
        inspectorFollowsSpeakers = false
        let imported = Set(items.map { SetupRowID.source($0.source.id) })
        // Select after the table has the new rows (selecting unknown rows is dropped by the table).
        Task { @MainActor in
            await Task.yield()
            self.selection = imported
        }
        announce("Imported \(items.count == 1 ? "1 source" : "\(items.count) sources")")
        let accepted = Dictionary(uniqueKeysWithValues: pairs.map { ($0.candidateID, $0.item.source.id) })
        let token = review.scanToken
        Task { [engine] in
            do {
                try await engine.commitImport(accepted, fromScan: token)
            } catch {
                self.message = "The sources were added, but WaveWrangler couldn't save permission to reach them on this Mac: \(Self.reason(error))."
            }
            self.startObserving()
            try? await Task.sleep(for: .milliseconds(200))
            if self.selection.isEmpty { self.selection = imported }
        }
    }

    /// Cancel changes nothing; the engine forgets the scan.
    func cancelImport(_ review: ImportReview) {
        sheet = nil
        let token = review.scanToken
        Task { [engine] in await engine.discardScan(token) }
    }

    // MARK: Relink / regrant (states §4)

    func beginRelink(_ sourceID: SourceID, mode: RelinkContext.Mode = .relink) {
        guard let window = window(), let source = episode?.source(sourceID) else { return }
        relinkGeneration = UUID()
        let generation = relinkGeneration
        let documentGeneration = store.modelGeneration
        relinkPending = true
        sheet = nil
        primaryOpenRequests.cancelAll()
        let name = source.displayNameHint
        Task { [engine] in
            let recorded = await engine.recordedDetails(for: sourceID)
            guard self.relinkGeneration == generation else { return }
            let folder = await engine.lastKnownFolder(for: sourceID)
            guard self.relinkGeneration == generation else { return }
            let url: URL?
            if let override = SetupFixtures.relinkCandidateOverride {
                url = override
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "\(RelinkComparison.panelPrompt(for: name)). \(RelinkComparison.panelMessage(for: recorded))"
                panel.prompt = mode == .grantAccess ? "Grant Access" : "Choose"
                if let folder { panel.directoryURL = folder }
                let response = await panel.beginSheetModal(for: window)
                url = response == .OK ? panel.url : nil
            }
            guard let url else {
                self.relinkPending = false
                return
            }
            let comparison = await engine.compare(candidate: url, for: sourceID)
            guard self.relinkGeneration == generation else { return }
            guard self.store.modelGeneration == documentGeneration,
                  self.episode?.source(sourceID) != nil else {
                self.relinkPending = false
                self.message = "The source or show changed while checking the file. Choose it again; nothing was changed."
                return
            }
            self.relinkPending = false
            self.sheet = .relink(RelinkContext(sourceID: sourceID, displayName: name, candidate: url, comparison: comparison,
                                               mode: mode, generation: generation, documentGeneration: documentGeneration))
        }
    }

    /// One undoable "Relink “file”" action. The device-local record changes; no file is touched.
    func confirmRelink(_ context: RelinkContext) {
        guard case let .relink(current) = sheet,
              current.generation == context.generation,
              current.sourceID == context.sourceID, current.candidate == context.candidate,
              current.comparison == context.comparison, current.mode == context.mode,
              relinkGeneration == context.generation,
              store.modelGeneration == context.documentGeneration,
              episode?.source(context.sourceID) != nil else {
            message = "The source or show changed while relinking. Choose the file again; nothing was changed."
            return
        }
        sheet = nil
        relinkGeneration = UUID()
        let generation = relinkGeneration
        primaryOpenRequests.cancelAll()
        guard let registrar = relinkRegistrar else {
            message = "Couldn't relink “\(context.displayName)”: this window has no undo history. Nothing was changed."
            return
        }
        relinkPending = true
        registrar.relink(context.sourceID, to: context.candidate, identity: context.comparison.acceptedIdentity, actionName: SetupUndoName.relink(context.displayName))
        Task {
            await registrar.settle()
            guard relinkGeneration == generation else { return }
            relinkPending = false
            relinkGeneration = UUID()
        }
        selection = [.source(context.sourceID)]
    }

    @ObservationIgnored private var registrarStorage: RelinkUndoRegistrar?

    private var relinkRegistrar: RelinkUndoRegistrar? {
        guard let undoManager = store.document?.undoManager else { return nil }
        if let existing = registrarStorage, existing.undoManager === undoManager { return existing }
        let registrar = RelinkUndoRegistrar(undoManager: undoManager, engine: engine)
        registrar.onFailure = { [weak self] reason in
            self?.message = "Couldn't relink: \(reason). Nothing was changed."
        }
        registrarStorage = registrar
        return registrar
    }

    // MARK: Downloads

    func perform(_ action: TransferAction, on sourceID: SourceID) {
        if action == .cancel, TransferAction.cancelNeedsConfirmation(status(of: sourceID).transfer) {
            confirmation = .cancelDownload(sourceID)
            return
        }
        performConfirmed(action, on: sourceID)
    }

    func performConfirmed(_ action: TransferAction, on sourceID: SourceID) {
        Task { [engine] in await engine.perform(action, on: sourceID) }
    }

    func tryAgain(_ sourceID: SourceID) {
        Task { [engine] in await engine.refresh([sourceID]) }
    }

    func availableActions(for sourceID: SourceID) -> [TransferAction] {
        let s = status(of: sourceID)
        return TransferAction.available(transfer: s.transfer, residency: s.residency, pauseSupported: engine.pauseSupported)
    }

    // MARK: Helpers

    static func neighbour<T: Equatable>(of item: T, in list: [T]) -> T? {
        guard let index = list.firstIndex(of: item) else { return nil }
        if index + 1 < list.count { return list[index + 1] }
        return index > 0 ? list[index - 1] : nil
    }

    static func reason(_ error: any Error) -> String {
        (error as? SourceEngineError)?.reason ?? error.localizedDescription
    }

    static func describe(_ error: DomainError) -> String {
        switch error {
        case .emptyTitle: "A name can't be empty."
        case let .invalidEpochNumber(n): "Epoch \(n) isn't valid. Enter a whole number of 1 or more."
        case .sourceNotInRecorderGroup: "Choose a recorder group first. Epochs belong to a recorder group."
        case .channelIsPrimaryOfAnotherSpeaker: "That channel is already another speaker's primary. Set a different channel first."
        case .channelNotAssignedToSpeaker: "Assign the speaker to this source first."
        case .invalidChannel: "Enter a whole number of 1 or more, or choose Unknown."
        case .channelOutOfRange(_, let count): "This source has \(count) channels."
        case .sourceIsDesignatedBackup: "This source is a backup. Choose Use as Primary to change it."
        default: "The change wasn't applied."
        }
    }
}

struct RelinkContext {
    enum Mode: Equatable {
        case relink
        case grantAccess
        case review
    }

    var sourceID: SourceID
    var displayName: String
    var candidate: URL
    var comparison: RelinkComparison
    var mode: Mode
    var generation: UUID
    var documentGeneration: UUID
}

struct NumberSheetContext {
    enum Kind: String {
        case epoch
        case channel
    }

    var kind: Kind
    var sourceIDs: [SourceID]
    var initial: Int?
}

struct NameSheetContext {
    enum Kind: String {
        case newGroup
        case newSpeaker
        case renameGroup
        case renameSpeaker
    }

    var kind: Kind
    var initial: String
    var assigning: [SourceID] = []
    var groupID: RecorderGroupID?
    var speakerID: SpeakerID?

    var title: String {
        switch kind {
        case .newGroup: "New Recorder Group"
        case .newSpeaker: "New Speaker"
        case .renameGroup: "Rename Recorder Group"
        case .renameSpeaker: "Rename Speaker"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .newGroup, .newSpeaker: "Create"
        case .renameGroup, .renameSpeaker: "Rename"
        }
    }
}
