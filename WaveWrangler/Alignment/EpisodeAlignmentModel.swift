import AppKit
import AVFAudio
import Foundation
import Observation
import SwiftUI
import WWAlignPipeline
import WWCore
import WWOrganizer
import WWTimeMap

@MainActor
@Observable
final class EpisodeAlignmentModel {
    private(set) var rows: [AlignmentRow] = []
    var selection: RecordingEpochID? {
        didSet {
            if selection != oldValue {
                selectedWaveformSource = nil
                resetWaveformTiming()
                stopAudition()
            }
        }
    }
    private(set) var isWorking = false
    private(set) var hasAnalysis = false
    private(set) var message = "Alignment has not read or analysed any audio."
    private(set) var dependents = "No dependent work yet."
    private(set) var lastError: String?
    private(set) var auditionLabel = "Audition stopped"
    private(set) var isAuditioning = false
    private(set) var isPreparingAudition = false
    private(set) var auditionPlayheadSeconds = 0.0
    var auditionStartSeconds = 0.0
    var auditionDurationSeconds = 5.0
    var editorRequest: AlignmentEditorRequest?
    var anchorSelection: Int?
    var requestedAnchorFocus: Int?
    var requestedEpochFocus: RecordingEpochID?
    private(set) var waveformTracks: [AlignmentWaveformTrack] = []
    private(set) var waveformRefusals: [AlignmentWaveformRefusal] = []
    private(set) var disabledGroups: Set<RecorderGroupID> = []
    private(set) var disabledTracks: Set<SourceID> = []
    var groupDraftMilliseconds = 0.0
    private(set) var selectedWaveformSource: SourceID?
    private(set) var isLoadingWaveforms = false
    private(set) var waveformOverviewTracks: [AlignmentWaveformTrack] = []
    private(set) var waveformOverviewRefusals: [AlignmentWaveformRefusal] = []
    private(set) var waveformOverviewMap: AlignedTimelineMap?
    private(set) var isLoadingOverview = false
    private(set) var waveformOverviewProgress = 0.0
    private(set) var waveformOverviewMessage = "Build Overview scans all covered PCM samples. It does not change or cache recordings."
    private(set) var waveformMessage = "Load a bounded audio window to see the recordings. Original files are never changed."
    var waveformStartSeconds = 0.0
    var waveformDurationSeconds = 5.0
    var waveformPlayheadSeconds = 0.0
    var waveformOffsetMilliseconds = 0.0 {
        didSet { if !resettingWaveformTiming, waveformOffsetMilliseconds != oldValue { waveformTimingIsDraft = true } }
    }
    var waveformRatePPM = 0.0 {
        didSet { if !resettingWaveformTiming, waveformRatePPM != oldValue { waveformTimingIsDraft = true } }
    }
    private(set) var waveformTimingIsDraft = false
    @ObservationIgnored private var resettingWaveformTiming = false
    var waveformReferencePoint = 0.0
    var waveformTargetPoint = 0.0
    var waveformAuditionChannel = 0
    private(set) var waveformDraftAnchors: [AlignmentAnchor] = []
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var waveformGeneration: UInt64 = 0
    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var overviewGeneration: UInt64 = 0
    private var loadedOverviewEpisode: Episode?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionGeneration: UInt64 = 0
    private var loadedWaveformMap: AlignedTimelineMap?
    private var loadedWaveformEpisode: Episode?
    private var anchorsByEpoch: [RecordingEpochID: [AlignmentAnchorRow]] = [:]
    private var acceptedMap: AlignedTimelineMap?

