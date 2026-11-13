import Foundation
import Observation
import WWCore
import WWPersistence
import WWOrganizer

/// Main-actor view model for one open show. Every change goes through a pure WWCore operation and is
/// registered with the document's undo manager, which also drives NSDocument's honest dirty state.
@MainActor
@Observable
final class ShowDocumentStore {
    private struct WeakListening {
        weak var value: RegularAudioPlayback?
    }
    @ObservationIgnored private var listeningSessions: [WeakListening] = []
    @ObservationIgnored lazy var autoInputGain = AutoInputGainController(store: self)

    /// A scope for pure operations, never the canonical catalog or evidence of episode membership.
    private(set) var residentModel: ShowDocumentModel {
        didSet {
            modelGeneration += 1
            listeningSessions.removeAll { $0.value == nil }
            listeningSessions.forEach { $0.value?.documentDidChange(residentModel) }
            if !isCapturingMixer { document?.mixerTransactions.modelDidChange() }
            for state in ShowWindowRegistry.states(for: self) {
                state.reviewModelDidChange()
                if !isCapturingMixer { state.mixerPresentation.modelDidChange(from: oldValue) }
            }
        }
    }
    /// Ephemeral publication identity, including load, coalesced edits and undo/redo.
    /// Unlike model equality, this detects an edit followed by an undo to identical bytes.
    private(set) var modelGeneration: UInt64 = 0
    /// The most recent refused operation, shown to the user until the next successful change.
    private(set) var lastError: DomainError?

