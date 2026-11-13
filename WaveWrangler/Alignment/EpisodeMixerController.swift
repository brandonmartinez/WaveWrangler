import Foundation
import Observation
import Synchronization
import WWCommonEdit
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
    private(set) var consoleMeters = MixerConsoleSnapshot()
    private(set) var metersUpdatedAt = Date()
    private(set) var unitStatuses: [MixerUnitStatus] = []
    private(set) var instanceRevision: UInt64 = 0
    private(set) var dependencyFailure: String?
    var mutedSpeakers: Set<SpeakerID> = [] { didSet { refreshPlaybackControls() } }
    var soloedSpeakers: Set<SpeakerID> = [] { didSet { refreshPlaybackControls() } }
    var mutedAudioTracks: Set<AudioTrackID> = [] { didSet { refreshPlaybackControls() } }
    var soloedAudioTracks: Set<AudioTrackID> = [] { didSet { refreshPlaybackControls() } }
    var masterMuted = false { didSet { refreshPlaybackControls() } }
    @ObservationIgnored private var playback: ProductionMixPlayback?
    @ObservationIgnored private var rawPlaybackCache = ProductionPlaybackPCMCache()
    @ObservationIgnored private var canRestartProcessor = false
    @ObservationIgnored private(set) var processor: MixerProcessor?
    @ObservationIgnored private var snapshot: ShowDocumentModel?
    @ObservationIgnored private var expectedMix: EpisodeMixState?
    @ObservationIgnored private var nativeStateBaseline: [AudioUnitSlotID: AudioUnitSlot]?
    @ObservationIgnored private var capturedParameterRevisions: [AudioUnitSlotID: UInt64] = [:]
    @ObservationIgnored private var editorPolling: Task<Void, Never>?
    @ObservationIgnored private var editorObservationGeneration: UInt64 = 0
    @ObservationIgnored private var editorObservationCancellation: MixerStateCaptureCancellation?
    @ObservationIgnored private let operations = MixerOperationQueue()
    private(set) var editorObservationKey: String?
    @ObservationIgnored private var generation: UInt64 = 0
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    let episodeID: EpisodeID
    #if DEBUG
    @ObservationIgnored var beforeStateCapture: (@MainActor () async throws -> Void)?
    @ObservationIgnored var afterObservationSlotCapture: (@MainActor (AudioUnitSlotID) async throws -> Void)?
    @ObservationIgnored var didCaptureNativeStates: (@MainActor ([AudioUnitSlotID]) -> Void)?
    @ObservationIgnored var waitForEditorObservationTick: (@MainActor () async throws -> Duration)?
    @ObservationIgnored var observationParameterRevisions: [AudioUnitSlotID: UInt64]?
    var pendingStateOperations: Int { operations.pending }
    var playbackDiagnosticsForTesting: ProductionPlaybackDiagnostics? { playback?.diagnosticsForTesting }
    #endif

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
        document.mixerTransactions.register(self)
    }

    func prepareForEditing() async throws {
        guard let model = document?.store.residentModel, let episode = model.episode(episodeID) else {
            throw MixerFailure.staleDependencies
        }
        let composition = try await runtime.programComposition(model: model, episode: episodeID)
        let production = try EpisodeProductionProjection(episode: episode, composition: composition)
        guard let frames = production.episodeFrames, !frames.isEmpty else {
            throw MixerFailure.invalidRecipe("the episode is empty")
        }
        _ = try await prepare(programFrames: frames.lowerBound..<(frames.lowerBound + 1))
    }

    func prepare(programFrames: Range<Int64>, policy: MixerRenderPolicy = .init(),
                 startup: ProductionPlaybackStartup? = nil) async throws -> MixerRecipe {
        let presentations = document.map {
            ShowWindowRegistry.states(for: $0.store).filter { $0.alignmentModel?.mixer === self }.map(\.mixerPresentation)
        } ?? []
        presentations.forEach { $0.hideEditorsForBarrier() }
        let key = editorObservationKey
        let retirementStarted = ContinuousClock.now
        try await runtime.productionRetirements.wait()
        try Task.checkCancellation()
        startup?.record(.retirement, since: retirementStarted)
        await suspendEditorObservation()
        do {
            let canceled = Mutex(false)
            return try await withTaskCancellationHandler {
                try await operations.run { [self] in
                    if canceled.withLock({ $0 }) { throw CancellationError() }
                    let captureStarted = ContinuousClock.now
                    if nativeStateBaseline != nil { try await captureState(coalescing: key) }
                    if canceled.withLock({ $0 }) { throw CancellationError() }
                    startup?.record(.stateCapture, since: captureStarted)
                    document?.store.endCoalescing()
                    presentations.forEach { $0.dismissEditorsAfterCapture() }
                    let recipe = try await load(programFrames: programFrames, policy: policy, startup: startup)
                    if canceled.withLock({ $0 }) { throw CancellationError() }
                    return recipe
                }
            } onCancel: {
                canceled.withLock { $0 = true }
            }
        } catch {
            presentations.forEach { $0.restoreEditorsAfterBarrier() }
            throw error
        }
    }

    private func load(programFrames: Range<Int64>, policy: MixerRenderPolicy,
                      startup: ProductionPlaybackStartup?) async throws -> MixerRecipe {
        playback?.cancel()
        playback = nil
        if canRestartProcessor, let processor, processor.recipe.programFrames == programFrames,
           processor.recipe.policy == policy, case .ready = state, currentDependencyFailure() == nil {
            let revision = generation
            let processorStarted = ContinuousClock.now
            state = .loading
            do {
                try await processor.restartPlayback(controls: liveControls())
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                try validateCurrent()
                startup?.record(.processor, since: processorStarted)
                startup?.reusedProcessor()
                state = .ready
                return processor.recipe
            } catch {
                if generation == revision { fail(error) }
                throw error
            }
        }
        canRestartProcessor = false
        rawPlaybackCache = ProductionPlaybackPCMCache()
        generation &+= 1
        let generation = generation
        editorObservationGeneration &+= 1
        editorObservationCancellation?.cancel()
        editorObservationCancellation = nil
        editorPolling?.cancel()
        editorPolling = nil
        state = .loading
        guard let document else { throw MixerFailure.staleDependencies }
        let model = document.store.residentModel
        do {
            guard document.verifiedModel?.hasSameMediaInputs(as: model, in: episodeID) == true else {
                throw MixerFailure.staleDependencies
            }
            let recipeStarted = ContinuousClock.now
            let recipe = try await runtime.mixerRecipe(model: model, episode: episodeID,
                programFrames: programFrames, policy: policy)
            startup?.record(.recipe, since: recipeStarted)
            let processorStarted = ContinuousClock.now
            let loaded = try await MixerProcessor.load(recipe: recipe, livePlayback: true)
            let statuses = await loaded.unitStatuses()
            startup?.record(.processor, since: processorStarted)
            try Task.checkCancellation()
            guard self.generation == generation,
                  document.store.residentModel.hasSameProcessingInputs(as: model, in: episodeID) else {
                throw MixerFailure.staleDependencies
            }
            processor = loaded
            instanceRevision &+= 1
            snapshot = model
            expectedMix = model.episode(episodeID)?.mix ?? EpisodeMixState()
            nativeStateBaseline = nil
            capturedParameterRevisions = [:]
            let speakers = Set(recipe.routes.map(\.speaker))
            mutedSpeakers.formIntersection(speakers)
            soloedSpeakers.formIntersection(speakers)
            let tracks = Set(recipe.audioTracks.map(\.track))
            mutedAudioTracks.formIntersection(tracks)
            soloedAudioTracks.formIntersection(tracks)
            unitStatuses = statuses
            canRestartProcessor = true
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
        guard let processor else { throw MixerFailure.staleDependencies }
        let controls = try liveControls()
        playback?.setControls(controls)
        try await processor.setLiveControls(controls)
    }

    private func liveControls() throws -> MixerLiveControls {
        guard let processor, let episode = document?.store.residentModel.episode(episodeID) else {
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
        for route in processor.recipe.audioTracks {
            let strip = mix.state(for: route.track)
            var live = route.strip
            live.gainDB = strip.gainDB
            live.balance = strip.balance
            controls.audioTracks[route.track] = live
        }
        controls.masterGainDB = mix.master.gainDB
        controls.bypassedSlots = Set((mix.speakers.flatMap(\.inserts)
            + (mix.audioTracks ?? []).flatMap(\.inserts) + mix.master.inserts).filter(\.bypassed).map(\.id))
        controls.mutedSpeakers = mutedSpeakers
        controls.soloedSpeakers = soloedSpeakers
        controls.mutedAudioTracks = mutedAudioTracks
        controls.soloedAudioTracks = soloedAudioTracks
        controls.masterMuted = masterMuted
        return controls
    }

    func makePlayback(output: AlignmentAudioPlayback,
                      startup: ProductionPlaybackStartup? = nil) throws -> ProductionMixPlayback {
        try validateCurrent()
        guard let processor, let snapshot else { throw MixerFailure.staleDependencies }
        let prepared = ProductionMixPlayback(processor: processor, runtime: runtime,
            model: snapshot, controls: try liveControls(), outputGeneration: output.generation, startup: startup,
            rawCache: rawPlaybackCache)
        playback?.cancel()
        playback = prepared
        consoleMeters = MixerConsoleSnapshot()
        metersUpdatedAt = Date()
        return prepared
    }

    func refreshPlaybackControls() {
        guard let playback else { return }
        do {
            try validateCurrent()
            playback.setControls(try liveControls())
        } catch { playback.invalidate(error) }
    }

    func publishPlaybackMeters(at programSeconds: Double) {
        guard let playback else { return }
        consoleMeters = playback.meterSnapshot(through: Int64(programSeconds * Double(MixerRecipe.sampleRate)))
        metersUpdatedAt = Date()
        if !consoleMeters.levels.isEmpty { state = .playing }
    }

    func resetMeterPeaks(for bus: MixerBusAddress) {
        playback?.resetMeterPeaks(for: bus)
        guard var levels = consoleMeters.levels[bus] else { return }
        for index in levels.indices {
            levels[index].heldPeakDB = -.infinity
            levels[index].clipped = false
        }
        consoleMeters.levels[bus] = levels
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
            try await captureState(coalescing: key, slot: slot)
        }
    }

    /// Begin before displaying a vendor editor. End only after captureAndPersist has succeeded.
    /// The poll captures opaque state even when the vendor emits no parameter notification.
    func beginEditorObservation(coalescing key: String) async throws {
        await suspendEditorObservation()
        try await operations.run { [self] in try await establishNativeStateBaseline() }
        editorObservationKey = key
        let token = editorObservationGeneration
        let generation = generation
        let cancellation = MixerStateCaptureCancellation()
        editorObservationCancellation = cancellation
        editorPolling = Task { [weak self] in
            let clock = ContinuousClock()
            var lastTick = clock.now
            var sinceFallback: Duration = .seconds(1)
            while let self, !Task.isCancelled {
                do {
                    let fallback = sinceFallback >= .seconds(1)
                    let completedFallback = try await operations.run { [self] in
                        try await observeEditorState(coalescing: key, token: token,
                            generation: generation, cancellation: cancellation, fallback: fallback)
                    }
                    if completedFallback { sinceFallback = .zero }
                    let elapsed: Duration
                    #if DEBUG
                    if let waitForEditorObservationTick {
                        elapsed = try await waitForEditorObservationTick()
                    } else {
                        try await Task.sleep(for: .milliseconds(200))
                        elapsed = lastTick.duration(to: clock.now)
                    }
                    #else
                    try await Task.sleep(for: .milliseconds(200))
                    elapsed = lastTick.duration(to: clock.now)
                    #endif
                    lastTick = clock.now
                    sinceFallback += elapsed
                } catch is CancellationError { return }
                catch {
                    guard editorObservationGeneration == token, self.generation == generation else { return }
                    fail(error)
                    return
                }
            }
        }
    }

    func endEditorObservation() async throws {
        let key = editorObservationKey
        await suspendEditorObservation()
        try await captureAndPersist(coalescing: key)
        document?.store.endCoalescing()
        nativeStateBaseline = nil
        capturedParameterRevisions = [:]
    }

    func suspendEditorObservation() async {
        // MixerOperationQueue uses unstructured tasks: cancellation of the waiting caller alone
        // cannot invalidate an observation that is queued or suspended between vendor getters.
        editorObservationGeneration &+= 1
        editorObservationCancellation?.cancel()
        editorObservationCancellation = nil
        let polling = editorPolling
        editorPolling = nil
        editorObservationKey = nil
        polling?.cancel()
        await polling?.value
    }

    var hasObservedState: Bool { nativeStateBaseline != nil && processor != nil }

    func captureAndPersist(coalescing key: String?, authoritative: Bool = false) async throws {
        try await operations.run { [self] in
            try Task.checkCancellation()
            try await captureState(coalescing: key, authoritative: authoritative)
        }
    }

    private func captureState(coalescing key: String?, slot: AudioUnitSlotID? = nil,
                              authoritative: Bool = false) async throws {
        try validateCurrent()
        guard let processor else { throw MixerFailure.staleDependencies }
        try await establishNativeStateBaseline()
        let generation = generation
        let expectedAtCapture = expectedMix
        let revisions = parameterRevisions(await processor.unitStatuses())
        #if DEBUG
        try await beforeStateCapture?()
        #endif
        let slots: [AudioUnitSlot]
        if let slot { slots = [try await processor.captureDocumentState(slot: slot)] }
        else { slots = try await processor.captureDocumentStates() }
        #if DEBUG
        didCaptureNativeStates?(slots.map(\.id))
        #endif
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        guard expectedMix == expectedAtCapture else { throw stale("another capture replaced the expected mix") }
        try publishCapturedStates(slots, complete: slot == nil, coalescing: key, authoritative: authoritative)
        for slot in slots { capturedParameterRevisions[slot.id] = revisions[slot.id] }
        let statuses = await processor.unitStatuses()
        guard generation == self.generation else { throw CancellationError() }
        unitStatuses = statuses
    }

    private func parameterRevisions(_ statuses: [MixerUnitStatus]) -> [AudioUnitSlotID: UInt64] {
        #if DEBUG
        if let observationParameterRevisions { return observationParameterRevisions }
        #endif
        return Dictionary(uniqueKeysWithValues: statuses.map { ($0.slot, $0.parameterRevision) })
    }

    private func validateObservation(token: UInt64, generation: UInt64) throws {
        guard token == editorObservationGeneration, generation == self.generation else { throw CancellationError() }
        try validateCurrent()
    }

    /// The controller queue spans the sweep, but each vendor getter owns only one processor turn.
    private func observeEditorState(coalescing key: String, token: UInt64,
                                    generation: UInt64, cancellation: MixerStateCaptureCancellation,
                                    fallback: Bool) async throws -> Bool {
        try validateObservation(token: token, generation: generation)
        guard let processor else { throw MixerFailure.staleDependencies }
        let expectedAtCapture = expectedMix
        let statuses = await processor.unitStatuses()
        try validateObservation(token: token, generation: generation)
        let revisions = parameterRevisions(statuses)
        let ids = statuses.filter { fallback || capturedParameterRevisions[$0.slot] != revisions[$0.slot] }.map(\.slot)
        guard !ids.isEmpty else { return fallback }
        #if DEBUG
        try await beforeStateCapture?()
        #endif
        var slots: [AudioUnitSlot] = []
        for id in ids {
            try validateObservation(token: token, generation: generation)
            slots.append(try await processor.captureDocumentState(slot: id, cancellation: cancellation))
            #if DEBUG
            didCaptureNativeStates?([id])
            try await afterObservationSlotCapture?(id)
            #endif
            try validateObservation(token: token, generation: generation)
        }
        let after = await processor.unitStatuses()
        try validateObservation(token: token, generation: generation)
        guard expectedMix == expectedAtCapture else { throw stale("another capture replaced the expected mix") }
        // Native editors do not take our operation queue. A notified edit during the sweep makes
        // this candidate obsolete; retry on a later tick, rather than publish a mixed revision.
        guard parameterRevisions(after) == revisions else { return false }
        try publishCapturedStates(slots, complete: fallback, coalescing: key)
        for id in ids { capturedParameterRevisions[id] = revisions[id] }
        unitStatuses = after
        return fallback
    }

    private func publishCapturedStates(_ slots: [AudioUnitSlot], complete: Bool,
                                       coalescing key: String?, authoritative: Bool = false) throws {
        try validateCurrent()
        guard let document else { throw MixerFailure.staleDependencies }
        guard let episode = document.store.residentModel.episode(episodeID) else { throw MixerFailure.staleDependencies }
        var mix = episode.mix ?? EpisodeMixState()
        let originalMix = mix
        let expectedIDs = Set((mix.speakers.flatMap(\.inserts)
            + (mix.audioTracks ?? []).flatMap(\.inserts) + mix.master.inserts).map(\.id))
        let ids = Set(slots.map(\.id))
        guard ids.count == slots.count, (complete ? ids == expectedIDs : ids.isSubset(of: expectedIDs)) else {
            throw stale("captured slot IDs differ from the document")
        }
        var baseline = nativeStateBaseline ?? [:]
        for slot in slots { baseline[slot.id] = slot }
        guard Set(baseline.keys) == expectedIDs else { throw stale("native state baseline is incomplete") }
        guard baseline.values.reduce(0, { $0 + ($1.documentState?.count ?? 0) })
                <= EpisodeMixState.maximumDocumentStateBytes else {
            throw MixerFailure.invalidRecipe("combined captured document state exceeds the episode budget")
        }
        let byID = Dictionary(uniqueKeysWithValues: try slots.filter {
            try authoritative || !Self.sameNativeState(nativeStateBaseline?[$0.id]?.documentState, $0.documentState, slot: $0.id)
        }.map { ($0.id, $0) })
        func mergingState(_ slot: AudioUnitSlot) -> AudioUnitSlot {
            var result = slot
            if let captured = byID[slot.id] { result.documentState = captured.documentState }
            return result
        }
        for index in mix.speakers.indices {
            mix.speakers[index].inserts = mix.speakers[index].inserts.map(mergingState)
        }
        if var tracks = mix.audioTracks {
            for index in tracks.indices {
                tracks[index].inserts = tracks[index].inserts.map(mergingState)
            }
            mix.audioTracks = tracks
        }
        mix.master.inserts = mix.master.inserts.map(mergingState)
        let captured = mix
        if captured != originalMix {
            guard document.store.applyMixerCapture(coalescing: key, { (model: ShowDocumentModel) throws(DomainError) in
                try model.settingMix(captured, in: episodeID)
            }) else { throw MixerFailure.invalidRecipe("the document refused the Audio Unit state transaction") }
        }
        expectedMix = mix
        refreshPlaybackControls()
        nativeStateBaseline = baseline
        if mix != originalMix { document.mixerTransactions.didCapture(from: self) }
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
        let revisions = parameterRevisions(await processor.unitStatuses())
        let slots = try await processor.captureDocumentStates()
        #if DEBUG
        didCaptureNativeStates?(slots.map(\.id))
        #endif
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
        if nativeStateBaseline == nil {
            nativeStateBaseline = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
            capturedParameterRevisions = revisions
        }
    }

    /// Undo/Redo/close suspend polling before capture; saves capture without replacing the live instance.
    /// Never let a stale vendor editor overwrite Undo or a changed Primary/insert chain.
    func stop() {
        playback?.cancel()
        playback = nil
        // Stopping the transport does not discard an editor's unsaved native state.
        if state == .loading { generation &+= 1 }
        state = processor == nil ? .idle : .ready
        meters = nil
    }

    /// Only after the awaited capture barrier; the next editor/play loads the resulting document.
    func invalidatePreparedInstance() {
        precondition(editorPolling == nil)
        generation &+= 1
        editorObservationGeneration &+= 1
        editorObservationCancellation?.cancel()
        editorObservationCancellation = nil
        playback?.invalidate(MixerFailure.staleDependencies)
        playback = nil
        processor = nil
        canRestartProcessor = false
        rawPlaybackCache = ProductionPlaybackPCMCache()
        snapshot = nil
        expectedMix = nil
        nativeStateBaseline = nil
        capturedParameterRevisions = [:]
        unitStatuses = []
        meters = nil
        consoleMeters = MixerConsoleSnapshot()
        state = .idle
        instanceRevision &+= 1
    }

    func discardUncapturedEditorState() async throws {
        await suspendEditorObservation()
        try await operations.run { [self] in invalidatePreparedInstance() }
    }

    func fail(_ error: Error) {
        canRestartProcessor = false
        playback?.invalidate(error)
        rawPlaybackCache = ProductionPlaybackPCMCache()
        generation &+= 1
        editorObservationGeneration &+= 1
        editorObservationCancellation?.cancel()
        editorObservationCancellation = nil
        editorPolling?.cancel()
        editorPolling = nil
        state = .failed(error.localizedDescription)
    }

    var preparedInstanceIsCurrent: Bool { currentDependencyFailure() == nil }

    private func validateCurrent() throws {
        if let detail = currentDependencyFailure() { throw stale(detail) }
        dependencyFailure = nil
    }

    private func currentDependencyFailure() -> String? {
        guard let document, !document.mixerTransactions.isClosed,
              let snapshot, let recipe = processor?.recipe, let expectedMix,
              let episode = document.store.residentModel.episode(episodeID) else {
            return "the originating document, episode, or prepared instance is unavailable"
        }
        guard EpisodeProcessingInputs(episode).hasSameProgramInputs(as: recipe.dependencies) else {
            return "the source/timing/cut dependencies changed"
        }
        guard document.verifiedModel?.hasSameMediaInputs(as: snapshot, in: episodeID) == true else {
            return "the verified media snapshot changed"
        }
        let mix = episode.mix ?? EpisodeMixState()
        guard MixerInsertRack.hasSameProcessingState(mix.master.inserts, expectedMix.master.inserts),
              recipe.routes.allSatisfy({
                  MixerInsertRack.hasSameProcessingState(mix.state(for: $0.speaker).inserts,
                                                        expectedMix.state(for: $0.speaker).inserts)
              }), recipe.audioTracks.allSatisfy({
                  MixerInsertRack.hasSameProcessingState(mix.state(for: $0.track).inserts,
                                                        expectedMix.state(for: $0.track).inserts)
              }) else { return "document insert state changed outside the prepared instance" }
        return nil
    }

    private func stale(_ detail: String) -> MixerFailure {
        dependencyFailure = detail
        return .staleDependencies
    }
}
