import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WWCommonEdit
import WWCore
import WWDerived
import WWEpisodeSetup

struct AudioImportReview: Identifiable {
    let id = UUID()
    let scan: ImportScan
    let tracks: [AudioTrack]
    var selected: Set<UUID>
    var track: AudioTrackID?
    var newTrackName: String
    var programSeconds: String
}

/// Shared Add Audio/Finder-drop staging. Selection is metadata-only; explicit Import authorizes
/// sequential qualification, followed by one complete canonical transaction and conditional adoption.
@MainActor @Observable
final class StagedAudioImportCoordinator {
    private let store: ShowDocumentStore
    let episodeID: EpisodeID
    private let runtime: AlignmentRuntime
    private weak var state: ShowWindowState?
    private weak var originWindow: NSWindow?
    private var expected: ShowDocumentModel?
    private var expectedGeneration: UInt64?
    private var engine: WWSourcesSetupEngine?
    private var scanToken: UUID?
    private var operation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    var review: AudioImportReview?
    private(set) var processing: TrackProcessingOperation?
    private(set) var error: String?
    private(set) var importedWaveforms: [SourceID: AudioAssetWaveform] = [:]
    private(set) var completedClips: [AudioClipID] = []
    private var publicationPending = false
    #if DEBUG
    @ObservationIgnored var sourceEngineForTesting: WWSourcesSetupEngine?
    @ObservationIgnored var beforeQualificationForTesting: (@MainActor @Sendable () async throws -> Void)?
    #endif

    init(store: ShowDocumentStore, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.store = store
        self.episodeID = episodeID
        self.runtime = runtime
    }

    func chooseAudio(in state: ShowWindowState, programSeconds: Double) {
        guard task == nil, review == nil, state.canEdit, let window = state.window else { return }
        let capturedPosition = programSeconds
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Choose"
        panel.message = "Choose audio to reference. Audio is not read or downloaded until you confirm Import."
        panel.beginSheetModal(for: window) { [weak self, weak state] result in
            guard result == .OK, let self, let state else { return }
            self.scan(panel.urls, in: state, programSeconds: capturedPosition)
        }
    }