    @ObservationIgnored weak var document: ShowDocument?
    /// Key of the edit burst currently being coalesced into a single undo step (e.g. live title typing).
    @ObservationIgnored private var coalescingKey: String?
    @ObservationIgnored private var isCapturingMixer = false
    @ObservationIgnored private var isEditingMixer = false
    private var catalogRevision: ShowCatalogRevision
    @ObservationIgnored private var archiveOwner: ShowCatalog?
    private struct WeakRevision { weak var value: ShowEpisodeRevision? }
    @ObservationIgnored private var revisions: [WeakRevision] = []
    @ObservationIgnored private var pins: [EpisodeID: Set<UUID>] = [:]
    @ObservationIgnored private var loads: [EpisodeID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadTokens: [EpisodeID: UUID] = [:]
    @ObservationIgnored private var loadRevisions: [EpisodeID: ObjectIdentifier] = [:]
    @ObservationIgnored private var eviction: Task<Void, Never>?
    @ObservationIgnored private var demandDriven = false
    @ObservationIgnored private var residencyClosed = false
    private(set) var loadingEpisodes: Set<EpisodeID> = []
    private(set) var episodeLoadErrors: [EpisodeID: String] = [:]

    var catalogIdentity: UUID { catalogRevision.identity }
    var episodeSummaries: [CatalogEpisodeSummary] { catalogRevision.episodes.map(\.summary) }
    var header: ShowCatalogHeader { catalogRevision.header }
    var allSourceIDs: Set<SourceID> { Set(episodeSummaries.flatMap(\.sourceIDs)) }
    var librarySummary: ShowLastOpenSummary {
        ShowLastOpenSummary(showID: header.show.id,
            episodes: episodeSummaries.map { .init(id: $0.id, number: $0.number, title: $0.title) },
            sourceReferenceCount: episodeSummaries.reduce(0) { $0 + $1.sourceIDs.count })
    }
    var pinnedEpisodeIDs: Set<EpisodeID> { Set(pins.keys) }
    var residentRevisionCount: Int { revisions.compactMap(\.value).filter { $0.resident != nil }.count }
    func containsEpisode(_ id: EpisodeID) -> Bool { episodeSummaries.contains { $0.id == id } }

    init(model: ShowDocumentModel) {
        residentModel = model
        catalogRevision = ShowCatalogRevision(model: model)
        rememberRevisions()
    }

    func registerListening(_ session: RegularAudioPlayback) {
        listeningSessions.removeAll { $0.value == nil }
        listeningSessions.append(WeakListening(value: session))
    }

    var canEdit: Bool {
        guard let document else { return true }
        return !document.isViewingForEditing && !document.saveStatus.state.isReadOnly
    }

    /// Replaces the value after reading from disk; not an undoable edit.
    func replaceLoadedModel(_ model: ShowDocumentModel) {
        residencyClosed = false
        demandDriven = false
        catalogRevision = ShowCatalogRevision(model: model)
        archiveOwner = nil
        rememberRevisions()
        residentModel = model
        lastError = nil
        coalescingKey = nil
        reloadPinnedEpisodes()
    }

    func replaceLoadedCatalog(_ catalog: ShowCatalog) {
        residencyClosed = false
        demandDriven = true
        catalogRevision = ShowCatalogRevision(catalog: catalog)
        archiveOwner = catalog
        rememberRevisions()
        residentModel = catalogRevision.residentModel
        lastError = nil
        coalescingKey = nil
        reloadPinnedEpisodes()
    }

    func captureCatalog() -> ShowCatalogDraft { catalogRevision.captured(archiveOwner: archiveOwner) }

    func adoptArchives(_ catalog: ShowCatalog, captured: ShowCatalogRevision) {
        archiveOwner = catalog
        for revision in captured.episodes {
            if let stored = catalog.episode(revision.summary.id) { revision.archived(stored) }
        }
        evictUnpinnedEpisodes()
    }

    func captureRevision() -> ShowCatalogRevision { catalogRevision }

    func replacePublishedRevision(_ revision: ShowCatalogRevision) {
        demandDriven = true
        adopt(revision)
    }

    func enableDemandDrivenEditing() { demandDriven = true }

    var nextNewEpisode: Episode {
        let summaries = episodeSummaries
        let number = (summaries.compactMap(\.number).max() ?? summaries.count) + 1
        return Episode(title: "Episode \(number)", number: number)
    }

    func canMoveEpisode(_ id: EpisodeID, by offset: Int) -> Bool {
        guard let index = episodeSummaries.firstIndex(where: { $0.id == id }), offset != 0 else { return false }
        return episodeSummaries.indices.contains(index + offset)
    }

    @discardableResult
    func removeEpisode(_ id: EpisodeID) -> Bool {
        editCatalog(UndoActionName.deleteEpisode) { $0.filter { $0.summary.id != id } }
    }

    @discardableResult
    func moveEpisode(_ id: EpisodeID, by offset: Int) -> Bool {
        guard canMoveEpisode(id, by: offset), let index = episodeSummaries.firstIndex(where: { $0.id == id }) else { return false }
        return editCatalog(UndoActionName.moveEpisode) {
            var episodes = $0
            let episode = episodes.remove(at: index)
            episodes.insert(episode, at: index + offset)
            return episodes
        }
    }

    @discardableResult
    func moveEpisodes(fromOffsets source: IndexSet, toOffset destination: Int) -> Bool {
        editCatalog(UndoActionName.moveEpisode) {
            LibraryModel.moving($0, fromOffsets: source, toOffset: destination)
        }
    }

    private func editCatalog(_ action: String, _ operation: ([ShowEpisodeRevision]) -> [ShowEpisodeRevision]) -> Bool {
        guard canEdit, document?.mixerTransactions.isBusy != true else {
            lastError = .invalidMix("This show cannot be edited while read-only or while a mixer transaction is running.")
            return false
        }
        let episodes = operation(catalogRevision.episodes)
        let projected = header.operationModel(episodes: episodes.compactMap(\.resident))
        guard document?.mixerTransactions.refusesReplacement(from: residentModel, to: projected) != true else {
            lastError = .invalidMix("Close the Audio Unit editor before removing its episode.")
            return false
        }
        guard episodes.map(\.summary.id) != episodeSummaries.map(\.id) else { return true }
        lastError = nil
        replace(with: ShowCatalogRevision(header: header, episodes: episodes), actionName: action)
        return true
    }

    /// Applies a pure operation immediately so the model (and therefore Save, autosave, Close and Quit)
    /// always sees the latest edit.
    ///
    /// Successive applies with the same non-nil `coalescing` key form one undo step: the first registers
    /// undo (which marks the document dirty), later ones in the burst only update the model. A burst ends
    /// on `endCoalescing()`, on any other edit, on undo/redo, and when a save begins, so an edit made after
    /// a save always registers new undo and makes the document dirty again.
    @discardableResult
    func apply(
        _ actionName: String,
        coalescing key: String? = nil,
        _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel
    ) -> Bool {
        // #159: an older-format show is read-only until its update has published.
        guard canEdit else {
            lastError = .invalidMix("This show is read-only. Open an editable copy before changing it.")
            return false
        }
        guard admitEpisodeEdit() else { return false }
        do throws(DomainError) {
            if document?.mixerTransactions.isBusy == true, !isCapturingMixer, !isEditingMixer {
                throw DomainError.invalidMix("Wait for the mixer document transaction to finish.")
            }
            let updated = try operation(residentModel)
            if !isCapturingMixer,
               document?.mixerTransactions.refusesReplacement(from: residentModel, to: updated) == true {
                throw DomainError.invalidMix("Close the Audio Unit editor before changing its source, timing, or insert chain.")
            }
            lastError = nil
            guard updated != residentModel else { return true }
            let replacement = try mergedRevision(updated)
            if let key, key == coalescingKey {
                adopt(replacement)
                // No new undo step, so AppKit won't reschedule autosaving: the quiescence timer must still move
                // to this edit, or a checkpoint/autosave taken mid-burst would miss the rest of it.
                document?.coalescedEditDidChangeModel()
            } else {
                replace(with: replacement, actionName: actionName)
            }
            coalescingKey = key
            Responsiveness.interaction("show.edit")
            return true
        } catch {
            lastError = error
            coalescingKey = nil
            return false
        }
    }

    func endCoalescing() {
        coalescingKey = nil
    }

    @discardableResult
    func setRecordingInputGain(_ gain: Double, reference: ChannelReference, in episode: EpisodeID) -> Bool {
        apply("Adjust Recording Input Gain",
              coalescing: "inputGain.\(episode).\(reference.sourceID).\(String(describing: reference.channel.value))") {
            model throws(DomainError) in try model.settingInputGain(gain, for: reference, in: episode)
        }
    }

    func applyMixerCapture(
        coalescing key: String?,
        _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel
    ) -> Bool {
        isCapturingMixer = true
        defer { isCapturingMixer = false }
        return apply("Edit Audio Unit", coalescing: key, operation)
    }

    func applyMixerEdit(
        _ action: String,
        _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel
    ) -> Bool {
        isEditingMixer = true
        defer { isEditingMixer = false }
        return apply(action, operation)
    }

    /// Applies a complete, already-validated model and runs `afterChange` for the initial edit and every
    /// undo/redo replacement. Alignment uses this to persist first, then activate the accepted map revision.
    @discardableResult
    func applyReplacement(
        _ actionName: String,
        model newModel: ShowDocumentModel,
        afterChange: @escaping @MainActor (ShowDocumentModel) -> Void
    ) -> Bool {
        guard canEdit else {
            lastError = .invalidMix("This show is read-only. Open an editable copy before changing it.")
            return false
        }
        guard admitEpisodeEdit() else { return false }
        guard document?.mixerTransactions.isBusy != true else {
            lastError = .invalidMix("Wait for the mixer document transaction to finish.")
            return false
        }
        guard document?.mixerTransactions.refusesReplacement(from: residentModel, to: newModel) != true else {
            lastError = .invalidMix("Close the Audio Unit editor before replacing its source, timing, or insert chain.")
            return false
        }
        guard newModel != residentModel else { return true }
        do {
            let replacement = try mergedRevision(newModel)
            lastError = nil
            replace(with: replacement, actionName: actionName, afterChange: afterChange)
            Responsiveness.interaction("show.edit")
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// Applies a replacement that was computed from `expected`, but only while the live model is still
    /// exactly that snapshot.
    ///
    /// Windows share one store, so a replacement prepared across awaits can arrive after another window has
    /// edited the show; publishing it then would discard that edit. Returns false without touching the model
    /// when the snapshot has been superseded (#219).
    @discardableResult
    func applyReplacement(
        _ actionName: String,
        expecting expected: ShowDocumentModel,
        model newModel: ShowDocumentModel,
        afterChange: @escaping @MainActor (ShowDocumentModel) -> Void
    ) -> Bool {
        guard SharedModelPublication.decide(live: residentModel, expected: expected) == .publish else { return false }
        return applyReplacement(actionName, model: newModel, afterChange: afterChange)
    }

    private func replace(
        with replacement: ShowCatalogRevision,
        actionName: String,
        afterChange: (@MainActor (ShowDocumentModel) -> Void)? = nil
    ) {
        let undo = document?.undoManager
        let ownsGroup = undo?.groupsByEvent == false && undo?.groupingLevel == 0
            && undo?.isUndoing != true && undo?.isRedoing != true
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        let previous = catalogRevision
        adopt(replacement)
        coalescingKey = nil
        if let undoManager = document?.undoManager {
            AppUndoRegistration.register(
                with: undoManager,
                target: self,
                actionName: actionName
            ) { store in
                store.replace(with: previous, actionName: actionName, afterChange: afterChange)
            }
        }
        notifyAfterLoad(afterChange)
    }

    /// Generic domain transforms are scoped to resident episodes. Preserve every opaque slot and
    /// validate global IDs/references against the complete index before publishing the replacement.
    private func mergedRevision(_ updated: ShowDocumentModel) throws(DomainError) -> ShowCatalogRevision {
        var header = ShowCatalogHeader(updated)
        guard Set(updated.episodes.map(\.id)).count == updated.episodes.count else {
            throw .invalidMix("The edit contains duplicate episode identities.")
        }
        let byID = Dictionary(uniqueKeysWithValues: updated.episodes.map { ($0.id, $0) })
        let oldIDs = Set(catalogRevision.episodes.map(\.summary.id))
        var merged: [ShowEpisodeRevision] = []
        for revision in catalogRevision.episodes {
            if let episode = byID[revision.summary.id] {
                merged.append(episode == revision.resident ? revision : ShowEpisodeRevision(episode, header: header))
            } else if revision.resident == nil {
                merged.append(revision)
            }
        }
        merged += updated.episodes.filter { !oldIDs.contains($0.id) }.map { ShowEpisodeRevision($0, header: header) }
        let referenced = Set(merged.flatMap { $0.summary.speakerIDs })
        let provided = Set(header.speakers.map(\.id))
        // Episode-scoped removal may prune a speaker from its operation scope, not from opaque episodes.
        header.speakers += catalogRevision.header.speakers.filter {
            referenced.contains($0.id) && !provided.contains($0.id)
        }
        do {
            try ShowCatalog.validate(header: header, summaries: merged.map(\.summary))
        } catch {
            throw .invalidMix("The edit conflicts with the complete episode catalog: \(error.localizedDescription)")
        }
        return ShowCatalogRevision(header: header, episodes: merged)
    }

    private func adopt(_ revision: ShowCatalogRevision) {
        catalogRevision = revision
        rememberRevisions()
        residentModel = revision.residentModel
        reloadPinnedEpisodes()
        evictUnpinnedEpisodes()
    }

    private func rememberRevisions() {
        revisions.removeAll { $0.value == nil }
        let known = Set(revisions.compactMap { $0.value.map(ObjectIdentifier.init) })
        revisions += catalogRevision.episodes.filter { !known.contains(ObjectIdentifier($0)) }.map { WeakRevision(value: $0) }
    }

    func pinEpisode(_ id: EpisodeID, owner: UUID) {
        pins[id, default: []].insert(owner)
        startLoading(id)
    }

    func unpinEpisode(_ id: EpisodeID, owner: UUID) {
        pins[id]?.remove(owner)
        guard pins[id]?.isEmpty == true else { return }
        pins[id] = nil
        loads[id]?.cancel()
        document?.releaseVerifiedEpisode(id)
        evictUnpinnedEpisodes()
    }

    func ensureEpisodeLoaded(_ id: EpisodeID) async throws {
        try Task.checkCancellation()
        guard !residencyClosed else { throw CancellationError() }
        guard containsEpisode(id) else { throw PersistenceError.malformed("The episode no longer exists") }
        let identity = catalogIdentity
        while residentModel.episode(id) == nil {
            startLoading(id)
            guard let task = loads[id] else {
                throw PersistenceError.malformed(episodeLoadErrors[id] ?? "The episode could not be loaded")
            }
            await task.value
            try Task.checkCancellation()
            guard catalogIdentity == identity else { throw CancellationError() }
            if let error = episodeLoadErrors[id] { throw PersistenceError.malformed(error) }
            guard residentModel.episode(id) != nil || loads[id] != nil else { throw CancellationError() }
        }
    }

    func retryEpisodeLoading(_ id: EpisodeID) { startLoading(id) }

    private func reloadPinnedEpisodes() {
        for id in Array(loads.keys) {
            let current = catalogRevision.episodes.first { $0.summary.id == id }.map(ObjectIdentifier.init)
            if loadRevisions[id] != current || pins[id] == nil {
                loads[id]?.cancel()
                loads[id] = nil
                loadTokens[id] = nil
                loadRevisions[id] = nil
                loadingEpisodes.remove(id)
            }
        }
        for id in pins.keys { startLoading(id) }
    }

    private func startLoading(_ id: EpisodeID) {
        guard !residencyClosed,
              let revision = catalogRevision.episodes.first(where: { $0.summary.id == id }),
              revision.resident == nil, loads[id] == nil, let stored = revision.archived else { return }
        let header = catalogRevision.header
        let token = UUID()
        loadTokens[id] = token
        loadRevisions[id] = ObjectIdentifier(revision)
        loadingEpisodes.insert(id)
        episodeLoadErrors[id] = nil
        loads[id] = Task { [weak self, weak revision] in
            do {
                let episode = try await ShowCatalogWork.perform { try stored.load(in: header) }
                try await self?.document?.ensureVerifiedEpisodeLoaded(id, resident: episode, record: stored)
                try Task.checkCancellation()
                guard let self, let revision,
                      self.loadTokens[id] == token,
                      self.catalogRevision.episodes.contains(where: { $0 === revision }) else { return }
                revision.loaded(episode)
                self.residentModel = self.catalogRevision.residentModel
                self.loadingEpisodes.remove(id)
                self.loads[id] = nil
                self.loadRevisions[id] = nil
            } catch {
                guard let self, let revision,
                      self.loadTokens[id] == token,
                      self.catalogRevision.episodes.contains(where: { $0 === revision }) else { return }
                self.loadingEpisodes.remove(id)
                self.loads[id] = nil
                self.loadRevisions[id] = nil
                if !(error is CancellationError) {
                    self.episodeLoadErrors[id] = error.localizedDescription
                } else if self.pins[id] != nil {
                    self.startLoading(id)
                }
            }
        }
    }

    private func evictUnpinnedEpisodes() {
        guard demandDriven else { return }
        revisions.removeAll { $0.value == nil }
        for revision in revisions.compactMap(\.value) where !keepsResident(revision) {
            revision.evict()
        }
        let resident = catalogRevision.residentModel
        if residentModel != resident { residentModel = resident }
        guard eviction == nil else { return }
        let pending = revisions.compactMap(\.value).filter {
            !keepsResident($0) && $0.archived == nil
        }
        guard !pending.isEmpty else { return }
        let archiveOwner = archiveOwner
        eviction = Task { [weak self] in
            for revision in pending {
                guard let episode = revision.resident else { continue }
                let header = revision.validationHeader
                do {
                    let stored = try await ShowCatalogWork.perform {
                        let owner = try archiveOwner ?? ShowCatalog(header.operationModel(episodes: []))
                        return try owner.archivingEpisode(episode, validatingWith: header)
                    }
                    try Task.checkCancellation()
                    revision.archived(stored)
                    guard let self else { return }
                    if !self.keepsResident(revision) { revision.evict() }
                } catch {
                    guard let self else { return }
                    if error is CancellationError { return }
                    self.lastError = .invalidMix("Could not archive an episode revision: \(error.localizedDescription)")
                    self.eviction = nil
                    let resident = self.catalogRevision.residentModel
                    if self.residentModel != resident { self.residentModel = resident }
                    return
                }
            }
            guard let self else { return }
            self.eviction = nil
            let resident = self.catalogRevision.residentModel
            if self.residentModel != resident { self.residentModel = resident }
            self.evictUnpinnedEpisodes()
        }
    }

    private func keepsResident(_ revision: ShowEpisodeRevision) -> Bool {
        pins[revision.summary.id] != nil && catalogRevision.episodes.contains { $0 === revision }
    }

    private func admitEpisodeEdit() -> Bool {
        guard demandDriven else { return true }
        evictUnpinnedEpisodes()
        let pending = revisions.compactMap(\.value).filter { !keepsResident($0) && $0.archived == nil }
        guard pending.count < 4 else {
            lastError = .invalidMix("Wait for earlier episode revisions to finish archiving before editing again.")
            return false
        }
        return true
    }

    func closeResidency() {
        residencyClosed = true
        for task in loads.values { task.cancel() }
        loads = [:]
        loadTokens = [:]
        loadRevisions = [:]
        pins = [:]
        loadingEpisodes = []
        eviction?.cancel()
        eviction = nil
    }

    private func notifyAfterLoad(_ callback: (@MainActor (ShowDocumentModel) -> Void)?) {
        guard let callback else { return }
        let pending = pins.keys.filter { residentModel.episode($0) == nil && containsEpisode($0) }
        guard !pending.isEmpty else { callback(residentModel); return }
        let identity = catalogIdentity
        Task { [weak self] in
            guard let self else { return }
            do {
                for id in pending { try await self.ensureEpisodeLoaded(id) }
                guard self.catalogIdentity == identity else { return }
                callback(self.residentModel)
            } catch is CancellationError {
                return
            } catch {
                self.lastError = .invalidMix("Could not restore the episode revision: \(error.localizedDescription)")
            }
        }
    }
}
