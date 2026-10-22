import AppKit
import Foundation
import Testing
import WWCore
import WWDerived
import WWPersistence
@testable import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("Tracks workflow transactions and listening", .serialized)
struct TracksWorkflowHostedTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Tracks workflow did not finish")
    }

    @Test func listeningDefaultIsOneShotPerAcceptanceAndDoesNotRewriteLegacyPreferences() throws {
        let primary = SourceRecord(displayNameHint: "Primary")
        let backup = SourceRecord(displayNameHint: "Backup")
        let episode = Episode(title: "Legacy", sources: [primary, backup], speakerAssignments: [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: primary.id, statedChannel: 0)),
        ], workspace: .init(editingPlaybackPolicy: .soloBackups))
        let state = EpisodeListeningState()
        state.playback.setSoloed(true, scope: .source(primary.id))
        let previous = state.playback
        try state.applyAcceptedAlignmentPolicy(.muteNonPrimaries, in: episode, identity: "first", revision: 1)
        #expect(state.previousPlayback == previous && state.editingPolicyRevision == 1)
        #expect(state.playback.muted.contains(.source(backup.id)))
        state.playback.setMuted(false, scope: .source(backup.id))
        let manual = state.playback
        try state.applyAcceptedAlignmentPolicy(.soloBackups, in: episode, identity: "first", revision: 1)
        #expect(state.playback == manual, "Refresh, Undo/Redo and preference changes cannot reapply this acceptance")
        try state.applyAcceptedAlignmentPolicy(.keepChoices, in: episode, identity: "next", revision: 2)
        #expect(state.playback == manual && state.previousPlayback == previous)
        #expect(episode.workspace?.editingPlaybackPolicy == .soloBackups)
    }

    @Test func lockedReplacementKeepsWorkDuringReviewThenResetsAndUndoesTogether() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let target = try #require(f.document.store.model.episodes[0].sources.first { $0.id == f.target })
        let group = try #require(target.placement.recorderGroupID)
        f.model.setPositionLocked(true, group: group)
        let state = ShowWindowState(store: f.document.store)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 20)
        let input = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(
            model: input, episode: f.model.episodeID, modelRevision: "synthetic-workflow",
            transcribeWindow: { _ in PCMTranscript(segments: [.init(text: "um", startSeconds: 1, endSeconds: 1.25)]) },
            progress: { _ in })
        try #require(try cleanup.publishTranscripts(transcripts, expecting: input))
        var prior = f.document.store.model
        let priorRevision = try #require(prior.episodes[0].alignment?.acceptedRevision)
        prior.episodes[0].cleanup?.manualCuts = [
            .init(alignmentRevision: priorRevision, startFrame: 240_000, endFrame: 288_000),
        ]
        let applied = f.document.store.applyReplacement("Synthetic edit", expecting: f.document.store.model,
            model: prior, afterChange: { _ in })
        try #require(applied)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let oldMap = try prior.timeMap(revision: #require(prior.episodes[0].alignment?.acceptedRevision), in: f.model.episodeID)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented, "\(f.model.lastError ?? "")")
        #expect(f.document.store.model == prior, "Analysis must not clear work or unlock live groups")
        #expect(f.model.tracksReviewProposals.count == 1)
        f.model.discardTracksReview()
        #expect(f.document.store.model == prior)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        f.model.selection = f.model.rows.first?.epochID
        f.model.selectedTracksProposals = f.model.tracksReviewProposals
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        undo.endUndoGrouping()
        let accepted = f.document.store.model
        try #require(accepted != prior && f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let episode = accepted.episodes[0]
        #expect(episode.cleanup?.transcripts.isEmpty == true && episode.cleanup?.workingRange == nil)
        #expect(episode.cleanup?.transcriptHistory == transcripts && episode.activeManualCuts.isEmpty)
        #expect(episode.cleanup?.manualCuts == prior.episodes[0].cleanup?.manualCuts)
        #expect(episode.workspace?.positionLocks == prior.episodes[0].workspace?.positionLocks)
        #expect(episode.sources == prior.episodes[0].sources && episode.speakerAssignments == prior.episodes[0].speakerAssignments)
        #expect(episode.alignment?.maps.dropLast() == prior.episodes[0].alignment?.maps[...])
        let newMap = try accepted.timeMap(revision: #require(episode.alignment?.acceptedRevision), in: episode.id)
        #expect(newMap.reference == oldMap.reference)
        undo.undo()
        try await wait { f.document.verifiedModel == f.document.store.model }
        #expect(f.document.store.model == prior, "One Undo restores timing, transcripts, reviews, cuts and IN/OUT")
        f.model.setTrack(f.target, enabled: true)
        let manualListening = f.model.listening.playback
        undo.redo()
        try await wait { f.document.verifiedModel == f.document.store.model }
        #expect(f.document.store.model == accepted)
        #expect(f.model.listening.playback == manualListening, "Redo cannot reapply the listening policy")
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func downstreamEditsDuringReviewRefuseResetAndCanceledAnalysisLeavesPriorWork() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.analyzeTracks()
        f.model.cancelTracksAnalysis()
        try await wait { !f.model.isWorking }
        #expect(f.document.store.model.episodes[0].alignment == nil && !f.model.tracksReviewPresented)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented)
        let prior = f.document.store.model
        #expect(f.document.store.apply("Concurrent edit", { model in
            var changed = model
            changed.episodes[0].cleanup = EpisodeCleanup()
            return changed
        }))
        let edited = f.document.store.model
        f.model.selectedTracksProposals = f.model.tracksReviewProposals
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking }
        #expect(f.model.lastError?.contains("downstream work changed") == true)
        #expect(f.document.store.model == edited && edited.episodes[0].alignment == prior.episodes[0].alignment)
    }

    @Test func initialAlignmentDoesNotOverrideAnExplicitPositionLock() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        let target = try #require(f.document.store.model.episodes[0].source(f.target))
        f.model.setPositionLocked(true, group: try #require(target.placement.recorderGroupID))
        let prior = f.document.store.model
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented && !f.model.tracksReviewProposals.isEmpty)
        f.model.selectedTracksProposals = f.model.tracksReviewProposals
        f.model.acceptTracksReview()
        #expect(f.model.lastError?.contains("position is locked") == true)
        #expect(f.document.store.model == prior, "Only confirmed replacement alignment may override non-reference locks")
    }

    @Test func recordingsSheetHasFlexibleNativeResizeLimitsInBothDimensions() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        let controller = EpisodeWindowController(store: f.document.store, episodeID: f.model.episodeID)
        f.document.addWindowController(controller)
        defer {
            controller.state.recordingsPresented = false
            f.close()
        }
        controller.showWindow(nil)
        controller.state.recordingsPresented = true
        let window = try #require(controller.window)
        try await wait { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let limits = "style \(sheet.styleMask.rawValue), minimum \(sheet.contentMinSize), maximum \(sheet.contentMaxSize)"
        #expect(sheet.styleMask.contains(.resizable), "\(limits)")
        #expect(sheet.contentMinSize.width <= 760 && sheet.contentMinSize.height <= 540, "\(limits)")
        #expect(sheet.contentMaxSize.width > sheet.contentMinSize.width + 160
            && sheet.contentMaxSize.height > sheet.contentMinSize.height + 80, "\(limits)")
    }
}
