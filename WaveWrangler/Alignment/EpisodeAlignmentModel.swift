import AppKit
import Foundation
import Observation
import SwiftUI
import WWAlignPipeline
import WWCore
import WWDerived
import WWEpisodeSetup
import WWOrganizer
import WWTimeMap
import WWMix

@MainActor
@Observable
final class EpisodeAlignmentModel {
    let listening: EpisodeListeningState
    private(set) var rows: [AlignmentRow] = []
    var selection: RecordingEpochID? {
        didSet {
            if selection != oldValue {
                selectedMatchSpeaker = nil
                selectedMatchOption = nil
                analysisStates = [:]
                selectedWaveformSource = nil
                resetWaveformTiming()
                stopAudition()
            }
        }
    }
    private(set) var isWorking = false
    private(set) var hasAnalysis = false
    var tracksReviewPresented = false
    private(set) var tracksReviewRows: [AlignmentRow] = []
    private(set) var tracksReviewProposals: Set<RecordingEpochID> = []
    var selectedTracksProposals: Set<RecordingEpochID> = []
    var selectedTracksAdaptive: Set<RecordingEpochID> = []
    private var tracksReport: AlignmentAnalysisReport?
    private var tracksSnapshot: ShowDocumentModel?
    var tracksReviewReferenceName: String? {
        guard let group = tracksReport?.plan.reference?.group else { return nil }
        return tracksSnapshot?.episode(episodeID)?.recorderGroup(group)?.name
    }
    func tracksAdaptiveRecord(for epoch: RecordingEpochID) -> AdaptiveAnalysisRecord? {
        tracksReport?.adaptiveRecords[epoch]
    }
    @ObservationIgnored private var tracksAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var tracksAcceptanceTask: Task<Void, Never>?
    @ObservationIgnored private var publicationGeneration = UUID()
    var isAnalyzingTracks: Bool { tracksAnalysisTask != nil }
    var canAcceptTracksReview: Bool {
        guard !isWorking, let report = tracksReport, report.plan.reference != nil else { return false }
        return !selectedTracksProposals.isEmpty || !selectedTracksAdaptive.isEmpty || report.plan.epochs.count == 1
    }
    private var adaptiveAnalysis: AdaptiveAnalysisRecord?
    private var adaptiveEpisode: Episode?
    private var adaptivePair: SpeakerMatchOption?
    @ObservationIgnored private var adaptiveTask: Task<Void, Never>?
    private(set) var adaptiveProgress = 0.0
    private var isMeasuringAdaptiveTiming = false
    var isAnalyzingAdaptively: Bool { isWorking && adaptiveTask != nil && isMeasuringAdaptiveTiming }
    var currentAdaptiveAnalysis: AdaptiveAnalysisRecord? {
        guard let record = adaptiveAnalysis, let snapshot = adaptiveEpisode,
              let live = document?.store.model.episode(episodeID),
              EpisodeMediaInputs(snapshot) == EpisodeMediaInputs(live),
              selection == record.target.epoch,
              selectedMatchOption == adaptivePair,
              adaptivePair?.target == record.target.source,
              adaptivePair?.reference.source == record.reference.source else { return nil }
        return record
    }
    var hasWaveformProposal: Bool {
        currentAdaptiveAnalysis.map { !$0.timing.regions.isEmpty } ?? canAcceptProposal
    }
    private(set) var analysisStates: [RecordingEpochID: EpochAlignmentState] = [:]
    private(set) var speakerMatches: [RecordingEpochID: [SpeakerMatchOption]] = [:]
    private var inspectedEpisode: Episode?
    private var inspectionSnapshot: AlignmentInspectionSnapshot?
    private var inspectedStates: [EpochAlignmentState] = []
    var selectedMatchSpeaker: SpeakerID?
    var selectedMatchOption: SpeakerMatchOption?
    var selectedSpeakerMatchOptions: [SpeakerMatchOption] {
        guard let selection else { return [] }
        var seen: Set<SpeakerID> = []
        return (speakerMatches[selection] ?? []).filter { seen.insert($0.speaker).inserted }
    }
    var selectedSpeakerPairs: [SpeakerMatchOption] {
        guard let selection else { return [] }
        let speaker = selectedMatchSpeaker ?? selectedSpeakerMatchOptions.first?.speaker
        return (speakerMatches[selection] ?? []).filter { $0.speaker == speaker }
    }
    func selectMatchSpeaker(_ speaker: SpeakerID?) {
        selectedMatchSpeaker = speaker
        selectedMatchOption = nil
        analysisStates = [:]
    }
    func selectMatchOption(_ option: SpeakerMatchOption?) {
        selectedMatchOption = option
        analysisStates = [:]
    }
    private var analysisSourceEndByEpoch: [RecordingEpochID: Double] = [:]
    private var analyzedInputs: EpisodeMediaInputs?
    private var observedAssignments: [SpeakerAssignment]?
    private var observedRevision: Int?
    private(set) var message = "Alignment has not read or analyzed any audio."
    private(set) var dependents = "No dependent work yet."
    private(set) var lastError: String?
    private(set) var staleAcceptedTiming = false
    private var pendingResetVerification = false
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
    struct WaveformFocus: Hashable, Sendable {
        let source: SourceID
        let speaker: SpeakerID
    }
    var requestedWaveformFocus: WaveformFocus?
    private(set) var waveformTracks: [AlignmentWaveformTrack] = []
    private(set) var waveformStrokes: [SourceID: [AlignmentWaveformStroke]] = [:]
    private(set) var waveformDisplayGains: [SourceID: Double] = [:]
    private(set) var waveformProjectionErrors: [SourceID: String] = [:]
    private(set) var waveformSnapshotID = UUID()
    private(set) var waveformTilesVersion = UUID()
    private(set) var waveformRefusals: [AlignmentWaveformRefusal] = []
    var groupDraftMilliseconds = 0.0
    private(set) var pendingWaveformMove: PendingWaveformMove?
    private(set) var selectedWaveformSource: SourceID?
    private(set) var isLoadingWaveforms = false
    private(set) var waveformOverviewTracks: [AlignmentWaveformTrack] = []
    private(set) var waveformOverviewStrokes: [SourceID: [AlignmentWaveformStroke]] = [:]
    private(set) var waveformOverviewIndices: [SourceID: AlignmentWaveformStrokeIndex] = [:]
    private(set) var waveformOverviewDisplayGains: [SourceID: Double] = [:]
    private(set) var waveformOverviewProjectionErrors: [SourceID: String] = [:]
    private(set) var waveformOverviewSnapshotID = UUID()
    private(set) var waveformOverviewRefusals: [AlignmentWaveformRefusal] = []
    private(set) var waveformOverviewMap: AlignedTimelineMap?
    private(set) var isLoadingOverview = false
    private(set) var waveformOverviewProgress = 0.0
    private(set) var waveformOverviewMessage = "Build Overview scans all covered PCM samples. It does not change or cache recordings."
    private(set) var waveformMessage = "Load a bounded audio window to see the recordings. Original files are never changed."
    var waveformStartSeconds: Double {
        get { listening.workspace.startSeconds }
        set { listening.workspace.startSeconds = newValue }
    }
    var waveformDurationSeconds: Double {
        get { listening.workspace.durationSeconds }
        set { listening.workspace.durationSeconds = newValue }
    }
    var waveformPlayheadSeconds: Double {
        get { listening.workspace.playheadSeconds }
        set { listening.workspace.playheadSeconds = newValue }
    }
    private var alignedNavigationEndSeconds = 0.0
    var waveformNavigationEndSeconds: Double {
        cutTimeline.editedTime(forAlignedTime: alignedNavigationEndSeconds)
    }
    private(set) var cutTimeline = ManualCutTimeline.unedited
    var primaryWaveformSources: Set<SourceID> {
        guard let episode = document?.store.model.episode(episodeID) else { return [] }
        return Set(episode.speakerAssignments.compactMap {
            guard $0.primaryConfirmation == .userConfirmed, let primary = $0.primary,
                  let source = episode.source(primary.sourceID),
                  source.role == .primary, source.roleConfirmation == .userConfirmed,
                  primary.resolvedChannel(channelCount: waveformTracks.first(where: { $0.id == source.id })?
                    .envelope.channelCount ?? source.observations.channelCount.value) != nil else { return nil }
            return primary.sourceID
        })
    }
    var primaryWaveformGroups: [AlignmentWaveformSpeakerGroup] {
        guard let episode = document?.store.model.episode(episodeID) else { return [] }
        return episode.speakerAssignments.compactMap { assignment in
            guard assignment.primaryConfirmation == .userConfirmed, let primary = assignment.primary,
                  primaryWaveformSources.contains(primary.sourceID) else { return nil }
            let tracks = waveformTracks.filter { $0.id == primary.sourceID }
            guard !tracks.isEmpty else { return nil }
            return AlignmentWaveformSpeakerGroup(id: assignment.speakerID, tracks: tracks)
        }
    }
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
    struct WaveformReferenceMarker: Identifiable {
        let id = UUID()
        let source: SourceID
        let group: RecorderGroupID
        let speaker: SpeakerID
        let trackName: String
        let alignedSeconds: Double
        let sourceSeconds: Double
    }
    private(set) var waveformReferenceMarkers: [WaveformReferenceMarker] = []
    private(set) var waveformPickedPoint: (source: SourceID, epoch: RecordingEpochID, sourceSeconds: Double, mapped: Bool)?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var projectingCutView = false
    @ObservationIgnored private var waveformGeneration: UInt64 = 0
    @ObservationIgnored private var scrubLoadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWaveformTile: (start: Double, duration: Double)?
    @ObservationIgnored private var waveformCache = AlignmentWaveformCache()
    @ObservationIgnored private var loadedWaveformGeneration: UInt64?
    @ObservationIgnored private var reprojectingWaveformGeneration: UInt64?
    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var overviewGeneration: UInt64 = 0
    @ObservationIgnored private var requestedOverviewEpisode: Episode?
    private var loadedOverviewEpisode: Episode?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionGeneration: UInt64 = 0
    private var loadedWaveformMap: AlignedTimelineMap?
    private var loadedWaveformEpisode: Episode?
    private var anchorsByEpoch: [RecordingEpochID: [AlignmentAnchorRow]] = [:]
    private var acceptedMap: AlignedTimelineMap?

    typealias WaveformTileSlice = AlignmentWaveformCache.Slice

    private struct WaveformSlicesKey: Equatable {
        let version: UUID
        let generation: UInt64?
        let start: Double
        let duration: Double
        let pendingPrior: UInt64?
        let pendingExpected: UInt64?
    }
    @ObservationIgnored private var cachedWaveformSlices: (key: WaveformSlicesKey, value: [WaveformTileSlice])?

    var waveformTileSlices: [WaveformTileSlice] {
        let key = WaveformSlicesKey(version: waveformTilesVersion, generation: document?.store.modelGeneration,
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            pendingPrior: pendingWaveformMove?.priorGeneration, pendingExpected: pendingWaveformMove?.expectedGeneration)
        if let cachedWaveformSlices, cachedWaveformSlices.key == key { return cachedWaveformSlices.value }
        let slices = waveformCache.visibleSlices(
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            generation: document?.store.modelGeneration, pendingMove: pendingWaveformMove,
            canReuseSamples: canRetainWaveformSamples
        )
        cachedWaveformSlices = (key, slices)
        return slices
    }

    func waveformTileSlices(for group: RecorderGroupID) -> [WaveformTileSlice] {
        let shift = ((selectedRow?.groupID == group ? groupDraftMilliseconds : 0)
            + (pendingWaveformMove?.displayShift(for: group) ?? 0)) / 1_000
        guard shift != 0 else { return waveformTileSlices }
        return waveformCache.visibleSlices(start: waveformStartSeconds - shift, duration: waveformDurationSeconds,
            generation: document?.store.modelGeneration, pendingMove: pendingWaveformMove,
            canReuseSamples: canRetainWaveformSamples)
    }

    func hasVisibleWaveformStrokes(for track: AlignmentWaveformTrack) -> Bool {
        let shift = ((selectedRow?.groupID == track.group ? groupDraftMilliseconds : 0)
            + (pendingWaveformMove?.displayShift(for: track.group) ?? 0)) / 1_000
        if retainedWaveformIndex(for: track.id).hasVisible(
            start: waveformStartSeconds - shift, duration: waveformDurationSeconds) { return true }
        return waveformTileSlices(for: track.group).contains {
            $0.indices[track.id]?.hasVisible(start: $0.range.lowerBound,
                duration: $0.range.upperBound - $0.range.lowerBound) == true
        }
    }

