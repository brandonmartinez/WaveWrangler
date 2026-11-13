import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import WWCore
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Manual cut production listening and waveform path", .serialized)
struct ManualCutsHostedTests {
    @Test func closingDuringCheckpointEncodingDoesNotResurrectRecovery() async throws {
        let f = try await MixerHostedTests().ready(durationSeconds: 4)
        defer { f.close() }
        let preference = PersistenceEnvironment.autosaveGate.preference
        PersistenceEnvironment.autosaveGate.preference = AutosavePreference(enabled: true, delaySeconds: 30)
        defer { PersistenceEnvironment.autosaveGate.preference = preference }
        let gate = SaveWorkerGate()
        ShowDocument.debugBeforeCheckpointEncoding = { gate.pauseOnce() }
        defer {
            gate.resume()
            ShowDocument.debugBeforeCheckpointEncoding = nil
        }
        let key = f.document.documentKey
        try #require(f.document.store.apply("Change Before Close") { model throws(DomainError) in
            try model.renamingShow(to: "Unsaved checkpoint")
        })
        try await wait { gate.entered }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { gate.resume() }
        f.document.close()
        #expect(!gate.timedOut && !gate.ranOnMainThread)
        let retained = PersistenceEnvironment.recovery.latestEditCheckpoint(for: key)
        #expect(retained == nil, "Don't Save must finish cleanup after the owned checkpoint before close returns.")
    }

    @Test func repeatedCutsAndUndoRemainInteractiveDuringAutosaveEncoding() async throws {
        let f = try await MixerHostedTests().ready(durationSeconds: 12)
        defer { f.close() }
        let preference = PersistenceEnvironment.autosaveGate.preference
        PersistenceEnvironment.autosaveGate.preference = AutosavePreference(enabled: true, delaySeconds: 30)
        defer { PersistenceEnvironment.autosaveGate.preference = preference }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        f.model.listening.selection = 1...2
        cleanup.applyManualCut()
        try #require(cleanup.error == nil)
        let snapshot = f.document.store.residentModel
        let gate = SaveWorkerGate()
        ShowDocument.debugBeforeSaveEncoding = { gate.pauseOnce() }
        defer {
            gate.resume()
            ShowDocument.debugBeforeSaveEncoding = nil
        }
        let saving = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                f.document.autosave(withImplicitCancellability: false) {
                    if let error = $0 { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        try await wait { gate.entered }
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 6
        f.model.listening.selection = 3...4
        let cutStarted = ContinuousClock.now
        cleanup.applyManualCut()
        let cutLatency = cutStarted.duration(to: .now)
        let secondCut = f.document.store.residentModel
        let cutError = cleanup.error
        #expect(cutError == nil && secondCut != snapshot)
        #expect(cutLatency < .milliseconds(100), "A cut must not wait for the stalled autosave.")
        let undoStarted = ContinuousClock.now
        undo.undo()
        let undone = f.document.store.residentModel == snapshot
        undo.redo()
        let undoLatency = undoStarted.duration(to: .now)
        let redone = f.document.store.residentModel == secondCut
        #expect(undone && redone)
        #expect(undoLatency < .milliseconds(150), "Undo/Redo must not wait for the stalled autosave.")
        try await wait { f.model.hasUsableWaveformPresentation || f.model.lastError != nil }
        let visibleLatency = cutStarted.duration(to: .now)
        let waveformError = f.model.lastError
        #expect(waveformError == nil && !gate.ranOnMainThread && !gate.timedOut)
        #expect(visibleLatency < .milliseconds(500), "The waveform must recover while autosave is still stalled.")
        gate.resume()
        try await saving.value
        let verified = f.document.verifiedModel
        let current = f.document.store.residentModel
        let dirty = f.document.isDocumentEdited
        let saved = f.document.status.saveStatus.state.isVerifiedOnDisk
        #expect(verified == snapshot && current == secondCut && dirty && !saved)
        ShowDocument.debugBeforeSaveEncoding = nil
        try await MixerHostedTests().save(f.document)
    }

    @Test func longRecordingCutKeepsTheVisibleWaveformsResponsive() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 1, durationSeconds: 600, extraSources: 2)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && !f.model.isLoadingOverview && f.model.canApplyManualCuts }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 600
        let host = HostedTimelineWindow(width: 1200, height: 900,
            content: AlignmentWaveformView(model: f.model, cleanup: cleanup, showInspector: {}))
        defer { host.close() }
        try await host.settle()
        f.model.listening.selection = 5...6
        try #require(cleanup.canApplyManualCut)
        var longestUITick = Duration.zero
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(10))
                    let now = ContinuousClock.now
                    longestUITick = max(longestUITick, previous.duration(to: now))
                    previous = now
                }
            } catch is CancellationError {
                return
            } catch {
                Issue.record(error)
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        let started = ContinuousClock.now
        cleanup.applyManualCut()
        let synchronous = started.duration(to: .now)
        try #require(cleanup.error == nil)
        try await wait { f.model.hasUsableWaveformPresentation || f.model.lastError != nil }
        let visible = started.duration(to: .now)
        #expect(synchronous < .milliseconds(100), "A cut must not block the UI actor: \(synchronous)")
        #expect(visible < .milliseconds(500), "The waveform must not wait for full reconstruction: \(visible)")
        try await wait { !f.model.isLoadingWaveforms }
        try await host.settle()
        let uiTick = longestUITick
        print("LONG_RECORDING_CUT synchronous=\(synchronous) visible=\(visible) longest_ui_tick=\(uiTick)")
        #expect(uiTick < .milliseconds(150), "Preview and detail publication must keep the UI responsive: \(uiTick)")
        #expect(f.model.lastError == nil)
    }

    @Test func cutViewportPublishesBeforeBackgroundDetailAndRemainsInteractive() async throws {
        let f = try await MixerHostedTests().ready(durationSeconds: 12)
        defer { f.close() }
        f.model.ensureWaveformOverview()
        try await wait { !f.model.isLoadingOverview && !f.model.waveformOverviewTracks.isEmpty }
        let episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let revision = try #require(episode.alignment?.acceptedRevision)
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 6
        f.model.cutWaveformDetailDelayForTesting = .seconds(2)
        let cut = ManualEpisodeCut(alignmentRevision: revision, startFrame: 48_000, endFrame: 96_000)
        try #require(f.document.store.apply("Cut preview", { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(manualCuts: [cut]), in: episode.id)
        }))
        let started = ContinuousClock.now
        f.model.synchronizeCuts()
        try await wait { f.model.hasUsableWaveformPresentation || f.model.lastError != nil }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .milliseconds(500), "The viewport cannot wait for the full-detail refresh: \(elapsed)")
        #expect(f.model.lastError == nil && f.model.isLoadingWaveforms)
        #expect(f.model.trackProcessingOperation == nil,
            "The correct cut preview must not remain behind a blocking preparation overlay.")
        let source = try #require(f.model.waveformOverviewTracks.first?.id)
        let preview = try #require(f.model.waveformOverviewIndices[source])
        #expect(!preview.isEmpty)
        #expect(preview.strokes.allSatisfy { !($0.groupSeconds > 1 && $0.groupSeconds < 2) })
        #expect(f.model.previewWaveformPlayhead(to: 0.5))
        f.model.listening.select(from: 0.5, to: 0.75, within: 0...6)
        #expect(f.model.listening.selection == 0.5...0.75)
        f.model.waveformStartSeconds = 7
        f.model.waveformDurationSeconds = 2
        try await wait {
            f.model.waveformOverviewIndices[source]?.hasVisible(start: 7, duration: 2) == true
        }
        #expect(f.model.isLoadingWaveforms && f.model.hasUsableWaveformPresentation)
        #expect(f.model.waveformTileSlices.isEmpty,
            "Old detailed geometry must stay hidden, not be discarded, until reprojection completes.")
        try #require(f.document.store.apply("Restore preview cut", { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(manualCuts: []), in: episode.id)
        }))
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 6
        f.model.synchronizeCuts()
        try await wait {
            f.model.hasUsableWaveformPresentation
                && f.model.waveformOverviewIndices[source]?.strokes.contains {
                    $0.groupSeconds > 1 && $0.groupSeconds < 2
                } == true
        }
        #expect(f.model.isLoadingWaveforms && f.model.trackProcessingOperation == nil)
        try await wait { !f.model.isLoadingWaveforms }
        #expect(f.model.hasUsableWaveformPresentation && f.model.lastError == nil)
        print("CUT_VIEWPORT elapsed=\(elapsed)")
    }

    @Test func unexpandedPresentationDoesNotObserveUnrelatedDocumentEdits() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 6)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        let episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let revision = try #require(episode.alignment?.acceptedRevision)
        let cuts = (0..<100).map {
            ManualEpisodeCut(alignmentRevision: revision,
                startFrame: Int64($0) * 2400, endFrame: Int64($0) * 2400 + 480)
        }
        try #require(f.document.store.apply("Synthetic dense cuts", { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(manualCuts: cuts), in: episode.id)
        }))
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.audioEditor.composition != nil }
        let projection = f.model.presentationTimeline
        let changed = Mutex(false)
        withObservationTracking {
            _ = f.model.presentationTimeline
        } onChange: {
            changed.withLock { $0 = true }
        }
        try #require(f.document.store.apply("Change monitoring gain", { model throws(DomainError) in
            try model.settingMasterMix(MasterMixState(gainDB: -1), in: episode.id)
        }))
        let mixInvalidatedGeometry = changed.withLock { $0 }
        let unchangedProjection = f.model.presentationTimeline == projection
        #expect(!mixInvalidatedGeometry && unchangedProjection)
        f.model.listening.expandedManualCutID = cuts[0].id
        let expansionObserved = changed.withLock { $0 }
        #expect(expansionObserved, "The fast unexpanded path must retain its expansion dependency.")
        changed.withLock { $0 = false }
        withObservationTracking {
            _ = f.model.presentationTimeline
        } onChange: {
            changed.withLock { $0 = true }
        }
        var updatedCuts = cuts
        updatedCuts[0] = ManualEpisodeCut(id: cuts[0].id, alignmentRevision: revision,
            startFrame: 0, endFrame: 960)
        try #require(f.document.store.apply("Adjust expanded cut", { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(manualCuts: updatedCuts), in: episode.id)
        }))
        let cutEditObserved = changed.withLock { $0 }
        #expect(cutEditObserved, "Expanded geometry must still observe document cut edits.")
    }

    @Test func removedAudioAuditionsExplicitlyLeaveProductionMixAndKeepOtherCuts() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 6)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        let episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let revision = try #require(episode.alignment?.acceptedRevision)
        let cut = ManualEpisodeCut(alignmentRevision: revision, startFrame: 48_000, endFrame: 96_000)
        let other = ManualEpisodeCut(alignmentRevision: revision, startFrame: 192_000, endFrame: 240_000)
        try #require(f.document.store.apply("Synthetic cut audition fixture", { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(manualCuts: [cut, other]), in: episode.id)
        }))
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: episode.id, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        f.model.load()
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        try #require(!f.model.enabledSources.isEmpty)
        let saved = f.document.store.residentModel
        for mode: ManualCutAudition in [.removed, .original] {
            f.model.selectProductionMix()
            cleanup.auditionManualCut(cut.id, mode: mode)
            let usesProductionMix = f.model.listening.usesProductionMix
            #expect(!usesProductionMix, "Removed audio is an explicit diagnostic source audition, not a production selection")
            try await wait { !f.model.isPreparingAudition && !f.model.isAuditioning }
            let status = f.model.auditionLabel
            let error = cleanup.error
            #expect(status == "Finished selection audition.")
            #expect(error == nil)
            #expect(cleanup.cutTimeline.removals == [other.startFrame..<other.endFrame])
            #expect(f.document.store.residentModel == saved)
        }
    }

    @Test(arguments: [0.5, 2.0])
    func sameRippleFramesReachPrimariesBackupsAndBothListeningPaths(jumpBack: Double) async throws {
        let priorJumpBack = AppSettings.shared.cutJumpBackSeconds
        AppSettings.shared.cutJumpBackSeconds = jumpBack
        defer { AppSettings.shared.cutJumpBackSeconds = priorJumpBack }
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        let original = f.document.store.residentModel
        let originalBytes = try f.files.map { try Data(contentsOf: $0) }
        let episode = try #require(original.episode(f.model.episodeID))
        let sources = episode.sources.map(\.id)
        let before = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: 24_000..<48_000)
        let after = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: 96_000..<120_000)
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: episode.id, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        try #require(cleanup.canReviewFillers)
        cleanup.listening.select(from: 1, to: 2, within: 0...40)
        cleanup.listening.playback.setMuted(true, scope: .source(f.target))
        let choices = cleanup.listening.playback
        cleanup.applyManualCut()
        try #require(cleanup.error == nil, "\(cleanup.error ?? "")")
        let expectedPlayhead = max(0, 1 - jumpBack)
        let alignmentPlayhead = f.model.waveformPlayheadSeconds
        let cleanupPlayhead = cleanup.playhead
        #expect(alignmentPlayhead == expectedPlayhead && cleanupPlayhead == expectedPlayhead,
            "Use the configured jump-back interval, clamping at the timeline start.")
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try await wait { f.document.verifiedModel == f.document.store.residentModel }
        let edited = f.document.store.residentModel
        let savedURL = try #require(f.document.fileURL)
        let savedMatches = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(LocalFileOperations().read(savedURL)).payload == edited
        #expect(savedMatches)
        #expect(edited.episodes[0].sources == episode.sources && edited.episodes[0].alignment == episode.alignment)
        #expect(cleanup.listening.playback == choices, "A cut never changes listening choices")
        let result = try await f.runtime.sourceAuditions(model: edited, episode: episode.id,
            sources: sources, outputFrames: 24_000..<72_000)
        let uncut = try await f.runtime.sourceAuditions(model: edited, episode: episode.id,
            sources: sources, outputFrames: 24_000..<72_000, applyingCuts: false)
        let originalWindow = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: 24_000..<72_000)
        for source in sources {
            #expect(result[source]?.samples == (before[source]?.samples ?? []) + (after[source]?.samples ?? []),
                    "Even a muted Backup receives exactly the same kept-frame prescription")
            #expect(uncut[source]?.samples == originalWindow[source]?.samples,
                    "Cut review explicitly reads original aligned audio without restoring or changing the saved cut")
        }
        let preview = try await f.runtime.cleanupPreview(model: edited, episode: episode.id,
            start: 0.5, duration: 1, respectWorkingRange: false)
        let lane = try #require(cleanup.plan?.lanes.first)
        #expect(preview.channels[lane.speaker] == result[lane.primary.sourceID]?.samples)
        f.model.load()
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms }
        #expect(f.model.primaryWaveformGroups.count == 1)
        #expect(f.model.primaryWaveformGroups.flatMap(\.tracks).map(\.id) == [lane.primary.sourceID])
        #expect(f.model.waveformTracks.count == 2, "Speakers-only filtering does not remove stored tracks")
        #expect(f.model.cutTimeline.removals == [48_000..<96_000])
        #expect(f.model.waveformNavigationEndSeconds == 39)
        let cut = try #require(cleanup.activeManualCuts.first)
        let listening = EpisodeListeningState()
        listening.workspace.startSeconds = 10
        listening.workspace.playheadSeconds = 12
        let reopened = EpisodeAlignmentModel(document: f.document, episodeID: episode.id,
            runtime: f.runtime, listening: listening)
        defer { reopened.suspend() }
        reopened.load()
        #expect(reopened.waveformStartSeconds == 10 && reopened.waveformPlayheadSeconds == 12,
                "Reopening edited coordinates must not ripple them a second time")
        #expect(reopened.cutTimeline == cleanup.cutTimeline.cuts)
        cleanup.restoreManualCut(cut.id)
        try #require(cleanup.error == nil && cleanup.activeManualCuts.isEmpty)
        let restored = try await f.runtime.sourceAuditions(model: f.document.store.residentModel, episode: episode.id,
            sources: sources, outputFrames: 24_000..<48_000)
        for source in sources { #expect(restored[source]?.samples == before[source]?.samples) }
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalBytes)
    }

    @Test(arguments: [0, 1, 2])
    func speakersOnlyMutesNonPrimariesWithoutChangingPrimaryChoices(primaryCount: Int) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: primaryCount, durationSeconds: 6)
        defer { f.close() }
        let original = f.document.store.residentModel
        let episode = try #require(original.episode(f.model.episodeID))
        let primaries = f.model.primaryWaveformSources
        let nonPrimaries = Set(episode.sources.map(\.id)).subtracting(primaries)
        if let primary = primaries.first { f.model.listening.playback.setMuted(true, scope: .source(primary)) }
        f.model.listening.playback.setSoloed(true, scope: .source(f.target))
        let prior = f.model.listening.playback
        f.model.muteNonPrimaryTracks()
        let playback = f.model.listening.playback
        #expect(playback.soloed == prior.soloed)
        #expect(playback.muted == prior.muted.union(nonPrimaries.map(EpisodePlaybackScope.source)))
        #expect(nonPrimaries.allSatisfy { !f.model.trackEnabled($0) })
        for primary in primaries {
            #expect(playback.isAudible(primary, in: episode) == prior.isAudible(primary, in: episode))
        }
        #expect(f.document.store.residentModel == original, "Layout-triggered mutes are session state, not saved source edits")
        f.model.muteNonPrimaryTracks()
        #expect(f.model.listening.playback == playback)
        f.model.restoreListeningChoices()
        #expect(f.model.listening.playback == prior)
    }

    @Test func revealingOnlyOneCutSharesThePresentationAndAudioPrescriptionWithoutDocumentEdits() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        let original = f.document.store.residentModel
        let episode = try #require(original.episode(f.model.episodeID))
        let revision = try #require(episode.alignment?.acceptedRevision)
        let sources = episode.sources.map(\.id)
        let first = ManualEpisodeCut(alignmentRevision: revision, startFrame: 48_000, endFrame: 96_000)
        let second = ManualEpisodeCut(alignmentRevision: revision, startFrame: 192_000, endFrame: 240_000)
        let saved = try original.settingCleanup(EpisodeCleanup(manualCuts: [first, second]), in: episode.id)
        try #require(f.document.store.apply("Synthetic two-cut fixture", { _ throws(DomainError) in saved }))
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: episode.id, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        cleanup.synchronizeCutTimeline()
        try await wait { f.document.verifiedModel == f.document.store.residentModel }
        try await wait { !f.model.isLoadingWaveforms }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms }
        let generation = f.document.store.modelGeneration
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        f.model.waveformPlayheadSeconds = 2.5
        cleanup.showManualCut(first.id, expanded: true)
        #expect(cleanup.cutTimeline.removals == [second.startFrame..<second.endFrame])
        #expect(f.model.cutTimeline == cleanup.cutTimeline.cuts)
        #expect(f.model.waveformPlayheadSeconds == 3.5)
        #expect(cleanup.listening.selection == 1...2)
        #expect(f.document.store.residentModel == saved && f.document.store.modelGeneration == generation && !undo.canUndo)
        try await wait { !f.model.isLoadingWaveforms }
        let revealed = try await f.runtime.sourceAuditions(model: saved, episode: episode.id,
            sources: sources, outputFrames: 24_000..<240_000, revealingCut: first.id)
        let beforeSecond = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: 24_000..<192_000)
        let afterSecond = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: 240_000..<288_000)
        for source in sources {
            #expect(revealed[source]?.samples ==
                (beforeSecond[source]?.samples ?? []) + (afterSecond[source]?.samples ?? []),
                "Showing one cut never bypasses other cuts, even on muted or hidden tracks")
        }
        let preview = try await f.runtime.cleanupPreview(model: saved, episode: episode.id,
            start: 0.5, duration: 4.5, respectWorkingRange: false, revealingCut: first.id)
        let lane = try #require(cleanup.plan?.lanes.first)
        #expect(preview.channels[lane.speaker] == revealed[lane.primary.sourceID]?.samples)
        let listening = EpisodeListeningState()
        listening.workspace = cleanup.listening.workspace
        let reopened = EpisodeAlignmentModel(document: f.document, episodeID: episode.id,
            runtime: f.runtime, listening: listening)
        defer { reopened.suspend() }
        #expect(reopened.cutTimeline == cleanup.cutTimeline.cuts && reopened.waveformPlayheadSeconds == 3.5)
        undo.beginUndoGrouping()
        let adjusted = cleanup.adjustManualCut(first, start: 1.01, end: 1.99)
        undo.endUndoGrouping()
        try #require(adjusted, "\(cleanup.error ?? "")")
        #expect(cleanup.expandedManualCut?.id == first.id && cleanup.activeManualCuts.last == second)
        #expect(cleanup.listening.selection == 1.01...1.99)
        undo.undo()
        cleanup.synchronizeCutTimeline()
        #expect(f.document.store.residentModel == saved && cleanup.expandedManualCut == first)
        undo.redo()
        cleanup.synchronizeCutTimeline()
        let adjustedModel = f.document.store.residentModel
        cleanup.showManualCut(first.id, expanded: false)
        #expect(f.document.store.residentModel == adjustedModel && cleanup.expandedManualCut == nil)
        #expect(cleanup.cutTimeline.cuts == (try adjustedModel.episodes[0].manualCutTimeline()))
        cleanup.showManualCut(first.id, expanded: true)
        undo.beginUndoGrouping()
        cleanup.restoreManualCut(first.id)
        undo.endUndoGrouping()
        #expect(cleanup.expandedManualCut == nil && cleanup.listening.expandedManualCutID == nil)
        #expect(cleanup.activeManualCuts == [second], "Restoring the selected cut leaves all other edits intact")
    }

    @Test func manualSelectionCutDoesNotRequireTranscriptionOrConfirmedPrimaries() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        #expect(!cleanup.canReviewFillers)
        cleanup.listening.select(from: 1, to: 2, within: 0...40)
        try #require(cleanup.canApplyManualCut)
        cleanup.applyManualCut()
        #expect(cleanup.error == nil && cleanup.activeManualCuts.count == 1)
        let cut = try #require(cleanup.activeManualCuts.first)
        let playhead = f.model.waveformPlayheadSeconds
        let edited = f.document.store.residentModel
        cleanup.zoomToManualCut(cut.id)
        #expect(cleanup.error == nil && f.model.waveformDurationSeconds == 2)
        #expect(f.model.waveformStartSeconds == 0 && f.model.waveformPlayheadSeconds == playhead)
        #expect(cleanup.expandedManualCut == nil && f.document.store.residentModel == edited)
        f.model.waveformOffsetMilliseconds += 1
        cleanup.listening.select(from: 2, to: 3, within: 0...40)
        #expect(!cleanup.canApplyManualCut, "An alignment preview is not an editable accepted timeline")
    }

    @Test(arguments: [false, true])
    func cutZoomPreservesPresentationPlayheadDocumentAndUndo(integrated: Bool) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        if integrated { cleanup.connectWorkspace(to: f.model) }
        defer { cleanup.cancel() }
        await cleanup.refresh()
        cleanup.listening.select(from: 1, to: 2, within: 0...40)
        cleanup.applyManualCut()
        let cut = try #require(cleanup.activeManualCuts.first)
        let edited = f.document.store.residentModel
        let originalBytes = try f.files.map { try Data(contentsOf: $0) }
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        for expanded in [false, true] {
            cleanup.showManualCut(cut.id, expanded: expanded)
            cleanup.setWindow(start: 10, duration: 10)
            let playhead = f.model.waveformPlayheadSeconds
            let standalonePlayhead = cleanup.playhead
            let selection = cleanup.listening.selection
            cleanup.zoomToManualCut(cut.id)
            #expect(cleanup.error == nil, "\(cleanup.error ?? "")")
            #expect(cleanup.visibleDuration == 2)
            #expect(cleanup.windowStart == (expanded ? 0.5 : 0))
            #expect((cleanup.expandedManualCut != nil) == expanded)
            #expect(cleanup.selectedManualCutID == cut.id && cleanup.listening.selection == selection)
            #expect(f.model.waveformPlayheadSeconds == playhead && cleanup.playhead == standalonePlayhead)
            if integrated {
                #expect(f.model.waveformStartSeconds == cleanup.windowStart)
                #expect(f.model.waveformDurationSeconds == cleanup.visibleDuration)
            }
            #expect(f.document.store.residentModel == edited && !undo.canUndo)
        }
        cleanup.zoomToManualCut(UUID())
        #expect(cleanup.error != nil, "A stale cut reports an error instead of silently changing the view")
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalBytes)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