    let episodeID: EpisodeID
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let auditionEngine = AVAudioEngine()
    @ObservationIgnored private let transportPlayer = AVAudioPlayerNode()
    @ObservationIgnored private var auditionSource: AVAudioSourceNode?
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
    @ObservationIgnored private var auditionGeneration: UInt64 = 0
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var transportProgressTask: Task<Void, Never>?
    @ObservationIgnored private var auditionStopTask: Task<Void, Never>?
    @ObservationIgnored private var auditionStartedAt: Date?
    @ObservationIgnored private var auditionPlaybackStartSeconds = 0.0
    @ObservationIgnored private var auditionPlaybackDurationSeconds = 0.0

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
    }

    var selectedRow: AlignmentRow? {
        rows.first { $0.epochID == selection }
    }

    var waveformMap: AlignedTimelineMap? { loadedWaveformMap }
    func trackIdentity(_ source: SourceID) -> (label: String, color: Color) {
        let references = document?.store.model.episode(episodeID)?.references(to: source) ?? []
        guard let reference = references.first,
              let speakers = document?.store.model.speakers,
              let index = speakers.firstIndex(where: { $0.id == reference.speakerID })
        else { return ("Unknown speaker", .gray) }
        let palette: [Color] = [.blue, .purple, .green, .pink, .cyan, .indigo, .mint, .brown]
        let role = reference.isPrimary ? "Primary" : "Backup"
        return ("\(speakers[index].name) · \(role)", palette[index % palette.count])
    }
    var enabledSources: [SourceID] {
        waveformTracks.filter { !disabledGroups.contains($0.group) && !disabledTracks.contains($0.id) }
            .map(\.id)
    }
    var enabledTimelineEnd: Double {
        guard let map = loadedWaveformMap else { return 0 }
        let sources = Set(enabledSources)
        return map.groups.flatMap { group in
            let epochs = Set(group.placements.filter { sources.contains($0.occurrence.source) }
                .flatMap { $0.spans.map(\.epoch) })
            return group.epochs.filter { epochs.contains($0.epoch) }.flatMap { epoch -> [Double] in
                guard case let .mapped(segments, _) = epoch.mapping else { return [] }
                return segments.compactMap {
                    try? $0.rateRatio.multiplied(by: $0.groupClockEnd)
                        .adding($0.alignedOffset).approximateDouble
                }
            }
        }.max() ?? 0
    }
    func groupEnabled(_ group: RecorderGroupID) -> Bool { !disabledGroups.contains(group) }
    func trackEnabled(_ source: SourceID) -> Bool { !disabledTracks.contains(source) }
    func setGroup(_ group: RecorderGroupID, enabled: Bool) {
        stopAudition()
        if enabled { disabledGroups.remove(group) } else { disabledGroups.insert(group) }
    }
    func setTrack(_ source: SourceID, enabled: Bool) {
        stopAudition()
        if enabled { disabledTracks.remove(source) } else { disabledTracks.insert(source) }
    }
    var canMoveGroup: Bool {
        guard let row = selectedRow, !isWorking, !isLoadingWaveforms else { return false }
        let reference = loadedWaveformMap?.reference.group
            ?? document?.store.model.episode(episodeID)?.recorderGroups.first?.id
        return row.groupID != reference
            && waveformTracks.contains(where: { $0.group == row.groupID })
            && (loadedWaveformMap == nil || loadedWaveformMap?.groups
                .first(where: { $0.group == row.groupID })?.epochs.contains(where: {
                    if case .mapped = $0.mapping { return true }
                    return false
                }) == true)
    }
    func commitGroupMove() {
        guard let document, let row = selectedRow, canMoveGroup,
              groupDraftMilliseconds.isFinite,
              abs(groupDraftMilliseconds) >= 0.001,
              abs(groupDraftMilliseconds) < Double(Int64.max) / 1_000
        else { return }
        let delta = Int64((groupDraftMilliseconds * 1_000).rounded())
        let prior = document.store.model
        let group = row.groupID
        isWorking = true
        stopAudition()
        Task {
            do {
                let accepted: AcceptedAlignment
                if prior.episode(episodeID)?.alignment?.acceptedRevision != nil {
                    accepted = try await runtime.shiftGroup(
                        model: prior, episode: episodeID, group: group, milliseconds: delta
                    )
                } else {
                    let report = try await runtime.prepareManual(model: prior, episode: episodeID)
                    guard group != report.plan.reference?.group else {
                        throw AlignmentAcceptanceError.invalidMap("The reference recorder cannot be moved.")
                    }
                    let decisions = Self.initialDecisions(
                        report, moving: group, milliseconds: Double(delta) / 1_000
                    )
                    accepted = try await runtime.accept(
                        model: prior, episode: episodeID, decisions: decisions
                    )
                }

                guard document.store.applyReplacement(
                    UndoActionName.editEpochTiming, expecting: prior, model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                ) else {
                    message = SharedModelPublication.supersededCorrectionMessage
                    isWorking = false
                    return
                }
                groupDraftMilliseconds = 0
                acceptedMap = accepted.map
                rows = Self.makeRows(model: accepted.model, episodeID: episodeID, states: [], map: accepted.map)
                message = "Recorder group moved as one undoable map revision; saving and verifying the show."
                cancelWaveforms()
            } catch {
                lastError = String(describing: error)
                message = "The recorder group was not moved: \(error)."
            }
            isWorking = false
        }
    }

    private static func initialDecisions(
        _ report: AlignmentAnalysisReport,
        moving group: RecorderGroupID? = nil,
        milliseconds: Double = 0
    ) -> [RecordingEpochID: EpochMapDecision] {
        var seen: Set<RecorderGroupID> = []
        var decisions: [RecordingEpochID: EpochMapDecision] = [:]
        for epoch in report.plan.epochs where epoch.group != report.plan.reference?.group {
            guard !seen.contains(epoch.group),
                  epoch.eligibleSources.contains(where: { report.facts[$0] != nil })
            else { continue }
            seen.insert(epoch.group)
            decisions[epoch.epoch] = .numeric(
                ppm: 0, offsetMilliseconds: epoch.group == group ? milliseconds : 0
            )
        }
        return decisions
    }

    func placeGroupsAtSourceTime() {
        guard let document, !isWorking,
              document.store.model.episode(episodeID)?.alignment?.acceptedRevision == nil else { return }
        let prior = document.store.model
        isWorking = true
        Task {
            do {
                let report = try await runtime.prepareManual(model: prior, episode: episodeID)
                let decisions = Self.initialDecisions(report)
                let accepted = try await runtime.accept(
                    model: prior, episode: episodeID, decisions: decisions
                )
                guard document.store.applyReplacement(
                    UndoActionName.editEpochTiming, expecting: prior, model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                ) else {
                    message = SharedModelPublication.supersededCorrectionMessage
                    isWorking = false
                    return
                }
                acceptedMap = accepted.map
                rows = Self.makeRows(model: accepted.model, episodeID: episodeID, states: [], map: accepted.map)
                message = "Source-time placement accepted. Move recorder groups to align them; the show is being verified."
            } catch {
                lastError = String(describing: error)
                message = "Initial manual placement was refused: \(error)."
            }
            isWorking = false
        }
    }
    var waveformMapRevision: Int? {
        guard loadedWaveformMap != nil else { return nil }
        return document?.store.model.episode(episodeID)?.alignment?.acceptedRevision
    }

    var selectedWaveform: AlignmentWaveformTrack? {
        guard let row = selectedRow else { return nil }
        return waveformTracks.first { track in
            guard track.id == selectedWaveformSource, track.group == row.groupID else { return false }
            return AlignmentWaveformProjection.containsSelectedEpoch(
                source: track.id, group: track.group, initialEpoch: track.epoch,
                selectedEpoch: row.epochID, map: loadedWaveformMap
            )
        }
    }

    var canCompareAligned: Bool {
        guard !isWorking, !isLoadingWaveforms, !isLoadingOverview,
              let row = selectedRow, let track = selectedWaveform,
              let map = loadedWaveformMap, track.group != map.reference.group,
              let epoch = map.groups.first(where: { $0.group == track.group })?.epochs.first(where: { $0.epoch == row.epochID }),
              case .mapped = epoch.mapping
        else { return false }
        return true
    }

    func resetWaveformTiming() {
        resettingWaveformTiming = true
        defer { resettingWaveformTiming = false }
        let defaults = numericEditorDefaults
        waveformOffsetMilliseconds = defaults.offsetMilliseconds
        waveformRatePPM = defaults.ratePPM
        waveformDraftAnchors = []
        waveformAuditionChannel = 0
        waveformTimingIsDraft = false
        groupDraftMilliseconds = 0
    }

    func selectWaveform(_ track: AlignmentWaveformTrack, epoch: RecordingEpochID? = nil) {
        let chosenEpoch = epoch ?? track.epoch
        if selection != chosenEpoch || selectedWaveformSource != track.id {
            selection = chosenEpoch
            selectedWaveformSource = track.id
            resetWaveformTiming()
            stopAudition()
        }
    }

    func loadWaveforms() {
        guard let document else { return }
        cancelWaveforms()
        let generation = waveformGeneration
        let snapshot = document.store.model
        let start = waveformStartSeconds
        let duration = waveformDurationSeconds
        lastError = nil
        isLoadingWaveforms = true
        waveformMessage = "Reading a bounded window through the read-only source gateway…"
        waveformTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == waveformGeneration {
                    isLoadingWaveforms = false
                    waveformTask = nil
                }
            }
            do {
                let loaded = try await runtime.waveformTracks(
                    model: snapshot, episode: episodeID,
                    startSeconds: start, durationSeconds: duration
                )
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "WWUITestHooks"),
                   UserDefaults.standard.bool(forKey: "WWUITestVisualAlignmentFixture"),
                   UserDefaults.standard.bool(forKey: "WWUITestDelayWaveformPublication") {
                    try await Task.sleep(for: .seconds(3))
                }
                #endif
                try Task.checkCancellation()
                guard generation == waveformGeneration else { return }
                guard document.store.model == snapshot else {
                    waveformMessage = "The episode changed while loading. Load the current audio window again."
                    return
                }
                waveformTracks = loaded.tracks
                disabledTracks.formIntersection(Set(loaded.tracks.map(\.id)))
                disabledGroups.formIntersection(Set(loaded.tracks.map(\.group)))
                waveformRefusals = loaded.refusals
                loadedWaveformMap = loaded.map
                loadedWaveformEpisode = snapshot.episode(episodeID)
                waveformMessage = loaded.mapWarning
                    ?? "\(loaded.tracks.count) recordings loaded; \(loaded.refusals.count) unavailable. This is a measured snapshot, not an alignment proposal."
            } catch is CancellationError {
                if generation == waveformGeneration { waveformMessage = "Waveform loading cancelled." }
            } catch {
                guard generation == waveformGeneration else { return }
                waveformMessage = "Waveforms unavailable: \(error.localizedDescription)"
                lastError = String(describing: error)
            }
        }
    }

    func cancelWaveforms() {
        waveformGeneration += 1
        waveformTask?.cancel()
        waveformTask = nil
        isLoadingWaveforms = false
        waveformTracks = []
        waveformRefusals = []
        loadedWaveformMap = nil
    }

    func loadWaveformOverview() {
        guard let document else { return }
        cancelWaveformOverview()
        stopAudition()
        let generation = overviewGeneration
        let snapshot = document.store.model
        isLoadingOverview = true
        waveformOverviewMessage = "Scanning every covered PCM sample; no partial overview is published."
        overviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == overviewGeneration {
                    isLoadingOverview = false
                    overviewTask = nil
                }
            }
            do {
                let loaded = try await runtime.waveformTracks(
                    model: snapshot, episode: episodeID, startSeconds: 0, durationSeconds: 1, overview: true
                ) { fraction in
                    try await self.updateOverviewProgress(fraction, generation: generation, snapshot: snapshot)
                }
                try Task.checkCancellation()
                guard generation == overviewGeneration else { return }
                guard document.store.model == snapshot else {
                    waveformOverviewMessage = "The episode changed. Build its current overview again."
                    return
                }
                waveformOverviewTracks = loaded.tracks
                waveformOverviewRefusals = loaded.refusals
                waveformOverviewMap = loaded.map
                loadedOverviewEpisode = snapshot.episode(episodeID)
                waveformOverviewProgress = 1
                waveformOverviewMessage = loaded.mapWarning
                    ?? "\(loaded.tracks.count) complete PCM overviews; \(loaded.refusals.count) unavailable. Click covered audio to load an exact window; coarse bins are not anchors."
            } catch is CancellationError {
                if generation == overviewGeneration {
                    waveformOverviewMessage = "Overview cancelled or episode changed. No partial result was kept."
                }
            } catch {
                guard generation == overviewGeneration else { return }
                waveformOverviewMessage = "Overview unavailable: \(error.localizedDescription)"
                lastError = String(describing: error)
            }
        }
    }

    private func updateOverviewProgress(
        _ fraction: Double, generation: UInt64, snapshot: ShowDocumentModel
    ) throws {
        guard generation == overviewGeneration, document?.store.model == snapshot else {
            throw CancellationError()
        }
        if fraction >= waveformOverviewProgress + 0.01 || fraction == 1 {
            waveformOverviewProgress = fraction
        }
    }

    func cancelWaveformOverview() {
        overviewGeneration += 1
        overviewTask?.cancel()
        overviewTask = nil
        isLoadingOverview = false
        waveformOverviewTracks = []
        waveformOverviewRefusals = []
        waveformOverviewMap = nil
        loadedOverviewEpisode = nil
        waveformOverviewProgress = 0
        waveformOverviewMessage = "Overview cleared. Original recordings stay unchanged."
    }

    func navigateWaveformOverview(to time: Double) {
        guard let start = AlignmentWaveformProjection.windowStart(
            centeredAt: time, duration: waveformDurationSeconds
        ) else {
            waveformOverviewMessage = "Choose covered audio between zero and 24 aligned hours."
            return
        }
        seekEnabledTracks(to: time)
        waveformStartSeconds = start
        loadWaveforms()
    }

    func suspend() {
        cancelWaveforms()
        cancelWaveformOverview()
        inspectionGeneration += 1
        inspectionTask?.cancel()
        inspectionTask = nil
        stopAudition()
    }

    func playEnabledTracks() {
        guard let document, !isWorking, !isLoadingWaveforms, !enabledSources.isEmpty,
              loadedWaveformMap != nil, groupDraftMilliseconds == 0,
              !waveformTimingIsDraft, waveformPlayheadSeconds.isFinite,
              waveformPlayheadSeconds >= 0, waveformPlayheadSeconds < enabledTimelineEnd
        else {
            auditionLabel = "Place and apply timing before playing; only confirmed, enabled tracks can be heard."
            return
        }
        stopAudition()
        let snapshot = document.store.model
        let sources = enabledSources
        let generation = auditionGeneration
        transportTask = Task { [weak self] in
            guard let self else { return }
            var position = waveformPlayheadSeconds
            let end = min(enabledTimelineEnd, 86_400)
            let start = position
            while !Task.isCancelled, generation == auditionGeneration, position < end {
                do {
                    isPreparingAudition = true
                    if !isAuditioning {
                        auditionLabel = "Preparing enabled tracks at the displayed map revision…"
                    }
                    let duration = min(AlignedAuditionWindowReader.maximumDurationSeconds, end - position)
                    let clip = try await runtime.mixedAudition(
                        model: snapshot, episode: episodeID, enabled: sources,
                        startSeconds: position, durationSeconds: duration
                    )
                    try Task.checkCancellation()
                    guard generation == auditionGeneration, document.store.model == snapshot,
                          enabledSources == sources else { throw CancellationError() }
                    isPreparingAudition = false
                    try enqueueTransport(clip, startSeconds: position, first: !isAuditioning)
                    isAuditioning = true
                    auditionLabel = "Playing \(sources.count) enabled tracks on the stored timeline."
                    if transportProgressTask == nil {
                        transportProgressTask = Task { [weak self] in
                            while let self, !Task.isCancelled, generation == auditionGeneration,
                                  isAuditioning, let started = auditionStartedAt {
                                waveformPlayheadSeconds = min(end, start + max(0, -started.timeIntervalSinceNow))
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    }
                    position += Double(clip.samples.count) / clip.sampleRate
                    while let started = auditionStartedAt,
                          position - start - max(0, -started.timeIntervalSinceNow)
                            >= 2 * AlignedAuditionWindowReader.maximumDurationSeconds {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == auditionGeneration else { return }
                    lastError = String(describing: error)
                    stopPlayback(updatePlayhead: true)
                    auditionLabel = "Playback stopped: \(error). No substitute audio was played."
                    return
                }
            }
            guard generation == auditionGeneration else { return }
            while let started = auditionStartedAt,
                  max(0, -started.timeIntervalSinceNow) < position - start {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard generation == auditionGeneration else { return }
            stopPlayback(updatePlayhead: true)
            waveformPlayheadSeconds = auditionPlayheadSeconds
            auditionLabel = "Playback reached the end of the available timeline."
        }
    }

    func pauseEnabledTracks() {
        stopAudition()
        waveformPlayheadSeconds = auditionPlayheadSeconds
    }

    func stopEnabledTracks() {
        stopAudition()
        waveformPlayheadSeconds = waveformStartSeconds
    }

    func seekEnabledTracks(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else {
            waveformPlayheadSeconds = auditionPlayheadSeconds
            auditionLabel = "Choose an aligned playhead between zero and 24 hours."
            return
        }
        let wasPlaying = canStopAudition
        stopAudition()
        waveformPlayheadSeconds = seconds
        auditionPlayheadSeconds = seconds
        if wasPlaying { playEnabledTracks() }
    }

    func compareAlignedAtPlayhead() {
        guard let document, let track = selectedWaveform, canCompareAligned,
              !canStopAudition, waveformPlayheadSeconds.isFinite, waveformPlayheadSeconds >= 0
        else { return }
        let snapshot = document.store.model
        let start = waveformPlayheadSeconds
        let duration = min(waveformDurationSeconds, AlignedAuditionWindowReader.maximumDurationSeconds)
        let channel = waveformAuditionChannel
        auditionGeneration += 1
        let generation = auditionGeneration
        isPreparingAudition = true
        auditionLabel = "Preparing an aligned reference/target comparison. Nothing is exported."
        auditionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == auditionGeneration {
                    isPreparingAudition = false
                    auditionTask = nil
                }
            }
            do {
                let clip = try await runtime.alignedAudition(
                    model: snapshot, episode: episodeID, target: track.id,
                    targetChannel: channel, startSeconds: start, durationSeconds: duration
                )
                try Task.checkCancellation()
                guard generation == auditionGeneration else { return }
                guard document.store.model == snapshot else {
                    throw CocoaError(.userCancelled)
                }
                try play(clip, startSeconds: start)
                isAuditioning = true
                auditionLabel = "Aligned comparison: reference channel 1 left, selected channel \(channel + 1) right. Uncovered map regions are silent. Nothing is exported."
            } catch {
                guard generation == auditionGeneration else { return }
                stopPlayback(updatePlayhead: false)
                if Task.isCancelled { return }
                lastError = String(describing: error)
                auditionLabel = "Aligned comparison unavailable: \(error). No partial audio was played."
            }
        }
    }

    func addWaveformAnchor() {
        guard waveformReferencePoint.isFinite, waveformTargetPoint.isFinite,
              waveformTargetPoint >= 0 else {
            lastError = "Anchor times must be finite, with a non-negative target source time."
            return
        }
        waveformDraftAnchors.removeAll { $0.sourceSeconds == waveformTargetPoint }
        waveformDraftAnchors.append(AlignmentAnchor(
            sourceSeconds: waveformTargetPoint, alignedSeconds: waveformReferencePoint
        ))
        waveformDraftAnchors.sort { $0.sourceSeconds < $1.sourceSeconds }
    }

    func applyWaveformAnchors() {
        guard waveformDraftAnchors.count >= 2 else { return }
        placeAnchors(waveformDraftAnchors)
    }

    var canCorrect: Bool {
        guard let row = selectedRow else { return false }
        return !isWorking && row.state.remedies.contains("Edit Numerically…")
    }
    /// Splitting at an endpoint produces an empty span, which the pipeline rejects. Only an anchor
    /// strictly inside the selected occurrence's span can start a new epoch.
    var canStartNewEpoch: Bool {
        !isWorking && selectedAnchorSplit() != nil
    }
    var canAudition: Bool {
        selectedRow?.state.remedies.contains("Audition") == true && !isWorking
    }
    var canStopAudition: Bool { isPreparingAudition || isAuditioning }
    var canPlaceAnchorAtPlayhead: Bool {
        !isWorking && !isAuditioning && selectedAnchors.count >= 2
            && alignedTime(atSourceSeconds: auditionPlayheadSeconds) != nil
    }
    var selectedAnchors: [AlignmentAnchorRow] {
        guard let selection else { return [] }
        return anchorsByEpoch[selection] ?? []
    }
    var selectedRegion: AlignmentRegionPresentation? {
        AlignmentRegionProjection.project(
            map: acceptedMap,
            row: selectedRow,
            sourceSeconds: auditionStartSeconds
        )
    }
    var numericEditorDefaults: (ratePPM: Double, offsetMilliseconds: Double) {
        AlignmentEditorDefaults.numeric(row: selectedRow)
    }
    var anchorEditorDefaults: [AlignmentAnchor] {
        AlignmentEditorDefaults.anchors(
            existing: selectedAnchors,
            map: acceptedMap,
            row: selectedRow
        )
    }

    func requestNumericEditor() {
        guard canCorrect else { return }
        editorRequest = .numeric
    }

    func requestAnchorEditor() {
        guard canCorrect else { return }
        editorRequest = .anchors
    }

    /// Opens the focused single-anchor editor for the selected anchor. The Anchors table itself is
    /// read-only: an inline editor inside the clipped table proved unreachable by keyboard (#219).
    func requestSelectedAnchorEditor() {
        guard let anchorSelection,
              selectedAnchors.contains(where: { $0.id == anchorSelection })
        else { return }
        editorRequest = .anchor(anchorSelection)
    }

    /// The anchor the single-anchor editor is editing, if that sheet is open.
    var editedAnchor: AlignmentAnchorRow? {
        guard case let .anchor(anchorID)? = editorRequest else { return nil }
        return selectedAnchors.first { $0.id == anchorID }
    }

    /// One output frame of the selected occurrence, for ↑/↓ nudges in the anchor editor (spec §4.1).
    var alignedNudgeSeconds: Double {
        guard let row = selectedRow, let map = acceptedMap,
              let group = map.groups.first(where: { $0.group == row.groupID }),
              let placement = group.placements.first(where: {
                  $0.spans.contains(where: { $0.epoch == row.epochID })
              })
        else { return 0.001 }
        let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
        return rate > 0 ? 1 / rate : 0.001
    }

    /// Returns keyboard focus to the anchor row after the single-anchor editor closes.
    func restoreAnchorFocus(to anchorID: Int) {
        guard selectedAnchors.contains(where: { $0.id == anchorID }) else { return }
        anchorSelection = anchorID
        requestedAnchorFocus = anchorID
    }

    func placeAnchorAtPlayhead() {
        guard canPlaceAnchorAtPlayhead,
              let alignedSeconds = alignedTime(atSourceSeconds: auditionPlayheadSeconds)
        else { return }
        let anchors = selectedAnchors.map {
            AlignmentAnchor(
                sourceSeconds: $0.sourceSeconds,
                alignedSeconds: $0.alignedSeconds
            )
        }
        guard !anchors.contains(where: {
            abs($0.sourceSeconds - auditionPlayheadSeconds) < 0.000_000_5
        }) else {
            message = "An anchor already exists at the current audition position."
            return
        }
        placeAnchors(
            anchors + [AlignmentAnchor(
                sourceSeconds: auditionPlayheadSeconds,
                alignedSeconds: alignedSeconds
            )],
            focusSourceSeconds: auditionPlayheadSeconds
        )
    }

    func goToRegionRemedy(_ remedy: String) {
        guard let region = selectedRegion else { return }
        switch remedy {
        case "Go to Epoch Before":
            if let epoch = region.precedingEpoch { selection = epoch }
        case "Go to Epoch After":
            if let epoch = region.followingEpoch { selection = epoch }
        case "Go to Nearest Mapped Time":
            if let time = region.nearestSourceSeconds {
                auditionStartSeconds = time
                auditionPlayheadSeconds = time
            }
        default:
            break
        }
    }

    func startNewEpochAtSelectedAnchor() {
        guard let document, !isWorking else { return }
        guard let split = selectedAnchorSplit() else {
            reportSplitRefusal()
            return
        }
        let row = split.row
        let placement = split.placement
        let frame = split.frame
        let keptAnchorSelection = split.anchor.id
        let prior = document.store.model
        var model = prior
        guard let episodeIndex = model.episodes.firstIndex(where: { $0.id == episodeID }),
              let groupIndex = model.episodes[episodeIndex].recorderGroups.firstIndex(where: { $0.id == row.groupID })
        else { return }
        let next = model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.count + 1
        let epoch = RecordingEpoch(label: "Epoch \(next)", note: "Started at a manual anchor")
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(epoch)
        isWorking = true
        lastError = nil
        Task {
            do {
                try await withCheckedThrowingContinuation { continuation in
                    document.persistExpectedModel(prior) { result in
                        continuation.resume(with: result)
                    }
                }
                guard document.store.model == prior else { throw CocoaError(.userCancelled) }
                try await runtime.activate(model: prior, episode: episodeID)
                let accepted = try await runtime.split(
                    model: model, episode: episodeID, group: row.groupID,
                    source: placement.occurrence.source, epoch: row.epochID,
                    frame: frame, newEpoch: epoch.id
                )
                if document.store.applyReplacement(
                    UndoActionName.startNewEpochAtAnchor,
                    expecting: prior,
                    model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                ) {
                    selection = epoch.id
                    anchorSelection = nil
                    acceptedMap = accepted.map
                    rows = Self.makeRows(
                        model: accepted.model, episodeID: episodeID, states: [],
                        map: accepted.map
                    )
                    requestedEpochFocus = epoch.id
                    message = "Started \(epoch.label) at the selected anchor. The new epoch is unsupported until you time it."
                } else {
                    anchorSelection = keptAnchorSelection
                    // `accepted.model` replaces the whole show, and every window shares this store: the
                    // activation and the split above each suspend, so an edit made meanwhile is already
                    // live. The store refuses the stale replacement; say so rather than fail silently.
                    if SharedModelPublication.decide(live: document.store.model, expected: prior) == .superseded {
                        message = SharedModelPublication.supersededSplitMessage
                    }
                }
            } catch {
                anchorSelection = keptAnchorSelection
                lastError = String(describing: error)
                message = "The occurrence was not split."
            }
            isWorking = false
        }
    }

    /// The selected anchor resolved to a split point, or nil when no anchor can start a new epoch.
    /// A split needs a frame strictly inside the selected occurrence's span: splitting at either
    /// endpoint would leave an empty span, which the pipeline rejects.
    private func selectedAnchorSplit() -> AnchorSplit? {
        guard let row = selectedRow, let selectedAnchorID = anchorSelection,
              let anchor = selectedAnchors.first(where: { $0.id == selectedAnchorID }),
              let map = acceptedMap,
              let group = map.groups.first(where: { $0.group == row.groupID }),
              let placement = group.placements.first(where: {
                  $0.spans.contains(where: { $0.epoch == row.epochID })
              }),
              let span = placement.spans.first(where: { $0.epoch == row.epochID })
        else { return nil }
        let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
        guard rate > 0, anchor.sourceSeconds.isFinite else { return nil }
        let frameValue = (anchor.sourceSeconds * rate).rounded()
        guard frameValue > Double(span.startFrame), frameValue < Double(span.endFrame) else { return nil }
        return AnchorSplit(
            anchor: anchor, row: row, placement: placement, frame: Int64(frameValue)
        )
    }

    /// Explains why the selected anchor cannot start a new epoch, so the refusal is never silent.
    private func reportSplitRefusal() {
        guard let row = selectedRow else {
            message = "Select an epoch before starting a new epoch at an anchor."
            return
        }
        guard let selectedAnchorID = anchorSelection,
              let anchor = selectedAnchors.first(where: { $0.id == selectedAnchorID })
        else {
            message = "Select an anchor in the Anchors table before starting a new epoch."
            return
        }
        guard acceptedMap != nil else {
            message = "Time this epoch before starting a new epoch at an anchor."
            return
        }
        message = "The anchor at \(AlignmentPresentation.formatTime(anchor.sourceSeconds)) is an endpoint of "
            + "\(row.epochLabel)'s recorded span. Select an anchor inside the span to start a new epoch there."
    }

    private struct AnchorSplit {
        var anchor: AlignmentAnchorRow
        var row: AlignmentRow
        var placement: OccurrencePlacement
        var frame: Int64
    }

    func auditionSelection() {
        guard let epoch = selection, canAudition, !isAuditioning,
              auditionStartSeconds.isFinite, auditionStartSeconds >= 0,
              auditionDurationSeconds.isFinite, auditionDurationSeconds > 0
        else { return }
        stopAudition()
        let generation = auditionGeneration
        isPreparingAudition = true
        auditionLabel = "Preparing the selected internal audition range. Nothing is exported."
        auditionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == auditionGeneration {
                    isPreparingAudition = false
                    auditionTask = nil
                }
            }
            do {
                let clip = try await runtime.audition(
                    episode: episodeID, epoch: epoch,
                    startSeconds: auditionStartSeconds,
                    durationSeconds: auditionDurationSeconds
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingAudition,
                              self.auditionGeneration == generation else { return }
                        self.auditionLabel = "Seeking through the source… \(Int(progress * 100))%. Nothing is exported."
                    }
                }
                try Task.checkCancellation()
                guard generation == auditionGeneration else { return }
                try play(clip)
                try Task.checkCancellation()
                isAuditioning = true
                auditionLabel = "Auditioning the selected source region as an internal check. Nothing is exported."
            } catch is CancellationError {
                if generation == auditionGeneration { stopPlayback(updatePlayhead: true) }
            } catch {
                guard generation == auditionGeneration else { return }
                lastError = String(describing: error)
                auditionLabel = (error as? LocalizedError)?.errorDescription
                    ?? "Audition unavailable for this source."
            }
        }
    }

    func load() {
        guard let document else { return }
        inspectionGeneration += 1
        let generation = inspectionGeneration
        inspectionTask?.cancel()
        let model = document.store.model
        let episode = model.episode(episodeID)
        if let loaded = loadedOverviewEpisode, loaded != episode {
            cancelWaveformOverview()
            waveformOverviewMessage = "Episode timing or sources changed. Build the current overview again."
        }
        if let loaded = loadedWaveformEpisode,
           loaded.sources != episode?.sources || loaded.recorderGroups != episode?.recorderGroups {
            cancelWaveforms()
            stopAudition()
            waveformMessage = "Source assignments changed. Load the current audio window again."
        }
        let interval = Responsiveness.begin("alignment.episodeSwitch")
        inspectionTask = Task {
            let prepared = await runtime.inspect(model: model, episode: episodeID)
            guard document.store.model == model else { return }
            guard !Task.isCancelled, generation == inspectionGeneration,
                  document.store.model == model else { return }
            let snapshot = prepared.snapshot
            acceptedMap = snapshot?.acceptedMap
            hasAnalysis = snapshot?.acceptedMap != nil
            rows = Self.makeRows(
                model: model,
                episodeID: episodeID,
                states: snapshot?.states ?? [],
                map: snapshot?.acceptedMap
            )
            if selection == nil { selection = rows.first?.epochID }
            anchorsByEpoch = Self.makeAnchors(map: snapshot?.acceptedMap)
            resetWaveformTiming()
            if !waveformTracks.isEmpty, loadedWaveformEpisode?.alignment != episode?.alignment {
                stopAudition()
                loadWaveforms()
            }
            if !selectedAnchors.contains(where: { $0.id == anchorSelection }) {
                anchorSelection = selectedAnchors.first?.id
            }
            await updateDependents()
            if let warning = prepared.reconciliationWarning {
                message = "The persisted map is visible, but its derived identity could not be restored: \(warning)"
            }
            if let interval { Responsiveness.endAfterCommit(interval) }
        }
    }

    func analyse() {
        guard let document, !isWorking else { return }
        isWorking = true
        lastError = nil
        message = "Analysing available sources…"
        let model = document.store.model
        Task {
            do {
                let report = try await runtime.analyse(model: model, episode: episodeID)
                let states = await runtime.states(model: model, episode: episodeID)
                hasAnalysis = true
                rows = Self.makeRows(model: model, episodeID: episodeID, states: states)
                selection = selection ?? rows.first?.epochID
                message = report.records.isEmpty
                    ? "Analysis completed. No current acoustic proposal was available; use anchors or numeric correction."
                    : "Analysis completed. Acoustic results are proposals for review, not clock approval."
            } catch {
                lastError = String(describing: error)
                message = "Analysis did not complete. No partial result was accepted."
            }
            isWorking = false
        }
    }

    func applyNumeric(ratePPM: Double, offsetMilliseconds: Double) {
        guard let epoch = selection else { return }
        accept(actionName: UndoActionName.editEpochTiming, decisions: [
            epoch: .numeric(ppm: ratePPM, offsetMilliseconds: offsetMilliseconds),
        ])
    }

    func acceptProposal() {
        guard let epoch = selection else { return }
        accept(actionName: UndoActionName.acceptProposal, decisions: [epoch: .acceptProposal()])
    }

    func rejectProposal() {
        guard let epoch = selection else { return }
        accept(actionName: UndoActionName.rejectProposal, decisions: [epoch: .unmapped])
    }

    func placeAnchors(
        _ anchors: [AlignmentAnchor],
        focusSourceSeconds: Double? = nil
    ) {
        guard let epoch = selection else { return }
        accept(
            actionName: UndoActionName.placeAnchor,
            decisions: [epoch: .anchors(anchors)]
        ) { [weak self] in
            guard let self, let focusSourceSeconds,
                  let focused = self.anchorsByEpoch[epoch]?.min(by: {
                      abs($0.sourceSeconds - focusSourceSeconds)
                          < abs($1.sourceSeconds - focusSourceSeconds)
                  })
            else { return }
            self.anchorSelection = focused.id
            self.editorRequest = .anchor(focused.id)
        }
    }

    func stopAudition() {
        auditionGeneration += 1
        transportTask?.cancel()
        transportTask = nil
        transportProgressTask?.cancel()
        transportProgressTask = nil
        auditionTask?.cancel()
        auditionTask = nil
        isPreparingAudition = false
        auditionStopTask?.cancel()
        auditionStopTask = nil
        stopPlayback(updatePlayhead: true)
    }

    private func stopPlayback(updatePlayhead: Bool) {
        if updatePlayhead, isAuditioning, let auditionStartedAt {
            let elapsed = max(0, -auditionStartedAt.timeIntervalSinceNow)
            auditionPlayheadSeconds = auditionPlaybackStartSeconds
                + min(elapsed, auditionPlaybackDurationSeconds)
        }
        auditionEngine.stop()
        if auditionEngine.attachedNodes.contains(transportPlayer) {
            auditionEngine.detach(transportPlayer)
        }
        if let auditionSource, auditionEngine.attachedNodes.contains(auditionSource) {
            auditionEngine.detach(auditionSource)
        }
        auditionSource = nil
        auditionStartedAt = nil
        isAuditioning = false
        auditionLabel = "Audition stopped at \(AlignmentPresentation.formatTime(auditionPlayheadSeconds))."
    }

    private func alignedTime(atSourceSeconds sourceSeconds: Double) -> Double? {
        guard sourceSeconds.isFinite, sourceSeconds >= 0,
              let row = selectedRow,
              let map = acceptedMap,
              let group = map.groups.first(where: { $0.group == row.groupID }),
              let placement = group.placements.first(where: {
                  $0.spans.contains(where: { $0.epoch == row.epochID })
              })
        else { return nil }
        let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
        let frameValue = (sourceSeconds * rate).rounded(.down)
        guard frameValue >= 0, frameValue < Double(Int64.max),
              case let .aligned(position)? = try? map.alignedTime(
                  ofFrame: Int64(frameValue),
                  in: placement.occurrence.id
              )
        else { return nil }
        return position.instant.approximateDouble
    }

    private func play(
        _ clip: AlignmentRuntime.AuditionClip, startSeconds: Double? = nil,
        automaticallyStop: Bool = true
    ) throws {
        stopPlayback(updatePlayhead: false)
        guard !clip.samples.isEmpty,
              clip.channelCount > 0, clip.samples.count.isMultiple(of: clip.channelCount),
              let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: AVAudioChannelCount(clip.channelCount))
        else { throw CocoaError(.fileReadCorruptFile) }
        let cursor = AuditionSampleCursor(samples: clip.samples, channelCount: clip.channelCount)
        let source = cursor.makeSourceNode(format: format)
        auditionSource = source
        auditionEngine.attach(source)
        auditionEngine.connect(source, to: auditionEngine.mainMixerNode, format: format)
        try auditionEngine.start()
        auditionPlaybackStartSeconds = startSeconds ?? auditionStartSeconds
        auditionPlayheadSeconds = auditionPlaybackStartSeconds
        auditionPlaybackDurationSeconds = Double(clip.samples.count / clip.channelCount) / clip.sampleRate
        auditionStartedAt = Date()
        if automaticallyStop {
            auditionStopTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(auditionPlaybackDurationSeconds))
                guard !Task.isCancelled, isAuditioning else { return }
                stopAudition()
            }
        }
    }

    private func enqueueTransport(
        _ clip: AlignmentRuntime.AuditionClip, startSeconds: Double, first: Bool
    ) throws {
        guard clip.channelCount == 1, !clip.samples.isEmpty,
              clip.samples.count <= Int(AVAudioFrameCount.max),
              let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let samples = buffer.floatChannelData?.pointee
        else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { samples.update(from: base, count: values.count) }
        }
        if first {
            stopPlayback(updatePlayhead: false)
            auditionEngine.attach(transportPlayer)
            auditionEngine.connect(transportPlayer, to: auditionEngine.mainMixerNode, format: format)
            try auditionEngine.start()
            auditionPlaybackStartSeconds = startSeconds
            auditionPlayheadSeconds = startSeconds
            auditionPlaybackDurationSeconds = 0
            auditionStartedAt = Date()
        }
        transportPlayer.scheduleBuffer(buffer)
        auditionPlaybackDurationSeconds += Double(clip.samples.count) / clip.sampleRate
        if first { transportPlayer.play() }
    }

    func editAnchor(id: Int, alignedSeconds: Double) {
        guard let epoch = selection, alignedSeconds.isFinite,
              var anchors = anchorsByEpoch[epoch],
              let index = anchors.firstIndex(where: { $0.id == id })
        else { return }
        anchors[index].alignedSeconds = alignedSeconds
        accept(
            actionName: UndoActionName.editAnchorTime,
            decisions: [epoch: .anchors(anchors.map {
                AlignmentAnchor(sourceSeconds: $0.sourceSeconds, alignedSeconds: $0.alignedSeconds)
            })]
        ) { [weak self] in
            self?.anchorsByEpoch[epoch] = anchors
            self?.anchorSelection = id
        }
    }

    func requestDeleteSelectedAnchor() {
        guard let epoch = selection, let anchorSelection,
              let anchors = anchorsByEpoch[epoch],
              anchors.contains(where: { $0.id == anchorSelection })
        else { return }
        guard anchors.count <= 2 else {
            deleteSelectedAnchor()
            return
        }
        Task {
            guard await Dialogs.confirm(
                in: document?.windowControllers.first?.window,
                message: "Delete Anchor?",
                informative: "Deleting this anchor leaves fewer than two anchors, so this epoch will become unsupported until you add another anchor.",
                confirmTitle: "Delete Anchor",
                destructiveIsDefault: true
            ) else { return }
            deleteSelectedAnchor()
        }
    }

    private func deleteSelectedAnchor() {
        guard let epoch = selection, let anchorSelection,
              var anchors = anchorsByEpoch[epoch],
              let index = anchors.firstIndex(where: { $0.id == anchorSelection })
        else { return }
        anchors.remove(at: index)
        let decision: EpochMapDecision = anchors.count >= 2
            ? .anchors(anchors.map { AlignmentAnchor(sourceSeconds: $0.sourceSeconds, alignedSeconds: $0.alignedSeconds) })
            : .unmapped
        accept(
            actionName: UndoActionName.deleteAnchor,
            decisions: [epoch: decision]
        ) { [weak self] in
            self?.anchorsByEpoch[epoch] = anchors.count >= 2 ? anchors : []
            self?.anchorSelection = anchors.first?.id
            if anchors.count < 2 {
                self?.message = "Fewer than two anchors remain. Add at least one more anchor to time this epoch."
            }
        }
    }

    enum AlignmentEditorRequest: Identifiable, Equatable {
        case numeric
        case anchors
        /// Focused single-anchor editor for the anchor with this row id.
        case anchor(Int)

        var id: Int {
            switch self {
            case .numeric: -1
            case .anchors: -2
            case let .anchor(anchorID): anchorID
            }
        }
    }

    private func accept(
        actionName: String,
        decisions: [RecordingEpochID: EpochMapDecision],
        onAccepted: @escaping @MainActor () -> Void = {}
    ) {
        guard let document, !isWorking else { return }
        let prior = document.store.model
        isWorking = true
        lastError = nil
        Task {
            do {
                if prior.episode(episodeID)?.alignment?.acceptedRevision == nil,
                   !decisions.values.contains(where: {
                       if case .acceptProposal = $0 { return true }
                       return false
                   }) {
                    _ = try await runtime.prepareManual(model: prior, episode: episodeID)
                }
                let accepted = try await runtime.accept(model: prior, episode: episodeID, decisions: decisions)
                let applied = document.store.applyReplacement(
                    actionName,
                    expecting: prior,
                    model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                )
                if applied {
                    acceptedMap = accepted.map
                    rows = Self.makeRows(
                        model: accepted.model, episodeID: episodeID,
                        states: await runtime.states(model: accepted.model, episode: episodeID),
                        map: accepted.map
                    )
                    message = "Map revision \(accepted.revision.revision) will activate after the show is verified on disk."
                    anchorsByEpoch = Self.makeAnchors(map: accepted.map)
                    resetWaveformTiming()
                    onAccepted()
                    if actionName == UndoActionName.acceptProposal {
                        announce("Accepted proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    } else if actionName == UndoActionName.rejectProposal {
                        announce("Rejected proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    }
                } else if SharedModelPublication.decide(
                    live: document.store.model, expected: prior
                ) == .superseded {
                    // `accepted.model` replaces the whole show and the accept above suspends, so an edit
                    // made in another window meanwhile is already live. Refuse rather than overwrite it.
                    message = SharedModelPublication.supersededCorrectionMessage
                }
            } catch {
                lastError = String(describing: error)
                message = "The correction was not accepted."
            }
            isWorking = false
        }
    }

    private func persistenceCallback(
        document: ShowDocument,
        accepted: AcceptedAlignment
    ) -> @MainActor (ShowDocumentModel) -> Void {
        { [weak document, weak self, runtime, episodeID] model in
            guard let document else { return }
            document.persistExpectedModel(model) { result in
                switch result {
                case .success:
                    Task {
                        do {
                            if model == accepted.model {
                                try await runtime.activate(accepted)
                            } else {
                                try await runtime.activate(model: model, episode: episodeID)
                            }
                            await self?.updateDependents(announce: true)
                            self?.load()
                            self?.loadWaveforms()
                        }
                        catch { NSApp.presentError(error) }
                    }
                case let .failure(error):
                    NSApp.presentError(error)
                }
            }
        }
    }

    static func makeRows(
        model: ShowDocumentModel,
        episodeID: EpisodeID,
        states: [EpochAlignmentState],
        map: AlignedTimelineMap? = nil
    ) -> [AlignmentRow] {
        AlignmentRowsProjection.makeRows(
            model: model, episodeID: episodeID, states: states, map: map
        )
    }

    private func updateDependents(announce: Bool = false) async {
        let counts = await runtime.dependentCounts(episode: episodeID)
        if counts.total == 0 {
            dependents = "No dependent work yet."
        } else if counts.stale == 0 {
            dependents = "\(counts.total) dependent job\(counts.total == 1 ? "" : "s") current; none stale."
        } else {
            dependents = "\(counts.stale) of \(counts.total) dependent job\(counts.total == 1 ? "" : "s") stale."
        }
        if announce {
            self.announce(
                counts.stale == 0
                    ? "No dependent work is stale"
                    : "\(counts.stale) dependent job\(counts.stale == 1 ? "" : "s") now stale"
            )
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    static func makeAnchors(map: AlignedTimelineMap?) -> [RecordingEpochID: [AlignmentAnchorRow]] {
        guard let map else { return [:] }
        var result: [RecordingEpochID: [AlignmentAnchorRow]] = [:]
        for group in map.groups {
            for epoch in group.epochs {
                guard case let .mapped(segments, .manual(correction)) = epoch.mapping,
                      correction.basis == .anchors,
                      let segment = segments.first,
                      let placement = group.placements.first(where: {
                          $0.spans.contains(where: { $0.epoch == epoch.epoch })
                      }),
                      let span = placement.spans.first(where: { $0.epoch == epoch.epoch })
                else { continue }
                let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
                if let anchors = AlignmentAnchorNote.decode(correction.note), !anchors.isEmpty {
                    result[epoch.epoch] = anchors.sorted { $0.sourceSeconds < $1.sourceSeconds }
                        .enumerated().map { index, anchor in
                            AlignmentAnchorRow(
                                id: index,
                                sourceSeconds: anchor.sourceSeconds,
                                groupSeconds: anchor.sourceSeconds + span.groupClockOffset.approximateDouble,
                                alignedSeconds: anchor.alignedSeconds
                            )
                        }
                    continue
                }
                let sourceTimes = [
                    Double(span.startFrame) / rate,
                    Double(max(span.startFrame, span.endFrame - 1)) / rate,
                ]
                result[epoch.epoch] = sourceTimes.enumerated().compactMap { index, source in
                    let groupTime = source + span.groupClockOffset.approximateDouble
                    guard let groupRational = try? ExactRational(
                        numerator: Int128((groupTime * 1_000_000_000).rounded()),
                        denominator: 1_000_000_000
                    ), let aligned = try? segment.rateRatio.multiplied(by: groupRational)
                        .adding(segment.alignedOffset)
                    else { return nil }
                    return AlignmentAnchorRow(
                        id: index, sourceSeconds: source,
                        groupSeconds: groupTime, alignedSeconds: aligned.approximateDouble
                    )
                }
            }
        }
        return result
    }
}

/// Audio render callbacks run off the main actor; AVAudioSourceNode invokes this cursor serially.
private final class AuditionSampleCursor: @unchecked Sendable {
    private let samples: [Float]
    private let channelCount: Int
    private var frameCount: Int { samples.count / channelCount }
    private var index = 0

    init(samples: [Float], channelCount: Int) {
        self.samples = samples
        self.channelCount = channelCount
    }

    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, output in
            render(frameCount: frameCount, output: output)
        }
    }

    func render(frameCount: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let count = Int(frameCount)
        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<count {
                data[frame] = channel < channelCount && index + frame < self.frameCount
                    ? samples[channel * self.frameCount + index + frame] : 0
            }
        }
        index = min(self.frameCount, index + count)
        return noErr
    }
}
