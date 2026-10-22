import AppKit
import Foundation
import Testing
import WWCore
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Manual cut production listening and waveform path", .serialized)
struct ManualCutsHostedTests {
    @Test func sameRippleFramesReachPrimariesBackupsAndBothListeningPaths() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let original = f.document.store.model
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
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try await wait { f.document.verifiedModel == f.document.store.model }
        let edited = f.document.store.model
        let savedURL = try #require(f.document.fileURL)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: savedURL)).payload == edited)
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
        #expect(reopened.cutTimeline == cleanup.cutTimeline)
        cleanup.restoreManualCut(cut.id)
        try #require(cleanup.error == nil && cleanup.activeManualCuts.isEmpty)
        let restored = try await f.runtime.sourceAuditions(model: f.document.store.model, episode: episode.id,
            sources: sources, outputFrames: 24_000..<48_000)
        for source in sources { #expect(restored[source]?.samples == before[source]?.samples) }
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalBytes)
    }

    @Test(arguments: [0, 1, 2])
    func speakersOnlyMutesNonPrimariesWithoutChangingPrimaryChoices(primaryCount: Int) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: primaryCount, durationSeconds: 6)
        defer { f.close() }
        let original = f.document.store.model
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
        #expect(f.document.store.model == original, "Layout-triggered mutes are session state, not saved source edits")
        f.model.muteNonPrimaryTracks()
        #expect(f.model.listening.playback == playback)
        f.model.restoreListeningChoices()
        #expect(f.model.listening.playback == prior)
    }

    @Test func revealingOnlyOneCutSharesThePresentationAndAudioPrescriptionWithoutDocumentEdits() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        let original = f.document.store.model
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
        try await wait { f.document.verifiedModel == f.document.store.model }
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
        #expect(f.model.cutTimeline == cleanup.cutTimeline)
        #expect(f.model.waveformPlayheadSeconds == 3.5)
        #expect(cleanup.listening.selection == 1...2)
        #expect(f.document.store.model == saved && f.document.store.modelGeneration == generation && !undo.canUndo)
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
        #expect(reopened.cutTimeline == cleanup.cutTimeline && reopened.waveformPlayheadSeconds == 3.5)
        undo.beginUndoGrouping()
        let adjusted = cleanup.adjustManualCut(first, start: 1.01, end: 1.99)
        undo.endUndoGrouping()
        try #require(adjusted, "\(cleanup.error ?? "")")
        #expect(cleanup.expandedManualCut?.id == first.id && cleanup.activeManualCuts.last == second)
        #expect(cleanup.listening.selection == 1.01...1.99)
        undo.undo()
        cleanup.synchronizeCutTimeline()
        #expect(f.document.store.model == saved && cleanup.expandedManualCut == first)
        undo.redo()
        cleanup.synchronizeCutTimeline()
        let adjustedModel = f.document.store.model
        cleanup.showManualCut(first.id, expanded: false)
        #expect(f.document.store.model == adjustedModel && cleanup.expandedManualCut == nil)
        #expect(cleanup.cutTimeline == (try adjustedModel.episodes[0].manualCutTimeline()))
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
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
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
        let edited = f.document.store.model
        cleanup.zoomToManualCut(cut.id)
        #expect(cleanup.error == nil && f.model.waveformDurationSeconds == 2)
        #expect(f.model.waveformStartSeconds == 0 && f.model.waveformPlayheadSeconds == playhead)
        #expect(cleanup.expandedManualCut == nil && f.document.store.model == edited)
        f.model.waveformOffsetMilliseconds += 1
        cleanup.listening.select(from: 2, to: 3, within: 0...40)
        #expect(!cleanup.canApplyManualCut, "An alignment preview is not an editable accepted timeline")
    }

    @Test(arguments: [false, true])
    func cutZoomPreservesPresentationPlayheadDocumentAndUndo(integrated: Bool) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
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
        let edited = f.document.store.model
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
            #expect(f.document.store.model == edited && !undo.canUndo)
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
