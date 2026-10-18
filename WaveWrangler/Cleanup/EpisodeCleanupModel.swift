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
    var mutedSpeakers: Set<SpeakerID> = []
    var overviewStrokes: [SpeakerID: [AlignmentWaveformStroke]] = [:]
    var windowStrokes: [SpeakerID: [AlignmentWaveformStroke]] = [:]
    var waveformWindow: ClosedRange<Double>?
    var waveformSnapshot = UUID()
    var waveformMessage = "Loading measured Primary waveforms…"
    var isLoadingWaveforms = false
    var isLoadingOverview = false
    var isPlaying = false
    var isPreparingPlayback = false
    var transportMessage = "Stopped"
    var playhead = 0.0
    var inText = ""
    var outText = ""
    var selectedSpeaker: SpeakerID?
    var selectedWord: TranscriptWord?
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
    @ObservationIgnored private var isPublishing = false
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var players: [SpeakerID: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var playbackJob: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var playbackStart = 0.0
    @ObservationIgnored private var scheduledDuration = 0.0
    @ObservationIgnored private var reviewGeneration: UInt64?
    @ObservationIgnored private var repetitionReviews: [UUID: Set<UUID>] = [:]

    static let repetitionReviewExplanation =
        "Long repetitive output may be hallucinated or genuine speech. Listen to verify. Raw text and timing are unchanged; this is not evidence of silence."

    init(state: ShowWindowState, episodeID: EpisodeID, runtime: AlignmentRuntime? = nil,
         transcriptionSettings: TranscriptionSettings = .shared) {
        self.state = state
        self.episodeID = episodeID
        self.suppliedRuntime = runtime
        self.transcriptionSettings = transcriptionSettings
    }

    private func resolveRuntime(for document: ShowDocument) async throws -> AlignmentRuntime {
        if let suppliedRuntime { return suppliedRuntime }
        return try await AlignmentRuntimeProvider.runtime(for: document, episode: episodeID)
    }

    var episode: Episode? { state.store.model.episode(episodeID) }
    var canNavigate: Bool {
        !isBusy && !isRefreshing && state.store.document != nil
            && plan?.alignmentRevision != nil && plan?.lanes.isEmpty == false
            && plan?.lanes.allSatisfy({ identities[$0.primary.sourceID] != nil }) == true
    }
    var maximumDuration: Double { max(0.5, bounds.upperBound - bounds.lowerBound) }
    var canTranscribe: Bool {
        !isBusy && !isRefreshing && state.canEdit && state.store.document != nil
            && plan?.isReady == true && transcriptionSettings.selectedURL != nil
            && plan?.lanes.allSatisfy({ identities[$0.primary.sourceID] != nil }) == true
    }
    var bounds: ClosedRange<Double> {
        let regions = plan?.lanes.flatMap(\.regions) ?? []
        let lo = regions.map(\.alignedStart).min() ?? 0
        let hi = regions.map(\.alignedEnd).max() ?? 1
        return lo...max(lo + 0.1, hi)
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
            return end > windowStart && start < windowStart + visibleDuration
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
        stopPlayback()
        let sameAudio = waveformEpisode?.sources == episode?.sources
            && waveformEpisode?.alignment == episode?.alignment
            && waveformEpisode?.speakerAssignments == episode?.speakerAssignments
        cancelWaveforms()
        if !sameAudio {
            overviewStrokes = [:]
            windowStrokes = [:]
            waveformWindow = nil
            waveformSnapshot = UUID()
        }
        identities = [:]
        plan = nil
        selectedWord = nil
        if !isPublishing, let workSnapshot, workSnapshot != state.store.model {
            cancel()
            message = "The show changed. Transcription was cancelled; no partial result was saved."
        }
    }

    func cancel() {
        generation = UUID()
        job?.cancel()
        job = nil
        workSnapshot = nil
        isBusy = false
        refreshGeneration = UUID()
        isRefreshing = false
        cancelWaveforms()
        stopPlayback()
    }

    func refresh() async {
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
        plan = PrimaryCleanupPlan.make(model: snapshot, episode: episodeID, map: map)
        identities = [:]
        guard map != nil, plan?.lanes.isEmpty == false, let document = state.store.document else { return }
        do {
            let runtime = try await resolveRuntime(for: document)
            let prepared = try await runtime.prepareCleanup(model: snapshot, episode: episodeID, requireReady: false)
            try Task.checkCancellation()
            guard token == refreshGeneration, state.store.model == snapshot else { return }
            plan = prepared.plan
            identities = prepared.identities
            error = nil
            if !bounds.contains(windowStart) { windowStart = plan?.lanes.map(\.start).min() ?? bounds.lowerBound }
            playhead = min(bounds.upperBound, max(bounds.lowerBound, playhead))
            mutedSpeakers.formIntersection(Set(prepared.plan.lanes.map(\.speaker)))
            waveformEpisode = episode
            isRefreshing = false
            loadWaveforms()
            if overviewStrokes.isEmpty { loadWaveforms(overview: true) }
        } catch is CancellationError {
            return
        } catch {
            guard token == refreshGeneration, state.store.model == snapshot else { return }
            self.error = "Cleanup readiness could not be verified: \(Self.describe(error))"
            plan = nil
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
        stopPlayback()
        cancelWaveforms()
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
                guard generation == token, state.store.model == snapshot, state.canEdit,
                      document === state.store.document else { throw CancellationError() }
                var cleanup = snapshot.episode(episodeID)?.cleanup ?? EpisodeCleanup()
                cleanup.transcripts = result
                let updated = try snapshot.settingCleanup(cleanup, in: episodeID)
                isPublishing = true
                defer { isPublishing = false }
                guard state.store.applyReplacement("Transcribe episode", expecting: snapshot, model: updated, afterChange: { _ in })
                else { throw CancellationError() }
                message = "Transcribed \(result.count) speaker\(result.count == 1 ? "" : "s") locally. Word timing is approximate; no cuts were applied."
            } catch is CancellationError {
                if generation == token { message = "Transcription cancelled. No partial result was saved." }
            } catch {
                if generation == token {
                    self.error = "Transcription failed: \(Self.describe(error))"
                    message = "Transcription stopped. No partial result was saved."
                }
            }
        }
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

    func setWindow(start: Double, duration: Double) {
        guard start.isFinite, duration.isFinite, duration >= 0.5,
              duration <= max(30, maximumDuration), abs(start) <= 86_400 else {
            error = "Choose a finite timeline window between 0.5 seconds and the episode span."
            return
        }
        windowDuration = duration
        windowStart = min(max(bounds.lowerBound, bounds.upperBound - duration), max(bounds.lowerBound, start))
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
        guard windowStart.isFinite, windowDuration.isFinite, windowDuration > 0 else { return }
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
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if overview, overviewGeneration == token { isLoadingOverview = false; overviewJob = nil }
                if !overview, waveformGeneration == token { isLoadingWaveforms = false; waveformJob = nil }
            }
            do {
                let runtime = try await resolveRuntime(for: document)
                var projected: [SpeakerID: [AlignmentWaveformStroke]] = [:]
                for lane in lanes {
                    let loaded = try await runtime.waveformTracks(
                        model: snapshot, episode: episodeID,
                        startSeconds: window?.start ?? 0, durationSeconds: window?.duration ?? 1,
                        overview: overview, onlySources: [lane.primary.sourceID],
                        decodedChannels: lane.primary.channel.value.map { [lane.primary.sourceID: $0] } ?? [:])
                    guard loaded.map != nil, loaded.mapWarning == nil, loaded.refusals.isEmpty,
                          let track = loaded.tracks.first else {
                        let reason = loaded.mapWarning ?? loaded.refusals.map(\.reason).joined(separator: "; ")
                        throw NSError(domain: "CleanupWaveforms", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "\(lane.name): \(reason)"])
                    }
                    projected[lane.speaker] = try AlignmentWaveformProjection.strokes(
                        track: track, map: loaded.map,
                        correction: snapshot.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections?
                            .first { $0.source == lane.primary.sourceID }).filter(\.mapped)
                }
                try Task.checkCancellation()
                guard (overview ? overviewGeneration : waveformGeneration) == token,
                      state.store.model == snapshot else { return }
                if overview { overviewStrokes = projected }
                else if let window {
                    windowStrokes = projected
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
    func previewSeek(to time: Double) -> Bool {
        guard time.isFinite, abs(time) <= 86_400 else {
            error = "Enter finite aligned seconds within the supported timeline."
            return false
        }
        stopPlayback()
        playhead = min(bounds.upperBound, max(bounds.lowerBound, time))
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
        saveRange(inValue: playhead, outValue: episode?.cleanup?.workingRange?.tracksOut)
    }

    func markOut() {
        saveRange(inValue: episode?.cleanup?.workingRange?.tracksIn, outValue: playhead)
    }

    func setSpeaker(_ speaker: SpeakerID, enabled: Bool) {
        if enabled { mutedSpeakers.remove(speaker) } else { mutedSpeakers.insert(speaker) }
        updateGains()
    }

    private func updateGains() {
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
        guard canNavigate, let document = state.store.document else { return }
        stopPlayback()
        let start = playhead >= bounds.upperBound ? bounds.lowerBound : max(bounds.lowerBound, playhead)
        let end = bounds.upperBound
        let snapshot = state.store.model
        let token = UUID()
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
                        duration: min(5, end - cursor), respectWorkingRange: false)
                    try Task.checkCancellation()
                    while started, scheduledDuration - elapsedPlayback >= 5 {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard playbackGeneration == token, state.store.model == snapshot,
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
                        startPlaybackProgress(token: token, end: end)
                    }
                }
                while elapsedPlayback < scheduledDuration - 1 / 48_000 {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard playbackGeneration == token else { return }
                playhead = end
                stopPlayback(updatePlayhead: false)
                transportMessage = "Reached the end of the aligned Primary timeline."
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
            playhead = audio.start
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

    private func startPlaybackProgress(token: UUID, end: Double) {
        transportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, playbackGeneration == token else { return }
                let elapsed = elapsedPlayback
                playhead = min(end, playbackStart + min(scheduledDuration, elapsed))
                if elapsed > scheduledDuration + 0.15, playbackStart + scheduledDuration < end - 0.000_1 {
                    stopPlayback()
                    error = "Playback could not keep up with aligned audio rendering. Stopped at the last prepared audio; retry from here."
                    return
                }
                if playhead > windowStart + windowDuration * 0.8 {
                    setWindow(start: playhead - windowDuration * 0.2, duration: windowDuration)
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    func stopPlayback(updatePlayhead: Bool = true) {
        if updatePlayhead, isPlaying {
            playhead = playbackStart + min(scheduledDuration, elapsedPlayback)
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
        stopPlayback()
        playhead = windowStart
        transportMessage = "Stopped"
    }

    func select(_ word: TranscriptWord, speaker: SpeakerID) {
        stopPlayback()
        selectedSpeaker = speaker
        selectedWord = word
        state.inspectorPresented = true
        if let start = word.alignedStart { playhead = start }
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
