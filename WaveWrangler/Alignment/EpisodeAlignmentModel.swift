import AppKit
import AVFAudio
import Foundation
import Observation
import WWAlignPipeline
import WWCore
import WWOrganizer
import WWTimeMap

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
    private(set) var isPreparingAudition = false
    private(set) var auditionPlayheadSeconds = 0.0
    var auditionStartSeconds = 0.0
    var auditionDurationSeconds = 5.0
    var editorRequest: AlignmentEditorRequest?
    var anchorSelection: Int?
    var requestedAnchorFocus: Int?
    var requestedEpochFocus: RecordingEpochID?
    private var anchorsByEpoch: [RecordingEpochID: [AlignmentAnchorRow]] = [:]
    private var acceptedMap: AlignedTimelineMap?

    let episodeID: EpisodeID
    private weak var document: ShowDocument?
    private let runtime: AlignmentRuntime
    @ObservationIgnored private let auditionEngine = AVAudioEngine()
    @ObservationIgnored private var auditionSource: AVAudioSourceNode?
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
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

    func requestSelectedAnchorFocus() {
        guard let anchorSelection else { return }
        requestedAnchorFocus = anchorSelection
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
        guard let document, let row = selectedRow, let selectedAnchorID = anchorSelection,
              let anchor = selectedAnchors.first(where: { $0.id == selectedAnchorID }),
              let map = acceptedMap, canStartNewEpoch,
              let group = map.groups.first(where: { $0.group == row.groupID }),
              let placement = group.placements.first(where: {
                  $0.spans.contains(where: { $0.epoch == row.epochID })
              })
        else { return }
        let prior = document.store.model
        var model = prior
        guard let episodeIndex = model.episodes.firstIndex(where: { $0.id == episodeID }),
              let groupIndex = model.episodes[episodeIndex].recorderGroups.firstIndex(where: { $0.id == row.groupID })
        else { return }
        let next = model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.count + 1
        let epoch = RecordingEpoch(label: "Epoch \(next)", note: "Started at a manual anchor")
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(epoch)
        let rate = Double(placement.occurrence.nominalRate.framesPerSecond)
        let frame = Int64((anchor.sourceSeconds * rate).rounded())
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
        auditionTask?.cancel()
        isPreparingAudition = true
        auditionLabel = "Preparing the selected internal audition range. Nothing is exported."
        auditionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isPreparingAudition = false
                auditionTask = nil
            }
            do {
                let clip = try await runtime.audition(
                    episode: episodeID, epoch: epoch,
                    startSeconds: auditionStartSeconds,
                    durationSeconds: auditionDurationSeconds
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingAudition else { return }
                        self.auditionLabel = "Seeking through the source… \(Int(progress * 100))%. Nothing is exported."
                    }
                }
                try Task.checkCancellation()
                try play(clip)
                try Task.checkCancellation()
                isAuditioning = true
                auditionLabel = "Auditioning the selected source region as an internal check. Nothing is exported."
            } catch is CancellationError {
                stopPlayback(updatePlayhead: true)
            } catch {
                lastError = String(describing: error)
                auditionLabel = (error as? LocalizedError)?.errorDescription
                    ?? "Audition unavailable for this source."
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
            self.requestedAnchorFocus = focused.id
        }
    }

    func stopAudition() {
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

    private func play(_ clip: AlignmentRuntime.AuditionClip) throws {
        stopPlayback(updatePlayhead: false)
        guard !clip.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)
        else { throw CocoaError(.fileReadCorruptFile) }
        let cursor = AuditionSampleCursor(samples: clip.samples)
        let source = cursor.makeSourceNode(format: format)
        auditionSource = source
        auditionEngine.attach(source)
        auditionEngine.connect(source, to: auditionEngine.mainMixerNode, format: format)
        try auditionEngine.start()
        auditionPlaybackStartSeconds = auditionStartSeconds
        auditionPlayheadSeconds = auditionStartSeconds
        auditionPlaybackDurationSeconds = Double(clip.samples.count) / clip.sampleRate
        auditionStartedAt = Date()
        auditionStopTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(auditionPlaybackDurationSeconds))
            guard !Task.isCancelled, isAuditioning else { return }
            stopAudition()
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
                    acceptedMap = accepted.map
                    rows = Self.makeRows(
                        model: accepted.model, episodeID: episodeID,
                        states: await runtime.states(model: accepted.model, episode: episodeID),
                        map: accepted.map
                    )
                    message = "Map revision \(accepted.revision.revision) will activate after the show is verified on disk."
                    anchorsByEpoch = Self.makeAnchors(map: accepted.map)
                    onAccepted()
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
    private var index = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, output in
            render(frameCount: frameCount, output: output)
        }
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
