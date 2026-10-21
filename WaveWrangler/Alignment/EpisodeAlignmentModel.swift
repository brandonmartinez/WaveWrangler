import AppKit
import Foundation
import Observation
import SwiftUI
import WWAlignPipeline
import WWCore
import WWEpisodeSetup
import WWOrganizer
import WWTimeMap

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
    private var adaptiveAnalysis: AdaptiveAnalysisRecord?
    private var adaptiveEpisode: Episode?
    private var adaptivePair: SpeakerMatchOption?
    @ObservationIgnored private var adaptiveTask: Task<Void, Never>?
    private(set) var adaptiveProgress = 0.0
    var includeEstimatedAdaptiveTiming = false
    var isAnalyzingAdaptively: Bool { isWorking && adaptiveTask != nil }
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
    private(set) var waveformOverviewDisplayGains: [SourceID: Double] = [:]
    private(set) var waveformOverviewProjectionErrors: [SourceID: String] = [:]
    private(set) var waveformOverviewSnapshotID = UUID()
    private(set) var waveformOverviewRefusals: [AlignmentWaveformRefusal] = []
    private(set) var waveformOverviewMap: AlignedTimelineMap?
    private(set) var isLoadingOverview = false
    private(set) var waveformOverviewProgress = 0.0
    private(set) var waveformOverviewMessage = "Build Overview scans all covered PCM samples. It does not change or cache recordings."
    private(set) var waveformMessage = "Load a bounded audio window to see the recordings. Original files are never changed."
    var waveformStartSeconds = 0.0
    var waveformDurationSeconds = 5.0
    var waveformPlayheadSeconds = 0.0
    private(set) var waveformNavigationEndSeconds = 0.0
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

    var waveformTileSlices: [WaveformTileSlice] {
        _ = waveformTilesVersion
        return waveformCache.visibleSlices(
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            generation: document?.store.modelGeneration, pendingMove: pendingWaveformMove,
            canReuseSamples: canRetainWaveformSamples
        )
    }

    func waveformVisibleStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        retainedWaveformStrokes(for: source) + waveformTileSlices.flatMap { slice in
            (slice.strokes[source] ?? []).filter { $0.displayRange.overlaps(slice.range) }
        }
    }

    func retainedWaveformStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        _ = waveformTilesVersion
        return waveformCache.retainedStrokes(for: source)
    }

    func proposedWaveformStrokes(for track: AlignmentWaveformTrack) -> [AlignmentWaveformStroke] {
        let complete = waveformOverviewTracks.first { $0.id == track.id }
        let tracks = complete.map { [$0] } ?? waveformCache.tracks.filter { $0.id == track.id }
        if let adaptive = currentAdaptiveAnalysis {
            return tracks.flatMap { AlignmentWaveformProjection.adaptiveStrokes(
                track: $0, record: adaptive, includeEstimated: includeEstimatedAdaptiveTiming) }
        }
        guard canAcceptProposal, let row = selectedRow, let proposal = selectedAnalysis?.proposal else { return [] }
        return tracks.flatMap {
            AlignmentWaveformProjection.proposedStrokes(
                track: $0, map: loadedWaveformMap, targetGroup: row.groupID,
                targetEpoch: row.epochID, segment: proposal.segment
            )
        }
    }

    private var canRetainWaveformSamples: Bool {
        AlignmentWaveformProjection.canReuseSamples(
            from: loadedWaveformEpisode, to: document?.store.model.episode(episodeID)
        )
    }
    func waveformInteractionStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        let exact = waveformVisibleStrokes(for: source)
        return exact.isEmpty ? waveformOverviewStrokes[source] ?? [] : exact
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
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let audioPlayback = AlignmentAudioPlayback()
    @ObservationIgnored private var transportUnavailable: [SourceID: String] = [:]
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
    @ObservationIgnored private var auditionGeneration: UInt64 = 0
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var transportProgressTask: Task<Void, Never>?
    @ObservationIgnored private var transportWarmupTask: Task<Void, Never>?
    @ObservationIgnored private var transportWarmup: (source: SourceID, frames: Range<Int64>)?
    @ObservationIgnored private var auditionStopTask: Task<Void, Never>?

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime,
         listening: EpisodeListeningState = EpisodeListeningState()) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
        self.listening = listening
    }

    var selectedRow: AlignmentRow? {
        rows.first { $0.epochID == selection }
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
    var hasAcceptedRevision: Bool { document?.store.model.episode(episodeID)?.alignment?.acceptedRevision != nil }

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

    func prefersTimingReference(_ group: RecorderGroupID) -> Bool {
        document?.store.model.episode(episodeID)?.recorderGroup(group)?.preferredAlignmentReference == true
    }

    func preferTimingReference(_ preferred: Bool, group: RecorderGroupID) {
        guard let document else {
            lastError = "The show document is no longer open."
            return
        }
        guard SetupEditCommands(editor: document.store, episodeID: episodeID)
            .preferAlignmentReference(preferred, group: group) else {
            lastError = document.store.lastError.map(String.init(describing:))
                ?? "Reference preference is unavailable while this show is read-only."
            return
        }
        invalidateMatchAfterSetupEdit()
        message = "Timing reference preference changed. Existing accepted timing was not rebased or approved."
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
            waveformOverviewStrokes.values.flatMap { $0 }
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
        if loadedWaveformEpisode?.alignment?.acceptedMap?.sourceCorrections?.contains(where: { $0.source == source }) == true {
            return true
        }
        return loadedWaveformMap.map { AlignmentWaveformProjection.timedSources(in: $0).contains(source) } ?? false
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
    private func timelineEnd(for sources: Set<SourceID>) -> Double {
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
        return max(groupEnd, adaptiveEnd)
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
        loadedWaveformMap?.reference.group
            ?? document?.store.model.episode(episodeID)?.recorderGroups.first(where: { $0.preferredAlignmentReference == true })?.id
            ?? document?.store.model.episode(episodeID)?.recorderGroups.first?.id
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

    var editingPlaybackPolicy: EditingPlaybackPolicy {
        document?.store.model.episode(episodeID)?.workspace?.editingPlaybackPolicy ?? .keepChoices
    }
    func setEditingPlaybackPolicy(_ policy: EditingPlaybackPolicy) {
        guard let document else { return }
        if !document.store.apply("Set editing playback policy", { model throws(DomainError) in
            try model.settingEditingPlaybackPolicy(policy, in: episodeID)
        }) { lastError = document.store.lastError.map(String.init(describing:)) }
    }
    func beginEditing() {
        guard let document, let episode = document.store.model.episode(episodeID),
              let revision = episode.alignment?.acceptedRevision, timingIsVerified(document.store.model) else {
            lastError = "Accept and save verified alignment before beginning editing."
            return
        }
        guard listening.editingPolicyRevision != revision else {
            message = "This alignment is already in editing intent; your current listening choices are preserved."
            return
        }
        do {
            let updated = try listening.playback.applying(editingPlaybackPolicy, in: episode)
            if editingPlaybackPolicy != .keepChoices { listening.previousPlayback = listening.playback }
            listening.playback = updated
            listening.editingPolicyRevision = revision
            refreshListeningGains()
            message = "Editing with verified alignment revision \(revision). \(editingPlaybackPolicy.title)."
        } catch { lastError = String(describing: error) }
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
        guard !isWorking, !isLoadingWaveforms, pendingWaveformMove == nil,
              let document, timingIsVerified(document.store.model),
              let row = selectedRow, let track = selectedWaveform,
              let map = loadedWaveformMap, track.group != map.reference.group,
              let epoch = map.groups.first(where: { $0.group == track.group })?.epochs.first(where: { $0.epoch == row.epochID }),
              case .mapped = epoch.mapping
        else { return false }
        return true
    }

    private func timingIsVerified(_ model: ShowDocumentModel) -> Bool {
        if !pendingResetVerification, model.episode(episodeID)?.alignment?.acceptedRevision == nil { return true }
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
        waveformMessage = "\(waveformDraftAnchors.count) linked anchor\(waveformDraftAnchors.count == 1 ? "" : "s") staged. Place at least two pairs on this epoch, then apply; nothing has changed yet."
    }

    func loadWaveforms(keepingSnapshot: Bool = false, preload: Bool = false) {
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
        guard let initialRequest = AlignmentWaveformProjection.tileWindow(
            start: visibleStart, visible: visibleDuration
        ) else {
            if visibleDuration > 30, waveformFitRange != nil {
                ensureWaveformOverview()
                return
            }
            waveformMessage = "Choose a finite exact window between minus 24 and plus 24 aligned hours, at most 30 seconds wide."
            return
        }
        let uncovered = keepingSnapshot
            ? firstUncoveredWaveformTime(start: visibleStart, duration: visibleDuration,
                                         margin: preload ? visibleDuration / 2 : 0)
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
               start: visibleStart, duration: visibleDuration,
               margin: preload ? visibleDuration / 2 : 0, includePending: true
           ) == nil { return }
        let request: (start: Double, duration: Double)
        if keepingSnapshot {
            guard let next = AlignmentWaveformProjection.tileWindow(
                start: min(uncovered ?? visibleStart, 86_400), visible: visibleDuration
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
                    startSeconds: request.start, durationSeconds: request.duration
                )
                var publishedWindow = request
                if request.duration > visibleDuration, !loaded.refusals.isEmpty {
                    let exact = try await runtime.waveformTracks(
                        model: snapshot, episode: episodeID,
                        startSeconds: visibleStart, durationSeconds: visibleDuration
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
                var strokes: [SourceID: [AlignmentWaveformStroke]] = [:]
                var gains: [SourceID: Double] = [:]
                var projectionErrors: [SourceID: String] = [:]
                for track in loaded.tracks {
                    do {
                        let projected = try AlignmentWaveformProjection.strokes(track: track, map: loaded.map,
                            correction: snapshot.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id })
                        strokes[track.id] = projected
                        gains[track.id] = AlignmentWaveformProjection.displayGain(for: projected, normalized: true)
                    } catch {
                        projectionErrors[track.id] = error.localizedDescription
                    }
                }
                let tile = AlignmentWaveformCache.Tile(
                    modelGeneration: document.store.modelGeneration, episode: document.store.model.episode(episodeID),
                    start: publishedWindow.start, duration: publishedWindow.duration,
                    load: loaded, strokes: strokes, gains: gains, errors: projectionErrors
                )
                waveformCache.insert(tile)
                waveformTilesVersion = UUID()
                publishWaveformTile(currentWaveformTile ?? tile)
                if firstUncoveredWaveformTime(
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
                lastError = String(describing: error)
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
                try waveformCache.reproject(
                    map: map, episode: model.episode(episodeID), modelGeneration: modelGeneration
                )
                waveformOverviewStrokes = try Dictionary(uniqueKeysWithValues: waveformOverviewTracks.map { track in
                    (track.id, try AlignmentWaveformProjection.strokes(track: track, map: map,
                        correction: model.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id }))
                })
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
                lastError = String(describing: error)
            }
        }
    }

    private func publishWaveformTile(_ tile: AlignmentWaveformCache.Tile) {
        let previousEnd = loadedWaveformEpisode == tile.episode ? waveformNavigationEndSeconds : 0
        if let map = tile.load.map {
            let timed = AlignmentWaveformProjection.timedSources(in: map)
            waveformNavigationEndSeconds = max(
                AlignmentWaveformProjection.timelineEnd(map: map),
                AlignmentWaveformProjection.sourceTimelineEnd(durations: tile.load.tracks
                    .filter { !timed.contains($0.id) }
                    .map { (frames: $0.envelope.totalFrames, rate: $0.envelope.sampleRate) })
            )
        } else if tile.load.mapWarning == nil {
            waveformNavigationEndSeconds = max(
                previousEnd, AlignmentWaveformProjection.sourceTimelineEnd(
                    durations: tile.load.tracks.map {
                        (frames: $0.envelope.totalFrames, rate: $0.envelope.sampleRate)
                    }
                )
            )
        } else {
            waveformNavigationEndSeconds = 0
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
        waveformNavigationEndSeconds = 0
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
                var strokes: [SourceID: [AlignmentWaveformStroke]] = [:]
                var gains: [SourceID: Double] = [:]
                var projectionErrors: [SourceID: String] = [:]
                for track in loaded.tracks {
                    do {
                        let projected = try AlignmentWaveformProjection.strokes(track: track, map: loaded.map,
                            correction: snapshot.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id })
                        strokes[track.id] = projected
                        gains[track.id] = AlignmentWaveformProjection.displayGain(for: projected, normalized: true)
                    } catch {
                        projectionErrors[track.id] = error.localizedDescription
                    }
                }
                waveformOverviewTracks = loaded.tracks
                waveformOverviewStrokes = strokes
                waveformOverviewDisplayGains = gains
                waveformOverviewProjectionErrors = projectionErrors
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
                lastError = String(describing: error)
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
        if canStopAudition {
            stopAudition()
            waveformPlayheadSeconds = auditionPlayheadSeconds
        }
        waveformStartSeconds = start
        return true
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
    func zoomWaveformViewport(magnification: Double, anchor: Double) -> Bool {
        guard let result = AlignmentWaveformProjection.rulerZoom(
            start: waveformStartSeconds, duration: waveformDurationSeconds, anchor: anchor,
            magnification: magnification, bounds: waveformViewingBounds,
            maximumDuration: maximumWaveformDuration
        ) else {
            waveformMessage = "Choose a finite zoom and an anchor within the visible timeline."
            return false
        }
        return previewWaveformViewport(start: result.start, duration: result.duration)
    }

    func suspend() {
        cancelAdaptiveAnalysis()
        cancelWaveforms()
        cancelWaveformOverview()
        waveformNavigationEndSeconds = 0
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
            waveformOverviewStrokes.values.flatMap { $0 }.filter(\.mapped)
        ) ?? 0...max(0.1, enabledTimelineEnd)
    }

    func playEnabledTracks(interval: ClosedRange<Double>? = nil, repeatInterval: Bool? = nil,
                           repeatWhile: (() -> Bool)? = nil) {
        adoptCachedPresentation()
        guard let document, !enabledSources.isEmpty,
              loadedWaveformGeneration == document.store.modelGeneration,
              let map = loadedWaveformMap, groupDraftMilliseconds == 0, pendingWaveformMove == nil,
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
        let timed = AlignmentWaveformProjection.timedSources(in: map)
        let sources = enabled.filter { timed.contains($0) }
        let availableSources = sources
            + waveformTracks.map(\.id).filter { timed.contains($0) && !enabled.contains($0) }
        guard !sources.isEmpty else {
            auditionLabel = "No enabled track has accepted timing. Set timing manually or enable a timed track."
            return
        }
        let requestedRange = interval ?? (listening.cycleEnabled ? listening.cycleRange : nil)
        let loops = repeatInterval ?? (listening.cycleEnabled && requestedRange != nil)
        let firstPosition = requestedRange.map { max(waveformAuditionBounds.lowerBound, $0.lowerBound) }
            ?? waveformPlayheadSeconds
        let lastPosition = min(enabledTimelineEnd, requestedRange?.upperBound ?? enabledTimelineEnd)
        guard firstPosition.isFinite, lastPosition.isFinite, firstPosition < lastPosition else {
            auditionLabel = "Choose a playhead time covered by an enabled track with accepted timing."
            return
        }
        let omitted = enabled.count - sources.count
        stopAudition()
        let snapshot = document.store.model
        let generation = auditionGeneration
        isPreparingAudition = true
        transportTask = Task { [weak self] in
            guard let self else { return }
            let end = min(lastPosition, timelineEnd(for: Set(availableSources)), 86_400)
            let rate = Double(AlignedAuditionWindowReader.outputRate)
            var schedule: AlignedAuditionSchedule
            do { schedule = try AlignedAuditionSchedule(startSeconds: firstPosition, endSeconds: end) }
            catch {
                stopPlayback(updatePlayhead: false)
                isPreparingAudition = false
                transportTask = nil
                lastError = String(describing: error)
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
                                sources: requestedSources, outputFrames: frames
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
                          timingIsVerified(snapshot) else { throw CancellationError() }
                    guard !clips.isEmpty else { throw WaveformWindowError.invalidSamples }
                    isPreparingAudition = false
                    try enqueueTransport(
                        clips, startSeconds: Double(frames.lowerBound) / rate, first: !isAuditioning,
                        availableSources: Set(availableSources), final: frames.upperBound == schedule.endFrame
                    )
                    isAuditioning = true
                    refreshTransportGains()
                    if transportWarmupTask == nil, transportWarmup == nil, schedule.nextFrame < schedule.endFrame {
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
                                )
                            )
                        }
                    }
                    if transportProgressTask == nil {
                        transportProgressTask = Task { [weak self] in
                            while let self, !Task.isCancelled, generation == auditionGeneration,
                                  isAuditioning, let started = audioPlayback.clock?.startedAt {
                                let time = min(end, start + max(0, -started.timeIntervalSinceNow))
                                waveformPlayheadSeconds = time
                                refreshTransportGains()
                                if requestedRange == nil,
                                   time > waveformStartSeconds + waveformDurationSeconds * 0.8,
                                   let window = AlignmentWaveformProjection.windowStart(
                                       centeredAt: time, duration: waveformDurationSeconds
                                   ) {
                                    waveformStartSeconds = window
                                    if firstUncoveredWaveformTime(
                                        start: window, duration: waveformDurationSeconds,
                                        margin: waveformDurationSeconds / 2
                                    ) != nil { scheduleScrubTile() }
                                }
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    }
                    while let started = audioPlayback.clock?.startedAt,
                          Double(frames.upperBound) / rate - start - max(0, -started.timeIntervalSinceNow)
                            >= AlignedAuditionSchedule.maximumAheadSeconds {
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
                    lastError = String(describing: error)
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
                playEnabledTracks(interval: requestedRange, repeatInterval: true, repeatWhile: repeatWhile)
            } else {
                waveformPlayheadSeconds = end
                auditionLabel = requestedRange == nil
                    ? "Playback reached the end of the available timeline." : "Finished selection audition."
            }
        }
    }

    private func warmTransportSource(
        _ source: SourceID, model: ShowDocumentModel, generation: UInt64, frames: Range<Int64>
    ) {
        transportWarmupTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == auditionGeneration { transportWarmupTask = nil } }
            do {
                let clips = try await runtime.sourceAuditions(
                    model: model, episode: episodeID, sources: [source], outputFrames: frames
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
                lastError = String(describing: error)
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
            analysisStates = [:]
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
                speakerMatches = snapshot?.speakerMatches ?? [:]
                inspectedEpisode = episode
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
            message = "Select an epoch with the same identified speaker on an already aligned recorder. State the speaker's channels in Setup, or place this epoch manually."
            return
        }
        isWorking = true
        adaptiveAnalysis = nil
        adaptiveEpisode = nil
        lastError = nil
        analysisStates = [:]
        analysisSourceEndByEpoch = [:]
        analyzedInputs = nil
        message = "Indexing full speaker recordings and matching passages… The first scan can take a while; unchanged fingerprints are cached."
        let model = document.store.model
        Task {
            do {
                let report = try await runtime.analyzeSpeaker(
                    model: model, episode: episodeID, targetEpoch: epoch, speaker: pair.speaker,
                    referenceSource: pair.reference.source, targetSource: pair.target
                )
                let states = await runtime.states(model: model, episode: episodeID)
                guard document.store.model.hasSameMediaInputs(as: model, in: episodeID),
                      selection == epoch, (selectedMatchOption ?? selectedSpeakerPairs.first) == pair
                else {
                    message = "The speaker pair, sources, or accepted timing changed during analysis. Run alignment again."
                    isWorking = false
                    return
                }
                analyzedInputs = model.episode(episodeID).map { EpisodeMediaInputs($0) }
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
                message = "Analysis finished: \(proposals) acoustic proposal\(proposals == 1 ? "" : "s"). Review each epoch's evidence; nothing was applied. Uncertain or unavailable matches stay manual."
            } catch AlignmentAcceptanceError.analysisStale(let changes) where changes.contains(.dependenciesChanged) {
                staleAcceptedTiming = true
                lastError = "Accepted timing no longer matches the recorded source revisions. No new alignment was applied. Confirm and restore changed originals in Setup, or use Start fresh alignment to retire the old timing before placing groups again."
                message = "Stored timing is stale. Analysis did not run."
            } catch {
                lastError = String(describing: error)
                message = "Analysis did not complete. No partial result was accepted."
            }
            isWorking = false
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
        includeEstimatedAdaptiveTiming = false
        message = "Measuring local speaker timing throughout the overlap… Full-length review can take several minutes; nothing will be applied."
        let model = document.store.model
        adaptiveTask = Task {
            defer {
                isWorking = false
                adaptiveTask = nil
                adaptiveProgress = 0
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
                message = "Adaptive review: \(record.timing.regions.count) independent measured runs, \(record.timing.anchoredRecovery?.regions.count ?? 0) anchor-guided matches and \(record.timing.quietTransitions?.count ?? 0) quiet-only transitions. Estimated gap timing is optional. Nothing was applied or played."
            } catch is CancellationError {
                message = "Adaptive review canceled. No timing was applied."
            } catch AlignmentWorkFailure.canceled {
                message = "Adaptive review canceled. No timing was applied."
            } catch {
                lastError = String(describing: error)
                message = "Adaptive analysis did not complete. No timing was applied."
            }
        }
    }

    func cancelAdaptiveAnalysis() {
        guard let adaptiveTask else { return }
        adaptiveTask.cancel()
        message = "Canceling adaptive review… No timing was applied."
    }

    func saveAdaptiveCorrection(removing source: SourceID? = nil) {
        guard let document, !isWorking else { return }
        let record = currentAdaptiveAnalysis
        let targetSource = source ?? record?.target.source
        guard let targetSource, let episode = document.store.model.episode(episodeID),
              let group = episode.source(targetSource)?.placement.recorderGroupID,
              !positionIsLocked(group) else {
            lastError = "Unlock this recorder before applying or removing file-local timing."
            return
        }
        guard source != nil || record?.timing.regions.isEmpty == false else { return }
        guard !pendingResetVerification || timingIsVerified(document.store.model) else { return }
        let prior = document.store.model
        let includeEstimated = includeEstimatedAdaptiveTiming
        stopAudition()
        isWorking = true
        lastError = nil
        Task {
            defer { isWorking = false }
            do {
                let accepted: AcceptedAlignment
                if let source {
                    accepted = try await runtime.removeAdaptive(model: prior, episode: episodeID, source: source)
                } else if let record {
                    accepted = try await runtime.acceptAdaptive(model: prior, episode: episodeID, record: record,
                                                               includeEstimated: includeEstimated)
                } else { return }
                guard publishAlignment(accepted, expecting: prior,
                    actionName: source == nil ? UndoActionName.acceptAdaptiveTiming : UndoActionName.removeAdaptiveTiming) else {
                    message = SharedModelPublication.supersededCorrectionMessage
                    return
                }
                acceptedMap = accepted.map
                adaptiveAnalysis = nil
                adaptiveEpisode = nil
                adaptivePair = nil
                message = "File-local timing revision \(accepted.revision.revision) will activate after save verification. Unsupported intervals are silent; other files remain unchanged."
            } catch {
                lastError = String(describing: error)
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
            auditionPlayheadSeconds = clock.playhead()
        }
        audioPlayback.stop()
        transportWarmupTask?.cancel()
        transportWarmupTask = nil
        transportWarmup = nil
        transportUnavailable.removeAll()
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
        guard transportTask != nil else { return }
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
                        announce("Accepted proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    } else if actionName == UndoActionName.rejectProposal {
                        announce("Rejected proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    }
                } else {
                    message = SharedModelPublication.supersededCorrectionMessage
                }
            } catch {
                lastError = String(describing: error)
                message = "The correction was not accepted."
            }
            isWorking = false
        }
    }

    func clearAcceptedTiming() {
        guard let document, !isWorking, hasAcceptedRevision else { return }
        let prior = document.store.model
        guard let episode = prior.episode(episodeID),
              !episode.recorderGroups.contains(where: { $0.id != referenceGroup && episode.positionIsLocked($0.id) }) else {
            lastError = "Unlock non-reference recorder positions before starting fresh alignment. Timing history is retained."
            return
        }
        do {
            let cleared = try prior.clearingAcceptedMap(in: episodeID)
            pendingResetVerification = true
            guard document.store.applyReplacement(
                "Start Fresh Alignment", expecting: prior, model: cleared,
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
            cancelWaveforms()
            cancelWaveformOverview()
            message = "Previous timing is no longer accepted. Its history remains; save verification must finish before new alignment."
            load()
        } catch {
            lastError = String(describing: error)
        }
    }

    @discardableResult
    func publishAlignment(_ accepted: AcceptedAlignment, expecting prior: ShowDocumentModel,
                          actionName: String) -> Bool {
        guard let document else { return false }
        let live = document.store.model
        guard live.hasSameMediaInputs(as: prior, in: episodeID),
              let index = live.episodes.firstIndex(where: { $0.id == episodeID }),
              live.episodes[index].workspace?.positionLocks == prior.episode(episodeID)?.workspace?.positionLocks,
              let result = accepted.model.episode(episodeID) else {
            message = "Timing inputs or position protection changed. No result was applied; run alignment again."
            return false
        }
        var merged = live
        merged.episodes[index].alignment = result.alignment
        return document.store.applyReplacement(actionName, expecting: live, model: merged,
            afterChange: persistenceCallback(document: document, accepted: accepted))
    }

    private func persistenceCallback(
        document: ShowDocument,
        accepted: AcceptedAlignment?
    ) -> @MainActor (ShowDocumentModel) -> Void {
        { [weak document, weak self, runtime, episodeID] model in
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
                                guard document.store.model == model else {
                                    self?.synchronizeWaveforms()
                                    return
                                }
                                if let accepted, model == accepted.model {
                                    try await runtime.activate(accepted)
                                } else {
                                    try await runtime.activate(model: model, episode: episodeID)
                                }
                                self?.pendingResetVerification = false
                                await self?.updateDependents(announce: true)
                                self?.load()
                                self?.synchronizeWaveforms()
                            }
                            catch {
                                self?.cancelWaveforms()
                                self?.waveformMessage = "Timing could not be activated; the unverified visual preview was removed."
                                NSApp.presentError(error)
                            }
                        }
                    case let .failure(error):
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
