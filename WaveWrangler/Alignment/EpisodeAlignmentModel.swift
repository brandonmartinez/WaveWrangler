import AppKit
import AVFAudio
import Darwin
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
    private(set) var analysisStates: [RecordingEpochID: EpochAlignmentState] = [:]
    private(set) var speakerMatches: [RecordingEpochID: [SpeakerMatchOption]] = [:]
    private var inspectedEpisode: Episode?
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
    private var analysedSources: [SourceRecord]?
    private var analysedGroups: [RecorderGroup]?
    private var analysedAssignments: [SpeakerAssignment]?
    private var observedAssignments: [SpeakerAssignment]?
    private var analysedRevision: Int?
    private var observedRevision: Int?
    private(set) var message = "Alignment has not read or analysed any audio."
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
    private(set) var disabledGroups: Set<RecorderGroupID> = []
    private(set) var disabledTracks: Set<SourceID> = []
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
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var waveformGeneration: UInt64 = 0
    @ObservationIgnored private var scrubLoadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWaveformTile: (start: Double, duration: Double)?
    @ObservationIgnored private var waveformTiles: [CachedWaveformTile] = []
    @ObservationIgnored private var loadedWaveformGeneration: UInt64?
    @ObservationIgnored private var loadedWaveformRequiresVerification = false
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

    private struct CachedWaveformTile {
        let modelGeneration: UInt64
        let episode: Episode?
        let start: Double
        let duration: Double
        let load: AlignmentWaveformLoad
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let gains: [SourceID: Double]
        let errors: [SourceID: String]
        let id = UUID()
    }

    struct WaveformTileSlice: Identifiable {
        let snapshot: UUID
        let segment: Int
        let start: Double
        let duration: Double
        let range: ClosedRange<Double>
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let gains: [SourceID: Double]

        var id: String { "\(snapshot.uuidString):\(segment)" }
    }

    var waveformTileSlices: [WaveformTileSlice] {
        _ = waveformTilesVersion
        let slices = AlignmentWaveformProjection.visibleTileSlices(
            start: waveformStartSeconds, duration: waveformDurationSeconds,
            tiles: waveformTiles.filter { tile in
                tile.modelGeneration == document?.store.modelGeneration
                    || (document?.store.modelGeneration).map { liveGeneration in
                        pendingWaveformMove?.retainsTile(
                            generation: tile.modelGeneration, liveGeneration: liveGeneration
                        ) == true
                    } == true
            }.map { (id: $0.id, start: $0.start, duration: $0.duration) }
        )
        var segmentCounts: [UUID: Int] = [:]
        return slices.compactMap { slice in
            guard let tile = waveformTiles.first(where: { $0.id == slice.id }) else { return nil }
            let segment = segmentCounts[slice.id, default: 0]
            segmentCounts[slice.id] = segment + 1
            return WaveformTileSlice(
                snapshot: tile.id, segment: segment, start: tile.start, duration: tile.duration,
                range: slice.range, strokes: tile.strokes, gains: tile.gains
            )
        }
    }

    func waveformVisibleStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        waveformTileSlices.flatMap { slice in
            (slice.strokes[source] ?? []).filter { $0.displayRange.overlaps(slice.range) }
        }
    }
    func waveformInteractionStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        let exact = waveformVisibleStrokes(for: source)
        return exact.isEmpty ? waveformOverviewStrokes[source] ?? [] : exact
    }

    private func firstUncoveredWaveformTime(
        start: Double, duration: Double, margin: Double = 0, includePending: Bool = false
    ) -> Double? {
        var ranges = waveformTiles.filter {
            $0.modelGeneration == document?.store.modelGeneration
        }.map { (id: $0.id, start: $0.start, duration: $0.duration) }
        if includePending, let pendingWaveformTile {
            ranges.append((id: UUID(), start: pendingWaveformTile.start, duration: pendingWaveformTile.duration))
        }
        return AlignmentWaveformProjection.firstUncoveredTime(
            start: start, duration: duration, margin: margin, tiles: ranges
        )
    }

    private var currentWaveformTile: CachedWaveformTile? {
        let center = waveformStartSeconds + waveformDurationSeconds / 2
        return waveformTiles.reversed().first {
            $0.modelGeneration == document?.store.modelGeneration
                && $0.start <= center && center < $0.start + $0.duration
        } ?? waveformTiles.first(where: {
            $0.modelGeneration == document?.store.modelGeneration && $0.id == waveformSnapshotID
        }) ?? waveformTiles.last(where: { $0.modelGeneration == document?.store.modelGeneration })
    }

    let episodeID: EpisodeID
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let auditionEngine = AVAudioEngine()
    @ObservationIgnored private var transportPlayers: [SourceID: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var transportUnavailable: [SourceID: String] = [:]
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

    var selectedAnalysis: EpochAnalysisRecord? {
        guard let selection else { return nil }
        return analysisStates[selection]?.analysis
    }

    var selectedAnalysisState: EpochAlignmentState? {
        guard let selection else { return nil }
        return analysisStates[selection]
    }

    var canAcceptProposal: Bool {
        guard !isWorking, selectedAnalysis?.proposal != nil,
              (!hasAcceptedRevision || waveformMap != nil),
              let episode = document?.store.model.episode(episodeID)
        else { return false }
        return analysedSources == episode.sources && analysedGroups == episode.recorderGroups
            && analysedAssignments == episode.speakerAssignments
            && analysedRevision == episode.alignment?.acceptedRevision
            && selectedRow?.groupID != acceptedMap?.reference.group
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
        loadedWaveformEpisode != document?.store.model.episode(episodeID)
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
              live.sources == inspectedEpisode.sources,
              live.recorderGroups == inspectedEpisode.recorderGroups,
              live.speakerAssignments == inspectedEpisode.speakerAssignments,
              live.alignment?.acceptedRevision == inspectedEpisode.alignment?.acceptedRevision
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
        lastError = nil
        analysisStates = [:]
        speakerMatches = [:]
        selectedMatchOption = nil
        selectedMatchSpeaker = nil
        message = "Assignment changed. Finding eligible speaker pairs again; no timing was applied."
        load()
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
        analyse()
    }
    func speakerMatchDescription(_ option: SpeakerMatchOption) -> String {
        guard let episode = document?.store.model.episode(episodeID),
              let targetGroup = episode.sources.first(where: { $0.id == option.target })?.placement.recorderGroupID
        else { return "Compare this speaker's assigned channels in the aligned and selected recorder groups." }
        let referenceName = episode.recorderGroup(option.reference.group)?.name ?? "aligned recorder"
        let targetName = episode.recorderGroup(targetGroup)?.name ?? "selected recorder"
        let referenceFile = episode.source(option.reference.source)?.displayNameHint ?? "reference track"
        let targetFile = episode.source(option.target)?.displayNameHint ?? "target track"
        return "\(referenceName): \(referenceFile) ch \(option.referenceChannel + 1) → \(targetName): \(targetFile) ch \(option.targetChannel + 1). The target recorder moves as one group."
    }
    func trackIdentity(_ source: SourceID) -> (label: String, color: Color) {
        let references = document?.store.model.episode(episodeID)?.references(to: source) ?? []
        guard let reference = references.first,
              let speakers = document?.store.model.speakers,
              let speaker = speakers.first(where: { $0.id == reference.speakerID })
        else { return ("Unknown speaker", .gray) }
        let palette: [Color] = [.blue, .purple, .green, .pink, .cyan, .indigo, .mint, .brown]
        let role = reference.isPrimary ? "Primary" : "Backup"
        let index = AlignmentWaveformProjection.speakerColorIndex(
            for: speaker.id, speakers: speakers.map(\.id), paletteCount: palette.count
        ) ?? 0
        return ("\(speaker.name) · \(role)", palette[index])
    }
    var enabledSources: [SourceID] {
        AlignmentTransportSelection.enabledSources(
            tracks: waveformTracks, disabledGroups: disabledGroups, disabledTracks: disabledTracks
        )
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
        guard !isWorking, pendingWaveformMove == nil, let range = waveformFitRange else { return }
        if canStopAudition {
            stopAudition()
            waveformPlayheadSeconds = auditionPlayheadSeconds
        }
        waveformStartSeconds = range.lowerBound
        waveformDurationSeconds = range.upperBound - range.lowerBound
        if waveformDurationSeconds <= 30 { loadWaveforms(keepingSnapshot: true) }
    }
    func sourceHasAcceptedTiming(_ source: SourceID) -> Bool {
        loadedWaveformMap.map { AlignmentWaveformProjection.timedSources(in: $0).contains(source) } ?? false
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
        if transportTask == nil { stopAudition() }
        if enabled { disabledGroups.remove(group) } else { disabledGroups.insert(group) }
        if transportTask != nil { refreshTransportGains() }
    }
    func setTrack(_ source: SourceID, enabled: Bool) {
        if transportTask == nil { stopAudition() }
        if enabled { disabledTracks.remove(source) } else { disabledTracks.insert(source) }
        if transportTask != nil { refreshTransportGains() }
    }
    var canMoveGroup: Bool {
        guard let row = selectedRow, let source = selectedWaveformSource else { return false }
        return canMoveWaveform(source: source, group: row.groupID, epoch: row.epochID)
    }
    func canMoveWaveform(source: SourceID, group: RecorderGroupID, epoch: RecordingEpochID) -> Bool {
        guard !isWorking, !isLoadingWaveforms, pendingWaveformMove == nil else { return false }
        let reference = loadedWaveformMap?.reference.group
            ?? document?.store.model.episode(episodeID)?.recorderGroups.first?.id
        return group != reference
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
                guard document.store.applyReplacement(
                    UndoActionName.editEpochTiming, expecting: prior, model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                ) else {
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
        if pendingResetVerification {
            return document?.verifiedModel == model
                && document?.status.saveStatus.state.isVerifiedOnDisk == true
        }
        guard model.episode(episodeID)?.alignment?.acceptedRevision != nil else { return true }
        return document?.verifiedModel == model
            && document?.status.saveStatus.state.isVerifiedOnDisk == true
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

    func loadWaveforms(keepingSnapshot: Bool = false, preload: Bool = false) {
        guard let document else { return }
        let snapshot = document.store.model
        let modelGeneration = document.store.modelGeneration
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
                if UserDefaults.standard.bool(forKey: "WWUITestHooks"),
                   UserDefaults.standard.bool(forKey: "WWUITestVisualAlignmentFixture"),
                   UserDefaults.standard.bool(forKey: "WWUITestDelayWaveformPublication") {
                    try await Task.sleep(for: .seconds(12))
                }
                #endif
                try Task.checkCancellation()
                guard generation == waveformGeneration else { return }
                guard document.store.modelGeneration == modelGeneration,
                      document.store.model == snapshot, timingIsVerified(snapshot) else {
                    waveformMessage = "The episode or verified timing changed. Save and load the current audio window again."
                    return
                }
                var strokes: [SourceID: [AlignmentWaveformStroke]] = [:]
                var gains: [SourceID: Double] = [:]
                var projectionErrors: [SourceID: String] = [:]
                for track in loaded.tracks {
                    do {
                        let projected = try AlignmentWaveformProjection.strokes(track: track, map: loaded.map)
                        strokes[track.id] = projected
                        gains[track.id] = AlignmentWaveformProjection.displayGain(for: projected, normalized: true)
                    } catch {
                        projectionErrors[track.id] = error.localizedDescription
                    }
                }
                let tile = CachedWaveformTile(
                    modelGeneration: modelGeneration, episode: snapshot.episode(episodeID),
                    start: publishedWindow.start, duration: publishedWindow.duration,
                    load: loaded, strokes: strokes, gains: gains, errors: projectionErrors
                )
                waveformTiles.removeAll {
                    $0.modelGeneration != modelGeneration
                        || ($0.start == tile.start && $0.duration == tile.duration)
                }
                waveformTiles.append(tile)
                if waveformTiles.count > 8 { waveformTiles.removeFirst() }
                waveformTilesVersion = UUID()
                publishWaveformTile(currentWaveformTile ?? tile)
                if firstUncoveredWaveformTime(
                    start: waveformStartSeconds, duration: waveformDurationSeconds
                ) != nil {
                    scheduleScrubTile()
                }
            } catch is CancellationError {
                if generation == waveformGeneration { waveformMessage = "Waveform loading cancelled." }
            } catch {
                guard generation == waveformGeneration else { return }
                waveformMessage = "Waveforms unavailable: \(error.localizedDescription)"
                    + (pendingWaveformMove == nil
                        ? "" : " The moved waveform remains an unverified visual preview; refresh audio to retry.")
                lastError = String(describing: error)
            }
        }
    }

    private func publishWaveformTile(_ tile: CachedWaveformTile) {
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
        loadedWaveformRequiresVerification = tile.episode?.alignment?.acceptedRevision != nil
        disabledTracks.formIntersection(Set(tile.episode?.sources.map(\.id) ?? []))
        disabledGroups.formIntersection(Set(tile.episode?.recorderGroups.map(\.id) ?? []))
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
        if keepingSnapshot { return }
        pendingWaveformMove = nil
        waveformTiles = []
        waveformTilesVersion = UUID()
        loadedWaveformGeneration = nil
        loadedWaveformRequiresVerification = false
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
                try Task.checkCancellation()
                guard generation == overviewGeneration else { return }
                guard document.store.model == snapshot, timingIsVerified(snapshot) else {
                    waveformOverviewMessage = "The episode or verified timing changed. Save and reload its overview."
                    return
                }
                var strokes: [SourceID: [AlignmentWaveformStroke]] = [:]
                var gains: [SourceID: Double] = [:]
                var projectionErrors: [SourceID: String] = [:]
                for track in loaded.tracks {
                    do {
                        let projected = try AlignmentWaveformProjection.strokes(track: track, map: loaded.map)
                        strokes[track.id] = projected
                        gains[track.id] = AlignmentWaveformProjection.displayGain(for: projected, normalized: true)
                    } catch {
                        projectionErrors[track.id] = error.localizedDescription
                    }
                }
                if pendingWaveformMove?.expectedGeneration == document.store.modelGeneration {
                    cancelWaveforms()
                    waveformTracks = loaded.tracks
                    loadedWaveformMap = loaded.map
                    loadedWaveformEpisode = snapshot.episode(episodeID)
                    loadedWaveformGeneration = document.store.modelGeneration
                    loadedWaveformRequiresVerification = loaded.map != nil
                    let timed = loaded.map.map(AlignmentWaveformProjection.timedSources) ?? []
                    waveformNavigationEndSeconds = max(
                        loaded.map.map(AlignmentWaveformProjection.timelineEnd) ?? 0,
                        AlignmentWaveformProjection.sourceTimelineEnd(durations: loaded.tracks
                            .filter { !timed.contains($0.id) }
                            .map { (frames: $0.envelope.totalFrames, rate: $0.envelope.sampleRate) })
                    )
                    waveformMessage = "Verified timing refreshed; the complete overview is ready."
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

    func navigateWaveformOverview(to time: Double) {
        let duration = min(30, waveformDurationSeconds)
        guard let start = AlignmentWaveformProjection.windowStart(
            centeredAt: time, duration: duration
        ) else {
            waveformOverviewMessage = "Choose covered audio between minus 24 and plus 24 aligned hours."
            return
        }
        seekEnabledTracks(to: time)
        waveformDurationSeconds = duration
        waveformStartSeconds = start
        loadWaveforms()
    }

    @discardableResult
    func previewWaveformPlayhead(to time: Double) -> Bool {
        guard !isWorking, groupDraftMilliseconds == 0,
              pendingWaveformMove == nil else {
            waveformMessage = "Finish the group preview or verified audio refresh before moving the shared timeline."
            return false
        }
        guard let document, loadedWaveformGeneration == document.store.modelGeneration,
              (!loadedWaveformRequiresVerification || document.status.saveStatus.state.isVerifiedOnDisk) else {
            waveformMessage = "Save and verify the current timing before moving the shared timeline."
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
        guard !isWorking, groupDraftMilliseconds == 0, pendingWaveformMove == nil,
              let document, loadedWaveformGeneration == document.store.modelGeneration,
              (!loadedWaveformRequiresVerification || document.status.saveStatus.state.isVerifiedOnDisk)
        else {
            waveformMessage = "Save and verify the current timing before moving the shared timeline."
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

    func suspend() {
        cancelWaveforms()
        cancelWaveformOverview()
        waveformNavigationEndSeconds = 0
        inspectionGeneration += 1
        inspectionTask?.cancel()
        inspectionTask = nil
        stopAudition()
    }

    func playEnabledTracks() {
        guard !isLoadingWaveforms else {
            auditionLabel = "Playback paused while the measured audio window refreshes."
            return
        }
        guard let document, !isWorking, !enabledSources.isEmpty,
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
        let preparedSources = sources
            + waveformTracks.map(\.id).filter { timed.contains($0) && !enabled.contains($0) }
        guard !sources.isEmpty else {
            auditionLabel = "No enabled track has accepted timing. Set timing manually or enable a timed track."
            return
        }
        guard waveformPlayheadSeconds < enabledTimelineEnd else {
            auditionLabel = "Choose a playhead time covered by an enabled track with accepted timing."
            return
        }
        let omitted = enabled.count - sources.count
        stopAudition()
        let snapshot = document.store.model
        let generation = auditionGeneration
        transportTask = Task { [weak self] in
            guard let self else { return }
            var position = waveformPlayheadSeconds
            let end = min(timelineEnd(for: Set(preparedSources)), 86_400)
            let start = position
            var unavailable: [SourceID: String] = [:]
            while !Task.isCancelled, generation == auditionGeneration, position < end {
                do {
                    isPreparingAudition = true
                    if !isAuditioning {
                        auditionLabel = "Preparing timed tracks for live listening at the displayed map revision…"
                            + (omitted == 0 ? "" : " \(omitted) enabled untimed \(omitted == 1 ? "track is" : "tracks are") excluded.")
                    }
                    let duration = min(AlignedAuditionWindowReader.maximumDurationSeconds, end - position)
                    var clips: [SourceID: AlignmentRuntime.AuditionClip] = [:]
                    for source in preparedSources where unavailable[source] == nil {
                        do {
                            clips[source] = try await runtime.sourceAudition(
                                model: snapshot, episode: episodeID, source: source,
                                startSeconds: position, durationSeconds: duration
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if enabledSources.contains(source) { throw error }
                            unavailable[source] = error is LocalizedError
                                ? error.localizedDescription : String(describing: error)
                        }
                    }
                    try Task.checkCancellation()
                    guard generation == auditionGeneration, document.store.model == snapshot,
                          timingIsVerified(snapshot) else { throw CancellationError() }
                    guard !clips.isEmpty else { throw WaveformWindowError.invalidSamples }
                    isPreparingAudition = false
                    try enqueueTransport(clips, startSeconds: position, first: !isAuditioning)
                    transportUnavailable = unavailable
                    isAuditioning = true
                    refreshTransportGains()
                    if transportProgressTask == nil {
                        transportProgressTask = Task { [weak self] in
                            while let self, !Task.isCancelled, generation == auditionGeneration,
                                  isAuditioning, let started = auditionStartedAt {
                                let time = min(end, start + max(0, -started.timeIntervalSinceNow))
                                waveformPlayheadSeconds = time
                                if time > waveformStartSeconds + waveformDurationSeconds * 0.8,
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
                    position += duration
                    while let started = auditionStartedAt,
                          position - start - max(0, -started.timeIntervalSinceNow)
                            >= 2 * AlignedAuditionWindowReader.maximumDurationSeconds {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } catch is CancellationError {
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
            while let started = auditionStartedAt,
                  max(0, -started.timeIntervalSinceNow) < position - start {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard generation == auditionGeneration else { return }
            stopPlayback(updatePlayhead: true)
            transportTask = nil
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
        if observedRevision != episode?.alignment?.acceptedRevision {
            observedRevision = episode?.alignment?.acceptedRevision
            staleAcceptedTiming = false
            analysisStates = [:]
            speakerMatches = [:]
            selectedMatchOption = nil
            analysedRevision = nil
        }
        if observedAssignments != episode?.speakerAssignments {
            observedAssignments = episode?.speakerAssignments
            analysisStates = [:]
            speakerMatches = [:]
            analysedAssignments = nil
            selectedMatchOption = nil
            selectedMatchSpeaker = nil
        }
        if analysedSources != episode?.sources || analysedGroups != episode?.recorderGroups {
            analysisStates = [:]
            speakerMatches = [:]
            selectedMatchOption = nil
            selectedMatchSpeaker = nil
            analysisSourceEndByEpoch = [:]
            analysedSources = nil
            analysedGroups = nil
            analysedAssignments = nil
        }
        if let pendingWaveformMove,
           pendingWaveformMove.expectedGeneration != document.store.modelGeneration {
            cancelWaveforms()
        }
        if let loaded = loadedOverviewEpisode, loaded != episode {
            let retainsPendingPreview = pendingWaveformMove?.expectedGeneration == document.store.modelGeneration
                && loaded.sources == episode?.sources && loaded.recorderGroups == episode?.recorderGroups
            if !retainsPendingPreview {
                cancelWaveformOverview()
                waveformOverviewMessage = "Episode timing or sources changed. Build the current overview again."
            }
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
            speakerMatches = snapshot?.speakerMatches ?? [:]
            inspectedEpisode = episode
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
                if pendingWaveformMove == nil { loadWaveforms() }
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
        guard !pendingResetVerification || timingIsVerified(document.store.model) else {
            message = "Save verification must finish before analysing the fresh timeline."
            return
        }
        guard let epoch = selection,
              let pair = selectedMatchOption ?? selectedSpeakerPairs.first else {
            message = "Select an epoch with the same identified speaker on an already aligned recorder. State the speaker's channels in Setup, or place this epoch manually."
            return
        }
        isWorking = true
        lastError = nil
        analysisStates = [:]
        analysisSourceEndByEpoch = [:]
        analysedSources = nil
        analysedGroups = nil
        analysedAssignments = nil
        analysedRevision = nil
        message = "Analysing available sources…"
        let model = document.store.model
        Task {
            do {
                let report = try await runtime.analyseSpeaker(
                    model: model, episode: episodeID, targetEpoch: epoch, speaker: pair.speaker,
                    referenceSource: pair.reference.source, targetSource: pair.target
                )
                let states = await runtime.states(model: model, episode: episodeID)
                guard document.store.model.episode(episodeID)?.sources == model.episode(episodeID)?.sources,
                      document.store.model.episode(episodeID)?.recorderGroups == model.episode(episodeID)?.recorderGroups,
                      document.store.model.episode(episodeID)?.speakerAssignments == model.episode(episodeID)?.speakerAssignments,
                      document.store.model.episode(episodeID)?.alignment?.acceptedRevision
                          == model.episode(episodeID)?.alignment?.acceptedRevision,
                      selection == epoch, (selectedMatchOption ?? selectedSpeakerPairs.first) == pair
                else {
                    message = "The speaker pair, sources, or accepted timing changed during analysis. Run alignment again."
                    isWorking = false
                    return
                }
                analysedSources = model.episode(episodeID)?.sources
                analysedGroups = model.episode(episodeID)?.recorderGroups
                analysedAssignments = model.episode(episodeID)?.speakerAssignments
                analysedRevision = model.episode(episodeID)?.alignment?.acceptedRevision
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

    func applyNumeric(ratePPM: Double, offsetMilliseconds: Double) {
        guard let epoch = selection else { return }
        accept(actionName: UndoActionName.editEpochTiming, decisions: [
            epoch: .numeric(ppm: ratePPM, offsetMilliseconds: offsetMilliseconds),
        ])
    }

    func acceptProposal() {
        guard canAcceptProposal, let epoch = selection else { return }
        accept(actionName: UndoActionName.acceptProposal, decisions: [epoch: .acceptProposal()])
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
        for player in transportPlayers.values where auditionEngine.attachedNodes.contains(player) {
            auditionEngine.detach(player)
        }
        transportPlayers.removeAll()
        transportUnavailable.removeAll()
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

    private func refreshTransportGains() {
        guard transportTask != nil else { return }
        let enabled = enabledSources
        let gains = AlignmentTransportSelection.gains(
            prepared: Set(transportPlayers.keys).subtracting(transportUnavailable.keys),
            enabled: enabled
        )
        for (source, player) in transportPlayers {
            player.volume = gains[source] ?? 0
        }
        guard isAuditioning else { return }
        let missing = enabled.filter { transportUnavailable[$0] != nil }
        let untimed = enabled.filter { !sourceHasAcceptedTiming($0) }
        let audible = gains.values.filter { $0 > 0 }.count
        auditionLabel = audible == 0
            ? "Playing the stored timeline silently; all timed tracks are muted."
            : "Playing \(audible) timed \(audible == 1 ? "track" : "tracks") on the stored timeline."
        if !untimed.isEmpty {
            auditionLabel += " \(untimed.count) enabled untimed \(untimed.count == 1 ? "track is" : "tracks are") excluded."
        }
        if let source = missing.first, let reason = transportUnavailable[source] {
            let name = waveformTracks.first(where: { $0.id == source })?.name ?? "Track"
            auditionLabel += " \(name) cannot be heard: \(reason). Restart playback to retry."
        }
    }

    private func enqueueTransport(
        _ clips: [SourceID: AlignmentRuntime.AuditionClip], startSeconds: Double, first: Bool
    ) throws {
        guard let representative = clips.values.first, !representative.samples.isEmpty,
              representative.samples.count <= Int(AVAudioFrameCount.max),
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: representative.sampleRate, channels: 1
              ),
              clips.values.allSatisfy({
                  $0.channelCount == 1 && $0.sampleRate == representative.sampleRate
                      && $0.samples.count == representative.samples.count
              })
        else { throw CocoaError(.fileReadCorruptFile) }
        if first {
            stopPlayback(updatePlayhead: false)
            for source in clips.keys {
                let player = AVAudioPlayerNode()
                transportPlayers[source] = player
                auditionEngine.attach(player)
                auditionEngine.connect(player, to: auditionEngine.mainMixerNode, format: format)
            }
            try auditionEngine.start()
            auditionPlaybackStartSeconds = startSeconds
            auditionPlayheadSeconds = startSeconds
            auditionPlaybackDurationSeconds = 0
        }
        guard Set(clips.keys).isSubset(of: Set(transportPlayers.keys)) else {
            throw WaveformWindowError.invalidSamples
        }
        for (source, clip) in clips {
            guard let player = transportPlayers[source],
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)
                  ),
                  let samples = buffer.floatChannelData?.pointee
            else { throw CocoaError(.fileReadCorruptFile) }
            buffer.frameLength = AVAudioFrameCount(clip.samples.count)
            clip.samples.withUnsafeBufferPointer { values in
                if let base = values.baseAddress { samples.update(from: base, count: values.count) }
            }
            player.scheduleBuffer(buffer)
        }
        auditionPlaybackDurationSeconds += Double(representative.samples.count) / representative.sampleRate
        if first {
            let lead = 0.1
            let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
            auditionStartedAt = Date().addingTimeInterval(lead)
            for player in transportPlayers.values { player.play(at: start) }
        }
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

    func clearAcceptedTiming() {
        guard let document, !isWorking, hasAcceptedRevision else { return }
        let prior = document.store.model
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

    private func persistenceCallback(
        document: ShowDocument,
        accepted: AcceptedAlignment?
    ) -> @MainActor (ShowDocumentModel) -> Void {
        { [weak document, weak self, runtime, episodeID] model in
            guard let document else { return }
            document.persistExpectedModel(model) { result in
                switch result {
                case .success:
                    Task {
                        do {
                            guard document.store.model == model else {
                                self?.cancelWaveforms()
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
                            self?.loadWaveforms(keepingSnapshot: self?.pendingWaveformMove != nil)
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
