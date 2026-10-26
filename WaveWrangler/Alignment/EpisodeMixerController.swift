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
    var mutedSpeakers: Set<SpeakerID> = []
    var soloedSpeakers: Set<SpeakerID> = []
    var masterMuted = false
    @ObservationIgnored private(set) var processor: MixerProcessor?
    @ObservationIgnored private var snapshot: ShowDocumentModel?
    @ObservationIgnored private var expectedMix: EpisodeMixState?
    @ObservationIgnored private var editorPolling: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    let episodeID: EpisodeID

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
    }

    func prepare(programFrames: Range<Int64>, policy: MixerRenderPolicy = .init()) async throws -> MixerRecipe {
        generation &+= 1
        let generation = generation
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

    func render(_ frames: Range<Int64>) async throws -> MixerPCMOutput {
        guard let processor, let snapshot else { throw MixerFailure.staleDependencies }
        let generation = generation
        try await synchronizeControls()
        let input = try await runtime.productionPCM(recipe: processor.recipe, model: snapshot, frames: frames)
        guard generation == self.generation else { throw CancellationError() }
        try validateCurrent()
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
        let output = try await processor.finishNext()
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
        try validateCurrent()
        guard let processor else { throw MixerFailure.staleDependencies }
        let generation = generation
        try await processor.setParameter(slot: slot, address: address, value: value)
        guard generation == self.generation else { throw CancellationError() }
        try await captureAndPersist(coalescing: key)
    }

    /// Begin before displaying a vendor editor. End only after captureAndPersist has succeeded.
    /// The poll captures opaque state even when the vendor emits no parameter notification.
    func beginEditorObservation(coalescing key: String) {
        editorPolling?.cancel()
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
        try await captureAndPersist(coalescing: nil)
        editorPolling?.cancel()
        editorPolling = nil
        document?.store.endCoalescing()
    }

    func captureAndPersist(coalescing key: String?) async throws {
        try validateCurrent()
        guard let processor, let document else { throw MixerFailure.staleDependencies }
        let generation = generation
        let expectedAtCapture = expectedMix
        let slots = try await processor.captureDocumentStates()
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        guard expectedMix == expectedAtCapture else { throw MixerFailure.staleDependencies }
        try validateCurrent()
        guard let episode = document.store.model.episode(episodeID) else { throw MixerFailure.staleDependencies }
        var mix = episode.mix ?? EpisodeMixState()
        let expectedIDs = Set((mix.speakers.flatMap(\.inserts) + mix.master.inserts).map(\.id))
        guard Set(slots.map(\.id)) == expectedIDs else { throw MixerFailure.staleDependencies }
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        for index in mix.speakers.indices {
            mix.speakers[index].inserts = mix.speakers[index].inserts.map { byID[$0.id] ?? $0 }
        }
        mix.master.inserts = mix.master.inserts.map { byID[$0.id] ?? $0 }
        let captured = mix
        guard document.store.apply("Edit Audio Unit", coalescing: key, { (model: ShowDocumentModel) throws(DomainError) in
            try model.settingMix(captured, in: episodeID)
        }) else { throw MixerFailure.invalidRecipe("the document refused the Audio Unit state transaction") }
        expectedMix = mix
        unitStatuses = await processor.unitStatuses()
    }

    /// Save/Undo/Redo/close must await capture, suspend polling, then restore/reload from the document.
    /// Never let a stale vendor editor overwrite Undo or a changed Primary/insert chain.
    func stop() {
        generation &+= 1
        editorPolling?.cancel()
        editorPolling = nil
        state = .idle
        meters = nil
    }

    func fail(_ error: Error) {
        generation &+= 1
        editorPolling?.cancel()
        editorPolling = nil
        state = .failed(error.localizedDescription)
    }

    private func validateCurrent() throws {
        guard let document, let snapshot, let recipe = processor?.recipe, let expectedMix,
              let episode = document.store.model.episode(episodeID),
              EpisodeProcessingInputs(episode).media == recipe.dependencies.media,
              episode.activeManualCuts == recipe.dependencies.manualCuts,
              document.verifiedModel?.hasSameMediaInputs(as: snapshot, in: episodeID) == true else {
            throw MixerFailure.staleDependencies
        }
        let mix = episode.mix ?? EpisodeMixState()
        guard mix.master.inserts == expectedMix.master.inserts,
              recipe.routes.allSatisfy({
                  mix.state(for: $0.speaker).inserts == expectedMix.state(for: $0.speaker).inserts
              }) else { throw MixerFailure.staleDependencies }
    }
}
