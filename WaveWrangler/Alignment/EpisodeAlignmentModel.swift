import AppKit
import AVFAudio
import Foundation
import Observation
import WWAlignPipeline
import WWCore
import WWOrganizer
import WWTimeMap

struct AlignmentRow: Identifiable, Equatable {
    var id: RecordingEpochID { epochID }
    var groupID: RecorderGroupID
    var epochID: RecordingEpochID
    var groupName: String
    var epochLabel: String
    var sourceNames: String
    var state: AlignmentStateCopy
    var ratePPM: Double?
    var offsetMilliseconds: Double?
}

struct AlignmentAnchorRow: Identifiable, Equatable {
    var id: Int
    var sourceSeconds: Double
    var groupSeconds: Double
    var alignedSeconds: Double
}

@MainActor
@Observable
final class EpisodeAlignmentModel {
    private(set) var rows: [AlignmentRow] = []
    var selection: RecordingEpochID?
    private(set) var isWorking = false
    private(set) var hasAnalysis = false
    private(set) var message = "Alignment has not read or analysed any audio."
    private(set) var dependents = "No dependent work yet."
    private(set) var lastError: String?
    private(set) var auditionLabel = "Audition stopped"
    private(set) var isAuditioning = false
    var auditionStartSeconds = 0.0
    var auditionDurationSeconds = 5.0
    var editorRequest: AlignmentEditorRequest?
    var anchorSelection: Int?
    var requestedAnchorFocus: Int?
    private var anchorsByEpoch: [RecordingEpochID: [AlignmentAnchorRow]] = [:]
    private var acceptedMap: AlignedTimelineMap?

    let episodeID: EpisodeID
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let auditionEngine = AVAudioEngine()
    @ObservationIgnored private var auditionSource: AVAudioSourceNode?

    init(document: ShowDocument, episodeID: EpisodeID, runtime: AlignmentRuntime) {
        self.document = document
        self.episodeID = episodeID
        self.runtime = runtime
    }

    var selectedRow: AlignmentRow? {
        rows.first { $0.epochID == selection }
    }

    var canCorrect: Bool {
        guard let row = selectedRow else { return false }
        return !isWorking && row.state.remedies.contains("Edit Numerically…")
    }
    var canStartNewEpoch: Bool {
        anchorSelection != nil && acceptedMap != nil && !isWorking
    }
    var canAudition: Bool {
        selectedRow?.state.remedies.contains("Audition") == true && !isWorking
    }
    var selectedAnchors: [AlignmentAnchorRow] {
        guard let selection else { return [] }
        return anchorsByEpoch[selection] ?? []
    }

    func requestNumericEditor() {
        guard canCorrect else { return }
        editorRequest = .numeric
    }

    func requestAnchorEditor() {
        guard canCorrect else { return }
        editorRequest = .anchors
    }

    func requestSelectedAnchorFocus() {
        guard let anchorSelection else { return }
        requestedAnchorFocus = anchorSelection
    }

    func startNewEpochAtSelectedAnchor() {
        guard let document, let row = selectedRow, let selectedAnchorID = anchorSelection,
              let anchor = selectedAnchors.first(where: { $0.id == selectedAnchorID }),
              let map = acceptedMap, canStartNewEpoch,
              let group = map.groups.first(where: { $0.group == row.groupID }),
              let placement = group.placements.first(where: {
                  $0.spans.contains(where: { $0.epoch == row.epochID })
              })
        else { return }
        var model = document.store.model
        guard let episodeIndex = model.episodes.firstIndex(where: { $0.id == episodeID }),
              let groupIndex = model.episodes[episodeIndex].recorderGroups.firstIndex(where: { $0.id == row.groupID })
        else { return }
        let next = model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.count + 1
        let epoch = RecordingEpoch(label: "Epoch \(next)", note: "Started at a manual anchor")
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(epoch)
        let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
        let frame = Int64((anchor.sourceSeconds * rate).rounded())
        isWorking = true
        Task {
            do {
                let accepted = try await runtime.split(
                    model: model, episode: episodeID, group: row.groupID,
                    source: placement.occurrence.source, epoch: row.epochID,
                    frame: frame, newEpoch: epoch.id
                )
                if document.store.applyReplacement(
                    UndoActionName.startNewEpochAtAnchor,
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
                    message = "Started \(epoch.label) at the selected anchor. The new epoch is unsupported until you time it."
                }
            } catch {
                lastError = String(describing: error)
                message = "The occurrence was not split."
            }
            isWorking = false
        }
    }

    func auditionSelection() {
        guard let epoch = selection, canAudition, !isAuditioning,
              auditionStartSeconds.isFinite, auditionStartSeconds >= 0,
              auditionDurationSeconds.isFinite, auditionDurationSeconds > 0
        else { return }
        auditionLabel = "Preparing the selected internal audition range. Nothing is exported."
        Task {
            do {
                let clip = try await runtime.audition(
                    episode: episodeID, epoch: epoch,
                    startSeconds: auditionStartSeconds,
                    durationSeconds: auditionDurationSeconds
                )
                try play(clip)
                isAuditioning = true
                auditionLabel = "Auditioning the selected source region as an internal check. Nothing is exported."
            } catch {
                lastError = String(describing: error)
                auditionLabel = "Audition unavailable for this source."
            }
        }
    }

