import Foundation
import Observation
import WWCore
import WWMix

/// The originating editor owns this controller. A detached mixer binds this same instance.
/// It has no engine/device or source grants; EpisodeAlignmentModel owns the one output transport.
@MainActor @Observable
final class EpisodeMixerController {
    enum State: Equatable {
        case idle, loading, ready, playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var meters: MixerPCMOutput?
    private(set) var unitStatuses: [MixerUnitStatus] = []
    private(set) var instanceRevision: UInt64 = 0
    private(set) var dependencyFailure: String?
    var mutedSpeakers: Set<SpeakerID> = []
    var soloedSpeakers: Set<SpeakerID> = []
    var masterMuted = false
    @ObservationIgnored private(set) var processor: MixerProcessor?
    @ObservationIgnored private var snapshot: ShowDocumentModel?
    @ObservationIgnored private var expectedMix: EpisodeMixState?
    @ObservationIgnored private var nativeStateBaseline: [AudioUnitSlotID: AudioUnitSlot]?
    @ObservationIgnored private var editorPolling: Task<Void, Never>?
    @ObservationIgnored private let operations = MixerOperationQueue()
    private(set) var editorObservationKey: String?
    @ObservationIgnored private var generation: UInt64 = 0
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    let episodeID: EpisodeID
    #if DEBUG
    @ObservationIgnored var beforeStateCapture: (@MainActor () async -> Void)?
    #endif

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
        document.mixerTransactions.register(self)
    }

    func prepare(programFrames: Range<Int64>, policy: MixerRenderPolicy = .init()) async throws -> MixerRecipe {
        let presentations = document.map {
            ShowWindowRegistry.states(for: $0.store).filter { $0.alignmentModel?.mixer === self }.map(\.mixerPresentation)
        } ?? []
        presentations.forEach { $0.hideEditorsForBarrier() }
        let key = editorObservationKey
        await suspendEditorObservation()
        do {
            return try await operations.run { [self] in
                if nativeStateBaseline != nil { try await captureState(coalescing: key) }
                document?.store.endCoalescing()
                presentations.forEach { $0.dismissEditorsAfterCapture() }
                return try await load(programFrames: programFrames, policy: policy)
            }
        } catch {
            presentations.forEach { $0.restoreEditorsAfterBarrier() }
            throw error
        }
    }

    private func load(programFrames: Range<Int64>, policy: MixerRenderPolicy) async throws -> MixerRecipe {
        generation &+= 1
        let generation = generation
        editorPolling?.cancel()
        editorPolling = nil
        state = .loading
        guard let document else { throw MixerFailure.staleDependencies }
        let model = document.store.model
        do {
            guard document.verifiedModel?.hasSameMediaInputs(as: model, in: episodeID) == true else {
                throw MixerFailure.staleDependencies
            }
            let recipe = try await runtime.mixerRecipe(model: model, episode: episodeID,
                programFrames: programFrames, policy: policy)
            let loaded = try await MixerProcessor.load(recipe: recipe)
            let statuses = await loaded.unitStatuses()
            try Task.checkCancellation()
            guard self.generation == generation,
                  document.store.model.hasSameProcessingInputs(as: model, in: episodeID) else {
                throw MixerFailure.staleDependencies
            }
            processor = loaded
            instanceRevision &+= 1
            snapshot = model
            expectedMix = model.episode(episodeID)?.mix ?? EpisodeMixState()
            nativeStateBaseline = nil
            let speakers = Set(recipe.routes.map(\.speaker))
            mutedSpeakers.formIntersection(speakers)
            soloedSpeakers.formIntersection(speakers)
            unitStatuses = statuses
            state = .ready
            return recipe
        } catch {
            if self.generation == generation { fail(error) }
            throw error
        }
    }

    func preparePCM(_ frames: Range<Int64>) async throws -> MixerPCMWindow {
        guard let processor, let snapshot else { throw MixerFailure.staleDependencies }
        let generation = generation
        guard !frames.isEmpty, frames.count <= MixerLiveTiming.sourceWindowFrames else {
            throw MixerFailure.incompletePCM
        }
        try validateCurrent()
        let input = try await runtime.productionPCM(recipe: processor.recipe, model: snapshot, frames: frames)
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
        return input
    }

