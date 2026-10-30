import AppKit
import Foundation
import Observation
import WWCommonEdit
import WWCore

@MainActor @Observable
final class AudioClipEditorModel {
    let importer: StagedAudioImportCoordinator
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    private let runtime: AlignmentRuntime
    private(set) var composition: ProgramComposition? {
        didSet {
            let prior = oldValue.map { AudioTimelineProjection(cuts: $0.timeline.cuts, program: $0.timeline) }
            let next = composition.map { AudioTimelineProjection(cuts: $0.timeline.cuts, program: $0.timeline) }
            if prior != next { geometryVersion = UUID() }
        }
    }
    private(set) var geometryVersion = UUID()
    private var compositionEpisode: Episode?
    private var compositionGeneration: UInt64?
    var selectedClip: AudioClipID?
    var selectedTrack: AudioTrackID?
    private(set) var insertionSession: AudioInsertionSession?
    private(set) var error: String?
    private(set) var waveforms: [SourceID: AudioAssetWaveform] = [:]
    private(set) var isPreparingWaveforms = false
    private(set) var preparationFraction = 0.0
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var projectionGeneration = UUID()
    @ObservationIgnored private var waveformGeneration = UUID()
    #if DEBUG
    @ObservationIgnored var beforeWaveformPreparationForTesting: (@MainActor @Sendable () async throws -> Void)?
    #endif
    private var waveformSources: [SourceRecord] = []
    private var waveformAssets: [AudioAsset] = []

    struct Gesture {
        let clip: ProgramAudioClip
        let generation: UInt64
        var startFrame: Int64
        var track: AudioTrackID
        var localFrames: Range<Int64>?
        var previewClip: AudioClip?
        var previewError: String?
    }
    private(set) var gesture: Gesture?
    var trackFrames: [AudioTrackID: CGRect] = [:]

    init(store: ShowDocumentStore, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.store = store
        self.episodeID = episodeID
        self.runtime = runtime
        importer = StagedAudioImportCoordinator(store: store, episodeID: episodeID, runtime: runtime)
    }

    var episode: Episode? { store.model.episode(episodeID) }
    var tracks: [AudioTrack] { episode?.audioArrangement?.tracks ?? [] }
    var selected: ProgramAudioClip? { composition?.clips.first { $0.clip.id == selectedClip } }
    var hasArrangement: Bool { episode?.audioArrangement != nil }
    var processing: TrackProcessingOperation? {
        if let importing = importer.processing { return importing }
        if isPreparingWaveforms, waveforms.isEmpty, !waveformAssets.isEmpty {
            return .init(kind: .waveforms, title: "Preparing audio clips",
                detail: "Preparing bounded, verified source waveforms. Original audio is unchanged.",
                fraction: preparationFraction, canCancel: true)
        }
        return nil
    }