    func load() {
        guard let document else { return }
        let model = document.store.model
        let interval = Responsiveness.begin("alignment.episodeSwitch")
        Task {
            let prepared = await runtime.inspect(model: model, episode: episodeID)
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
            if !selectedAnchors.contains(where: { $0.id == anchorSelection }) {
                anchorSelection = selectedAnchors.first?.id
            }
            await updateDependents()
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

    func placeAnchors(_ anchors: [AlignmentAnchor]) {
        guard let epoch = selection else { return }
        accept(
            actionName: UndoActionName.placeAnchor,
            decisions: [epoch: .anchors(anchors)]
        ) { [weak self] in
            self?.anchorsByEpoch[epoch] = anchors.sorted { $0.sourceSeconds < $1.sourceSeconds }.enumerated().map {
                AlignmentAnchorRow(
                    id: $0.offset, sourceSeconds: $0.element.sourceSeconds,
                    groupSeconds: $0.element.sourceSeconds,
                    alignedSeconds: $0.element.alignedSeconds
                )
            }
            self?.anchorSelection = self?.anchorsByEpoch[epoch]?.first?.id
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

    func stopAudition() {
        auditionEngine.stop()
        if let auditionSource, auditionEngine.attachedNodes.contains(auditionSource) {
            auditionEngine.detach(auditionSource)
        }
        auditionSource = nil
        isAuditioning = false
        auditionLabel = "Audition stopped"
    }

    private func play(_ clip: AlignmentRuntime.AuditionClip) throws {
        stopAudition()
        guard !clip.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)
        else { throw CocoaError(.fileReadCorruptFile) }
        let cursor = AuditionSampleCursor(samples: clip.samples)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, output in
            cursor.render(frameCount: frameCount, output: output)
        }
        auditionSource = source
        auditionEngine.attach(source)
        auditionEngine.connect(source, to: auditionEngine.mainMixerNode, format: format)
        try auditionEngine.start()
        let duration = Double(clip.samples.count) / clip.sampleRate
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard self?.isAuditioning == true else { return }
            self?.stopAudition()
        }
    }

    private final class AuditionSampleCursor: @unchecked Sendable {
        private let samples: [Float]
        private var index = 0

        init(samples: [Float]) {
            self.samples = samples
        }

        func render(frameCount: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            let count = Int(frameCount)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<count {
                    data[frame] = index + frame < samples.count ? samples[index + frame] : 0
                }
            }
            index = min(samples.count, index + count)
            return noErr
        }
    }

    enum AlignmentEditorRequest: Identifiable {
        case numeric
        case anchors

        var id: Int {
            switch self {
            case .numeric: 1
            case .anchors: 2
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
                let accepted = try await runtime.accept(model: prior, episode: episodeID, decisions: decisions)
                let applied = document.store.applyReplacement(
                    actionName,
                    model: accepted.model,
                    afterChange: persistenceCallback(document: document, accepted: accepted)
                )
                if applied {
                    onAccepted()
                    acceptedMap = accepted.map
                    rows = Self.makeRows(
                        model: accepted.model, episodeID: episodeID,
                        states: await runtime.states(model: accepted.model, episode: episodeID),
                        map: accepted.map
                    )
                    message = "Map revision \(accepted.revision.revision) will activate after the show is verified on disk."
                    anchorsByEpoch = Self.makeAnchors(map: accepted.map)
                    if actionName == UndoActionName.acceptProposal {
                        announce("Accepted proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    } else if actionName == UndoActionName.rejectProposal {
                        announce("Rejected proposal for \(selectedRow?.epochLabel ?? "selected epoch")")
                    }
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
        guard let episode = model.episode(episodeID) else { return [] }
        let byEpoch = Dictionary(uniqueKeysWithValues: states.map { ($0.epoch, $0) })
        let timing = Dictionary(
            uniqueKeysWithValues: (map?.groups ?? []).flatMap { group in
                group.epochs.compactMap { epoch -> (RecordingEpochID, (Double, Double))? in
                    guard case let .mapped(segments, _) = epoch.mapping, let segment = segments.first else { return nil }
                    return (
                        epoch.epoch,
                        ((segment.rateRatio.approximateDouble - 1) * 1_000_000,
                         segment.alignedOffset.approximateDouble * 1_000)
                    )
                }
            }
        )
        var mappedSources: [RecordingEpochID: [SourceID]] = [:]
        for group in map?.groups ?? [] {
            for placement in group.placements {
                for span in placement.spans {
                    if mappedSources[span.epoch]?.contains(placement.occurrence.source) != true {
                        mappedSources[span.epoch, default: []].append(placement.occurrence.source)
                    }
                }
            }
        }
        return episode.recorderGroups.flatMap { group in
            group.epochs.map { epoch in
                let mapped = Set(mappedSources[epoch.id] ?? [])
                let sources = episode.sources.filter {
                    mapped.contains($0.id)
                        || ($0.placement.recorderGroupID == group.id && $0.placement.epochID == epoch.id)
                }
                let status = byEpoch[epoch.id]?.status ?? .unsupported(.notAttempted, .analysisPending)
                let blockedName: String? = {
                    guard case let .sourceBlocked(sourceID, _) = status else { return nil }
                    return episode.source(sourceID)?.displayNameHint
                }()
                return AlignmentRow(
                    groupID: group.id,
                    epochID: epoch.id,
                    groupName: group.name,
                    epochLabel: epoch.label,
                    sourceNames: sources.map(\.displayNameHint).joined(separator: ", "),
                    state: AlignmentPresentation.copy(for: status, fileName: blockedName),
                    ratePPM: timing[epoch.id]?.0,
                    offsetMilliseconds: timing[epoch.id]?.1
                )
            }
        }
    }

    private func updateDependents(announce: Bool = false) async {
        let jobs = await runtime.dependentJobCount(episode: episodeID)
        dependents = jobs == 0
            ? "No dependent work yet."
            : "Dependents affected by accepting this map: 0 edits, \(jobs) jobs will become stale."
        if announce {
            self.announce(jobs == 0 ? "No dependent work is stale" : "0 edits, \(jobs) jobs now stale")
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