    func renderPrepared(_ input: MixerPCMWindow) async throws -> MixerPCMOutput {
        guard let processor, input.frames.count <= MixerLiveTiming.processingBlockFrames else {
            throw MixerFailure.incompletePCM
        }
        let generation = generation
        // Read current controls for EVERY short DSP block, not once per long source window.
        try await synchronizeControls()
        let output = try await processor.process(input)
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
        meters = output
        state = .playing
        return output
    }

    func finishNext() async throws -> MixerPCMOutput? {
        try validateCurrent()
        guard let processor else { throw MixerFailure.staleDependencies }
        let generation = generation
        try await synchronizeControls()
        let output = try await processor.finishNext(maximumFrames: MixerLiveTiming.processingBlockFrames)
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
        if let output { meters = output }
        return output
    }

    /// Call after document controls change. Source admission/cut/insert edits are restart boundaries.
    func synchronizeControls() async throws {
        try validateCurrent()
        guard let processor, let episode = document?.store.model.episode(episodeID) else {
            throw MixerFailure.staleDependencies
        }
        let mix = episode.mix ?? EpisodeMixState()
        var controls = MixerLiveControls(recipe: processor.recipe)
        for route in processor.recipe.routes {
            guard let channel = route.reference.channel.value else {
                throw MixerFailure.unresolvedChannel(route.reference.sourceID)
            }
            controls.inputGainDB[route.reference] = mix.inputGainDB(for: route.reference.sourceID,
                channel: channel)
            let strip = mix.state(for: route.speaker)
            var live = route.strip
            live.gainDB = strip.gainDB
            live.pan = strip.pan
            controls.speakers[route.speaker] = live
        }
        controls.masterGainDB = mix.master.gainDB
        controls.mutedSpeakers = mutedSpeakers
        controls.soloedSpeakers = soloedSpeakers
        controls.masterMuted = masterMuted
        try await processor.setLiveControls(controls)
    }

    func setParameter(slot: AudioUnitSlotID, address: UInt64, value: Float,
                      coalescing key: String) async throws {
        let revision = instanceRevision
        try await operations.run { [self] in
            guard revision == instanceRevision else { throw MixerFailure.staleDependencies }
            try validateCurrent()
            guard let processor else { throw MixerFailure.staleDependencies }
            let generation = generation
            try await establishNativeStateBaseline()
            try await processor.setParameter(slot: slot, address: address, value: value)
            guard generation == self.generation else { throw CancellationError() }
            try await captureState(coalescing: key)
        }
    }