    func waveformVisibleStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        retainedWaveformIndex(for: source).visible(start: waveformStartSeconds, duration: waveformDurationSeconds,
            draftEpoch: waveformTimingIsDraft ? selection : nil,
            ratePPM: waveformRatePPM, offsetMilliseconds: waveformOffsetMilliseconds)
        + waveformTileSlices.flatMap { slice in
            slice.indices[source]?.visible(start: waveformStartSeconds, duration: waveformDurationSeconds,
                draftEpoch: waveformTimingIsDraft ? selection : nil,
                ratePPM: waveformRatePPM, offsetMilliseconds: waveformOffsetMilliseconds) ?? []
        }
    }

    func retainedWaveformStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        _ = waveformTilesVersion
        return waveformCache.retainedStrokes(for: source)
    }

    func retainedWaveformIndex(for source: SourceID) -> AlignmentWaveformStrokeIndex {
        _ = waveformTilesVersion
        return waveformCache.retainedIndices[source] ?? .empty
    }

    func waveformMeasuredBinCount(for source: SourceID) -> Int {
        waveformOverviewIndices[source]?.count
            ?? waveformCache.tiles.reduce(0) { $0 + ($1.indices[source]?.count ?? 0) }
    }

    func proposedWaveformStrokes(for track: AlignmentWaveformTrack) -> [AlignmentWaveformStroke] {
        waveformProposalInput(for: track)?.strokes() ?? []
    }

    func waveformProposalInput(for track: AlignmentWaveformTrack) -> AlignmentWaveformProjection.ProposalInput? {
        let complete = waveformOverviewTracks.first { $0.id == track.id }
        let tracks = complete.map { [$0] } ?? waveformCache.tracks.filter { $0.id == track.id }
        let adaptive = currentAdaptiveAnalysis
        guard adaptive != nil || canAcceptProposal else { return nil }
        return AlignmentWaveformProjection.ProposalInput(
            source: track.id, tilesVersion: waveformTilesVersion, overviewVersion: waveformOverviewSnapshotID,
            modelGeneration: document?.store.modelGeneration, tracks: tracks, map: loadedWaveformMap,
            adaptive: adaptive, group: selectedRow?.groupID, epoch: selectedRow?.epochID,
            segment: selectedAnalysis?.proposal?.segment, cuts: cutTimeline,
            includeEstimated: true)
    }

    private var canRetainWaveformSamples: Bool {
        AlignmentWaveformProjection.canReuseSamples(
            from: loadedWaveformEpisode, to: document?.store.model.episode(episodeID)
        )
    }
    func waveformInteractionStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        let exact = waveformVisibleStrokes(for: source)
        return exact.isEmpty
            ? waveformOverviewIndices[source]?.visible(start: waveformStartSeconds, duration: waveformDurationSeconds,
                draftEpoch: waveformTimingIsDraft ? selection : nil, ratePPM: waveformRatePPM,
                offsetMilliseconds: waveformOffsetMilliseconds) ?? []
            : exact
    }

    private func firstUncoveredWaveformTime(
        start: Double, duration: Double, margin: Double = 0, includePending: Bool = false
    ) -> Double? {
        waveformCache.firstUncoveredTime(
            start: start, duration: duration, margin: margin,
            generation: document?.store.modelGeneration,
            pendingWindow: includePending ? pendingWaveformTile : nil
        )
    }

    private var currentWaveformTile: AlignmentWaveformCache.Tile? {
        waveformCache.currentTile(
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            generation: document?.store.modelGeneration, snapshot: waveformSnapshotID
        )
    }

    let episodeID: EpisodeID
    let mixer: EpisodeMixerController
    var mixerStore: ShowDocumentStore? { document?.store }
    enum ListeningMode { case sourceAudition, productionMix }
    private(set) var listeningMode: ListeningMode = .sourceAudition
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let audioPlayback = AlignmentAudioPlayback()
    #if DEBUG
    var playbackClockForTesting: AlignmentPlaybackClock? { audioPlayback.clock }
    #endif
    @ObservationIgnored private var transportUnavailable: [SourceID: String] = [:]
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
    @ObservationIgnored private var auditionGeneration: UInt64 = 0
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var transportProgressTask: Task<Void, Never>?
    @ObservationIgnored private var transportWarmupTask: Task<Void, Never>?
    @ObservationIgnored private var transportWarmup: (source: SourceID, frames: Range<Int64>)?
    @ObservationIgnored private var auditionStopTask: Task<Void, Never>?
    @ObservationIgnored private var auditionUsesOriginalTime = false
    @ObservationIgnored private var productionTimeline: ManualCutTimeline?
    @ObservationIgnored private var productionPreparationTask: Task<MixerPCMWindow, any Error>?

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime,
         listening: EpisodeListeningState = EpisodeListeningState()) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
        self.listening = listening
        mixer = EpisodeMixerController(document: document, episodeID: episodeID, runtime: runtime)
        do {
            if let id = listening.expandedManualCutID,
               document.store.model.episode(episodeID)?.activeManualCuts.contains(where: { $0.id == id }) != true {
                listening.expandedManualCutID = nil
            }
            cutTimeline = try document.store.model.episode(episodeID)?
                .manualCutTimeline(revealing: listening.expandedManualCutID) ?? .unedited
            auditionPlayheadSeconds = waveformPlayheadSeconds
        } catch {
            lastError = "Saved cuts could not be restored: \(error)."
        }
    }

    var selectedRow: AlignmentRow? {
        rows.first { $0.epochID == selection }
    }

    var selectedRecordingTimingState: AlignmentStateCopy? {
        guard let row = selectedRow else { return nil }
        return AlignmentPresentation.recordingTimingState(
            groupState: row.state,
            correction: selectedWaveformSource.flatMap { adaptiveCorrection(for: $0) })
    }

    var selectedAnalysis: EpochAnalysisRecord? {
        guard let selection else { return nil }
        return analysisStates[selection]?.analysis
    }

    var selectedAnalysisState: EpochAlignmentState? {
        guard let selection else { return nil }
        return analysisStates[selection]
    }

    var canAcceptProposal: Bool {
        guard !isWorking, let row = selectedRow,
              let episode = document?.store.model.episode(episodeID)
        else { return false }
        guard row.groupID != acceptedMap?.reference.group,
              !episode.positionIsLocked(row.groupID) else { return false }
        if let analysis = selectedAnalysis {
            return analysis.proposal != nil && analyzedInputs == EpisodeMediaInputs(episode)
                && (!hasAcceptedRevision || waveformMap != nil)
        }
        guard let document, timingIsVerified(document.store.model),
              !waveformNeedsRefreshAfterSave, let acceptedMap, acceptedMap == waveformMap,
              let mapping = acceptedMap.groups.first(where: { $0.group == row.groupID })?
                .epochs.first(where: { $0.epoch == row.epochID })?.mapping else { return false }
        if case .mapped(_, .acousticConsistentProposal) = mapping { return true }
        return false
    }

    var proposalNeedsExtension: Bool {
        guard let record = selectedAnalysis, let proposal = record.proposal else { return false }
        let end = analysisSourceEndByEpoch[record.target.epoch]
            ?? Double(record.target.sourceFrames) / Double(record.target.sourceRate)
        return proposal.segment.groupClockStart > .zero
            || proposal.segment.groupClockEnd.approximateDouble < end - 1 / Double(record.target.sourceRate)
    }

    var waveformMap: AlignedTimelineMap? { loadedWaveformMap }
    var waveformNeedsRefreshAfterSave: Bool {
        guard let loaded = loadedWaveformEpisode, let current = document?.store.model.episode(episodeID) else { return true }
        return EpisodeMediaInputs(loaded) != EpisodeMediaInputs(current)
    }
    func trackSpeakerID(_ source: SourceID) -> SpeakerID? {
        document?.store.model.episode(episodeID)?.references(to: source).first?.speakerID
    }
    func speakerName(_ id: SpeakerID?) -> String {
        guard let id else { return "Unknown speaker" }
        return document?.store.model.speaker(id)?.name ?? "Unknown speaker"
    }

    var availableSpeakers: [Speaker] { document?.store.model.speakers ?? [] }
    var ungroupedSources: [SourceRecord] {
        (document?.store.model.episode(episodeID)?.sources ?? []).filter {
            $0.placement.recorderGroupID == nil
        }
    }
    var availableRecorderGroups: [RecorderGroup] {
        document?.store.model.episode(episodeID)?.recorderGroups ?? []
    }

    func ungroupedSpeakerLabel(for source: SourceID) -> String {
        guard let episode = document?.store.model.episode(episodeID) else { return "Unassigned speaker" }
        let names = episode.references(to: source).map { speakerName($0.speakerID) }
        return names.isEmpty ? "Unassigned speaker" : names.joined(separator: ", ")
    }

    func groupUngroupedSource(_ source: SourceID, existing: RecorderGroupID? = nil, newName: String? = nil) {
        guard let document, ungroupedSources.contains(where: { $0.id == source }) else {
            lastError = "The recording is no longer ungrouped in this episode."
            return
        }
        let commands = SetupEditCommands(editor: document.store, episodeID: episodeID)
        let applied: Bool
        if let newName {
            applied = commands.createGroup(
                RecorderGroup(name: newName.trimmingCharacters(in: .whitespacesAndNewlines)),
                assigning: [source]
            )
        } else if let existing {
            applied = commands.assign([source], toGroup: existing)
        } else {
            lastError = "Choose a recorder group or create a new one."
            return
        }
        guard applied else {
            lastError = document.store.lastError.map(EpisodeSetupModel.describe)
                ?? "Recorder group assignment is unavailable while this show is read-only."
            return
        }
        invalidateMatchAfterSetupEdit()
    }

    var hasAcceptedRevision: Bool { document?.store.model.episode(episodeID)?.alignment?.acceptedRevision != nil }

    var canResetAlignment: Bool {
        guard let document else { return false }
        return hasAcceptedRevision && !isWorking && pendingWaveformMove == nil
            && FormatUpdatePolicy.allowsEdits(document.status.formatUpdate)
    }

    func statedChannel(for source: SourceID) -> Int? {
        document?.store.model.episode(episodeID)?.statedChannel(of: source)
    }

    func matchOptions(for track: AlignmentWaveformTrack) -> [SpeakerMatchOption] {
        guard let live = document?.store.model.episode(episodeID),
              (!hasAcceptedRevision || waveformMap != nil),
              let inspectedEpisode,
              EpisodeMediaInputs(live) == EpisodeMediaInputs(inspectedEpisode)
        else { return [] }
        return (speakerMatches[track.epoch] ?? []).filter { $0.target == track.id }
    }

    func assignSpeaker(_ speaker: SpeakerID?, to track: AlignmentWaveformTrack) {
        guard let document else {
            lastError = "The show document is no longer open."
            return
        }
        selectWaveform(track)
        let commands = SetupEditCommands(editor: document.store, episodeID: episodeID)
        let applied: Bool
        if let speaker, track.envelope.channelCount == 1, statedChannel(for: track.id) == nil {
            applied = commands.assignSpeaker(speaker, toMeasuredMonoSource: track.id)
        } else {
            applied = commands.assignSpeaker(speaker, to: [track.id])
        }
        guard applied else {
            lastError = document.store.lastError.map(String.init(describing:))
                ?? "Speaker assignment is unavailable while this show is read-only."
            return
        }
        invalidateMatchAfterSetupEdit()
    }

    func setChannel(_ channel: Int?, for track: AlignmentWaveformTrack) {
        guard let document else {
            lastError = "The show document is no longer open."
            return
        }
        selectWaveform(track)
        let commands = SetupEditCommands(editor: document.store, episodeID: episodeID)
        guard commands.setChannel(channel.map { $0 + 1 }, for: [track.id]) else {
            lastError = document.store.lastError.map(String.init(describing:))
                ?? "Channel assignment is unavailable while this show is read-only."
            return
        }
        invalidateMatchAfterSetupEdit()
    }

    private func invalidateMatchAfterSetupEdit() {
        adaptiveAnalysis = nil
        adaptiveEpisode = nil
        clearWaveformMarkers()
        lastError = nil
        analysisStates = [:]
        speakerMatches = [:]
        selectedMatchOption = nil
        selectedMatchSpeaker = nil
        message = "Assignment changed. Finding eligible speaker pairs again; no timing was applied."
        load()
    }

    var timingReferenceSelection: TimingReferenceSelection {
        if loadedWaveformMap == nil, acceptedMap == nil, hasAcceptedRevision {
            return TimingReferenceSelection.read(model: document?.store.model, episodeID: episodeID)
        }
        return TimingReferenceSelection(
            episode: document?.store.model.episode(episodeID),
            currentGroup: loadedWaveformMap?.reference.group ?? acceptedMap?.reference.group
        )
    }

    func useAsTimingReference(_ group: RecorderGroupID) {
        guard !isWorking, pendingWaveformMove == nil else {
            lastError = "Finish the current alignment operation before choosing its next reference."
            return
        }
        guard let document else {
            lastError = "The show document is no longer open."
            return
        }
        guard SetupEditCommands(editor: document.store, episodeID: episodeID)
            .preferAlignmentReference(true, group: group) else {
            lastError = document.store.lastError.map(String.init(describing:))
                ?? "The timing reference cannot be changed while this show is read-only."
            return
        }
        invalidateMatchAfterSetupEdit()
        message = timingReferenceSelection.detail
    }

    func align(_ track: AlignmentWaveformTrack, with option: SpeakerMatchOption) {
        guard !isWorking else { return }
        guard matchOptions(for: track).contains(option) else {
            message = "Speaker assignments or accepted timing changed. Choose a current pair and try again."
            load()
            return
        }
        selectWaveform(track)
        selectedMatchSpeaker = option.speaker
        selectedMatchOption = option
        analyze()
    }
    func speakerMatchDescription(_ option: SpeakerMatchOption, fileLocal: Bool = false) -> String {
        guard let episode = document?.store.model.episode(episodeID),
              let targetGroup = episode.sources.first(where: { $0.id == option.target })?.placement.recorderGroupID
        else { return "Compare this speaker's assigned channels in the aligned and selected recorder groups." }
        let referenceName = episode.recorderGroup(option.reference.group)?.name ?? "aligned recorder"
        let targetName = episode.recorderGroup(targetGroup)?.name ?? "selected recorder"
        let referenceFile = episode.source(option.reference.source)?.displayNameHint ?? "reference track"
        let targetFile = episode.source(option.target)?.displayNameHint ?? "target track"
        let scope = fileLocal
            ? "Adaptive preview is for this target file only, with one timing curve shared by all its channels. Nothing is applied."
            : "The target recorder moves as one group."
        return "\(referenceName): \(referenceFile) ch \(option.referenceChannel + 1) → \(targetName): \(targetFile) ch \(option.targetChannel + 1). \(scope)"
    }
    func trackIdentity(_ source: SourceID) -> (label: String, color: Color) {
        let references = document?.store.model.episode(episodeID)?.references(to: source) ?? []
        guard let reference = references.first,
              let speakers = document?.store.model.speakers,
              let speaker = speakers.first(where: { $0.id == reference.speakerID })
        else { return ("Unknown speaker", .gray) }
        let role = reference.isPrimary ? "Primary" : "Backup"
        let appearance = document?.store.model.speakerAppearance(speaker.id, in: episodeID)
        return ("\(speaker.name) · \(role)", appearance?.color.swiftUIColor ?? .gray)
    }
    var enabledSources: [SourceID] {
        guard let episode = document?.store.model.episode(episodeID) else { return [] }
        return waveformTracks.map(\.id).filter { listening.playback.isAudible($0, in: episode) }
    }
    var waveformFitRange: ClosedRange<Double>? {
        guard let extent = AlignmentWaveformProjection.overviewExtent(
            indices: waveformOverviewIndices.values
        ) else { return nil }
        let lower = min(-300, extent.lowerBound)
        let upper = max(0, extent.upperBound)
        return lower...max(lower + 0.5, upper)
    }
    var waveformViewingBounds: ClosedRange<Double> {
        let fit = waveformFitRange
        return min(-86_400, fit?.lowerBound ?? 0)...max(86_400, fit?.upperBound ?? 0)
    }
    var maximumWaveformDuration: Double {
        max(30, waveformFitRange.map { $0.upperBound - $0.lowerBound } ?? 30)
    }
    func fitWaveformTimeline() {
        guard pendingWaveformMove == nil, let range = waveformFitRange else { return }
        if canStopAudition {
            stopAudition()
            waveformPlayheadSeconds = auditionPlayheadSeconds
        }
        waveformStartSeconds = range.lowerBound
        waveformDurationSeconds = range.upperBound - range.lowerBound
        if waveformDurationSeconds <= 30 { loadWaveforms(keepingSnapshot: true) }
    }
    func sourceHasAcceptedTiming(_ source: SourceID) -> Bool {
        playableWaveformSources.contains(source)
    }
    private var playableWaveformSources: Set<SourceID> {
        guard let map = loadedWaveformMap else { return [] }
        return AlignmentWaveformProjection.playableSources(
            in: map, corrections: loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections ?? [])
    }
    var canApplyManualCuts: Bool {
        guard let document, let episode = document.store.model.episode(episodeID),
              let loadedWaveformEpisode else { return false }
        return !isWorking && pendingWaveformMove == nil && !waveformTimingIsDraft
            && groupDraftMilliseconds == 0 && loadedWaveformMap != nil
            && episode.alignment?.acceptedRevision != nil && timingIsVerified(document.store.model)
            && EpisodeMediaInputs(episode) == EpisodeMediaInputs(loadedWaveformEpisode)
    }
    var manualCutBounds: ClosedRange<Double>? {
        guard let map = loadedWaveformMap else { return nil }
        let starts = map.groups.flatMap(\.epochs).flatMap { epoch -> [Double] in
            guard case let .mapped(segments, _) = epoch.mapping else { return [] }
            return segments.map {
                $0.rateRatio.approximateDouble * $0.groupClockStart.approximateDouble
                    + $0.alignedOffset.approximateDouble
            }
        }
        let corrections = loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections?.flatMap(\.segments) ?? []
        let lo = min(starts.min() ?? .infinity, corrections.map(\.alignedStart).min() ?? .infinity)
        let hi = max(AlignmentWaveformProjection.timelineEnd(map: map), corrections.map(\.alignedEnd).max() ?? -.infinity)
        return lo.isFinite && hi.isFinite && hi > lo ? lo...hi : nil
    }
    func adaptiveCorrection(for source: SourceID) -> SourceTimingCorrection? {
        guard let model = document?.store.model, timingIsVerified(model),
              loadedWaveformEpisode == model.episode(episodeID) else { return nil }
        return loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == source }
    }
    private var selectedWaveformHasAcceptedTiming: Bool {
        guard let row = selectedRow, let source = selectedWaveformSource else { return false }
        return AlignmentWaveformProjection.hasAcceptedTiming(
            source: source, epoch: row.epochID, group: row.groupID, map: loadedWaveformMap
        )
    }
    var enabledTimelineEnd: Double {
        timelineEnd(for: Set(enabledSources))
    }
    private func timelineEnd(for sources: Set<SourceID>, applyingCuts: Bool = true) -> Double {
        guard let map = loadedWaveformMap else { return 0 }
        let groupEnd = map.groups.flatMap { group in
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
        let adaptiveEnd = loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections?
            .filter { sources.contains($0.source) }.flatMap(\.segments).map(\.alignedEnd).max() ?? 0
        let end = max(groupEnd, adaptiveEnd)
        return applyingCuts ? cutTimeline.editedTime(forAlignedTime: end) : end
    }
    func groupEnabled(_ group: RecorderGroupID) -> Bool { !listening.playback.muted.contains(.recorder(group)) }
    func trackEnabled(_ source: SourceID) -> Bool {
        guard let episode = document?.store.model.episode(episodeID) else { return false }
        return listening.playback.isAudible(source, in: episode)
    }
    func setGroup(_ group: RecorderGroupID, enabled: Bool) {
        setMuted(!enabled, scope: .recorder(group))
    }
    func setTrack(_ source: SourceID, enabled: Bool) {
        setMuted(!enabled, scope: .source(source))
    }
    func setMuted(_ muted: Bool, scope: EpisodePlaybackScope) {
        listening.playback.setMuted(muted, scope: scope)
        refreshListeningGains()
    }
    func setSoloed(_ soloed: Bool, scope: EpisodePlaybackScope) {
        listening.playback.setSoloed(soloed, scope: scope)
        refreshListeningGains()
    }
    func muteNonPrimaryTracks() {
        guard let episode = document?.store.model.episode(episodeID) else { return }
        let primaries = primaryWaveformSources
        var playback = listening.playback
        for source in episode.sources where !primaries.contains(source.id) {
            playback.setMuted(true, scope: .source(source.id))
        }
        guard playback != listening.playback else { return }
        if listening.previousPlayback == nil { listening.previousPlayback = listening.playback }
        listening.playback = playback
        refreshListeningGains()
    }
    func refreshListeningGains() {
        if transportTask != nil { refreshTransportGains() }
    }
    func speakerAppearance(_ speaker: SpeakerID) -> SpeakerAppearance {
        document?.store.model.speakerAppearance(speaker, in: episodeID)
            ?? .init(color: .defaultColor(for: speaker))
    }
    func recorderIcon(_ group: RecorderGroupID) -> RecorderIcon {
        document?.store.model.episode(episodeID)?.recorderGroup(group)?.icon ?? .recorder
    }
    var referenceGroup: RecorderGroupID? {
        let reference = timingReferenceSelection
        if hasAcceptedRevision { return reference.currentGroup }
        return reference.nextGroup ?? document?.store.model.episode(episodeID)?.recorderGroups.first?.id
    }
    func positionIsLocked(_ group: RecorderGroupID) -> Bool {
        group == referenceGroup || document?.store.model.episode(episodeID)?.positionIsLocked(group) != false
    }
    func setPositionLocked(_ locked: Bool, group: RecorderGroupID) {
        guard let document, !isWorking, group != referenceGroup else {
            lastError = "The reference stays fixed. Wait for active alignment before changing other position locks."
            return
        }
        if !document.store.apply("Set recorder position lock", { model throws(DomainError) in
            try model.settingPositionLock(locked, group: group, in: episodeID)
        }) { lastError = document.store.lastError.map(String.init(describing:)) }
    }

    func restoreListeningChoices() {
        guard let previous = listening.previousPlayback else { return }
        listening.playback = previous
        if let episode = document?.store.model.episode(episodeID) { listening.playback.retainScopes(in: episode) }
        listening.previousPlayback = nil
        refreshListeningGains()
    }
    var canMoveGroup: Bool {
        guard let row = selectedRow, let source = selectedWaveformSource else { return false }
        return canMoveWaveform(source: source, group: row.groupID, epoch: row.epochID)
    }
    func canMoveWaveform(source: SourceID, group: RecorderGroupID, epoch: RecordingEpochID) -> Bool {
        guard !isWorking, !isLoadingWaveforms, pendingWaveformMove == nil,
              document?.store.model.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections?.isEmpty != false
        else { return false }
        let reference = loadedWaveformMap?.reference.group
            ?? document?.store.model.episode(episodeID)?.recorderGroups.first?.id
        return group != reference && document?.store.model.episode(episodeID)?.positionIsLocked(group) == false
            && waveformTracks.contains(where: { $0.group == group && $0.id == source })
            && (loadedWaveformMap == nil || AlignmentWaveformProjection.hasAcceptedTiming(
                source: source, epoch: epoch, group: group, map: loadedWaveformMap
            ) || rows.first(where: { $0.groupID == group && $0.epochID == epoch })?
                .state.remedies.contains("Edit Numerically…") == true)
    }
    func commitGroupMove() {
        guard let document, let row = selectedRow, canMoveGroup,
              let delta = AlignmentWaveformProjection.moveMicroseconds(
                  fromMilliseconds: groupDraftMilliseconds
              ), delta != 0
        else { return }
        let prior = document.store.model
        let group = row.groupID
        isWorking = true
        stopAudition()
        Task {
            do {
                let accepted: AcceptedAlignment
                if prior.episode(episodeID)?.alignment?.acceptedRevision != nil,
                   selectedWaveformHasAcceptedTiming {
                    accepted = try await runtime.shiftGroup(
                        model: prior, episode: episodeID, group: group, microseconds: delta
                    )
                } else {
                    let report = try await runtime.prepareManual(model: prior, episode: episodeID)
                    guard group != report.plan.reference?.group else {
                        throw AlignmentAcceptanceError.invalidMap("The reference recorder cannot be moved.")
                    }
                    guard let source = selectedWaveformSource else {
                        throw AlignmentAcceptanceError.noPlaceableSource(row.epochID)
                    }
                    accepted = try await runtime.accept(
                        model: prior, episode: episodeID, decisions: [
                            row.epochID: .numeric(ppm: 0, offsetMilliseconds: Double(delta) / 1_000)
                        ], requiringPlacementOf: source
                    )
                }

                let priorGeneration = document.store.modelGeneration
                pendingWaveformMove = PendingWaveformMove(
                    group: group, milliseconds: Double(delta) / 1_000,
                    priorGeneration: priorGeneration, expectedGeneration: priorGeneration + 1
                )
                guard publishAlignment(accepted, expecting: prior, actionName: UndoActionName.editEpochTiming) else {
                    pendingWaveformMove = nil
                    message = SharedModelPublication.supersededCorrectionMessage
                    isWorking = false
                    return
                }
                groupDraftMilliseconds = 0
                acceptedMap = accepted.map
                rows = Self.makeRows(model: accepted.model, episodeID: episodeID, states: [], map: accepted.map)
                message = "Recorder group moved as one undoable map revision; saving and verifying the show."
                cancelWaveforms(keepingSnapshot: true)
                loadedWaveformMap = nil
                waveformMessage = "Saving timing; the moved waveform is a visual preview until the verified audio refresh completes."
            } catch {
                groupDraftMilliseconds = 0
                lastError = AlignmentPresentation.errorDescription(error)
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
        guard !pendingResetVerification || timingIsVerified(document.store.model) else {
            message = "Save verification must finish before placing the fresh timeline."
            return
        }
        let prior = document.store.model
        isWorking = true
        Task {
            do {
                let report = try await runtime.prepareManual(model: prior, episode: episodeID)
                let decisions = Self.initialDecisions(report)
                let accepted = try await runtime.accept(
                    model: prior, episode: episodeID, decisions: decisions
                )
                guard publishAlignment(accepted, expecting: prior, actionName: UndoActionName.editEpochTiming) else {
                    message = SharedModelPublication.supersededCorrectionMessage
                    isWorking = false
                    return
                }
                acceptedMap = accepted.map
                rows = Self.makeRows(model: accepted.model, episodeID: episodeID, states: [], map: accepted.map)
                message = "Source-time placement accepted. Move recorder groups to align them; the show is being verified."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
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
        guard !isWorking, !isLoadingWaveforms, pendingWaveformMove == nil,
              let document, timingIsVerified(document.store.model),
              let track = selectedWaveform,
              let map = loadedWaveformMap, track.group != map.reference.group,
              sourceHasAcceptedTiming(track.id)
        else { return false }
        return true
    }

    private func timingIsVerified(_ model: ShowDocumentModel) -> Bool {
        let alignment = model.episode(episodeID)?.alignment
        if !pendingResetVerification, alignment?.acceptedRevision == nil, alignment?.maps.isEmpty != false {
            return true
        }
        return document?.verifiedModel?.hasSameMediaInputs(as: model, in: episodeID) == true
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
            selectedMatchOption = nil
            selectedMatchSpeaker = nil
            analysisStates = [:]
            resetWaveformTiming()
            stopAudition()
        }
    }

    func selectWaveformAnchorPoint(
        _ track: AlignmentWaveformTrack, position: AlignmentWaveformStroke, sourceSeconds: Double
    ) {
        guard !isWorking, groupDraftMilliseconds == 0, pendingWaveformMove == nil,
              !waveformTimingIsDraft,
              let document, loadedWaveformGeneration == document.store.modelGeneration,
              timingIsVerified(document.store.model) else { return }
        waveformPickedPoint = (track.id, position.epoch, sourceSeconds, position.mapped)
    }

    func markWaveformReference(_ track: AlignmentWaveformTrack) {
        guard let document, loadedWaveformGeneration == document.store.modelGeneration,
              timingIsVerified(document.store.model),
              let point = waveformPickedPoint, point.source == track.id, point.mapped,
              sourceHasAcceptedTiming(track.id), let speaker = trackSpeakerID(track.id),
              let map = waveformMap, let group = map.groups.first(where: { $0.group == track.group }),
              let placement = group.placements.first(where: { $0.occurrence.source == track.id }),
              let span = placement.spans.first(where: { $0.epoch == point.epoch }),
              let mapping = group.epochs.first(where: { $0.epoch == point.epoch })?.mapping,
              case let .mapped(segments, _) = mapping,
              let segment = segments.first(where: {
                  let clock = point.sourceSeconds + span.groupClockOffset.approximateDouble
                  return clock >= $0.groupClockStart.approximateDouble
                      && clock < $0.groupClockEnd.approximateDouble
              })
        else {
            waveformMessage = "Click covered audio on an already timed speaker track to mark a reference point."
            return
        }
        let clock = point.sourceSeconds + span.groupClockOffset.approximateDouble
        let aligned = segment.rateRatio.approximateDouble * clock + segment.alignedOffset.approximateDouble
        guard aligned.isFinite else {
            waveformMessage = "The selected reference point cannot be represented on the aligned timeline."
            return
        }
        waveformReferenceMarkers.append(WaveformReferenceMarker(
            source: track.id, group: track.group, speaker: speaker,
            trackName: track.name,
            alignedSeconds: aligned, sourceSeconds: point.sourceSeconds
        ))
        waveformMessage = "Reference marker placed. Click the matching sound on another recorder for \(speakerName(speaker)), then link it."
    }

    func referenceMarkers(for track: AlignmentWaveformTrack) -> [WaveformReferenceMarker] {
        guard let speaker = trackSpeakerID(track.id) else { return [] }
        return waveformReferenceMarkers.filter { $0.speaker == speaker && $0.group != track.group }
    }

    func acceptedAnchorRows(for track: AlignmentWaveformTrack) -> [AlignmentAnchorRow] {
        guard selectedWaveformSource == track.id, let epoch = selection,
              let group = acceptedMap?.groups.first(where: { $0.group == track.group }),
              let mapping = group.epochs.first(where: { $0.epoch == epoch })?.mapping,
              case let .mapped(_, .manual(correction)) = mapping,
              AlignmentAnchorNote.source(in: correction.note) == track.id
        else { return [] }
        return selectedAnchors
    }

    func clearWaveformMarkers() {
        waveformReferenceMarkers = []
        waveformPickedPoint = nil
    }

    func linkWaveformAnchor(_ marker: WaveformReferenceMarker, to track: AlignmentWaveformTrack) {
        guard waveformReferenceMarkers.contains(where: { $0.id == marker.id }),
              referenceMarkers(for: track).contains(where: { $0.id == marker.id }),
              let point = waveformPickedPoint, point.source == track.id,
              point.epoch == selection, canCorrect,
              let document, timingIsVerified(document.store.model),
              loadedWaveformGeneration == document.store.modelGeneration
        else {
            waveformMessage = "Select covered audio on the target speaker track, then link a current reference marker."
            return
        }
        selectWaveform(track, epoch: point.epoch)
        waveformTargetPoint = point.sourceSeconds
        waveformReferencePoint = marker.alignedSeconds
        addWaveformAnchor()
        waveformMessage = "\(waveformDraftAnchors.count) linked anchor\(waveformDraftAnchors.count == 1 ? "" : "s") staged. Place at least two pairs on this recording segment, then apply; nothing has changed yet."
    }

    func loadWaveforms(keepingSnapshot: Bool = false, preload: Bool = false) {
        guard !projectingCutView else { return }
        guard let document else { return }
        adoptCachedPresentation()
        let snapshot = document.store.model
        let modelGeneration = document.store.modelGeneration
        if canRetainWaveformSamples, loadedWaveformGeneration != modelGeneration {
            guard timingIsVerified(snapshot) else {
                cancelWaveforms(keepingSnapshot: true)
                waveformMessage = "Saving timing; the recordings remain visible until the new positions are verified."
                return
            }
            reprojectWaveforms(model: snapshot, modelGeneration: modelGeneration)
            return
        }
        guard timingIsVerified(snapshot) else {
            if pendingWaveformMove != nil {
                waveformMessage = "Saving timing; the moved waveform is only a visual preview until the verified audio refresh completes."
            } else {
                cancelWaveforms()
                waveformMessage = "Timing is not verified on disk yet. Save the show before loading aligned audio."
            }
            return
        }
        let visibleStart = waveformStartSeconds
        let visibleDuration = waveformDurationSeconds
        guard visibleStart.isFinite,
              AlignmentWaveformProjection.overviewNavigationRange.contains(visibleStart),
              visibleDuration.isFinite, visibleDuration > 0, visibleDuration <= 172_800,
              waveformPlayheadSeconds.isFinite else {
            waveformMessage = "Choose a finite timeline window within the supported minus-24-to-plus-24-hour range."
            return
        }
        if visibleDuration > 30, canRetainWaveformSamples,
           !waveformTracks.isEmpty, waveformRefusals.isEmpty {
            ensureWaveformOverview()
            return
        }
        let exactDuration = min(30, visibleDuration)
        let exactStart = visibleDuration > 30
            ? max(visibleStart, min(waveformPlayheadSeconds - exactDuration / 2,
                                    visibleStart + visibleDuration - exactDuration))
            : visibleStart
        guard let initialRequest = AlignmentWaveformProjection.tileWindow(
            start: exactStart, visible: exactDuration
        ) else {
            waveformMessage = "The exact audio window is outside the supported minus-24-to-plus-24-hour range."
            return
        }
        let uncovered = keepingSnapshot
            ? firstUncoveredWaveformTime(start: exactStart, duration: exactDuration,
                                         margin: preload ? exactDuration / 2 : 0)
            : nil
        if keepingSnapshot, uncovered == nil {
            if isLoadingWaveforms {
                cancelWaveforms(keepingSnapshot: true)
                if let cached = currentWaveformTile { publishWaveformTile(cached) }
            }
            return
        }
        if keepingSnapshot, isLoadingWaveforms,
           firstUncoveredWaveformTime(
               start: exactStart, duration: exactDuration,
               margin: preload ? exactDuration / 2 : 0, includePending: true
           ) == nil { return }
        let request: (start: Double, duration: Double)
        if keepingSnapshot {
            guard let next = AlignmentWaveformProjection.tileWindow(
                start: min(uncovered ?? exactStart, 86_400), visible: exactDuration
            ) else {
                waveformMessage = "The next aligned tile is outside the supported navigation range."
                return
            }
            request = next
        } else {
            request = initialRequest
        }
        cancelWaveforms(keepingSnapshot: keepingSnapshot)
        let generation = waveformGeneration
        lastError = nil
        isLoadingWaveforms = true
        pendingWaveformTile = request
        waveformMessage = pendingWaveformMove == nil
            ? "Loading the next measured timeline tile through the read-only source gateway…"
            : "Loading verified audio; the moved waveform is only a visual preview until this read completes."
        let revealingCut = listening.expandedManualCutID
        let cuts = cutTimeline
        waveformTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == waveformGeneration {
                    isLoadingWaveforms = false
                    waveformTask = nil
                    pendingWaveformTile = nil
                }
            }
            do {
                var loaded = try await runtime.waveformTracks(
                    model: snapshot, episode: episodeID,
                    startSeconds: request.start, durationSeconds: request.duration,
                    revealingCut: revealingCut
                )
                var publishedWindow = request
                if request.duration > visibleDuration, !loaded.refusals.isEmpty {
                    let exact = try await runtime.waveformTracks(
                        model: snapshot, episode: episodeID,
                        startSeconds: visibleStart, durationSeconds: visibleDuration,
                        revealingCut: revealingCut
                    )
                    if exact.refusals.count < loaded.refusals.count,
                       Set(exact.tracks.map(\.id)).isSuperset(of: Set(loaded.tracks.map(\.id))) {
                        loaded = exact
                        publishedWindow = (visibleStart, visibleDuration)
                    }
                }
                #if DEBUG
                try await delayWaveformPublicationForUITest()
                #endif
                try Task.checkCancellation()
                guard generation == waveformGeneration else { return }
                guard document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                      timingIsVerified(snapshot) else {
                    waveformMessage = "The episode or verified timing changed. Save and load the current audio window again."
                    return
                }
                let prepared = try await AlignmentWaveformProjection.prepare(
                    load: loaded, episode: snapshot.episode(episodeID), cuts: cuts)
                guard generation == waveformGeneration,
                      document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                      timingIsVerified(snapshot) else { return }
                let tile = AlignmentWaveformCache.Tile(
                    modelGeneration: document.store.modelGeneration, episode: document.store.model.episode(episodeID),
                    start: publishedWindow.start, duration: publishedWindow.duration,
                    load: loaded, strokes: prepared.strokes, gains: prepared.gains, errors: prepared.errors,
                    indices: prepared.indices
                )
                let cacheVersion = waveformTilesVersion
                var cache = try await waveformCache.inserting(tile)
                try Task.checkCancellation()
                guard generation == waveformGeneration,
                      cacheVersion == waveformTilesVersion,
                      document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                      timingIsVerified(snapshot) else { return }
                if let episode = document.store.model.episode(episodeID) {
                    cache.adoptPresentation(of: episode, generation: document.store.modelGeneration)
                }
                waveformCache = cache
                waveformTilesVersion = UUID()
                publishWaveformTile(currentWaveformTile ?? tile)
                if waveformDurationSeconds <= 30, firstUncoveredWaveformTime(
                    start: waveformStartSeconds, duration: waveformDurationSeconds
                ) != nil {
                    scheduleScrubTile()
                }
            } catch is CancellationError {
                if generation == waveformGeneration { waveformMessage = "Waveform loading canceled." }
            } catch {
                guard generation == waveformGeneration else { return }
                waveformMessage = "Waveforms unavailable: \(error.localizedDescription)"
                    + (pendingWaveformMove == nil
                        ? "" : " The moved waveform remains an unverified visual preview; refresh audio to retry.")
                lastError = AlignmentPresentation.errorDescription(error)
            }
        }
    }

    func synchronizeWaveforms() {
        guard let document else { return }
        adoptCachedPresentation()
        if canRetainWaveformSamples, loadedWaveformGeneration == document.store.modelGeneration { return }
        loadWaveforms(keepingSnapshot: canRetainWaveformSamples)
    }

    private func adoptCachedPresentation() {
        guard let document, let prior = loadedWaveformEpisode,
              let current = document.store.model.episode(episodeID),
              EpisodeMediaInputs(prior) == EpisodeMediaInputs(current) else { return }
        waveformCache.adoptPresentation(of: current, generation: document.store.modelGeneration)
        loadedWaveformGeneration = document.store.modelGeneration
        loadedWaveformEpisode = current
        if let overview = loadedOverviewEpisode, EpisodeMediaInputs(overview) == EpisodeMediaInputs(current) {
            loadedOverviewEpisode = current
        }
    }

    private func reprojectWaveforms(model: ShowDocumentModel, modelGeneration: UInt64) {
        guard let document, reprojectingWaveformGeneration != modelGeneration else { return }
        cancelWaveforms(keepingSnapshot: true)
        cancelWaveformOverview(keepingSnapshot: true)
        let generation = waveformGeneration
        reprojectingWaveformGeneration = modelGeneration
        isLoadingWaveforms = true
        waveformMessage = "Verifying source identities and updating waveform positions; decoded audio is retained."
        waveformTask = Task {
            defer {
                if generation == waveformGeneration {
                    isLoadingWaveforms = false
                    reprojectingWaveformGeneration = nil
                    waveformTask = nil
                }
            }
            do {
                let retainedTracks = waveformTracks
                let retained = waveformTracks + waveformOverviewTracks + waveformCache.tracks
                let map = try await runtime.revalidateWaveforms(model: model, episode: episodeID, tracks: retained)
                try Task.checkCancellation()
                guard generation == waveformGeneration, document.store.model == model,
                      document.store.modelGeneration == modelGeneration, timingIsVerified(model) else {
                    waveformMessage = "Timing changed again before waveform positions were verified; refresh audio to retry."
                    return
                }
                waveformMessage = "Updating cached waveform coordinates."
                let projectedCache = try await waveformCache.reprojected(
                    map: map, episode: model.episode(episodeID), modelGeneration: modelGeneration,
                    revealingCut: listening.expandedManualCutID
                )
                let overview = try await AlignmentWaveformProjection.prepare(
                    load: AlignmentWaveformLoad(tracks: waveformOverviewTracks, refusals: [], map: map, mapWarning: nil),
                    episode: model.episode(episodeID), cuts: cutTimeline)
                guard generation == waveformGeneration, document.store.model == model,
                      document.store.modelGeneration == modelGeneration, timingIsVerified(model) else { return }
                guard overview.errors.isEmpty else {
                    throw ManualCutReviewFailure(reason: overview.errors.values.sorted().joined(separator: "; "))
                }
                waveformCache = projectedCache
                waveformOverviewStrokes = overview.strokes
                waveformOverviewIndices = overview.indices
                waveformOverviewDisplayGains = overview.gains
                waveformOverviewMap = map
                loadedOverviewEpisode = model.episode(episodeID)
                waveformOverviewSnapshotID = UUID()
                waveformTilesVersion = UUID()
                if let tile = waveformCache.tiles.last {
                    publishWaveformTile(tile)
                    waveformTracks = retainedTracks
                } else {
                    loadedWaveformMap = map
                    loadedWaveformEpisode = model.episode(episodeID)
                    loadedWaveformGeneration = modelGeneration
                    waveformStrokes = waveformOverviewStrokes
                    pendingWaveformMove = nil
                }
                waveformMessage = "Timing updated in place. Recordings and decoded waveform bins were retained."
            } catch is CancellationError {
                if generation == waveformGeneration {
                    waveformMessage = "Updating waveform positions was canceled; refresh audio to retry."
                }
            } catch {
                guard generation == waveformGeneration else { return }
                cancelWaveforms()
                cancelWaveformOverview()
                waveformMessage = "Waveform positions could not be verified: \(error.localizedDescription)"
                lastError = AlignmentPresentation.errorDescription(error)
            }
        }
    }

    private func publishWaveformTile(_ tile: AlignmentWaveformCache.Tile) {
        let previousEnd = loadedWaveformEpisode == tile.episode ? waveformNavigationEndSeconds : 0
        if let map = tile.load.map {
            let corrections = tile.episode?.alignment?.acceptedMap?.sourceCorrections ?? []
            let timed = AlignmentWaveformProjection.playableSources(in: map, corrections: corrections)
            alignedNavigationEndSeconds = max(
                AlignmentWaveformProjection.timelineEnd(map: map),
                corrections.filter { timed.contains($0.source) }.flatMap(\.segments).map(\.alignedEnd).max() ?? 0,
                AlignmentWaveformProjection.sourceTimelineEnd(durations: tile.load.tracks
                    .filter { !timed.contains($0.id) }
                    .map { (frames: $0.envelope.totalFrames, rate: $0.envelope.sampleRate) })
            )
        } else if tile.load.mapWarning == nil {
            alignedNavigationEndSeconds = max(
                previousEnd, AlignmentWaveformProjection.sourceTimelineEnd(
                    durations: tile.load.tracks.map {
                        (frames: $0.envelope.totalFrames, rate: $0.envelope.sampleRate)
                    }
                )
            )
        } else {
            alignedNavigationEndSeconds = 0
        }
        waveformTracks = tile.load.tracks
        waveformStrokes = tile.strokes
        waveformDisplayGains = tile.gains
        waveformProjectionErrors = tile.errors
        waveformSnapshotID = tile.id
        loadedWaveformGeneration = tile.modelGeneration
        if let episode = tile.episode { listening.playback.retainScopes(in: episode) }
        waveformRefusals = tile.load.refusals
        loadedWaveformMap = tile.load.map
        loadedWaveformEpisode = tile.episode
        refreshMeasuredSpeakerMatches()
        if pendingWaveformMove?.expectedGeneration == tile.modelGeneration {
            pendingWaveformMove = nil
        }
        waveformMessage = tile.load.mapWarning
            ?? "\(tile.load.tracks.count) recordings loaded; \(tile.load.refusals.count) failed to load. Measured tiles are cached in memory; originals stay unchanged."
        ensureWaveformOverview()
    }

    private func scheduleScrubTile() {
        scrubLoadTask?.cancel()
        scrubLoadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            scrubLoadTask = nil
            loadWaveforms(keepingSnapshot: true, preload: true)
        }
    }

    func cancelWaveforms(keepingSnapshot: Bool = false) {
        projectingCutView = false
        waveformGeneration += 1
        scrubLoadTask?.cancel()
        scrubLoadTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        pendingWaveformTile = nil
        isLoadingWaveforms = false
        reprojectingWaveformGeneration = nil
        if keepingSnapshot { return }
        waveformPickedPoint = nil
        pendingWaveformMove = nil
        waveformCache.removeAll()
        waveformTilesVersion = UUID()
        loadedWaveformGeneration = nil
        waveformTracks = []
        waveformStrokes = [:]
        waveformDisplayGains = [:]
        waveformProjectionErrors = [:]
        waveformRefusals = []
        loadedWaveformMap = nil
        loadedWaveformEpisode = nil
        alignedNavigationEndSeconds = 0
        waveformSnapshotID = UUID()
    }

    func ensureWaveformOverview() {
        guard let document, let episode = document.store.model.episode(episodeID),
              timingIsVerified(document.store.model) else { return }
        if canRetainWaveformSamples, loadedWaveformGeneration != document.store.modelGeneration { return }
        if isLoadingOverview, requestedOverviewEpisode == episode { return }
        if loadedOverviewEpisode == episode,
           waveformOverviewRefusals.isEmpty,
           Set(waveformTracks.map(\.id)).isSubset(of: Set(waveformOverviewTracks.map(\.id))) {
            return
        }
        loadWaveformOverview(keepingSnapshot: pendingWaveformMove != nil)
    }

    func loadWaveformOverview(keepingSnapshot: Bool = false) {
        guard let document else { return }
        cancelWaveformOverview(keepingSnapshot: keepingSnapshot)
        let generation = overviewGeneration
        let snapshot = document.store.model
        guard timingIsVerified(snapshot) else {
            waveformOverviewMessage = "Timing is not verified on disk yet. Save the show before loading its aligned overview."
            return
        }
        requestedOverviewEpisode = snapshot.episode(episodeID)
        isLoadingOverview = true
        waveformOverviewMessage = "Scanning every covered PCM sample; no partial overview is published."
        let cuts = cutTimeline
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
                #if DEBUG
                try await delayWaveformPublicationForUITest()
                #endif
                try Task.checkCancellation()
                guard generation == overviewGeneration else { return }
                guard document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID), timingIsVerified(snapshot) else {
                    waveformOverviewMessage = "The episode or verified timing changed. Save and reload its overview."
                    return
                }
                let prepared = try await AlignmentWaveformProjection.prepare(
                    load: loaded, episode: snapshot.episode(episodeID), cuts: cuts)
                guard generation == overviewGeneration,
                      document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                      timingIsVerified(snapshot) else { return }
                waveformOverviewTracks = loaded.tracks
                waveformOverviewStrokes = prepared.strokes
                waveformOverviewIndices = prepared.indices
                waveformOverviewDisplayGains = prepared.gains
                waveformOverviewProjectionErrors = prepared.errors
                waveformOverviewSnapshotID = UUID()
                waveformOverviewRefusals = loaded.refusals
                waveformOverviewMap = loaded.map
                loadedOverviewEpisode = snapshot.episode(episodeID)
                waveformOverviewProgress = 1
                waveformOverviewMessage = loaded.mapWarning
                    ?? "\(loaded.tracks.count) cached PCM overviews; \(loaded.refusals.count) failed to load. Click covered audio to load an exact window; coarse bins are not anchors."
            } catch is CancellationError {
                if generation == overviewGeneration {
                    waveformOverviewMessage = "Overview canceled or episode changed. No partial result was kept."
                }
            } catch {
                guard generation == overviewGeneration else { return }
                waveformOverviewMessage = "Overview unavailable: \(error.localizedDescription)"
                lastError = AlignmentPresentation.errorDescription(error)
            }
        }
    }

    #if DEBUG
    private func delayWaveformPublicationForUITest() async throws {
        if UserDefaults.standard.bool(forKey: "WWUITestHooks"),
           UserDefaults.standard.bool(forKey: "WWUITestVisualAlignmentFixture"),
           UserDefaults.standard.bool(forKey: "WWUITestDelayWaveformPublication") {
            try await Task.sleep(for: .seconds(12))
        }
    }
    #endif

    private func updateOverviewProgress(
        _ fraction: Double, generation: UInt64, snapshot: ShowDocumentModel
    ) throws {
        guard generation == overviewGeneration,
              document?.store.model.hasSameMediaInputs(as: snapshot, in: episodeID) == true else {
            throw CancellationError()
        }
        if fraction >= waveformOverviewProgress + 0.01 || fraction == 1 {
            waveformOverviewProgress = fraction
        }
    }

    func cancelWaveformOverview(keepingSnapshot: Bool = false) {
        overviewGeneration += 1
        overviewTask?.cancel()
        overviewTask = nil
        requestedOverviewEpisode = nil
        isLoadingOverview = false
        waveformOverviewProgress = 0
        if keepingSnapshot { return }
        waveformOverviewTracks = []
        waveformOverviewStrokes = [:]
        waveformOverviewIndices = [:]
        waveformOverviewDisplayGains = [:]
        waveformOverviewProjectionErrors = [:]
        waveformOverviewRefusals = []
        waveformOverviewMap = nil
        loadedOverviewEpisode = nil
        waveformOverviewMessage = "Overview cleared. Original recordings stay unchanged."
    }

    @discardableResult
    func previewWaveformPlayhead(to time: Double) -> Bool {
        guard groupDraftMilliseconds == 0,
              pendingWaveformMove == nil else {
            waveformMessage = "Finish the group preview or verified audio refresh before moving the shared timeline."
            return false
        }
        guard waveformNavigationEndSeconds > -86_400, time.isFinite,
              time >= -86_400, time <= min(waveformNavigationEndSeconds, 86_400) else {
            waveformMessage = "Choose a time within the available minus-24-to-plus-24-hour aligned timeline."
            return false
        }
        if canStopAudition { stopAudition() }
        waveformPlayheadSeconds = time
        auditionPlayheadSeconds = time
        return true
    }

    @discardableResult
    func previewWaveformWindow(start: Double) -> Bool {
        guard groupDraftMilliseconds == 0, pendingWaveformMove == nil else {
            waveformMessage = "Finish the group preview or verified audio refresh before moving the shared timeline."
            return false
        }
        guard start.isFinite, waveformViewingBounds.contains(start) else {
            waveformMessage = "Choose a window within the visible alignment workspace."
            return false
        }
        listening.workspace.followPlayhead = false
        waveformStartSeconds = start
        return true
    }

    func setFollowPlayhead(_ enabled: Bool) {
        listening.workspace.followPlayhead = enabled
        if enabled { followPlayheadIfNeeded() }
    }

    func followPlayheadIfNeeded() {
        guard listening.workspace.followPlayhead, pendingWaveformMove == nil,
              groupDraftMilliseconds == 0, waveformPlayheadSeconds.isFinite,
              waveformDurationSeconds.isFinite, waveformDurationSeconds > 0,
              waveformViewingBounds.contains(waveformPlayheadSeconds),
              waveformPlayheadSeconds < waveformStartSeconds
                || waveformPlayheadSeconds >= waveformStartSeconds + waveformDurationSeconds else { return }
        // This is presentation-only: never seek, reschedule, or replace the playback clock.
        waveformStartSeconds = waveformPlayheadSeconds
        if waveformDurationSeconds <= 30, firstUncoveredWaveformTime(
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            margin: waveformDurationSeconds / 2
        ) != nil { scheduleScrubTile() }
    }

    @discardableResult
    func previewWaveformViewport(start: Double, duration: Double) -> Bool {
        guard duration.isFinite, (0.5...maximumWaveformDuration).contains(duration) else {
            waveformMessage = "Choose a finite timeline duration between 0.5 seconds and the episode span."
            return false
        }
        guard previewWaveformWindow(start: start) else { return false }
        waveformDurationSeconds = duration
        if duration <= 30 { scheduleScrubTile() }
        return true
    }

    @discardableResult
    func zoomWaveformViewport(magnification: Double) -> Bool {
        guard let result = AlignmentWaveformProjection.rulerZoom(
            duration: waveformDurationSeconds, playhead: waveformPlayheadSeconds,
            magnification: magnification, bounds: waveformViewingBounds,
            maximumDuration: maximumWaveformDuration
        ) else {
            waveformMessage = "Choose a finite zoom and a playhead within the available timeline."
            return false
        }
        let follows = listening.workspace.followPlayhead
        let changed = previewWaveformViewport(start: result.start, duration: result.duration)
        listening.workspace.followPlayhead = follows
        return changed
    }

    func suspend() {
        publicationGeneration = UUID()
        cancelTracksAnalysis()
        tracksAcceptanceTask?.cancel()
        discardTracksReview()
        cancelAdaptiveAnalysis()
        cancelWaveforms()
        cancelWaveformOverview()
        alignedNavigationEndSeconds = 0
        inspectionGeneration += 1
        inspectionTask?.cancel()
        inspectionTask = nil
        stopAudition()
    }

    func playSelection(context: Double = 0) {
        guard let interval = listening.auditionRange(context: context, within: waveformAuditionBounds) else {
            auditionLabel = "Select an interval that overlaps available media."
            return
        }
        playEnabledTracks(interval: interval, repeatInterval: false)
    }

    var waveformAuditionBounds: ClosedRange<Double> {
        AlignmentWaveformProjection.overviewExtent(
            indices: waveformOverviewIndices.values, mappedOnly: true
        ) ?? 0...max(0.1, enabledTimelineEnd)
    }

    /// Explicit production listening. Panel visibility, source Solo/Mute, and comparison layouts
    /// never select this mode implicitly. Intervals use the collapsed shared-edit timeline.
    func playProductionMix(interval: ClosedRange<Double>? = nil) {
        adoptCachedPresentation()
        stopAudition()
        guard let document, let episode = document.store.model.episode(episodeID),
              timingIsVerified(document.store.model), !waveformTimingIsDraft,
              loadedWaveformMap != nil, !waveformNeedsRefreshAfterSave,
              groupDraftMilliseconds == 0, pendingWaveformMove == nil else {
            auditionLabel = "Save and verify accepted timing before playing the production mix."
            return
        }
        let generation = auditionGeneration
        listeningMode = .productionMix
        isPreparingAudition = true
        auditionLabel = "Preparing the confirmed Primary-speaker production mix."
        transportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try episode.manualCutTimeline()
                let sources = Set(episode.speakerAssignments.compactMap(\.primary?.sourceID))
                let end = min(86_400, timeline.editedTime(forAlignedTime: timelineEnd(for: sources, applyingCuts: false)))
                let position = timeline.editedTime(
                    forAlignedTime: cutTimeline.alignedTime(forEditedTime: waveformPlayheadSeconds))
                let start = interval?.lowerBound ?? position
                let last = min(end, interval?.upperBound ?? end)
                let schedule = try AlignedAuditionSchedule(startSeconds: start, endSeconds: last)
                let frames = schedule.firstFrame..<schedule.endFrame
                let recipe = try await mixer.prepare(programFrames: frames)
                guard generation == auditionGeneration else { throw CancellationError() }
                productionTimeline = timeline
                var next = recipe.programFrames.lowerBound
                @MainActor func enqueue(_ output: MixerPCMOutput, final: Bool) throws {
                    guard generation == auditionGeneration else { throw CancellationError() }
                    guard output.frameCount > 0 else { return }
                    try audioPlayback.enqueueProduction(output, final: final) { [weak self] in
                        guard let self else { return }
                        stopAudition()
                        let error = AlignmentTransportFailure.bufferDeadline
                        mixer.fail(error)
                        lastError = error.localizedDescription
                        auditionLabel = "Production playback stopped: \(error.localizedDescription)."
                    }
                    isAuditioning = true
                    isPreparingAudition = false
                    auditionLabel = "Playing the Primary-speaker production mix; source audition choices are unchanged."
                    if transportProgressTask == nil {
                        transportProgressTask = Task { [weak self] in
                            while let self, generation == auditionGeneration, !Task.isCancelled,
                                  let clock = audioPlayback.clock {
                                waveformPlayheadSeconds = cutTimeline.editedTime(
                                    forAlignedTime: timeline.alignedTime(forEditedTime: clock.playhead()))
                                followPlayheadIfNeeded()
                                do { try await Task.sleep(for: .milliseconds(50)) }
                                catch { return }
                            }
                        }
                    }
                }
                @MainActor func prepare(_ start: Int64) -> Task<MixerPCMWindow, any Error> {
                    let range = start..<min(start + Int64(MixerLiveTiming.sourceWindowFrames),
                        recipe.programFrames.upperBound)
                    return Task { try await mixer.preparePCM(range) }
                }
                productionPreparationTask = prepare(next)
                while next < recipe.programFrames.upperBound {
                    try Task.checkCancellation()
                    guard let preparation = productionPreparationTask else { throw MixerFailure.incompletePCM }
                    let input = try await preparation.value
                    guard generation == auditionGeneration else { throw CancellationError() }
                    productionPreparationTask = input.frames.upperBound < recipe.programFrames.upperBound
                        ? prepare(input.frames.upperBound) : nil
                    while next < input.frames.upperBound {
                        let end = min(next + Int64(MixerLiveTiming.processingBlockFrames), input.frames.upperBound)
                        let range = next..<end
                        let offset = Int(next - input.frames.lowerBound)
                        let samples = input.channels.mapValues { Array($0[offset..<(offset + range.count)]) }
                        let output = try await mixer.renderPrepared(.init(frames: range, channels: samples))
                        let lastInput = range.upperBound == recipe.programFrames.upperBound
                        try enqueue(output, final: lastInput && mixer.processor?.latencyFrames == 0)
                        next = range.upperBound
                        let horizon = Double(MixerLiveTiming.maximumScheduledAheadFrames) / Double(MixerRecipe.sampleRate)
                        while let clock = audioPlayback.clock,
                              clock.startedAt.addingTimeInterval(clock.duration).timeIntervalSinceNow > horizon {
                            try await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
                while let output = try await mixer.finishNext() {
                    let final = output.firstFrame + Int64(output.frameCount) == recipe.programFrames.upperBound
                    try enqueue(output, final: final)
                    let horizon = Double(MixerLiveTiming.maximumScheduledAheadFrames) / Double(MixerRecipe.sampleRate)
                    while let clock = audioPlayback.clock,
                          clock.startedAt.addingTimeInterval(clock.duration).timeIntervalSinceNow > horizon {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
                while let clock = audioPlayback.clock,
                      clock.startedAt.addingTimeInterval(clock.duration) > Date() {
                    waveformPlayheadSeconds = cutTimeline.editedTime(
                        forAlignedTime: timeline.alignedTime(forEditedTime: clock.playhead()))
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard generation == auditionGeneration else { return }
                stopPlayback(updatePlayhead: false)
                waveformPlayheadSeconds = cutTimeline.editedTime(forAlignedTime: timeline.alignedTime(forEditedTime: last))
                auditionPlayheadSeconds = waveformPlayheadSeconds
                auditionLabel = "Production mix reached the end of the selected program."
                transportTask = nil
            } catch {
                guard generation == auditionGeneration else { return }
                stopPlayback(updatePlayhead: true)
                transportTask = nil
                isPreparingAudition = false
                mixer.fail(error)
                lastError = error.localizedDescription
                auditionLabel = "Production playback stopped: \(error.localizedDescription). No substitute audio was played."
            }
        }
    }

    func playEnabledTracks(interval: ClosedRange<Double>? = nil, repeatInterval: Bool? = nil,
                           repeatWhile: (() -> Bool)? = nil, applyingCuts: Bool = true) {
        adoptCachedPresentation()
        guard let document, !enabledSources.isEmpty,
              loadedWaveformGeneration == document.store.modelGeneration,
              loadedWaveformMap != nil, groupDraftMilliseconds == 0, pendingWaveformMove == nil,
              !waveformTimingIsDraft, waveformPlayheadSeconds.isFinite,
              waveformPlayheadSeconds >= -86_400
        else {
            auditionLabel = "Place and apply timing before playing; only confirmed, enabled tracks can be heard."
            return
        }
        guard timingIsVerified(document.store.model) else {
            auditionLabel = "Timing is not verified on disk yet. Save the show before playing aligned audio."
            return
        }
        let enabled = enabledSources
        let timed = playableWaveformSources
        let sources = enabled.filter { timed.contains($0) }
        let availableSources = sources
            + waveformTracks.map(\.id).filter { timed.contains($0) && !enabled.contains($0) }
        let adaptiveSources = Set(loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections?.map(\.source) ?? [])
        guard !sources.isEmpty else {
            auditionLabel = "No enabled track has accepted timing. Set timing manually or enable a timed track."
            return
        }
        let requestedRange = interval ?? (listening.cycleEnabled ? listening.cycleRange : nil)
        let loops = repeatInterval ?? (listening.cycleEnabled && requestedRange != nil)
        let auditionBounds = applyingCuts ? waveformAuditionBounds : manualCutBounds ?? waveformAuditionBounds
        let timelineEnd = timelineEnd(for: Set(enabled), applyingCuts: applyingCuts)
        let firstPosition = requestedRange.map { max(auditionBounds.lowerBound, $0.lowerBound) }
            ?? waveformPlayheadSeconds
        let lastPosition = min(timelineEnd, requestedRange?.upperBound ?? timelineEnd)
        guard firstPosition.isFinite, lastPosition.isFinite, firstPosition < lastPosition else {
            auditionLabel = "Choose a playhead time covered by an enabled track with accepted timing."
            return
        }
        let omitted = enabled.count - sources.count
        stopAudition()
        listeningMode = .sourceAudition
        auditionUsesOriginalTime = !applyingCuts
        let snapshot = document.store.model
        let generation = auditionGeneration
        let revealingCut = listening.expandedManualCutID
        isPreparingAudition = true
        transportTask = Task { [weak self] in
            guard let self else { return }
            let end = min(lastPosition, self.timelineEnd(for: Set(availableSources), applyingCuts: applyingCuts), 86_400)
            let rate = Double(AlignedAuditionWindowReader.outputRate)
            var schedule: AlignedAuditionSchedule
            do {
                schedule = try AlignedAuditionSchedule(startSeconds: firstPosition, endSeconds: end,
                    usesAdaptiveTiming: availableSources.contains { adaptiveSources.contains($0) })
            }
            catch {
                stopPlayback(updatePlayhead: false)
                isPreparingAudition = false
                transportTask = nil
                lastError = AlignmentPresentation.errorDescription(error)
                auditionLabel = "Playback unavailable: \(error.localizedDescription)"
                return
            }
            let start = Double(schedule.firstFrame) / rate
            var preparedSources = sources
            var warmedSources: Set<SourceID> = []
            while !Task.isCancelled, generation == auditionGeneration, let frames = schedule.next() {
                do {
                    isPreparingAudition = true
                    if !isAuditioning {
                        auditionLabel = "Preparing timed tracks for live listening at the displayed map revision…"
                            + (omitted == 0 ? "" : " \(omitted) enabled untimed \(omitted == 1 ? "track is" : "tracks are") excluded.")
                    }
                    var joining: SourceID?
                    if let warm = transportWarmup {
                        warmedSources.insert(warm.source)
                        if enabledSources.contains(warm.source),
                           warm.frames.lowerBound <= frames.lowerBound, warm.frames.upperBound >= frames.upperBound {
                            joining = warm.source
                            transportWarmup = nil
                        } else if !enabledSources.contains(warm.source) || warm.frames.upperBound < frames.upperBound {
                            transportWarmup = nil
                        }
                    }
                    var requestedSources = preparedSources + (joining.map { [$0] } ?? [])
                    var clips: [SourceID: AlignmentRuntime.AuditionClip] = [:]
                    while true {
                        do {
                            clips = try await runtime.sourceAuditions(
                                model: snapshot, episode: episodeID,
                                sources: requestedSources, outputFrames: frames, applyingCuts: applyingCuts,
                                revealingCut: revealingCut
                            )
                            preparedSources = requestedSources
                            break
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as AlignmentRuntime.AuditionSourceFailure {
                            guard requestedSources.contains(error.source),
                                  error.source == joining || !enabledSources.contains(error.source) else {
                                throw error
                            }
                            transportUnavailable[error.source] = error.reason
                            audioPlayback.excludeSource(error.source)
                            requestedSources.removeAll { $0 == error.source }
                            guard !requestedSources.isEmpty else { throw error }
                        }
                    }
                    try Task.checkCancellation()
                    guard generation == auditionGeneration,
                          document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                          document.store.model.episode(episodeID)?.mix?.inputGains == snapshot.episode(episodeID)?.mix?.inputGains,
                          timingIsVerified(snapshot) else { throw CancellationError() }
                    guard !clips.isEmpty else { throw WaveformWindowError.invalidSamples }
                    isPreparingAudition = false
                    try enqueueTransport(
                        clips, startSeconds: Double(frames.lowerBound) / rate, first: !isAuditioning,
                        availableSources: Set(availableSources), final: frames.upperBound == schedule.endFrame
                    )
                    auditionUsesOriginalTime = !applyingCuts
                    if !isAuditioning {
                        let time = Double(frames.lowerBound) / rate
                        auditionPlayheadSeconds = applyingCuts ? time : cutTimeline.editedTime(forAlignedTime: time)
                    }
                    isAuditioning = true
                    refreshTransportGains()
                    let buffered = audioPlayback.clock.map {
                        $0.startedAt.addingTimeInterval($0.duration).timeIntervalSinceNow
                    } ?? 0
                    if transportWarmupTask == nil, transportWarmup == nil, schedule.nextFrame < schedule.endFrame,
                       buffered >= schedule.maximumBufferedSeconds / 2 {
                        let remaining = availableSources.filter {
                            !preparedSources.contains($0) && transportUnavailable[$0] == nil
                                && (!warmedSources.contains($0) || enabledSources.contains($0))
                        }
                        let warmStart = schedule.nextFrame + AlignedAuditionSchedule.followingFrames
                        if let source = remaining.first(where: { enabledSources.contains($0) }) ?? remaining.first,
                           warmStart < schedule.endFrame {
                            warmTransportSource(
                                source, model: snapshot, generation: generation,
                                frames: warmStart..<min(
                                    schedule.endFrame, warmStart + AlignedAuditionSchedule.initialFrames
                                ), applyingCuts: applyingCuts
                            )
                        }
                    }
                    if transportProgressTask == nil {
                        transportProgressTask = Task { [weak self] in
                            while let self, !Task.isCancelled, generation == auditionGeneration,
                                  isAuditioning, let started = audioPlayback.clock?.startedAt {
                                let time = min(end, start + max(0, -started.timeIntervalSinceNow))
                                waveformPlayheadSeconds = applyingCuts ? time : cutTimeline.editedTime(forAlignedTime: time)
                                refreshTransportGains()
                                followPlayheadIfNeeded()
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    }
                    while let started = audioPlayback.clock?.startedAt,
                          Double(frames.upperBound) / rate - start - max(0, -started.timeIntervalSinceNow)
                            >= schedule.maximumBufferedSeconds {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch is CancellationError {
                    if generation == auditionGeneration {
                        isPreparingAudition = false
                        stopPlayback(updatePlayhead: true)
                        transportTask = nil
                        auditionLabel = "Playback canceled or media inputs changed. No substitute audio was played."
                    }
                    return
                } catch {
                    guard generation == auditionGeneration else { return }
                    isPreparingAudition = false
                    lastError = AlignmentPresentation.errorDescription(error)
                    stopPlayback(updatePlayhead: true)
                    transportTask = nil
                    let reason = error is LocalizedError ? error.localizedDescription : String(describing: error)
                    auditionLabel = "Playback stopped: \(reason). No substitute audio was played."
                    return
                }
            }
            guard generation == auditionGeneration else { return }
            while let started = audioPlayback.clock?.startedAt,
                  max(0, -started.timeIntervalSinceNow) < Double(schedule.endFrame) / rate - start {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard generation == auditionGeneration else { return }
            stopPlayback(updatePlayhead: true)
            transportTask = nil
            waveformPlayheadSeconds = auditionPlayheadSeconds
            if loops, (repeatWhile?() ?? (listening.cycleEnabled && listening.cycleRange == requestedRange)),
               document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID) {
                playEnabledTracks(interval: requestedRange, repeatInterval: true,
                                  repeatWhile: repeatWhile, applyingCuts: applyingCuts)
            } else {
                waveformPlayheadSeconds = applyingCuts ? end : cutTimeline.editedTime(forAlignedTime: end)
                auditionLabel = requestedRange == nil
                    ? "Playback reached the end of the available timeline." : "Finished selection audition."
            }
        }
    }

    private func warmTransportSource(
        _ source: SourceID, model: ShowDocumentModel, generation: UInt64, frames: Range<Int64>,
        applyingCuts: Bool = true
    ) {
        transportWarmupTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == auditionGeneration { transportWarmupTask = nil } }
            do {
                let clips = try await runtime.sourceAuditions(
                    model: model, episode: episodeID, sources: [source], outputFrames: frames,
                    applyingCuts: applyingCuts, revealingCut: listening.expandedManualCutID
                )
                try Task.checkCancellation()
                guard generation == auditionGeneration,
                      document?.store.model.hasSameMediaInputs(as: model, in: episodeID) == true,
                      timingIsVerified(model), clips[source] != nil else { throw CancellationError() }
                transportWarmup = (source, frames)
            } catch is CancellationError {
                return
            } catch {
                guard generation == auditionGeneration, !Task.isCancelled else { return }
                transportUnavailable[source] = error is LocalizedError
                    ? error.localizedDescription : String(describing: error)
                refreshTransportGains()
            }
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

    func jumpEnabledTracks(by seconds: Double) {
        guard seconds.isFinite else {
            auditionLabel = "Choose a finite timeline jump."
            return
        }
        let upper = waveformNavigationEndSeconds == 0 ? 86_400 : min(86_400, waveformNavigationEndSeconds)
        let lower = manualCutBounds.map { cutTimeline.editedTime(forAlignedTime: $0.lowerBound) }
            ?? waveformAuditionBounds.lowerBound
        seekEnabledTracks(to: max(lower, min(upper, waveformPlayheadSeconds + seconds)))
    }

    func seekEnabledTracks(to seconds: Double) {
        guard seconds.isFinite, (-86_400...86_400).contains(seconds),
              (waveformNavigationEndSeconds == 0 || seconds <= waveformNavigationEndSeconds) else {
            waveformPlayheadSeconds = auditionPlayheadSeconds
            auditionLabel = "Choose an aligned playhead within the available minus-24-to-plus-24-hour timeline."
            return
        }
        let wasPlaying = canStopAudition
        stopAudition()
        waveformPlayheadSeconds = seconds
        auditionPlayheadSeconds = seconds
        if seconds < waveformStartSeconds || seconds > waveformStartSeconds + waveformDurationSeconds,
           let window = AlignmentWaveformProjection.windowStart(
               centeredAt: seconds, duration: min(30, waveformDurationSeconds)
           ) {
            waveformDurationSeconds = min(30, waveformDurationSeconds)
            waveformStartSeconds = window
            if firstUncoveredWaveformTime(
                start: window, duration: waveformDurationSeconds, margin: waveformDurationSeconds / 2
            ) != nil { scheduleScrubTile() }
        }
        if wasPlaying { playEnabledTracks() }
    }

    func compareAlignedAtPlayhead() {
        guard let document, let track = selectedWaveform, canCompareAligned,
              !canStopAudition, waveformPlayheadSeconds.isFinite,
              (-86_400...86_400).contains(waveformPlayheadSeconds)
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
                guard document.store.model == snapshot, timingIsVerified(snapshot) else {
                    throw CocoaError(.userCancelled)
                }
                try play(clip, startSeconds: start)
                isAuditioning = true
                auditionLabel = "Aligned comparison: reference channel 1 left, selected channel \(channel + 1) right. Uncovered map regions are silent. Nothing is exported."
            } catch {
                guard generation == auditionGeneration else { return }
                stopPlayback(updatePlayhead: false)
                if Task.isCancelled { return }
                lastError = AlignmentPresentation.errorDescription(error)
                let reason = error is LocalizedError ? error.localizedDescription : String(describing: error)
                auditionLabel = "Aligned comparison unavailable: \(reason). No partial audio was played."
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
        placeAnchors(waveformDraftAnchors, source: selectedWaveformSource)
    }

    var canCorrect: Bool {
        guard let row = selectedRow else { return false }
        return !isWorking && !positionIsLocked(row.groupID) && row.state.remedies.contains("Edit Numerically…")
    }
    /// Splitting at an endpoint produces an empty span, which the pipeline rejects. Only an anchor
    /// strictly inside the selected occurrence's span can start a new epoch.
    var canStartNewEpoch: Bool {
        canCorrect && selectedAnchorSplit() != nil
    }
    var canAudition: Bool {
        selectedRow?.state.remedies.contains("Audition") == true && !isWorking
    }
    var canStopAudition: Bool { isPreparingAudition || isAuditioning }
    var canPlaceAnchorAtPlayhead: Bool {
        canCorrect && !isAuditioning && selectedAnchors.count >= 2
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
        case "Go to Recording Segment Before":
            if let epoch = region.precedingEpoch { selection = epoch }
        case "Go to Recording Segment After":
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
        if let row = selectedRow, positionIsLocked(row.groupID) {
            lastError = "Unlock this recorder's position before splitting its accepted timing."
            return
        }
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
        let epoch = RecordingEpoch(label: "Recording Segment \(next)", note: "Started at a manual anchor")
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
                    message = "Started \(epoch.label) at the selected anchor. The new recording segment is unsupported until you time it."
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
                lastError = AlignmentPresentation.errorDescription(error)
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
            message = "Select a recording segment before starting a new recording segment at an anchor."
            return
        }
        guard let selectedAnchorID = anchorSelection,
              let anchor = selectedAnchors.first(where: { $0.id == selectedAnchorID })
        else {
            message = "Select an anchor in the Anchors table before starting a new recording segment."
            return
        }
        guard acceptedMap != nil else {
            message = "Time this recording segment before starting a new recording segment at an anchor."
            return
        }
        message = "The anchor at \(AlignmentPresentation.formatTime(anchor.sourceSeconds)) is an endpoint of "
            + "\(row.epochLabel)'s recorded span. Select an anchor inside the span to start a new recording segment there."
    }

    private struct AnchorSplit {
        var anchor: AlignmentAnchorRow
        var row: AlignmentRow
        var placement: OccurrencePlacement
        var frame: Int64
    }

    func auditionSelection() {
        guard let document, let epoch = selection, canAudition, !isAuditioning,
              auditionStartSeconds.isFinite, auditionStartSeconds >= 0,
              auditionDurationSeconds.isFinite, auditionDurationSeconds > 0
        else { return }
        stopAudition()
        let snapshot = document.store.model
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
                    durationSeconds: auditionDurationSeconds,
                    inputGains: snapshot.episode(episodeID)?.mix?.inputGains ?? []
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingAudition,
                              self.auditionGeneration == generation else { return }
                        self.auditionLabel = "Seeking through the source… \(Int(progress * 100))%. Nothing is exported."
                    }
                }
                try Task.checkCancellation()
                guard generation == auditionGeneration,
                      document.store.model.hasSameProcessingInputs(as: snapshot, in: episodeID) else {
                    throw CancellationError()
                }
                try play(clip)
                try Task.checkCancellation()
                isAuditioning = true
                auditionLabel = "Auditioning the selected source region as an internal check. Nothing is exported."
            } catch is CancellationError {
                if generation == auditionGeneration { stopPlayback(updatePlayhead: true) }
            } catch {
                guard generation == auditionGeneration else { return }
                lastError = AlignmentPresentation.errorDescription(error)
                auditionLabel = (error as? LocalizedError)?.errorDescription
                    ?? "Audition unavailable for this source."
            }
        }
    }

    private func synchronizeCuts() {
        guard let episode = document?.store.model.episode(episodeID) else { return }
        do {
            if let id = listening.expandedManualCutID, !episode.activeManualCuts.contains(where: { $0.id == id }) {
                listening.expandedManualCutID = nil
            }
            let timeline = try episode.manualCutTimeline(revealing: listening.expandedManualCutID)
            guard timeline != cutTimeline else { return }
            stopAudition()
            let alignedPlayhead = cutTimeline.alignedTime(forEditedTime: waveformPlayheadSeconds)
            let alignedStart = cutTimeline.alignedTime(forEditedTime: waveformStartSeconds)
            cutTimeline = timeline
            waveformPlayheadSeconds = timeline.editedTime(forAlignedTime: alignedPlayhead)
            auditionPlayheadSeconds = waveformPlayheadSeconds
            waveformStartSeconds = timeline.editedTime(forAlignedTime: alignedStart)
            listening.selection = nil
            listening.cycleRange = nil
            listening.cycleEnabled = false
            cancelWaveforms(keepingSnapshot: true)
            cancelWaveformOverview(keepingSnapshot: true)
            let generation = waveformGeneration
            let modelGeneration = document?.store.modelGeneration ?? 0
            let cache = waveformCache
            let map = loadedWaveformMap
            let overview = AlignmentWaveformLoad(tracks: waveformOverviewTracks, refusals: [],
                map: waveformOverviewMap, mapWarning: nil)
            let revealingCut = listening.expandedManualCutID
            isLoadingWaveforms = true
            projectingCutView = true
            waveformMessage = "Updating the cut view; original recordings and alignment are unchanged."
            waveformTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if generation == waveformGeneration {
                        isLoadingWaveforms = false
                        projectingCutView = false
                        waveformTask = nil
                    }
                }
                do {
                    let projectedCache = try await cache.reprojected(map: map, episode: episode,
                        modelGeneration: modelGeneration, revealingCut: revealingCut)
                    let projectedOverview = try await AlignmentWaveformProjection.prepare(
                        load: overview, episode: episode, cuts: timeline)
                    try Task.checkCancellation()
                    guard generation == waveformGeneration, cutTimeline == timeline,
                          document?.store.modelGeneration == modelGeneration else { return }
                    guard projectedOverview.errors.isEmpty else {
                        throw ManualCutReviewFailure(reason: projectedOverview.errors.values.sorted().joined(separator: "; "))
                    }
                    waveformCache = projectedCache
                    waveformTilesVersion = UUID()
                    waveformOverviewStrokes = projectedOverview.strokes
                    waveformOverviewIndices = projectedOverview.indices
                    waveformOverviewDisplayGains = projectedOverview.gains
                    waveformOverviewSnapshotID = UUID()
                    waveformMessage = "Manual cuts ripple every aligned track. Original recordings and alignment are unchanged."
                    if waveformDurationSeconds <= 30 { scheduleScrubTile() }
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == waveformGeneration else { return }
                    lastError = "Manual cuts could not be displayed: \(error)."
                    waveformMessage = lastError ?? "Cut view unavailable."
                }
            }
        } catch {
            lastError = "Manual cuts could not be displayed: \(error)."
            stopAudition()
        }
    }

    func load() {
        guard let document else { return }
        synchronizeCuts()
        if let prior = inspectedEpisode, let current = document.store.model.episode(episodeID),
           EpisodeMediaInputs(prior) == EpisodeMediaInputs(current) {
            rows = Self.makeRows(model: document.store.model, episodeID: episodeID,
                                 states: inspectedStates, map: acceptedMap)
            inspectedEpisode = current
            return
        }
        inspectionGeneration += 1
        let generation = inspectionGeneration
        inspectionTask?.cancel()
        let model = document.store.model
        let episode = model.episode(episodeID)
        if observedRevision != episode?.alignment?.acceptedRevision {
            observedRevision = episode?.alignment?.acceptedRevision
            clearWaveformMarkers()
            staleAcceptedTiming = false
            discardAlignmentAnalysis()
            speakerMatches = [:]
            selectedMatchOption = nil
            analyzedInputs = nil
        }
        if observedAssignments != episode?.speakerAssignments {
            observedAssignments = episode?.speakerAssignments
            analysisStates = [:]
            speakerMatches = [:]
            analyzedInputs = nil
            selectedMatchOption = nil
            selectedMatchSpeaker = nil
        }
        if analyzedInputs != episode.map({ EpisodeMediaInputs($0) }) {
            analysisStates = [:]
            speakerMatches = [:]
            selectedMatchOption = nil
            selectedMatchSpeaker = nil
            analysisSourceEndByEpoch = [:]
            analyzedInputs = nil
        }
        if let pendingWaveformMove,
           pendingWaveformMove.expectedGeneration != document.store.modelGeneration {
            cancelWaveforms(keepingSnapshot: canRetainWaveformSamples)
            self.pendingWaveformMove = nil
        }
        if let loaded = loadedOverviewEpisode,
           !AlignmentWaveformProjection.canReuseSamples(from: loaded, to: episode) {
            let retainsPendingPreview = pendingWaveformMove?.expectedGeneration == document.store.modelGeneration
                && loaded.sources == episode?.sources && loaded.recorderGroups == episode?.recorderGroups
            if !retainsPendingPreview {
                cancelWaveformOverview()
                waveformOverviewMessage = "Episode timing or sources changed. Build the current overview again."
            }
        }
        if let loaded = loadedWaveformEpisode,
           !AlignmentWaveformProjection.canReuseSamples(from: loaded, to: episode) {
            cancelWaveforms()
            stopAudition()
            waveformMessage = "Source assignments changed. Load the current audio window again."
        }
        let interval = Responsiveness.begin("alignment.episodeSwitch")
        inspectionTask = Task {
            defer { if let interval { Responsiveness.endAfterCommit(interval) } }
            do {
                let prepared = try await runtime.inspect(model: model, episode: episodeID)
                guard !Task.isCancelled, generation == inspectionGeneration,
                      document.store.model.hasSameMediaInputs(as: model, in: episodeID) else { return }
                let snapshot = prepared.snapshot
                acceptedMap = snapshot?.acceptedMap
                inspectionSnapshot = snapshot
                inspectedEpisode = episode
                refreshMeasuredSpeakerMatches()
                inspectedStates = snapshot?.states ?? []
                hasAnalysis = snapshot?.acceptedMap != nil
                rows = Self.makeRows(
                    model: model,
                    episodeID: episodeID,
                    states: snapshot?.states ?? [],
                    map: snapshot?.acceptedMap
                )
                if selection == nil { selection = rows.first?.epochID }
                anchorsByEpoch = AlignmentPresentation.makeAnchors(map: snapshot?.acceptedMap)
                resetWaveformTiming()
                if !waveformTracks.isEmpty, loadedWaveformEpisode?.alignment != episode?.alignment {
                    stopAudition()
                    if pendingWaveformMove == nil { synchronizeWaveforms() }
                }
                if !selectedAnchors.contains(where: { $0.id == anchorSelection }) {
                    anchorSelection = selectedAnchors.first?.id
                }
                await updateDependents()
                if let warning = prepared.reconciliationWarning {
                    message = "The persisted map is visible, but its derived identity could not be restored: \(warning)"
                } else if message == "Alignment has not read or analyzed any audio.",
                          let revision = episode?.alignment?.acceptedRevision, snapshot?.acceptedMap != nil {
                    message = "Saved alignment revision \(revision) loaded. Solo and playback use accepted timing; transcription setup is separate."
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == inspectionGeneration,
                      document.store.model.hasSameMediaInputs(as: model, in: episodeID) else { return }
                lastError = error.localizedDescription
                message = "Alignment inspection failed: \(error.localizedDescription)"
                stopAudition()
            }
        }
    }

    func requestAlignTracks() {
        guard let document, !isWorking else { return }
        let snapshot = document.store.model
        Task {
            if hasAcceptedRevision {
                guard await Dialogs.confirm(
                    in: document.windowControllers.first?.window, message: "Align Tracks Again?",
                    informative: "Current timing, transcription and edits stay in place while you analyze and review. Accepting replacement alignment resets active transcription, transcript-linked reviews, cuts and episode IN/OUT as one undoable change. Original recordings, assignments and recoverable history remain. This operation may reposition locked non-reference groups. \(timingReferenceSelection.detail)",
                    confirmTitle: "Analyze Tracks"
                ) else { return }
            }
            guard document.store.model == snapshot else {
                lastError = "The show changed while confirming alignment. Review the current episode and try again."
                return
            }
            analyzeTracks()
        }
    }

    func analyzeTracks() {
        guard let document, !isWorking, pendingWaveformMove == nil else { return }
        let snapshot = document.store.model
        guard timingIsVerified(snapshot) else {
            lastError = "Save and verify current accepted alignment before analyzing replacement timing."
            return
        }
        isWorking = true
        lastError = nil
        tracksReport = nil
        tracksSnapshot = nil
        message = "Analyzing eligible recorder groups using shared speaker channels. Current timing and edits remain unchanged."
        tracksAnalysisTask = Task {
            defer { isWorking = false; tracksAnalysisTask = nil }
            do {
                let report = try await runtime.analyzeTracks(model: snapshot, episode: episodeID)
                try Task.checkCancellation()
                let states = await runtime.pipeline.states(
                    model: snapshot, episode: episodeID, report: report, reviewingAnalysis: true
                )
                try Task.checkCancellation()
                guard document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID) else {
                    lastError = "Sources, assignments or timing changed during analysis. Run Align Tracks again."
                    return
                }
                let priorReference = try snapshot.episode(episodeID)?.alignment?.acceptedRevision.map {
                    try snapshot.timeMap(revision: $0, in: episodeID).reference
                }
                let replacesReference = priorReference.map {
                    report.plan.reference?.group != $0.group || report.plan.reference?.epoch != $0.epoch
                        || report.plan.reference?.occurrence != $0.occurrence
                } ?? false
                tracksReport = report
                // Capture current downstream work only after analysis; later changes must not be discarded.
                tracksSnapshot = document.store.model
                tracksReviewRows = Self.makeRows(model: snapshot, episodeID: episodeID, states: states)
                for index in tracksReviewRows.indices {
                    let epoch = tracksReviewRows[index].epochID
                    if let failure = report.epochFailures[epoch] {
                        switch failure {
                        case let .setupRequired(detail):
                            tracksReviewRows[index].state = AlignmentPresentation.copy(
                                for: .unsupported(.notAttempted, .analysisFailed(.setupRequired(detail)))
                            )
                        case let .encoding(detail):
                            tracksReviewRows[index].state.details = detail
                        default:
                            tracksReviewRows[index].state.details = String(describing: failure)
                        }
                    } else if let record = report.records[epoch] {
                        let reference = snapshot.episode(episodeID)?.source(record.reference.source)?.displayNameHint
                            ?? "\(record.reference.source)"
                        let referenceTiming = replacesReference
                            ? "the newly selected reference's original recording clock"
                            : report.referenceRevision.map { "previously accepted timing revision \($0)" }
                                ?? "the fixed timeline reference"
                        let proposal = record.proposal.map {
                            String(format: "Measured interval %.3f-%.3f s; proposed offset at center %.6f s; drift %.3f ppm.",
                                   $0.segment.groupClockStart.approximateDouble,
                                   $0.segment.groupClockEnd.approximateDouble, $0.offsetAtCenterSeconds, $0.ppm)
                        }
                        tracksReviewRows[index].state.details = [
                            record.abstention?.detail,
                            "Reference recording: \(reference), using \(referenceTiming).",
                            proposal,
                            AlignmentPresentation.automaticEvidence(record),
                        ].compactMap { $0 }.joined(separator: "\n")
                    }
                    if let adaptive = report.adaptiveRecords[epoch] {
                        tracksReviewRows[index].state.heading = adaptive.timing.regions.isEmpty
                            ? "Adaptive timing unavailable" : "Adaptive file timing proposed"
                        tracksReviewRows[index].state.evidence = AlignmentPresentation.adaptiveEvidence(adaptive)
                        tracksReviewRows[index].state.details = [
                            "A single offset/rate could not fit this recording. Local timing was measured automatically.",
                            adaptive.refusal,
                            "Only this file's channels use the adaptive curve; sibling recordings and the fixed reference are not moved by it.",
                        ].compactMap { $0 }.joined(separator: "\n")
                    }
                }
                tracksReviewProposals = Set(states.filter { $0.analysis?.proposal != nil }.map(\.epoch))
                selectedTracksProposals = []
                selectedTracksAdaptive = []
                tracksReviewPresented = true
                message = "Analysis finished. Review recorder and adaptive file timing before accepting. Adaptive timing retains all audio; unverified gaps and ends are labeled estimated."
            } catch is CancellationError {
                message = "Alignment analysis canceled. Current timing and downstream work are unchanged."
            } catch AlignmentAcceptanceError.invalidMap(let reason) {
                lastError = reason
                message = "Alignment analysis could not use the selected reference. Current timing and downstream work are unchanged."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "Alignment analysis failed. Current timing and downstream work are unchanged. Check source authorization, grouping and speaker channels in Recordings & Speakers."
            }
        }
    }

    func cancelTracksAnalysis() { tracksAnalysisTask?.cancel() }

    private func refreshMeasuredSpeakerMatches() {
        guard let inspectionSnapshot, let inspectedEpisode,
              let live = document?.store.model.episode(episodeID),
              EpisodeMediaInputs(live) == EpisodeMediaInputs(inspectedEpisode) else {
            speakerMatches = [:]
            return
        }
        let counts: [SourceID: Int]
        if loadedWaveformEpisode.map({ EpisodeMediaInputs($0) }) == EpisodeMediaInputs(inspectedEpisode) {
            counts = Dictionary(uniqueKeysWithValues: waveformTracks.map { ($0.id, $0.envelope.channelCount) })
        } else {
            counts = [:]
        }
        speakerMatches = inspectionSnapshot.speakerMatches(in: inspectedEpisode, channelCounts: counts)
    }

    func discardTracksReview() {
        tracksReviewPresented = false
        tracksReport = nil
        tracksSnapshot = nil
        tracksReviewRows = []
        tracksReviewProposals = []
        selectedTracksProposals = []
        selectedTracksAdaptive = []
    }

    func acceptTracksReview() {
        guard let document, canAcceptTracksReview, let report = tracksReport, let snapshot = tracksSnapshot else { return }
        if let episode = snapshot.episode(episodeID), episode.alignment?.acceptedRevision == nil,
           tracksReviewRows.contains(where: {
               (selectedTracksProposals.contains($0.epochID) || selectedTracksAdaptive.contains($0.epochID))
                    && episode.positionIsLocked($0.groupID)
           }) {
            lastError = "A selected recorder position is locked. Unlock it in advanced timing, then run Align Tracks again. No work was changed."
            return
        }
        isWorking = true
        lastError = nil
        let selected = selectedTracksProposals
        let adaptive = selectedTracksAdaptive
        let estimated = adaptive
        tracksAcceptanceTask = Task {
            defer { isWorking = false; tracksAcceptanceTask = nil }
            do {
                guard document.store.model.hasSameMediaInputs(as: snapshot, in: episodeID),
                      document.store.model.episode(episodeID)?.cleanup == snapshot.episode(episodeID)?.cleanup else {
                    lastError = "Timing inputs or downstream work changed during review. Cancel and run Align Tracks again; nothing was reset."
                    return
                }
                let accepted = try await runtime.acceptTracks(
                    model: snapshot, episode: episodeID, report: report, selected: selected,
                    adaptive: adaptive, estimated: estimated
                )
                try Task.checkCancellation()
                guard publishAlignment(
                    accepted, expecting: snapshot, actionName: "Accept Tracks Alignment",
                    resettingDownstream: snapshot.episode(episodeID)?.alignment?.acceptedRevision != nil
                ) else {
                    lastError = message
                    return
                }
                discardTracksReview()
                message = "Alignment accepted. Timing activates only after verified save. With the same reference, unselected recordings keep their saved timing. Adaptive files retain all audio with unverified timing labeled estimated."
            } catch is CancellationError {
                message = "Alignment acceptance canceled. Current timing and downstream work are unchanged."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "Alignment was not accepted. Current timing and downstream work are unchanged."
            }
        }
    }

    func analyze() {
        guard let document, !isWorking else { return }
        guard let episode = document.store.model.episode(episodeID), let group = selectedRow?.groupID,
              !episode.positionIsLocked(group) else {
            message = "Unlock this recorder's position before running alignment. Navigation and listening remain available."
            return
        }
        guard !pendingResetVerification || timingIsVerified(document.store.model) else {
            message = "Save verification must finish before analyzing the fresh timeline."
            return
        }
        guard let epoch = selection,
              let pair = selectedMatchOption ?? selectedSpeakerPairs.first else {
            message = "Select a recording segment with the same identified speaker on an already aligned recorder. State the speaker's channels in Setup, or place this recording segment manually."
            return
        }
        isWorking = true
        adaptiveAnalysis = nil
        adaptiveEpisode = nil
        adaptivePair = nil
        selectedMatchSpeaker = pair.speaker
        selectedMatchOption = pair
        adaptiveProgress = 0
        lastError = nil
        analysisStates = [:]
        analysisSourceEndByEpoch = [:]
        analyzedInputs = nil
        message = "Indexing full speaker recordings and matching passages… The first scan can take a while; unchanged fingerprints are cached."
        let model = document.store.model
        isMeasuringAdaptiveTiming = false
        adaptiveTask = Task {
            defer {
                isWorking = false
                adaptiveTask = nil
                adaptiveProgress = 0
                isMeasuringAdaptiveTiming = false
            }
            do {
                let report = try await runtime.analyzeSpeaker(
                    model: model, episode: episodeID, targetEpoch: epoch, speaker: pair.speaker,
                    referenceSource: pair.reference.source, targetSource: pair.target
                )
                var adaptive: AdaptiveAnalysisRecord?
                if report.records[epoch]?.needsAdaptiveTiming == true {
                    isMeasuringAdaptiveTiming = true
                    message = "A single offset/rate does not fit. Measuring local timing for adaptive review; nothing will be applied."
                    adaptive = try await runtime.analyzeAdaptiveSpeaker(
                        model: model, episode: episodeID, targetEpoch: epoch, pair: pair
                    ) { value in
                        await MainActor.run {
                            guard self.isWorking, self.selectedMatchOption == pair else { return }
                            self.adaptiveProgress = value
                        }
                    }
                }
                try Task.checkCancellation()
                let states = await runtime.states(model: model, episode: episodeID)
                guard document.store.model.hasSameMediaInputs(as: model, in: episodeID),
                      selection == epoch, (selectedMatchOption ?? selectedSpeakerPairs.first) == pair
                else {
                    message = "The speaker pair, sources, or accepted timing changed during analysis. Run alignment again."
                    isWorking = false
                    return
                }
                analyzedInputs = model.episode(episodeID).map { EpisodeMediaInputs($0) }
                adaptiveAnalysis = adaptive
                adaptiveEpisode = adaptive == nil ? nil : model.episode(episodeID)
                adaptivePair = adaptive == nil ? nil : pair
                inspectedStates = states
                analysisStates = Dictionary(uniqueKeysWithValues: states.map { ($0.epoch, $0) })
                analysisSourceEndByEpoch = Dictionary(uniqueKeysWithValues: report.plan.epochs.map { epoch in
                    (epoch.epoch, epoch.sources.compactMap { source in
                        report.facts[source].map { Double($0.frameCount) / Double($0.sampleRate) }
                    }.max() ?? 0)
                })
                hasAnalysis = true
                rows = Self.makeRows(
                    model: document.store.model, episodeID: episodeID, states: states,
                    map: acceptedMap
                )
                selection = selection ?? rows.first?.epochID
                let proposals = report.records.values.filter { $0.proposal != nil }.count
                message = adaptive.map(AlignmentPresentation.adaptiveEvidence)
                    ?? "Analysis finished: \(proposals) acoustic proposal\(proposals == 1 ? "" : "s"). Review each recording segment's evidence; nothing was applied. Uncertain or unavailable matches stay manual."
            } catch is CancellationError {
                message = "Alignment analysis canceled. No timing was applied."
            } catch AlignmentWorkFailure.canceled {
                message = "Alignment analysis canceled. No timing was applied."
            } catch AlignmentAcceptanceError.analysisStale(let changes) where changes.contains(.dependenciesChanged) {
                staleAcceptedTiming = true
                lastError = "Accepted timing no longer matches the recorded source revisions. No new alignment was applied. Confirm and restore changed originals in Setup, or use Reset Alignment to retire the old timing before placing groups again."
                message = "Stored timing is stale. Analysis did not run."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "Analysis did not complete. No partial result was accepted."
            }
        }
    }

    func analyzeAdaptively(_ track: AlignmentWaveformTrack, with pair: SpeakerMatchOption) {
        guard let document, !isWorking, matchOptions(for: track).contains(pair) else { return }
        guard !pendingResetVerification || timingIsVerified(document.store.model) else {
            message = "Save verification must finish before adaptive analysis."
            return
        }
        selectWaveform(track)
        selectedMatchSpeaker = pair.speaker
        selectedMatchOption = pair
        adaptiveAnalysis = nil
        adaptiveEpisode = nil
        analysisStates = [:]
        analyzedInputs = nil
        isWorking = true
        lastError = nil
        adaptiveProgress = 0
        isMeasuringAdaptiveTiming = true
        message = "Measuring local speaker timing throughout the overlap… Full-length review can take several minutes; nothing will be applied."
        let model = document.store.model
        adaptiveTask = Task {
            defer {
                isWorking = false
                adaptiveTask = nil
                adaptiveProgress = 0
                isMeasuringAdaptiveTiming = false
            }
            do {
                let record = try await runtime.analyzeAdaptiveSpeaker(
                    model: model, episode: episodeID, targetEpoch: track.epoch, pair: pair
                ) { value in
                    await MainActor.run {
                        guard self.isWorking, self.selectedMatchOption == pair else { return }
                        self.adaptiveProgress = value
                    }
                }
                try Task.checkCancellation()
                guard let snapshot = model.episode(episodeID),
                      let live = document.store.model.episode(episodeID),
                      EpisodeMediaInputs(live) == EpisodeMediaInputs(snapshot),
                      selection == track.epoch, selectedMatchOption == pair else {
                    message = "The speaker pair, sources, or accepted timing changed. Adaptive evidence was discarded."
                    return
                }
                adaptiveAnalysis = record
                adaptiveEpisode = snapshot
                adaptivePair = pair
                message = "Adaptive review: \(record.timing.regions.count) independent measured runs, \(record.timing.anchoredRecovery?.regions.count ?? 0) anchor-guided matches and \(record.timing.quietTransitions?.count ?? 0) quiet-only transitions. All audio will be retained; unmatched timing is estimated. Nothing was applied or played."
            } catch is CancellationError {
                message = "Adaptive review canceled. No timing was applied."
            } catch AlignmentWorkFailure.canceled {
                message = "Adaptive review canceled. No timing was applied."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "Adaptive analysis did not complete. No timing was applied."
            }
        }
    }

    func cancelAdaptiveAnalysis() {
        guard let adaptiveTask else { return }
        adaptiveTask.cancel()
        message = "Canceling adaptive review… No timing was applied."
    }

    func saveAdaptiveCorrection(removing source: SourceID? = nil, restoringAudio: SourceID? = nil) {
        guard let document, !isWorking else { return }
        let record = currentAdaptiveAnalysis
        let targetSource = source ?? restoringAudio ?? record?.target.source
        guard let targetSource, let episode = document.store.model.episode(episodeID),
              let group = episode.source(targetSource)?.placement.recorderGroupID,
              !positionIsLocked(group) else {
            lastError = "Unlock this recorder before applying or removing file-local timing."
            return
        }
        guard source != nil || restoringAudio != nil || record?.timing.regions.isEmpty == false else { return }
        guard !pendingResetVerification || timingIsVerified(document.store.model) else { return }
        let prior = document.store.model
        stopAudition()
        isWorking = true
        lastError = nil
        Task {
            defer { isWorking = false }
            do {
                let accepted: AcceptedAlignment
                if let source {
                    accepted = try await runtime.removeAdaptive(model: prior, episode: episodeID, source: source)
                } else if let restoringAudio {
                    accepted = try await runtime.preserveAdaptiveAudio(
                        model: prior, episode: episodeID, source: restoringAudio)
                } else if let record {
                    accepted = try await runtime.acceptAdaptive(model: prior, episode: episodeID, record: record,
                                                               includeEstimated: true)
                } else { return }
                guard publishAlignment(accepted, expecting: prior,
                    actionName: restoringAudio != nil ? "Restore Unmatched Audio"
                        : source == nil ? UndoActionName.acceptAdaptiveTiming : UndoActionName.removeAdaptiveTiming) else {
                    message = SharedModelPublication.supersededCorrectionMessage
                    return
                }
                acceptedMap = accepted.map
                adaptiveAnalysis = nil
                adaptiveEpisode = nil
                adaptivePair = nil
                message = "File-local timing revision \(accepted.revision.revision) will activate after save verification. \(source == nil ? "All audio is retained; unmatched timing is estimated." : "The file's recorder-group timing is restored.") Other files remain unchanged."
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "Adaptive timing was not changed."
            }
        }
    }

    func applyNumeric(ratePPM: Double, offsetMilliseconds: Double) {
        guard let epoch = selection else { return }
        accept(actionName: UndoActionName.editEpochTiming, decisions: [
            epoch: .numeric(ppm: ratePPM, offsetMilliseconds: offsetMilliseconds),
        ])
    }

    func acceptProposal() {
        guard canAcceptProposal, let epoch = selection else { return }
        let note = selectedAnalysis.flatMap { record -> String? in
            guard let proposal = record.proposal else { return nil }
            let windows = record.windows.filter { $0.status == "eligible" }
            guard let first = windows.first, let last = windows.last,
                  first.groupClockCenter < last.groupClockCenter else { return nil }
            let markers = [first, last].map { window in
                AlignmentAnchor(
                    sourceSeconds: window.groupClockCenter,
                    alignedSeconds: window.groupClockCenter * proposal.segment.rateRatio.approximateDouble
                        + proposal.segment.alignedOffset.approximateDouble
                )
            }
            guard markers.allSatisfy({ $0.sourceSeconds.isFinite && $0.sourceSeconds >= 0
                && $0.alignedSeconds.isFinite }) else { return nil }
            return AlignmentAnchorNote.encode(markers, source: record.target.source)
        } ?? ""
        accept(actionName: UndoActionName.acceptProposal, decisions: [epoch: .acceptProposal(note: note)],
               reviewingSavedProposal: selectedAnalysis == nil)
    }

    func extendProposalToEpoch() {
        guard canAcceptProposal, proposalNeedsExtension, let epoch = selection else { return }
        accept(actionName: UndoActionName.acceptProposal, decisions: [epoch: .extendProposalToEpoch()])
    }

    func rejectProposal() {
        guard canAcceptProposal, let epoch = selection else { return }
        accept(actionName: UndoActionName.rejectProposal, decisions: [epoch: .unmapped])
    }

    func placeAnchors(
        _ anchors: [AlignmentAnchor],
        source: SourceID? = nil,
        focusSourceSeconds: Double? = nil
    ) {
        guard let epoch = selection else { return }
        let chosenSource = source ?? existingAnchorSource(for: epoch) ?? selectedWaveformSource
        let decision: EpochMapDecision = chosenSource.map { .anchorsForSource($0, anchors) } ?? .anchors(anchors)
        accept(
            actionName: UndoActionName.placeAnchor,
            decisions: [epoch: decision]
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

    private func existingAnchorSource(for epoch: RecordingEpochID) -> SourceID? {
        guard let mapped = acceptedMap?.groups.flatMap(\.epochs).first(where: { $0.epoch == epoch }),
              case let .mapped(_, .manual(correction)) = mapped.mapping
        else { return nil }
        return AlignmentAnchorNote.source(in: correction.note)
    }

    func stopAudition() {
        auditionGeneration += 1
        transportTask?.cancel()
        transportTask = nil
        productionPreparationTask?.cancel()
        productionPreparationTask = nil
        transportProgressTask?.cancel()
        transportProgressTask = nil
        transportWarmupTask?.cancel()
        transportWarmupTask = nil
        transportWarmup = nil
        auditionTask?.cancel()
        auditionTask = nil
        isPreparingAudition = false
        auditionStopTask?.cancel()
        auditionStopTask = nil
        stopPlayback(updatePlayhead: true)
    }

    private func stopPlayback(updatePlayhead: Bool) {
        if updatePlayhead, isAuditioning, let clock = audioPlayback.clock {
            let time = clock.playhead()
            if listeningMode == .productionMix, let productionTimeline {
                auditionPlayheadSeconds = cutTimeline.editedTime(
                    forAlignedTime: productionTimeline.alignedTime(forEditedTime: time))
            } else {
                auditionPlayheadSeconds = auditionUsesOriginalTime ? cutTimeline.editedTime(forAlignedTime: time) : time
            }
        }
        audioPlayback.stop()
        mixer.stop()
        productionPreparationTask?.cancel()
        productionPreparationTask = nil
        transportProgressTask?.cancel()
        transportProgressTask = nil
        productionTimeline = nil
        transportWarmupTask?.cancel()
        transportWarmupTask = nil
        transportWarmup = nil
        transportUnavailable.removeAll()
        isAuditioning = false
        auditionUsesOriginalTime = false
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
        listeningMode = .sourceAudition
        let start = startSeconds ?? auditionStartSeconds
        try audioPlayback.play(clip, startSeconds: start)
        auditionPlayheadSeconds = start
        if automaticallyStop {
            auditionStopTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(clip.duration))
                guard !Task.isCancelled, isAuditioning else { return }
                stopAudition()
            }
        }
    }

    private func refreshTransportGains() {
        guard transportTask != nil, listeningMode == .sourceAudition else { return }
        let enabled = enabledSources
        let pendingStarts = audioPlayback.pendingSources
        let gains = AlignmentTransportSelection.gains(
            prepared: audioPlayback.preparedSources.subtracting(transportUnavailable.keys).subtracting(pendingStarts),
            enabled: enabled
        )
        audioPlayback.setGains(gains)
        guard isAuditioning else { return }
        let missing = enabled.filter { transportUnavailable[$0] != nil }
        let untimed = enabled.filter { !sourceHasAcceptedTiming($0) }
        let pending = enabled.filter {
            sourceHasAcceptedTiming($0) && transportUnavailable[$0] == nil
                && (!audioPlayback.preparedSources.contains($0) || pendingStarts.contains($0))
        }
        let audible = gains.values.filter { $0 > 0 }.count
        auditionLabel = audible == 0
            ? (pending.isEmpty ? "Playing the stored timeline silently; all timed tracks are muted."
                : "Waiting for enabled timed tracks to join; the stored clock continues.")
            : "Playing \(audible) timed \(audible == 1 ? "track" : "tracks") on the stored timeline."
        if !untimed.isEmpty {
            auditionLabel += " \(untimed.count) enabled untimed \(untimed.count == 1 ? "track is" : "tracks are") excluded."
        }
        if !pending.isEmpty {
            auditionLabel += " \(pending.count) enabled timed \(pending.count == 1 ? "track is" : "tracks are") preparing to join the shared clock; existing playback continues."
        }
        if let source = missing.first, let reason = transportUnavailable[source] {
            let name = waveformTracks.first(where: { $0.id == source })?.name ?? "Track"
            auditionLabel += " \(name) cannot be heard: \(reason). Restart playback to retry."
        }
    }

    private func enqueueTransport(
        _ clips: [SourceID: AlignmentRuntime.AuditionClip], startSeconds: Double, first: Bool,
        availableSources: Set<SourceID>, final: Bool
    ) throws {
        if first {
            stopPlayback(updatePlayhead: false)
        }
        try audioPlayback.enqueue(
            clips, startSeconds: startSeconds, first: first, availableSources: availableSources, final: final,
            onSourcesJoined: { [weak self] in self?.refreshTransportGains() }
        ) { [weak self] in
            guard let self else { return }
            let error = AlignmentTransportFailure.bufferDeadline
            stopAudition()
            lastError = error.localizedDescription
            auditionLabel = "Playback stopped: \(error.localizedDescription). No substitute audio was played."
        }
        if first {
            auditionPlayheadSeconds = startSeconds
        }
    }

    func editAnchor(id: Int, alignedSeconds: Double) {
        guard let epoch = selection, alignedSeconds.isFinite,
              var anchors = anchorsByEpoch[epoch],
              let index = anchors.firstIndex(where: { $0.id == id })
        else { return }
        anchors[index].alignedSeconds = alignedSeconds
        let values = anchors.map {
            AlignmentAnchor(sourceSeconds: $0.sourceSeconds, alignedSeconds: $0.alignedSeconds)
        }
        let decision: EpochMapDecision = existingAnchorSource(for: epoch).map {
            .anchorsForSource($0, values)
        } ?? .anchors(values)
        accept(
            actionName: UndoActionName.editAnchorTime,
            decisions: [epoch: decision]
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
                informative: "Deleting this anchor leaves fewer than two anchors, so this recording segment will become unsupported until you add another anchor.",
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
        let values = anchors.map {
            AlignmentAnchor(sourceSeconds: $0.sourceSeconds, alignedSeconds: $0.alignedSeconds)
        }
        let decision: EpochMapDecision = anchors.count >= 2
            ? existingAnchorSource(for: epoch).map { .anchorsForSource($0, values) } ?? .anchors(values)
            : .unmapped
        accept(
            actionName: UndoActionName.deleteAnchor,
            decisions: [epoch: decision]
        ) { [weak self] in
            self?.anchorsByEpoch[epoch] = anchors.count >= 2 ? anchors : []
            self?.anchorSelection = anchors.first?.id
            if anchors.count < 2 {
                self?.message = "Fewer than two anchors remain. Add at least one more anchor to time this recording segment."
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
        reviewingSavedProposal: Bool = false,
        onAccepted: @escaping @MainActor () -> Void = {}
    ) {
        guard let document, !isWorking else { return }
        guard let episode = document.store.model.episode(episodeID),
              !episode.recorderGroups.contains(where: { group in
                  group.epochs.contains { decisions[$0.id] != nil } && episode.positionIsLocked(group.id)
              }) else {
            lastError = "Unlock the affected recorder positions before changing timing."
            return
        }
        guard !pendingResetVerification || timingIsVerified(document.store.model) else {
            message = "Save verification must finish before editing the fresh timeline."
            return
        }
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
                let accepted: AcceptedAlignment
                if reviewingSavedProposal {
                    accepted = try await runtime.reviewSavedProposal(
                        model: prior, episode: episodeID, decisions: decisions)
                } else {
                    accepted = try await runtime.accept(model: prior, episode: episodeID, decisions: decisions)
                }
                let applied = publishAlignment(accepted, expecting: prior, actionName: actionName)
                if applied {
                    acceptedMap = accepted.map
                    rows = Self.makeRows(
                        model: accepted.model, episodeID: episodeID,
                        states: await runtime.states(model: accepted.model, episode: episodeID),
                        map: accepted.map
                    )
                    message = "Map revision \(accepted.revision.revision) will activate after the show is verified on disk."
                    anchorsByEpoch = AlignmentPresentation.makeAnchors(map: accepted.map)
                    resetWaveformTiming()
                    onAccepted()
                    if actionName == UndoActionName.acceptProposal {
                        announce("Accepted proposal for \(selectedRow?.epochLabel ?? "selected recording segment")")
                    } else if actionName == UndoActionName.rejectProposal {
                        announce("Rejected proposal for \(selectedRow?.epochLabel ?? "selected recording segment")")
                    }
                } else {
                    message = SharedModelPublication.supersededCorrectionMessage
                }
            } catch {
                lastError = AlignmentPresentation.errorDescription(error)
                message = "The correction was not accepted."
            }
            isWorking = false
        }
    }

    func requestResetAlignment() {
        guard let document, canResetAlignment else { return }
        let prior = document.store.model
        Task {
            guard await Dialogs.confirm(
                in: document.windowControllers.first?.window,
                message: "Reset Alignment?",
                informative: "Return every recorder group to zero offset and normal speed, including locked groups. This removes active automatic alignment, adaptive file timing, manual offsets, drift and anchors. Active transcription, transcript-linked reviews, cuts and episode IN/OUT reset together, just as when accepting replacement alignment. Original recordings, speaker assignments, recorder groups, reference selection and recoverable history remain. Undo restores the previous timing and work.",
                confirmTitle: "Reset Alignment"
            ) else { return }
            resetAlignment(expecting: prior)
        }
    }

    func resetAlignment(expecting prior: ShowDocumentModel) {
        guard let document else { return }
        guard document.store.model == prior else {
            lastError = "The show changed while confirming reset. Nothing was reset. Review the current episode and try Reset Alignment again."
            return
        }
        guard canResetAlignment else {
            lastError = "Finish the current operation before resetting an aligned episode. This show must be editable."
            return
        }
        do {
            let cleared = try prior.resettingAlignment(in: episodeID)
            pendingResetVerification = true
            guard document.store.applyReplacement(
                "Reset Alignment", expecting: prior, model: cleared,
                afterChange: persistenceCallback(document: document, accepted: nil)
            ) else {
                pendingResetVerification = false
                lastError = SharedModelPublication.decide(live: document.store.model, expected: prior) == .superseded
                    ? SharedModelPublication.supersededCorrectionMessage
                    : "This show is read-only until its format update finishes."
                return
            }
            staleAcceptedTiming = false
            lastError = nil
            stopAudition()
            discardAlignmentAnalysis()
            clearWaveformMarkers()
            acceptedMap = nil
            anchorsByEpoch = [:]
            rows = Self.makeRows(model: cleared, episodeID: episodeID, states: [])
            resetWaveformTiming()
            message = "Alignment reset. Recorder groups return to zero offset and normal speed after verified save. Active transcription, reviews, cuts and IN/OUT were reset; Undo restores the previous work. Original recordings are unchanged."
            load()
            synchronizeWaveforms()
        } catch {
            lastError = AlignmentPresentation.errorDescription(error)
        }
    }

    private func discardAlignmentAnalysis() {
        tracksAnalysisTask?.cancel()
        adaptiveTask?.cancel()
        discardTracksReview()
        adaptiveAnalysis = nil
        adaptiveEpisode = nil
        adaptivePair = nil
        adaptiveProgress = 0
        selectedMatchSpeaker = nil
        selectedMatchOption = nil
        analysisStates = [:]
        analysisSourceEndByEpoch = [:]
        analyzedInputs = nil
        inspectedStates = []
        hasAnalysis = false
    }

    @discardableResult
    func publishAlignment(_ accepted: AcceptedAlignment, expecting prior: ShowDocumentModel,
                          actionName: String, resettingDownstream: Bool = false) -> Bool {
        guard let document else { return false }
        let live = document.store.model
        guard live.hasSameMediaInputs(as: prior, in: episodeID),
              let index = live.episodes.firstIndex(where: { $0.id == episodeID }),
              live.episodes[index].alignment == prior.episode(episodeID)?.alignment,
              live.episodes[index].workspace?.positionLocks == prior.episode(episodeID)?.workspace?.positionLocks,
              let result = accepted.model.episode(episodeID) else {
            message = "Timing inputs or position protection changed. No result was applied; run alignment again."
            return false
        }
        var merged = live
        merged.episodes[index].alignment = result.alignment
        if resettingDownstream {
            guard live.episodes[index].cleanup == prior.episode(episodeID)?.cleanup else {
                message = "Downstream work changed during acceptance. Nothing was reset; review alignment again."
                return false
            }
            do {
                merged.episodes[index].cleanup = try live.episodes[index].cleanup?.resettingForReplacementAlignment()
            } catch {
                lastError = error.localizedDescription
                return false
            }
        } else if result.cleanup != prior.episode(episodeID)?.cleanup {
            guard live.episodes[index].cleanup == prior.episode(episodeID)?.cleanup else {
                message = "Episode boundaries or downstream work changed during acceptance. No result was applied."
                return false
            }
            merged.episodes[index].cleanup = result.cleanup
        }
        return document.store.applyReplacement(actionName, expecting: live, model: merged,
            afterChange: persistenceCallback(document: document, accepted: accepted))
    }

    private func persistenceCallback(
        document: ShowDocument,
        accepted: AcceptedAlignment?
    ) -> @MainActor (ShowDocumentModel) -> Void {
        let playbackPolicy = AppSettings.shared.editingPlaybackPolicy
        return { [weak document, weak self, runtime, episodeID] model in
            let generation = self?.publicationGeneration
            // Undo/Redo posts change-count notifications after its handler returns.
            // Save afterward so those notifications cannot overwrite the verified save status.
            Task { @MainActor in
                guard let document, document.store.model == model else { return }
                document.persistExpectedModel(model) { result in
                    guard document.store.model == model else {
                        self?.synchronizeWaveforms()
                        return
                    }
                    switch result {
                    case .success:
                        Task {
                            do {
                                guard let generation, self?.publicationGeneration == generation else { return }
                                guard document.store.model == model else {
                                    self?.synchronizeWaveforms()
                                    return
                                }
                                if let accepted, model == accepted.model {
                                    try await runtime.activate(accepted)
                                } else {
                                    try await runtime.activate(model: model, episode: episodeID)
                                }
                                guard document.store.model == model,
                                      self?.publicationGeneration == generation else { return }
                                if let accepted,
                                   model.episode(episodeID)?.alignment == accepted.model.episode(episodeID)?.alignment,
                                   let episode = model.episode(episodeID) {
                                    do {
                                        try self?.listening.applyAcceptedAlignmentPolicy(
                                            playbackPolicy, in: episode, identity: accepted.mapContentDigest,
                                            revision: accepted.revision.revision
                                        )
                                        self?.refreshListeningGains()
                                    } catch {
                                        self?.lastError = "Alignment is saved, but the listening default could not be applied: \(error.localizedDescription)"
                                    }
                                }
                                self?.pendingResetVerification = false
                                await self?.updateDependents(announce: true)
                                self?.load()
                                self?.synchronizeWaveforms()
                            }
                            catch {
                                guard let generation, self?.publicationGeneration == generation else { return }
                                self?.cancelWaveforms()
                                self?.waveformMessage = "Timing could not be activated; the unverified visual preview was removed."
                                NSApp.presentError(error)
                            }
                        }
                    case let .failure(error):
                        guard let generation, self?.publicationGeneration == generation else { return }
                        self?.cancelWaveforms()
                        self?.waveformMessage = "Timing could not be saved; the unverified visual preview was removed."
                        NSApp.presentError(error)
                    }
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

}