    func refresh() {
        guard let episode else { suspend(); return }
        if let selectedClip, episode.audioArrangement?.clips.contains(where: { $0.id == selectedClip }) != true {
            self.selectedClip = nil
        }
        if let selectedTrack, !tracks.contains(where: { $0.id == selectedTrack }) { self.selectedTrack = nil }
        if gesture?.generation != store.modelGeneration { gesture = nil }
        if compositionEpisode != episode || compositionGeneration != store.modelGeneration {
            projectionTask?.cancel()
            projectionGeneration = UUID()
            let projectionID = projectionGeneration
            let snapshot = store.model, generation = store.modelGeneration
            do {
                if episode.alignment?.acceptedMap == nil
                    || compositionEpisode?.alignment?.acceptedMap == episode.alignment?.acceptedMap,
                   episode.alignment?.acceptedMap == nil || composition != nil {
                    let coverage = episode.alignment?.acceptedMap == nil ? nil : composition?.timeline.dialogueFrames
                    composition = try ProgramTimeline(episode: episode, dialogueFrames: coverage).composition()
                    compositionEpisode = episode
                    compositionGeneration = generation
                    if let selected { selectedTrack = selected.clip.track }
                    error = nil
                } else {
                    projectionTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            let next = try await runtime.programComposition(model: snapshot, episode: episodeID)
                            try Task.checkCancellation()
                            guard projectionGeneration == projectionID,
                                  store.modelGeneration == generation, store.model == snapshot else { return }
                            composition = next
                            compositionEpisode = episode
                            compositionGeneration = generation
                            error = nil
                        } catch is CancellationError {} catch {
                            guard projectionGeneration == projectionID, store.modelGeneration == generation else { return }
                            composition = nil
                            self.error = "Audio placement needs review: \(error)"
                        }
                    }
                }
            } catch {
                composition = nil
                self.error = "Audio placement needs review: \(error)"
            }
        }
        if let selected { selectedTrack = selected.clip.track }
        prepareWaveformsIfNeeded(episode)
    }

    private func prepareWaveformsIfNeeded(_ episode: Episode) {
        guard importer.processing == nil else { return }
        let assets = episode.audioArrangement?.assets ?? []
        let ids = Set(assets.map(\.source))
        let sources = episode.sources.filter { ids.contains($0.id) }
        let imported = importer.takeImportedWaveforms().filter { ids.contains($0.key) }
        guard assets != waveformAssets || sources != waveformSources else { return }
        waveformTask?.cancel()
        waveformGeneration = UUID()
        let generation = waveformGeneration
        waveforms = waveforms.filter { key, _ in
            assets.first { $0.source == key } == waveformAssets.first { $0.source == key }
                && sources.first { $0.id == key } == waveformSources.first { $0.id == key }
        }
        waveformAssets = assets
        waveformSources = sources
        waveforms.merge(imported) { _, new in new }
        let missing = assets.filter { waveforms[$0.source] == nil }
        guard !missing.isEmpty else { isPreparingWaveforms = false; return }
        let snapshot = store.model
        isPreparingWaveforms = true
        preparationFraction = 0
        waveformTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if waveformGeneration == generation { isPreparingWaveforms = false }
            }
            for (index, asset) in missing.enumerated() {
                do {
                    #if DEBUG
                    try await beforeWaveformPreparationForTesting?()
                    try Task.checkCancellation()
                    #endif
                    let waveform = try await runtime.audioAssetWaveform(asset, model: snapshot, episode: episodeID) {
                        [weak self] fraction in
                        try Task.checkCancellation()
                        await self?.updatePreparation(
                            (Double(index) + fraction) / Double(missing.count), generation: generation)
                    }
                    try Task.checkCancellation()
                    guard waveformGeneration == generation else { return }
                    waveforms[asset.source] = waveform
                } catch is CancellationError { return } catch {
                    guard waveformGeneration == generation else { return }
                    self.error = "Audio clip is blocked: \(error). Open Recordings & Speakers to review access or relink the original."
                }
            }
        }
    }

    private func updatePreparation(_ value: Double, generation: UUID) {
        guard waveformGeneration == generation else { return }
        preparationFraction = value
    }

    func select(_ clip: AudioClipID) {
        selectedClip = clip
        selectedTrack = composition?.clips.first { $0.clip.id == clip }?.clip.track
    }

    func addTrack() {
        apply("Add Audio Track") { model throws(DomainError) in
            try model.addingAudioTrack(AudioTrack(name: "Audio \(self.tracks.count + 1)"), in: self.episodeID)
        }
    }

    func renameTrack(_ id: AudioTrackID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Audio track names cannot be empty."; return }
        apply("Rename Audio Track") { model throws(DomainError) in
            try model.replacingAudioTrack(AudioTrack(id: id, name: name), in: self.episodeID)
        }
    }

    func reorderTrack(_ id: AudioTrackID, by step: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }), tracks.indices.contains(index + step) else { return }
        apply("Reorder Audio Tracks") { model throws(DomainError) in
            guard var arrangement = model.episode(self.episodeID)?.audioArrangement else {
                throw .invalidAudio("The audio arrangement was removed.")
            }
            arrangement.tracks.swapAt(index, index + step)
            return try model.settingAudioArrangement(arrangement, in: self.episodeID)
        }
    }

    func moveSelected(start text: String, track: AudioTrackID) {
        performSelected("Move Audio Clip") { projected, timeline in
            try AudioClipEditing.moving(projected, to: Self.programFrame(text), track: track, timeline: timeline)
        }
    }

    func pinSelected(_ pinned: Bool) {
        performSelected(pinned ? "Pin Audio Clip" : "Unpin Audio Clip") {
            try AudioClipEditing.pinning($0, pinned: pinned, timeline: $1)
        }
    }

    func resizeSelected(start: String, end: String) {
        performSelected("Trim Audio Clip") { projected, timeline in
            guard let lo = Int64(start), let hi = Int64(end), lo < hi,
                  let owned = projected.clip.ownedOutputFrames(asset: projected.asset),
                  let nominal = projected.clip.nominalDurationFrames(asset: projected.asset),
                  lo >= 0, hi <= nominal else {
                throw StagedAudioImportCoordinator.Refusal("Enter an increasing pair of whole output-frame bounds.")
            }
            return try AudioClipEditing.resizing(projected,
                localFrames: (lo - owned.lowerBound)..<(hi - owned.lowerBound), timeline: timeline)
        }
    }

    func duplicateSelected() {
        guard let projected = selected, let composition else { return }
        do {
            let duplicate = try AudioClipEditing.duplicating(projected, timeline: composition.timeline)
            apply("Duplicate Audio Clip") { model throws(DomainError) in
                try model.addingAudioClip(duplicate, in: self.episodeID)
            }
            if store.lastError == nil { selectedClip = duplicate.id }
        } catch { report(error) }
    }

    func deleteSelected() {
        guard let selectedClip else { return }
        apply("Delete Audio Clip") { model throws(DomainError) in
            try model.removingAudioClip(selectedClip, in: self.episodeID)
        }
    }

    func splitSelected(atProgramSeconds seconds: Double) {
        guard let projected = selected, let composition else { return }
        do {
            let split = try projected.split(atProgramFrame: Self.programFrame(seconds), timeline: composition.timeline)
            apply("Split Audio Clip") { model throws(DomainError) in
                guard var arrangement = model.episode(self.episodeID)?.audioArrangement,
                      let index = arrangement.clips.firstIndex(where: { $0.id == projected.clip.id }) else {
                    throw .invalidAudio("The selected audio clip is no longer available.")
                }
                arrangement.clips.replaceSubrange(index...index, with: [split.leading, split.trailing])
                return try model.settingAudioArrangement(arrangement, in: self.episodeID)
            }
        } catch { report(error) }
    }

    func beginGesture(_ clip: ProgramAudioClip) {
        guard store.canEdit, processing == nil, compositionGeneration == store.modelGeneration else { return }
        select(clip.clip.id)
        gesture = .init(clip: clip, generation: store.modelGeneration,
                        startFrame: clip.programFrames.lowerBound, track: clip.clip.track, previewClip: clip.clip)
    }

    func previewGesture(start: Int64, track: AudioTrackID, localFrames: Range<Int64>? = nil) {
        guard var gesture, gesture.generation == store.modelGeneration else { cancelGesture(); return }
        gesture.startFrame = start
        gesture.track = track
        gesture.localFrames = localFrames
        if let composition {
            do {
                if let localFrames {
                    gesture.previewClip = try AudioClipEditing.resizing(gesture.clip, localFrames: localFrames,
                                                                        timeline: composition.timeline)
                } else {
                    gesture.previewClip = try AudioClipEditing.moving(gesture.clip, to: start, track: track,
                                                                      timeline: composition.timeline)
                }
                gesture.previewError = nil
            } catch {
                gesture.previewClip = nil
                gesture.previewError = String(describing: error)
            }
        }
        self.gesture = gesture
    }

    func completeGesture() {
        guard let gesture, gesture.generation == store.modelGeneration, let composition else {
            cancelGesture(); return
        }
        self.gesture = nil
        if let reason = gesture.previewError {
            error = "Audio edit refused: \(reason). The saved clip is unchanged."
            return
        }
        do {
            let replacement: AudioClip
            if let local = gesture.localFrames {
                replacement = try AudioClipEditing.resizing(gesture.clip, localFrames: local, timeline: composition.timeline)
            } else {
                replacement = try AudioClipEditing.moving(gesture.clip, to: gesture.startFrame,
                    track: gesture.track, timeline: composition.timeline)
            }
            replace(replacement, action: gesture.localFrames == nil ? "Move Audio Clip" : "Trim Audio Clip")
        } catch { report(error) }
    }

    func cancelGesture() { gesture = nil }
    func refuseGesture(_ reason: String) { gesture = nil; error = reason }
    func refuse(_ reason: String) { error = reason }

    func cancelPreparation() {
        if importer.processing != nil { importer.cancel() }
        else { waveformGeneration = UUID(); waveformTask?.cancel(); isPreparingWaveforms = false }
    }

    func reloadWaveforms() {
        waveformGeneration = UUID()
        waveformTask?.cancel()
        isPreparingWaveforms = false
        _ = importer.takeImportedWaveforms()
        waveformSources = []
        waveformAssets = []
        waveforms = [:]
        if let episode { prepareWaveformsIfNeeded(episode) }
    }

    func suspend() {
        importer.cancel()
        projectionGeneration = UUID()
        waveformGeneration = UUID()
        projectionTask?.cancel()
        waveformTask?.cancel()
        isPreparingWaveforms = false
        gesture = nil
    }

    private func performSelected(_ action: String, edit: (ProgramAudioClip, ProgramTimeline) throws -> AudioClip) {
        guard let selected, let composition else { return }
        do { replace(try edit(selected, composition.timeline), action: action) } catch { report(error) }
    }

    private func replace(_ clip: AudioClip, action: String) {
        apply(action) { model throws(DomainError) in try model.replacingAudioClip(clip, in: self.episodeID) }
    }

    @discardableResult
    private func apply(_ action: String, edit: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool {
        guard processing == nil, compositionGeneration == store.modelGeneration else {
            error = "The audio projection changed. Wait for the current placement before editing."
            return false
        }
        if store.apply(action, edit) { error = nil; refresh(); return true }
        error = store.lastError.map(EpisodeSetupModel.describe)
        return false
    }

    func requestInsertion(intro: Bool, programSeconds: Double?) {
        do {
            let editing = try insertionEditing()
            let frame: Int64
            if intro { frame = editing.introPosition }
            else if let programSeconds { frame = try Self.programFrame(programSeconds) }
            else {
                throw AudioInsertionEditing.Refusal("Show cut's removed audio is review-only. Choose a production position before inserting time.")
            }
            insertionSession = .init(purpose: intro ? .intro : .insert, generation: store.modelGeneration,
                editing: editing, position: frame, duration: 480_000, clip: selectedClip)
            error = nil
        } catch { report(error) }
    }

    func requestInsertionEdit(_ id: AudioInsertionRegionID) {
        do {
            let editing = try insertionEditing()
            guard let region = editing.composition.timeline.insertions.first(where: { $0.region.id == id }) else {
                throw AudioInsertionEditing.Refusal("The inserted-time region is no longer available.")
            }
            insertionSession = .init(purpose: .edit(id), generation: store.modelGeneration,
                editing: editing, position: region.programFrames.lowerBound,
                duration: region.region.durationFrames, clip: nil)
            error = nil
        } catch { report(error) }
    }

    func dismissInsertion() { insertionSession = nil }

    func insertionPreview(_ session: AudioInsertionSession, position: String, length: String,
                          usingEnd: Bool, retarget: Bool, removing: Bool) throws -> AudioInsertionEditing.Edit {
        try validateInsertionSession(session)
        if case .edit(let id) = session.purpose, removing { return try session.editing.removing(id) }
        let start = try Self.programFrame(position), value = try Self.programFrame(length)
        let duration = usingEnd ? value - start : value
        switch session.purpose {
        case .edit(let id): return try session.editing.replacing(id, at: start, duration: duration)
        case .intro, .insert:
            return try session.editing.inserting(at: start, duration: duration,
                moving: retarget ? session.clip : nil, id: session.regionID)
        }
    }

    @discardableResult
    func commitInsertion(_ session: AudioInsertionSession, position: String, length: String,
                         usingEnd: Bool, retarget: Bool, removing: Bool) -> Bool {
        do {
            let edit = try insertionPreview(session, position: position, length: length,
                usingEnd: usingEnd, retarget: retarget, removing: removing)
            let action: String
            switch session.purpose {
            case .intro: action = "Insert Intro"
            case .insert: action = "Insert & Ripple"
            case .edit: action = removing ? "Remove Inserted Time" : "Edit Inserted Time"
            }
            guard apply(action, edit: { model throws(DomainError) in
                try model.settingAudioArrangement(edit.arrangement, in: self.episodeID)
            }) else { return false }
            insertionSession = nil
            return true
        } catch { report(error); return false }
    }

    private func insertionEditing() throws -> AudioInsertionEditing {
        guard store.canEdit, !insertionProcessing, compositionGeneration == store.modelGeneration,
              let episode, let composition else {
            throw AudioInsertionEditing.Refusal("Wait for the current editable program projection before inserting time.")
        }
        return try AudioInsertionEditing(episode: episode, composition: composition)
    }

    private func validateInsertionSession(_ session: AudioInsertionSession) throws {
        guard insertionSession?.id == session.id, session.generation == store.modelGeneration,
              compositionGeneration == store.modelGeneration, store.canEdit, !insertionProcessing,
              episode == session.editing.episode else {
            throw AudioInsertionEditing.Refusal("The program changed or is processing. Cancel and reopen this preview; nothing was applied.")
        }
    }

    private var insertionProcessing: Bool {
        processing != nil || ShowWindowRegistry.states(for: store).contains { state in
            guard let alignment = state.alignmentModel, alignment.episodeID == episodeID else { return false }
            return TrackProcessingOperation.current(alignment: alignment, cleanup: state.cleanupModel) != nil
        }
    }

    private func report(_ failure: Error) {
        if let edit = failure as? AudioClipEditError, edit == .extensionRequiresEnvelope {
            error = "This crop discarded envelope automation. Extension is unavailable without an explicit replacement curve; the clip and its fades were kept unchanged."
        } else { error = "Audio edit refused: \(failure)" }
    }

    static func programFrame(_ text: String) throws -> Int64 {
        guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw StagedAudioImportCoordinator.Refusal("Enter a finite program time in seconds.")
        }
        return try programFrame(seconds)
    }

    static func programFrame(_ seconds: Double) throws -> Int64 {
        guard seconds.isFinite, (-86_400...86_400).contains(seconds) else {
            throw StagedAudioImportCoordinator.Refusal("Program time must be within minus 24 to plus 24 hours.")
        }
        return Int64((seconds * 48_000).rounded(.toNearestOrEven))
    }
}

struct AudioInsertionSession: Identifiable {
    enum Purpose { case intro, insert, edit(AudioInsertionRegionID) }
    let id = UUID()
    let regionID = AudioInsertionRegionID()
    let purpose: Purpose
    let generation: UInt64
    let editing: AudioInsertionEditing
    let position: Int64
    let duration: Int64
    let clip: AudioClipID?

    var title: String {
        switch purpose {
        case .intro: "Insert Intro"
        case .insert: "Insert & Ripple"
        case .edit: "Edit Inserted Time"
        }
    }
}
