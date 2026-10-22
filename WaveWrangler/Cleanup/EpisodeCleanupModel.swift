import AppKit
import AVFoundation
import Observation
import WWAlignPipeline
import WWCore
import WWDerived
import WWPersistence
import WWSpeech
import WWTimeMap

enum CleanupTimelineTool: String, CaseIterable {
    case seek = "Seek"
    case markIn = "Mark In"
    case markOut = "Mark Out"
}

@MainActor
@Observable
final class EpisodeCleanupModel {
    let state: ShowWindowState
    let episodeID: EpisodeID
    private let standaloneListening: EpisodeListeningState
    var listening: EpisodeListeningState { workspaceAlignment?.listening ?? standaloneListening }
    var rendersWaveforms = true
    @ObservationIgnored private(set) weak var workspaceAlignment: EpisodeAlignmentModel?
    var plan: PrimaryCleanupPlan?
    var identities: [SourceID: String] = [:]
    var windowStart = 0.0 {
        didSet { if oldValue != windowStart { scheduleWaveforms() } }
    }
    var windowDuration = 10.0 {
        didSet { if oldValue != windowDuration { scheduleWaveforms() } }
    }
    var visibleDuration: Double { windowDuration }
    var laneHeight = 96.0
    var normalizeView = false
    var timelineTool = CleanupTimelineTool.seek
    var mutedSpeakers: Set<SpeakerID> {
        guard let episode else { return [] }
        return Set((plan?.lanes ?? []).filter {
            !listening.playback.isAudible($0.primary.sourceID, in: episode)
        }.map(\.speaker))
    }
    var overviewStrokes: [SpeakerID: [AlignmentWaveformStroke]] = [:]
    var windowStrokes: [SpeakerID: [AlignmentWaveformStroke]] = [:]
    private var overviewIndices: [SpeakerID: AlignmentWaveformStrokeIndex] = [:]
    private var windowIndices: [SpeakerID: AlignmentWaveformStrokeIndex] = [:]
    var waveformWindow: ClosedRange<Double>?
    var waveformSnapshot = UUID()
    var waveformMessage = "Loading measured Primary waveforms…"
    var isLoadingWaveforms = false
    var isLoadingOverview = false
    private var standaloneIsPlaying = false
    private var standaloneIsPreparingPlayback = false
    private var standaloneTransportMessage = "Stopped"
    var isPlaying: Bool {
        get { workspaceAlignment?.isAuditioning ?? standaloneIsPlaying }
        set { standaloneIsPlaying = newValue }
    }
    var isPreparingPlayback: Bool {
        get { workspaceAlignment?.isPreparingAudition ?? standaloneIsPreparingPlayback }
        set { standaloneIsPreparingPlayback = newValue }
    }
    var transportMessage: String {
        get { workspaceAlignment?.auditionLabel ?? standaloneTransportMessage }
        set { standaloneTransportMessage = newValue }
    }
    var playhead = 0.0
    var inText = ""
    var outText = ""
    var selectedSpeaker: SpeakerID?
    var selectedWord: TranscriptWord?
    var selectedFillerID: UUID?
    var selectedManualCutID: UUID?
    private var standaloneCutTimeline = ManualCutTimeline.unedited
    var workspaceCutTimeline: ManualCutTimeline { workspaceAlignment?.cutTimeline ?? standaloneCutTimeline }
    var fillerStartText = ""
    var fillerEndText = ""
    var loopsFillerAudition = false
    @ObservationIgnored var isEditingFillerReview = false
    @ObservationIgnored var fillerPublicationGeneration: UInt64?
    @ObservationIgnored var fillerWordIndexGeneration: UInt64?
    @ObservationIgnored var fillerWordIndex: [UUID: [UUID: TranscriptWord]] = [:]
    var isBusy = false
    var isRefreshing = false
    var transcriptionStatus: CleanupTranscriptionStatus?
    var activeModelName: String?
    var message = "All Primaries must have current accepted alignment before transcription."
    var error: String?
    let transcriptionSettings: TranscriptionSettings
    @ObservationIgnored private let suppliedRuntime: AlignmentRuntime?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var waveformJob: Task<Void, Never>?
    @ObservationIgnored private var overviewJob: Task<Void, Never>?
    @ObservationIgnored private var waveformDebounce: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var waveformGeneration = UUID()
    @ObservationIgnored private var overviewGeneration = UUID()
    @ObservationIgnored private var waveformEpisode: Episode?
    @ObservationIgnored private var workSnapshot: ShowDocumentModel?
    @ObservationIgnored private var readyInputs: EpisodeMediaInputs?
    @ObservationIgnored private var isPublishing = false
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var players: [SpeakerID: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var playbackJob: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var playbackStart = 0.0
    @ObservationIgnored private var scheduledDuration = 0.0
    @ObservationIgnored private var playbackAppliesCuts = true
    @ObservationIgnored private var reviewGeneration: UInt64?
    @ObservationIgnored private var repetitionReviews: [UUID: Set<UUID>] = [:]

    static let repetitionReviewExplanation =
        "Long repetitive output may be hallucinated or genuine speech. Listen to verify. Raw text and timing are unchanged; this is not evidence of silence."

    init(state: ShowWindowState, episodeID: EpisodeID, runtime: AlignmentRuntime? = nil,
         transcriptionSettings: TranscriptionSettings = .shared) {
        self.state = state
        self.episodeID = episodeID
        self.standaloneListening = state.listeningState(for: episodeID)
        self.suppliedRuntime = runtime
        self.transcriptionSettings = transcriptionSettings
    }

    func resolveRuntime(for document: ShowDocument) async throws -> AlignmentRuntime {
        if let suppliedRuntime { return suppliedRuntime }
        return try await AlignmentRuntimeProvider.runtime(for: document, episode: episodeID)
    }

    func connectWorkspace(to alignment: EpisodeAlignmentModel) {
        workspaceAlignment = alignment
        rendersWaveforms = false
        windowStart = alignment.waveformStartSeconds
        windowDuration = alignment.waveformDurationSeconds
        playhead = alignment.waveformPlayheadSeconds
    }

    var episode: Episode? { state.store.model.episode(episodeID) }
    var canNavigate: Bool {
        state.store.document != nil
            && plan?.alignmentRevision != nil && plan?.lanes.isEmpty == false
            && plan?.lanes.allSatisfy({ identities[$0.primary.sourceID] != nil }) == true
            && bounds.upperBound > bounds.lowerBound
    }
    var maximumDuration: Double { max(0.5, bounds.upperBound - bounds.lowerBound) }
    var canTranscribe: Bool {
        !isBusy && !isRefreshing && state.canEdit && state.store.document != nil
            && plan?.isReady == true && transcriptionSettings.selectedURL != nil
            && plan?.lanes.allSatisfy({ identities[$0.primary.sourceID] != nil }) == true
    }
    var bounds: ClosedRange<Double> {
        let regions = plan?.lanes.flatMap(\.regions) ?? []
        let lo = cutTimeline.editedTime(forAlignedTime: regions.map(\.alignedStart).min() ?? 0)
        let hi = cutTimeline.editedTime(forAlignedTime: regions.map(\.alignedEnd).max() ?? 1)
        return lo...max(lo, hi)
    }

    func transcript(for lane: CleanupSpeakerLane) -> SpeakerTranscript? {
        guard let transcript = episode?.cleanup?.transcripts.first(where: { $0.speaker == lane.speaker }),
              transcript.primary == lane.primary, transcript.sourceRate == lane.sourceRate,
              transcript.alignmentRevision == plan?.alignmentRevision,
              transcript.sourceIdentity == identities[lane.primary.sourceID],
              (transcript.workingRange?.tracksIn ?? -.infinity) <= lane.start,
              (transcript.workingRange?.tracksOut ?? .infinity) >= lane.end
        else { return nil }
        return transcript
    }

    func visibleWords(for lane: CleanupSpeakerLane) -> [TranscriptWord] {
        guard windowStart.isFinite, visibleDuration.isFinite, visibleDuration > 0 else { return [] }
        return (transcript(for: lane)?.words ?? []).filter {
            guard let start = $0.alignedStart, let end = $0.alignedEnd else { return false }
            return displayRange(start: start, end: end).map {
                $0.upperBound > windowStart && $0.lowerBound < windowStart + visibleDuration
            } == true
                && end > lane.start && start < lane.end
        }
    }

    func uncertainWordIDs(for lane: CleanupSpeakerLane) -> Set<UUID> {
        guard let transcript = transcript(for: lane) else { return [] }
        if reviewGeneration != state.store.modelGeneration {
            repetitionReviews = [:]
            reviewGeneration = state.store.modelGeneration
        }
        if let cached = repetitionReviews[transcript.id] { return cached }
        let ids = TranscriptRepetitionReview.suspectWordIDs(in: transcript.words)
        repetitionReviews[transcript.id] = ids
        return ids
    }

    func modelDidChange() {
        synchronizeCutTimeline()
        if isEditingFillerReview { return }
        if let readyInputs, let episode,
           readyInputs == EpisodeMediaInputs(episode, includingWorkingRange: true) { return }
        let sameAudio = waveformEpisode.map { EpisodeMediaInputs($0) } == episode.map { EpisodeMediaInputs($0) }
        if !sameAudio {
            stopPlayback()
            cancelWaveforms()
            overviewStrokes = [:]
            windowStrokes = [:]
            overviewIndices = [:]
            windowIndices = [:]
            waveformWindow = nil
            waveformSnapshot = UUID()
        }
        identities = [:]
        plan = nil
        selectedWord = nil
        if !isPublishing, let workSnapshot,
           !state.store.model.hasSameMediaInputs(as: workSnapshot, in: episodeID, includingWorkingRange: true) {
            cancel()
            message = "Source, assignment, timing or working-range inputs changed. Transcription was canceled; no partial result was saved."
        }
    }

    func cancel() {
        cancelTranscription()
        refreshGeneration = UUID()
        isRefreshing = false
        fillerPublicationGeneration = nil
        cancelWaveforms()
        stopPlayback()
    }

    func cancelTranscription() {
        generation = UUID()
        job?.cancel()
        job = nil
        workSnapshot = nil
        isBusy = false
    }

    func refresh(skippingReviewOnlyChange: Bool = false) async {
        synchronizeCutTimeline()
        if skippingReviewOnlyChange, fillerPublicationGeneration == state.store.modelGeneration { return }
        fillerPublicationGeneration = nil
        transcriptionSettings.refreshAvailability()
        let token = UUID()
        refreshGeneration = token
        let snapshot = state.store.model
        isRefreshing = true
        defer { if refreshGeneration == token { isRefreshing = false } }
        updateRangeDrafts()
        let revision = episode?.alignment?.acceptedRevision
        let map: AlignedTimelineMap?
        do {
            if let revision { map = try snapshot.timeMap(revision: revision, in: episodeID) }
            else { map = nil }
        } catch {
            self.error = "Accepted alignment could not be read: \(Self.describe(error))"
            plan = nil
            identities = [:]
            return
        }

        if readyInputs != episode.map({ EpisodeMediaInputs($0, includingWorkingRange: true) }) {
            plan = PrimaryCleanupPlan.make(model: snapshot, episode: episodeID, map: map)
            identities = [:]
        }
        guard map != nil, plan?.lanes.isEmpty == false, let document = state.store.document else { return }
        do {
            let runtime = try await resolveRuntime(for: document)
            let prepared = try await runtime.prepareCleanup(model: snapshot, episode: episodeID, requireReady: false)
            try Task.checkCancellation()
            guard token == refreshGeneration,
                  state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID, includingWorkingRange: true) else { return }
            plan = prepared.plan
            identities = prepared.identities
            error = nil
            if !bounds.contains(windowStart) {
                windowStart = cutTimeline.editedTime(forAlignedTime: plan?.lanes.map(\.start).min() ?? bounds.lowerBound)
            }
            playhead = min(bounds.upperBound, max(bounds.lowerBound, playhead))
            if let episode { listening.playback.retainScopes(in: episode) }
            waveformEpisode = episode
            readyInputs = episode.map { EpisodeMediaInputs($0, includingWorkingRange: true) }
            isRefreshing = false
            loadWaveforms()
            if overviewStrokes.isEmpty { loadWaveforms(overview: true) }
            updateFillerDrafts()
        } catch is CancellationError {
            return
        } catch {
            guard token == refreshGeneration,
                  state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID, includingWorkingRange: true) else { return }
            self.error = "Cleanup readiness could not be verified: \(Self.describe(error))"
            plan = nil
            identities = [:]
            readyInputs = nil
            stopPlayback()
        }
    }

    func synchronizeCutTimeline() {
        if let id = listening.expandedManualCutID, !activeManualCuts.contains(where: { $0.id == id }) {
            listening.expandedManualCutID = nil
        }
        workspaceAlignment?.load()
        do {
            let timeline = try episode?.manualCutTimeline(revealing: listening.expandedManualCutID) ?? .unedited
            if timeline != standaloneCutTimeline {
                if rendersWaveforms {
                    stopPlayback()
                    let aligned = standaloneCutTimeline.alignedTime(forEditedTime: playhead)
                    let alignedStart = standaloneCutTimeline.alignedTime(forEditedTime: windowStart)
                    playhead = timeline.editedTime(forAlignedTime: aligned)
                    windowStart = timeline.editedTime(forAlignedTime: alignedStart)
                    cancelWaveforms()
                    overviewStrokes = [:]
                    windowStrokes = [:]
                    overviewIndices = [:]
                    windowIndices = [:]
                    waveformWindow = nil
                }
                standaloneCutTimeline = timeline
                listening.selection = nil
                listening.cycleRange = nil
                listening.cycleEnabled = false
                selectedFillerID = nil
                if rendersWaveforms {
                    loadWaveforms(force: true)
                    loadWaveforms(overview: true, force: true)
                }
            }
            refreshManualCutSelection()
        } catch {
            self.error = "Manual cut timing is unavailable: \(Self.describe(error))"
            stopPlayback()
        }
    }

    func saveRange(inValue: Double?, outValue: Double?) {
        guard !isBusy, state.canEdit, let revision = episode?.alignment?.acceptedRevision else {
            error = "Accept alignment before setting Tracks In / Out."
            return
        }
        let range = EpisodeWorkingRange(alignmentRevision: revision, tracksIn: inValue, tracksOut: outValue)
        guard range.isValid else { error = "Tracks In must be earlier than Tracks Out; enter finite aligned seconds."; return }
        var cleanup = episode?.cleanup ?? EpisodeCleanup()
        cleanup.workingRange = inValue == nil && outValue == nil ? nil : range
        state.window?.makeFirstResponder(nil)
        if state.store.apply("Set Tracks In / Out", { model throws(DomainError) in
            try model.settingCleanup(cleanup, in: episodeID)
        }) {
            updateRangeDrafts()
            error = nil
            message = "Working range updated on every speaker lane. Banter remains in the originals and can be restored."
        } else { error = "The working range could not be saved: \(String(describing: state.store.lastError))." }
    }

    private func updateRangeDrafts() {
        inText = episode?.cleanup?.workingRange?.tracksIn.map { String(format: "%.6f", $0) } ?? ""
        outText = episode?.cleanup?.workingRange?.tracksOut.map { String(format: "%.6f", $0) } ?? ""
    }

    func applyRangeText() {
        let a = inText.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = outText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.isEmpty || Double(a) != nil, b.isEmpty || Double(b) != nil else {
            error = "Enter aligned seconds (for example 12.500), or leave an end blank."
            return
        }
        saveRange(inValue: Double(a), outValue: Double(b))
    }

    func transcribe() {
        guard canTranscribe, let modelURL = transcriptionSettings.selectedURL,
              let document = state.store.document else { return }
        let configuration: TranscriptionConfiguration
        do { configuration = try transcriptionSettings.captureConfiguration() }
        catch { self.error = Self.describe(error); return }
        let snapshot = state.store.model
        let token = UUID()
        generation = token
        workSnapshot = snapshot
        isBusy = true
        error = nil
        transcriptionStatus = CleanupTranscriptionStatus(startedAt: Date())
        message = "Waiting for the shared transcription resource budget…"
        let weights = transcriptionSettings.selection
        let concurrency = transcriptionSettings.concurrency
        activeModelName = "\(weights.title) | \(configuration.backend.title) | \(configuration.threads.rawValue) threads"
        job = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { isBusy = false; job = nil; workSnapshot = nil } }
            do {
                let workerPool = await transcriptionSettings.configuredWorkerPool()
                try Task.checkCancellation()
                message = "Verifying aligned Primaries and source access…"
                let runtime = try await resolveRuntime(for: document)
                let result = try await runtime.transcribeCleanup(model: snapshot, episode: episodeID,
                    modelURL: modelURL, weights: weights, configuration: configuration,
                    concurrency: concurrency, workerPool: workerPool) {
                    [weak self] update in
                    await self?.reportProgress(token: token, update: update)
                }
                try Task.checkCancellation()
                guard generation == token,
                      state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID, includingWorkingRange: true),
                      state.canEdit,
                      document === state.store.document else { throw CancellationError() }
                guard try publishTranscripts(result, expecting: snapshot)
                else { throw CancellationError() }
                message = "Transcribed \(result.count) speaker\(result.count == 1 ? "" : "s") locally. Word timing is approximate; no cuts were applied."
            } catch is CancellationError {
                if generation == token { message = "Transcription canceled. No partial result was saved." }
            } catch {
                if generation == token {
                    self.error = "Transcription failed: \(Self.describe(error))"
                    message = "Transcription stopped. No partial result was saved."
                }
            }
        }
    }

    /// Called only after all speakers and live source/timing verification have finished.
    func publishTranscripts(_ result: [SpeakerTranscript], expecting snapshot: ShowDocumentModel) throws(DomainError) -> Bool {
        let live = state.store.model
        guard live.hasSameMediaInputs(as: snapshot, in: episodeID, includingWorkingRange: true),
              live.episode(episodeID)?.cleanup?.transcripts == snapshot.episode(episodeID)?.cleanup?.transcripts,
              live.episode(episodeID)?.cleanup?.transcriptHistory == snapshot.episode(episodeID)?.cleanup?.transcriptHistory
        else { return false }
        let cleanup = try (live.episode(episodeID)?.cleanup ?? EpisodeCleanup()).replacingTranscripts(result)
        let updated = try live.settingCleanup(cleanup, in: episodeID)
        isPublishing = true
        defer { isPublishing = false }
        return state.store.applyReplacement("Transcribe episode", expecting: live, model: updated, afterChange: { _ in })
    }

    private func reportProgress(token: UUID, update: CleanupTranscriptionProgress) {
        guard generation == token else { return }
        if transcriptionStatus?.record(update) == true { message = update.heading }
    }

    func strokes(for speaker: SpeakerID) -> [AlignmentWaveformStroke] {
        if let waveformWindow, windowStart >= waveformWindow.lowerBound,
           windowStart + windowDuration <= waveformWindow.upperBound + 0.000_001,
           windowDuration <= 30, let strokes = windowStrokes[speaker] { return strokes }
        return overviewStrokes[speaker] ?? []
    }

    func waveformIndex(for speaker: SpeakerID) -> AlignmentWaveformStrokeIndex {
        if let waveformWindow, windowStart >= waveformWindow.lowerBound,
           windowStart + windowDuration <= waveformWindow.upperBound + 0.000_001,
           windowDuration <= 30, let index = windowIndices[speaker] { return index }
        return overviewIndices[speaker] ?? .empty
    }

    func setWindow(start: Double, duration: Double) {
        let bounds = workspaceAlignment?.waveformViewingBounds ?? self.bounds
        let maximum = workspaceAlignment?.maximumWaveformDuration ?? max(30, maximumDuration)
        guard start.isFinite, duration.isFinite, duration >= 0.5,
              duration <= maximum, abs(start) <= 86_400 else {
            error = "Choose a finite timeline window between 0.5 seconds and the episode span."
            return
        }
        windowDuration = duration
        windowStart = min(max(bounds.lowerBound, bounds.upperBound - duration), max(bounds.lowerBound, start))
        if let alignment = workspaceAlignment {
            alignment.waveformStartSeconds = windowStart
            alignment.waveformDurationSeconds = windowDuration
            alignment.loadWaveforms(keepingSnapshot: true)
        }
    }

    func fitTimeline() {
        setWindow(start: bounds.lowerBound, duration: maximumDuration)
        if overviewStrokes.isEmpty { loadWaveforms(overview: true) }
    }

    func zoomTimeline(duration: Double) {
        guard playhead.isFinite, abs(playhead) <= 86_400 else {
            error = "Enter finite aligned seconds within the supported timeline."
            return
        }
        setWindow(start: max(bounds.lowerBound, playhead - duration / 2), duration: duration)
    }

    private func scheduleWaveforms() {
        waveformDebounce?.cancel()
        guard rendersWaveforms, windowStart.isFinite, windowDuration.isFinite, windowDuration > 0 else { return }
        waveformDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            self?.loadWaveforms()
        }
    }

    func cancelWaveforms() {
        waveformGeneration = UUID()
        overviewGeneration = UUID()
        waveformJob?.cancel()
        overviewJob?.cancel()
        waveformDebounce?.cancel()
        waveformJob = nil
        overviewJob = nil
        waveformDebounce = nil
        isLoadingWaveforms = false
        isLoadingOverview = false
    }

    func refreshWaveforms() {
        cancelWaveforms()
        loadWaveforms(force: true)
        loadWaveforms(overview: true, force: true)
    }

    func loadWaveforms(overview: Bool = false, force: Bool = false) {
        guard rendersWaveforms else { return }
        guard windowStart.isFinite, windowDuration.isFinite, windowDuration >= 0.5,
              windowDuration <= max(30, maximumDuration), abs(windowStart) <= 86_400 else {
            error = "Choose a finite timeline window between 0.5 seconds and the episode span."
            return
        }
        guard canNavigate, let document = state.store.document, let lanes = plan?.lanes else { return }
        let window = AlignmentWaveformProjection.tileWindow(start: windowStart, visible: windowDuration)
        if !overview {
            guard window != nil else { return }
            if !force, let waveformWindow, windowStart >= waveformWindow.lowerBound,
               windowStart + windowDuration <= waveformWindow.upperBound + 0.000_001 { return }
            if isLoadingWaveforms { waveformJob?.cancel() }
        } else if isLoadingOverview { return }
        let token = UUID()
        if overview { overviewGeneration = token; isLoadingOverview = true }
        else { waveformGeneration = token; isLoadingWaveforms = true }
        let snapshot = state.store.model
        let revealingCut = listening.expandedManualCutID
        let cuts = cutTimeline
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if overview, overviewGeneration == token { isLoadingOverview = false; overviewJob = nil }
                if !overview, waveformGeneration == token { isLoadingWaveforms = false; waveformJob = nil }
            }
            do {
                let runtime = try await resolveRuntime(for: document)
                var projected: [SpeakerID: [AlignmentWaveformStroke]] = [:]
                var indices: [SpeakerID: AlignmentWaveformStrokeIndex] = [:]
                for lane in lanes {
                    let loaded = try await runtime.waveformTracks(
                        model: snapshot, episode: episodeID,
                        startSeconds: window?.start ?? 0, durationSeconds: window?.duration ?? 1,
                        overview: overview, onlySources: [lane.primary.sourceID],
                        decodedChannels: lane.primary.channel.value.map { [lane.primary.sourceID: $0] } ?? [:],
                        revealingCut: revealingCut)
                    guard loaded.map != nil, loaded.mapWarning == nil, loaded.refusals.isEmpty,
                          let track = loaded.tracks.first else {
                        let reason = loaded.mapWarning ?? loaded.refusals.map(\.reason).joined(separator: "; ")
                        throw NSError(domain: "CleanupWaveforms", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "\(lane.name): \(reason)"])
                    }
                    let prepared = try await AlignmentWaveformProjection.prepare(
                        load: loaded, episode: snapshot.episode(episodeID), cuts: cuts, mappedOnly: true)
                    if let reason = prepared.errors[track.id] {
                        throw ManualCutReviewFailure(reason: "\(lane.name): \(reason)")
                    }
                    projected[lane.speaker] = prepared.strokes[track.id] ?? []
                    indices[lane.speaker] = prepared.indices[track.id]
                }
                try Task.checkCancellation()
                guard (overview ? overviewGeneration : waveformGeneration) == token,
                      state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID) else { return }
                if overview {
                    overviewStrokes = projected
                    overviewIndices = indices
                }
                else if let window {
                    windowStrokes = projected
                    windowIndices = indices
                    waveformWindow = window.start...(window.start + window.duration)
                }
                waveformSnapshot = UUID()
                waveformMessage = "Measured Primary waveforms. Shaded banter is recoverable; gaps in accepted timing are not measured silence."
            } catch is CancellationError {
                return
            } catch {
                guard (overview ? overviewGeneration : waveformGeneration) == token else { return }
                self.error = "Primary waveforms could not be loaded: \(Self.describe(error))"
            }
        }
        if overview { overviewJob = task } else { waveformJob = task }
    }

    @discardableResult
    func previewSeek(to time: Double, revealing: Bool = true) -> Bool {
        guard time.isFinite, abs(time) <= 86_400 else {
            error = "Enter finite aligned seconds within the supported timeline."
            return false
        }
        stopPlayback()
        playhead = min(bounds.upperBound, max(bounds.lowerBound, time))
        if let workspaceAlignment {
            if revealing {
                workspaceAlignment.seekEnabledTracks(to: playhead)
            } else {
                return workspaceAlignment.previewWaveformPlayhead(to: playhead)
            }
        }
        return true
    }

    func seek(to time: Double) {
        let resume = isPlaying || isPreparingPlayback
        guard previewSeek(to: time) else { return }
        if playhead < windowStart || playhead > windowStart + windowDuration {
            setWindow(start: playhead - windowDuration / 2, duration: windowDuration)
        }
        if resume { play() }
    }

    func timelineClick(at time: Double) {
        seek(to: time)
        switch timelineTool {
        case .seek: break
        case .markIn: markIn()
        case .markOut: markOut()
        }
    }

    func markIn() {
        saveRange(inValue: cutTimeline.alignedTime(forEditedTime: playhead), outValue: episode?.cleanup?.workingRange?.tracksOut)
    }

    func markOut() {
        saveRange(inValue: episode?.cleanup?.workingRange?.tracksIn, outValue: cutTimeline.alignedTime(forEditedTime: playhead))
    }

    func setSpeaker(_ speaker: SpeakerID, enabled: Bool) {
        listening.playback.setMuted(!enabled, scope: .speaker(speaker))
        updateGains()
    }

    func updateGains() {
        if let workspaceAlignment {
            workspaceAlignment.refreshListeningGains()
            return
        }
        let audible = players.keys.filter { !mutedSpeakers.contains($0) }.count
        for (speaker, player) in players {
            player.volume = mutedSpeakers.contains(speaker) ? 0 : 1 / Float(max(1, audible))
        }
        if isPlaying {
            transportMessage = audible == 0 ? "Playing timeline; all speakers muted."
                : "Playing \(audible) aligned Primary \(audible == 1 ? "track" : "tracks")."
        }
    }

    private var elapsedPlayback: Double {
        guard let player = players.values.first, let rendered = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: rendered), time.sampleRate > 0 else { return 0 }
        return max(0, Double(time.sampleTime) / time.sampleRate)
    }

    func play() {
        if let workspaceAlignment {
            workspaceAlignment.playEnabledTracks()
            return
        }
        play(interval: listening.cycleEnabled ? listening.cycleRange : nil, loop: listening.cycleEnabled)
    }

    func play(interval: ClosedRange<Double>?, loop: Bool, applyingCuts: Bool = true) {
        if let workspaceAlignment {
            workspaceAlignment.playEnabledTracks(interval: interval, repeatInterval: loop,
                repeatWhile: { [weak self] in self?.loopsFillerAudition == true }, applyingCuts: applyingCuts)
            return
        }
        let regions = plan?.lanes.flatMap(\.regions) ?? []
        let originalBounds = (regions.map(\.alignedStart).min() ?? 0)...(regions.map(\.alignedEnd).max() ?? 0)
        guard let document = state.store.document,
              applyingCuts ? canNavigate : plan?.lanes.isEmpty == false
                && plan?.alignmentRevision == episode?.alignment?.acceptedRevision
                && plan?.lanes.allSatisfy({ identities[$0.primary.sourceID] != nil }) == true else {
            error = "Verify the sources and accepted alignment before auditioning this cut."
            return
        }
        stopPlayback()
        playbackAppliesCuts = applyingCuts
        let playbackBounds = applyingCuts ? bounds : originalBounds
        let start = max(playbackBounds.lowerBound, interval?.lowerBound
            ?? (playhead >= playbackBounds.upperBound ? playbackBounds.lowerBound : max(playbackBounds.lowerBound, playhead)))
        let end = min(playbackBounds.upperBound, interval?.upperBound ?? playbackBounds.upperBound)
        guard start.isFinite, end.isFinite, end > start else {
            error = "The selected interval does not overlap available aligned media."
            return
        }
        let cycling = listening.cycleEnabled && interval == listening.cycleRange
        let snapshot = state.store.model
        let token = UUID()
        let revealingCut = listening.expandedManualCutID
        playbackGeneration = token
        isPreparingPlayback = true
        transportMessage = "Preparing aligned Primary audio…"
        playbackJob = Task { [weak self] in
            guard let self else { return }
            do {
                let runtime = try await resolveRuntime(for: document)
                var cursor = start
                var first = true
                var started = false
                while cursor < end - 1 / 48_000 {
                    try Task.checkCancellation()
                    let audio = try await runtime.cleanupPreview(
                        model: snapshot, episode: episodeID, start: cursor,
                        duration: min(5, end - cursor), respectWorkingRange: false, applyingCuts: applyingCuts,
                        revealingCut: revealingCut)
                    try Task.checkCancellation()
                    while started, scheduledDuration - elapsedPlayback >= 5 {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard playbackGeneration == token, state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                          document === state.store.document else { throw CancellationError() }
                    try enqueue(audio, first: first)
                    first = false
                    cursor = audio.start + audio.duration
                    if !started, cursor >= min(end, start + 10) - 1 / 48_000 {
                        let hostTime = AVAudioTime(
                            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1))
                        for player in players.values { player.play(at: hostTime) }
                        started = true
                        isPreparingPlayback = false
                        isPlaying = true
                        updateGains()
                        startPlaybackProgress(token: token, end: end, followsPlayhead: interval == nil)
                    }
                }
                while elapsedPlayback < scheduledDuration - 1 / 48_000 {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard playbackGeneration == token else { return }
                playhead = applyingCuts ? end : cutTimeline.editedTime(forAlignedTime: end)
                stopPlayback(updatePlayhead: false)
                if loop, (cycling ? listening.cycleEnabled && listening.cycleRange == interval : loopsFillerAudition),
                   state.store.model.hasSameMediaInputs(as: snapshot, in: episodeID) {
                    play(interval: start...end, loop: true, applyingCuts: applyingCuts)
                } else {
                    transportMessage = interval == nil
                        ? "Reached the end of the aligned Primary timeline." : "Finished filler timing audition."
                }
            } catch is CancellationError {
                return
            } catch {
                guard playbackGeneration == token else { return }
                stopPlayback()
                self.error = "Playback failed: \(Self.describe(error))"
            }
        }
    }

    private func enqueue(_ audio: AlignmentRuntime.CleanupAudio, first: Bool) throws {
        guard let samples = audio.channels.values.first, !samples.isEmpty,
              samples.count <= Int(AVAudioFrameCount.max),
              audio.channels.values.allSatisfy({ $0.count == samples.count && $0.allSatisfy(\.isFinite) }),
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        else { throw WaveformWindowError.invalidSamples }
        if first {
            let engine = AVAudioEngine()
            for speaker in audio.channels.keys {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players[speaker] = player
            }
            audioEngine = engine
            try engine.start()
            playbackStart = audio.start
            scheduledDuration = 0
            playhead = playbackAppliesCuts ? audio.start : cutTimeline.editedTime(forAlignedTime: audio.start)
        }
        guard Set(audio.channels.keys) == Set(players.keys) else { throw WaveformWindowError.invalidSamples }
        for (speaker, samples) in audio.channels {
            guard let player = players[speaker],
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let output = buffer.floatChannelData?[0] else { throw WaveformWindowError.invalidSamples }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { values in
                if let base = values.baseAddress { output.update(from: base, count: values.count) }
            }
            player.scheduleBuffer(buffer)
        }
        scheduledDuration += Double(samples.count) / 48_000
        updateGains()
    }

    private func startPlaybackProgress(token: UUID, end: Double, followsPlayhead: Bool) {
        transportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, playbackGeneration == token else { return }
                let elapsed = elapsedPlayback
                let time = min(end, playbackStart + min(scheduledDuration, elapsed))
                playhead = playbackAppliesCuts ? time : cutTimeline.editedTime(forAlignedTime: time)
                if elapsed > scheduledDuration + 0.15, playbackStart + scheduledDuration < end - 0.000_1 {
                    stopPlayback()
                    error = "Playback could not keep up with aligned audio rendering. Stopped at the last prepared audio; retry from here."
                    return
                }
                if followsPlayhead, playhead > windowStart + windowDuration * 0.8 {
                    setWindow(start: playhead - windowDuration * 0.2, duration: windowDuration)
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    func stopPlayback(updatePlayhead: Bool = true) {
        if let workspaceAlignment {
            workspaceAlignment.stopAudition()
            playhead = workspaceAlignment.waveformPlayheadSeconds
            return
        }
        if updatePlayhead, isPlaying {
            let time = playbackStart + min(scheduledDuration, elapsedPlayback)
            playhead = playbackAppliesCuts ? time : cutTimeline.editedTime(forAlignedTime: time)
        }
        playbackGeneration = UUID()
        playbackJob?.cancel()
        playbackJob = nil
        transportTask?.cancel()
        transportTask = nil
        for player in players.values { player.stop() }
        audioEngine?.stop()
        players = [:]
        audioEngine = nil
        isPlaying = false
        isPreparingPlayback = false
        transportMessage = "Paused at \(AlignmentPresentation.formatTime(playhead))."
    }

    func stop() {
        if let workspaceAlignment {
            workspaceAlignment.stopEnabledTracks()
            playhead = workspaceAlignment.waveformPlayheadSeconds
            return
        }
        stopPlayback()
        playhead = windowStart
        transportMessage = "Stopped"
    }

    func select(_ word: TranscriptWord, speaker: SpeakerID) {
        stopPlayback()
        listening.selectionToolsPresented = true
        selectedSpeaker = speaker
        selectedWord = word
        if let start = word.alignedStart, let end = word.alignedEnd, end > start {
            listening.selection = displayRange(start: start, end: end)
        } else { listening.selection = nil }
        selectedFillerID = fillerReviews.first { $0.speaker == speaker && $0.word?.id == word.id
            && fillerIssue($0) == nil }?.id
        updateFillerDrafts()
        state.inspectorPresented = true
        if let start = word.alignedStart { _ = previewSeek(to: cutTimeline.editedTime(forAlignedTime: start)) }
    }

    func select(_ words: [TranscriptWord], speaker: SpeakerID) {
        guard let first = words.first else { return }
        select(first, speaker: speaker)
        if let start = words.compactMap(\.alignedStart).min(),
           let end = words.compactMap(\.alignedEnd).max(), end > start {
            if words.count > 1 { selectedFillerID = nil }
            listening.selection = displayRange(start: start, end: end)
        }
        listening.selectedTranscriptText = words.map(\.text).joined(separator: " ")
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? SpeechModelError {
            switch error {
            case .hashMismatch, .invalidSize: return "The weights do not match this model's pinned size or SHA-256. Download the model again in Settings > Transcription."
            case .notMaterialized, .nonLocalFilesystem: return "The model must be on local storage. Download it in Settings > Transcription."
            default: return "Local model verification refused: \(error). Open Settings > Transcription to download the weights again."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