    func scan(_ urls: [URL], in state: ShowWindowState, programSeconds: Double) {
        guard task == nil, review == nil, !urls.isEmpty, let window = state.window else { return }
        operation = UUID()
        let id = operation
        self.state = state
        originWindow = window
        error = nil
        completedClips = []
        processing = .init(kind: .audioImport, title: "Reviewing audio selection",
            detail: "Reading file metadata only. Originals are referenced, not copied or changed.",
            fraction: nil, canCancel: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let document = store.document, document.mixerTransactions.needsBarrier {
                    try await document.mixerTransactions.barrier(replacingInstances: true, episode: episodeID) {}
                }
                try validateOwner(id)
                expected = store.model
                expectedGeneration = store.modelGeneration
                SetupEngineProvider.watchClose(of: window)
                let shared = await acquireEngine(for: window)
                try validateDestination(id)
                guard let shared = shared as? WWSourcesSetupEngine else {
                    throw Refusal("Staged audio import is unavailable for this source engine.")
                }
                engine = shared
                shared.activeSourceIDs = { [weak store] in
                    store.map { Set($0.model.episodes.flatMap(\.sources).map(\.id)) }
                }
                let scan = try await shared.scanForImport(urls, episodeSourceIDs: store.model.episode(episodeID)?.sources.map(\.id) ?? [])
                do { try validateDestination(id) } catch {
                    await shared.discardScan(scan.token)
                    throw error
                }
                scanToken = scan.token
                let candidates = scan.candidates.filter { $0.isRecording && !$0.alreadyInEpisode }
                guard !candidates.isEmpty else {
                    throw Refusal("No new audio files can be imported. Already referenced media can be reused with Duplicate Clip; unsupported or unreadable selections were not opened.")
                }
                let tracks = store.model.episode(episodeID)?.audioArrangement?.tracks ?? []
                review = .init(scan: scan, tracks: tracks, selected: Set(candidates.map(\.id)),
                    track: tracks.first?.id, newTrackName: "Audio \(tracks.count + 1)",
                    programSeconds: String(format: "%.6f", programSeconds))
                processing = nil
                task = nil
            } catch {
                await fail(error, operation: id, published: false)
            }
        }
    }

    func commit(_ review: AudioImportReview) {
        guard task == nil, self.review?.id == review.id, let engine else { return }
        let id = operation
        self.review = nil
        processing = .init(kind: .audioImport, title: "Importing audio",
            detail: "Authorizing and qualifying the selected originals. Cancel leaves the show unchanged.",
            fraction: 0, canCancel: true)
        task = Task { [weak self, weak engine] in
            guard let self, let engine else { return }
            var tokens: [PendingSourceImport] = []
            var published = false
            do {
                try validateDestination(id)
                let position = try AudioClipEditorModel.programFrame(review.programSeconds)
                let chosen = review.scan.candidates.filter { review.selected.contains($0.id) }
                guard !chosen.isEmpty, chosen.allSatisfy({ $0.isRecording && !$0.alreadyInEpisode }) else {
                    throw Refusal("Choose at least one new audio file.")
                }
                guard let snapshot = expected, let episode = snapshot.episode(episodeID) else {
                    throw Refusal("The destination episode is no longer available.")
                }
                let timeline: ProgramTimeline
                if episode.alignment?.acceptedMap != nil {
                    timeline = try await runtime.programComposition(model: snapshot, episode: episodeID).timeline
                } else { timeline = try ProgramTimeline(episode: episode) }
                try validateDestination(id)
                let anchor = try timeline.unpinnedAnchor(atProgramFrame: position)
                var arrangement = episode.audioArrangement ?? AudioArrangement()
                let track: AudioTrack
                if let existing = review.track {
                    guard let destination = arrangement.tracks.first(where: { $0.id == existing }) else {
                        throw Refusal("The selected audio track is no longer available.")
                    }
                    track = destination
                } else {
                    let name = review.newTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { throw Refusal("Give the new audio track a name.") }
                    track = AudioTrack(name: name)
                    arrangement.tracks.append(track)
                }
                var sources = episode.sources
                var clips: [AudioClipID] = []
                var waveforms: [SourceID: AudioAssetWaveform] = [:]
                for (index, candidate) in chosen.enumerated() {
                    let token = try await engine.preparePendingImport(candidate: candidate.id, fromScan: review.scan.token)
                    tokens.append(token)
                    try validateDestination(id)
                    let read = try await engine.validatePendingImport(token)
                    try validateDestination(id)
                    let admission = SourceReadAdmission(source: token.source, location: read.location,
                        witness: read.witness, authorization: .explicitUserRequest(for: token.source), availability: .on) {
                        [weak self, weak engine] in
                        guard let self, let engine else { throw CancellationError() }
                        try await self.validatePending(token, engine: engine, operation: id)
                    }
                    #if DEBUG
                    try await beforeQualificationForTesting?()
                    try validateDestination(id)
                    #endif
                    let qualified = try await runtime.qualifyAudioImport(admission) { [weak self] fraction in
                        guard let self else { throw CancellationError() }
                        try await self.reportProgress(
                            (Double(index) + fraction) / Double(chosen.count), name: candidate.displayName, operation: id)
                    }
                    try validateDestination(id)
                    var source = read.source
                    source.purpose = .supplementalAudio
                    source.observations = qualified.observations
                    sources.append(source)
                    arrangement.assets.append(qualified.asset)
                    let clip = AudioClip(track: track.id, source: source.id,
                        trim: .init(startFrame: 0, endFrame: qualified.asset.frameCount), anchor: anchor)
                    arrangement.clips.append(clip)
                    clips.append(clip.id)
                    waveforms[source.id] = qualified.waveform
                }
                for token in tokens { try await validatePending(token, engine: engine, operation: id) }
                try validateDestination(id)
                let next = try snapshot.settingAudioState(arrangement, mix: episode.mix, sources: sources, in: episodeID)
                guard let nextEpisode = next.episode(episodeID) else { throw Refusal("The destination episode was removed.") }
                _ = try ProgramTimeline(episode: nextEpisode, dialogueFrames: timeline.dialogueFrames).composition()
                guard store.apply("Add Audio", { _ throws(DomainError) in next }) else {
                    throw Refusal(store.lastError.map(EpisodeSetupModel.describe) ?? "Audio could not be added.")
                }
                published = true
                publicationPending = true
                expected = store.model
                expectedGeneration = store.modelGeneration
                try await engine.adoptPendingImports(tokens) { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.validateDestination(id)
                    guard self.store.model.episode(self.episodeID)?.sources.suffix(chosen.count).map(\.id)
                            == tokens.map(\.source) else {
                        throw Refusal("The published audio references were replaced.")
                    }
                }
                try validateDestination(id)
                importedWaveforms.merge(waveforms) { _, new in new }
                completedClips = clips
                publicationPending = false
                error = nil
                processing = nil
                task = nil
                await engine.discardScan(review.scan.token)
                if scanToken == review.scan.token { scanToken = nil }
            } catch {
                for token in tokens { engine.discardPendingImport(token) }
                await fail(error, operation: id, published: published)
            }
        }
    }

    func cancel() {
        if publicationPending {
            error = "Audio references were added, but adoption was canceled. Access is blocked; relink the originals in Recordings & Speakers, or Undo Add Audio."
            publicationPending = false
        }

        operation = UUID()
        task?.cancel()
        task = nil
        review = nil
        processing = nil
        if let scanToken, let engine { Task { await engine.discardScan(scanToken) } }
        scanToken = nil
        expected = nil
        expectedGeneration = nil
    }

    func reviewDidDismiss() {
        if task == nil, review == nil { cancel() }
    }

    func takeImportedWaveforms() -> [SourceID: AudioAssetWaveform] {
        defer { importedWaveforms = [:] }
        return importedWaveforms
    }

    private func acquireEngine(for window: NSWindow) async -> any SourceSetupEngine {
        #if DEBUG
        if let sourceEngineForTesting { return sourceEngineForTesting }
        #endif
        return await SetupEngineProvider.engine(for: window, show: store.model.show.id)
    }

    private func validateOwner(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operation == id, let state, let originWindow,
              state.window === originWindow, state.destination == .alignment,
              state.selectedEpisodeID == episodeID, state.store === store,
              state.alignmentModel?.audioEditor.importer === self, state.canEdit,
              store.document?.mixerTransactions.isClosed != true else {
            throw Refusal("The audio destination was closed or replaced. No pending audio was published.")
        }
    }

    private func validateDestination(_ id: UUID) throws {
        try validateOwner(id)
        guard expectedGeneration == store.modelGeneration, expected == store.model,
              store.model.episode(episodeID) != nil else {
            throw Refusal("The show changed during audio import, including Undo, restore, or native effect capture. Choose the audio again.")
        }
    }

    private func validatePending(_ token: PendingSourceImport, engine: WWSourcesSetupEngine, operation id: UUID) async throws {
        try validateDestination(id)
        _ = try await engine.validatePendingImport(token)
        try validateDestination(id)
    }

    private func reportProgress(_ value: Double, name: String, operation id: UUID) throws {
        try validateDestination(id)
        processing = .init(kind: .audioImport, title: "Importing audio",
            detail: "Preparing \(name). Original files remain unchanged.", fraction: value, canCancel: true)
    }

    private func fail(_ failure: Error, operation id: UUID, published: Bool) async {
        guard operation == id else { return }
        if let scanToken, let engine { await engine.discardScan(scanToken) }
        guard operation == id else { return }
        scanToken = nil
        processing = nil
        publicationPending = false
        task = nil
        let reason = (failure as? SourceEngineError)?.reason
            ?? (failure as? LocalizedError)?.errorDescription ?? String(describing: failure)
        let detail = failure as? NativeSourcePreparationFailure == .unsupportedChannelLayout
            ? "Unsupported custom or ambiguous channel layout. Add Audio requires declared mono/left-right stereo or verified standard legacy PCM WAV order; no channels were guessed."
            : reason
        error = published
            ? "Audio references were added, but access is blocked: \(detail) Open Recordings & Speakers to relink the originals. Undo removes the entire Add Audio action."
            : failure is CancellationError ? "Audio import canceled. Nothing was added." : "Audio was not added: \(detail)"
    }

    struct Refusal: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