    /// Begin before displaying a vendor editor. End only after captureAndPersist has succeeded.
    /// The poll captures opaque state even when the vendor emits no parameter notification.
    func beginEditorObservation(coalescing key: String) async throws {
        await suspendEditorObservation()
        try await operations.run { [self] in try await establishNativeStateBaseline() }
        editorObservationKey = key
        editorPolling = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await captureAndPersist(coalescing: key)
                    try await Task.sleep(for: .milliseconds(200))
                } catch is CancellationError { return }
                catch { fail(error); return }
            }
        }
    }

    func endEditorObservation() async throws {
        let key = editorObservationKey
        await suspendEditorObservation()
        try await captureAndPersist(coalescing: key)
        document?.store.endCoalescing()
        nativeStateBaseline = nil
    }

    func suspendEditorObservation() async {
        let polling = editorPolling
        editorPolling = nil
        editorObservationKey = nil
        polling?.cancel()
        await polling?.value
    }

    var hasObservedState: Bool { nativeStateBaseline != nil && processor != nil }

    func captureAndPersist(coalescing key: String?) async throws {
        try await operations.run { [self] in
            try Task.checkCancellation()
            try await captureState(coalescing: key)
        }
    }

    private func captureState(coalescing key: String?) async throws {
        try validateCurrent()
        guard let processor, let document else { throw MixerFailure.staleDependencies }
        try await establishNativeStateBaseline()
        let generation = generation
        let expectedAtCapture = expectedMix
        #if DEBUG
        await beforeStateCapture?()
        #endif
        let slots = try await processor.captureDocumentStates()
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        guard expectedMix == expectedAtCapture else { throw stale("another capture replaced the expected mix") }
        try validateCurrent()
        guard let episode = document.store.model.episode(episodeID) else { throw MixerFailure.staleDependencies }
        var mix = episode.mix ?? EpisodeMixState()
        let expectedIDs = Set((mix.speakers.flatMap(\.inserts) + mix.master.inserts).map(\.id))
        guard Set(slots.map(\.id)) == expectedIDs else { throw stale("captured slot IDs differ from the document") }
        let byID = Dictionary(uniqueKeysWithValues: try slots.filter {
            try !Self.sameNativeState(nativeStateBaseline?[$0.id]?.documentState, $0.documentState, slot: $0.id)
        }.map { ($0.id, $0) })
        for index in mix.speakers.indices {
            mix.speakers[index].inserts = mix.speakers[index].inserts.map { byID[$0.id] ?? $0 }
        }
        mix.master.inserts = mix.master.inserts.map { byID[$0.id] ?? $0 }
        let captured = mix
        guard document.store.applyMixerCapture(coalescing: key, { (model: ShowDocumentModel) throws(DomainError) in
            try model.settingMix(captured, in: episodeID)
        }) else { throw MixerFailure.invalidRecipe("the document refused the Audio Unit state transaction") }
        expectedMix = mix
        nativeStateBaseline = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        let statuses = await processor.unitStatuses()
        guard generation == self.generation else { throw CancellationError() }
        unitStatuses = statuses
    }

    static func sameNativeState(_ lhs: Data?, _ rhs: Data?, slot: AudioUnitSlotID) throws -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs else { return false }
        guard let a = try PropertyListSerialization.propertyList(from: lhs, options: [], format: nil) as? [String: Any],
              let b = try PropertyListSerialization.propertyList(from: rhs, options: [], format: nil) as? [String: Any] else {
            throw MixerFailure.state(slot, "captured state is not a property-list dictionary")
        }
        // Dictionary serialization order is not a knob edit. Preserve original bytes until state changes.
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    private func establishNativeStateBaseline() async throws {
        if nativeStateBaseline != nil { return }
        try validateCurrent()
        guard let processor else { throw MixerFailure.staleDependencies }
        let generation = generation
        let slots = try await processor.captureDocumentStates()
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
        if nativeStateBaseline == nil {
            nativeStateBaseline = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        }
    }

    /// Save/Undo/Redo/close must await capture, suspend polling, then restore/reload from the document.
    /// Never let a stale vendor editor overwrite Undo or a changed Primary/insert chain.
    func stop() {
        // Stopping the transport does not discard an editor's unsaved native state.
        if state == .loading { generation &+= 1 }
        state = processor == nil ? .idle : .ready
        meters = nil
    }

    /// Only after the awaited capture barrier; the next editor/play loads the resulting document.
    func invalidatePreparedInstance() {
        precondition(editorPolling == nil)
        generation &+= 1
        processor = nil
        snapshot = nil
        expectedMix = nil
        nativeStateBaseline = nil
        unitStatuses = []
        meters = nil
        state = .idle
        instanceRevision &+= 1
    }

    func fail(_ error: Error) {
        generation &+= 1
        editorPolling?.cancel()
        editorPolling = nil
        state = .failed(error.localizedDescription)
    }

    private func validateCurrent() throws {
        guard let document, !document.mixerTransactions.isClosed,
              let snapshot, let recipe = processor?.recipe, let expectedMix,
              let episode = document.store.model.episode(episodeID) else {
            throw stale("the originating document, episode, or prepared instance is unavailable")
        }
        guard EpisodeProcessingInputs(episode).media == recipe.dependencies.media,
              episode.activeManualCuts == recipe.dependencies.manualCuts else {
            throw stale("the source/timing/cut dependencies changed")
        }
        guard document.verifiedModel?.hasSameMediaInputs(as: snapshot, in: episodeID) == true else {
            throw stale("the verified media snapshot changed")
        }
        let mix = episode.mix ?? EpisodeMixState()
        guard mix.master.inserts == expectedMix.master.inserts,
              recipe.routes.allSatisfy({
                  mix.state(for: $0.speaker).inserts == expectedMix.state(for: $0.speaker).inserts
              }) else { throw stale("document insert state changed outside the prepared instance") }
        dependencyFailure = nil
    }

    private func stale(_ detail: String) -> MixerFailure {
        dependencyFailure = detail
        return .staleDependencies
    }
}
