import AppKit
import Foundation
import SwiftUI
import Testing
import WWAlignPipeline
import WWCore
import WWDerived
import WWEpisodeSetup
import WWPersistence
@testable import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("Tracks workflow transactions and listening", .serialized)
struct TracksWorkflowHostedTests {
    private func wait(seconds: TimeInterval = 40, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Tracks workflow did not finish")
    }

    @Test func nativeAcceptanceAlertNamesTheTimingFailureAndItsRecovery() {
        let alert = NSAlert(error: AlignmentAcceptanceError.staleSnapshot)
        #expect(alert.messageText.contains("no longer matches the current timing"))
        #expect(alert.informativeText.contains("Refresh audio"))
        #expect(!alert.messageText.contains("error 17") && !alert.messageText.contains("WWAlignPipeline"))
    }

    @Test(arguments: [false, true])
    func resetClearsAllTimingAndDownstreamWorkWithVerifiedUndoRedo(adaptive: Bool) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 1, durationSeconds: adaptive ? 96 : 40,
            targetStepSeconds: adaptive ? 0.02 : 0
        )
        defer { f.close() }
        #expect(!f.model.canResetAlignment)
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.analyzeTracks()
        #expect(!f.model.canResetAlignment)
        try await wait(seconds: 90) { !f.model.isWorking && f.model.tracksReviewPresented }
        if adaptive {
            let epoch = try #require(f.model.tracksReviewRows.first { $0.groupName == "Target" }?.epochID)
            try #require(f.model.tracksAdaptiveRecord(for: epoch)?.timing.regions.isEmpty == false)
            f.model.selectedTracksAdaptive = [epoch]
        } else {
            f.model.selectedTracksProposals = f.model.tracksReviewProposals
        }
        try #require(f.model.canAcceptTracksReview)
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && f.model.waveformMap != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        if !adaptive {
            f.model.setPositionLocked(false, group: target.group)
            f.model.selectWaveform(target)
            f.model.applyNumeric(ratePPM: 125, offsetMilliseconds: 350)
            try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
            try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        }
        f.model.setPositionLocked(true, group: target.group)
        let cleanup = EpisodeCleanupModel(
            state: ShowWindowState(store: f.document.store), episodeID: f.model.episodeID, runtime: f.runtime
        )
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 20)
        let input = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(
            model: input, episode: f.model.episodeID, modelRevision: "synthetic-reset",
            transcribeWindow: { _ in PCMTranscript(segments: [.init(text: "um", startSeconds: 1, endSeconds: 1.25)]) },
            progress: { _ in }
        )
        try #require(try cleanup.publishTranscripts(transcripts, expecting: input))
        var before = f.document.store.model
        let revision = try #require(before.episodes[0].alignment?.acceptedRevision)
        before.episodes[0].cleanup?.manualCuts = [
            .init(alignmentRevision: revision, startFrame: 240_000, endFrame: 288_000),
        ]
        let applied = f.document.store.applyReplacement(
            "Synthetic cut", expecting: f.document.store.model, model: before, afterChange: { _ in }
        )
        try #require(applied)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        #expect((before.episodes[0].alignment?.acceptedMap?.sourceCorrections?.isEmpty == false) == adaptive)
        f.model.listening.playback.setMuted(true, scope: .source(f.target))
        let listening = f.model.listening.playback
        try #require(f.model.canResetAlignment, "Reset must include locked groups")
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.resetAlignment(expecting: before)
        undo.endUndoGrouping()
        #expect(!f.model.canResetAlignment && !f.model.hasAcceptedRevision)
        #expect(!f.model.hasAnalysis && !f.model.tracksReviewPresented && f.model.currentAdaptiveAnalysis == nil)
        #expect(f.model.tracksReviewRows.isEmpty && f.model.tracksReviewProposals.isEmpty)
        #expect(f.model.waveformOffsetMilliseconds == 0 && f.model.waveformRatePPM == 0)
        #expect(undo.undoActionName == "Reset Alignment")
        let reset = f.document.store.model
        try await wait { f.document.verifiedModel == reset && !f.model.isLoadingWaveforms
            && f.model.waveformMap == nil && !f.model.waveformTracks.isEmpty }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.listening.playback == listening)
        #expect(await f.runtime.coordinator.inputs.acceptedMaps[f.model.episodeID] == nil)
        for track in f.model.waveformTracks {
            let strokes = f.model.retainedWaveformStrokes(for: track.id)
            #expect(!strokes.isEmpty)
            #expect(strokes.allSatisfy {
                !$0.mapped && abs($0.displaySeconds - $0.sourceSeconds) < 1e-9
                    && abs($0.groupSeconds - $0.sourceSeconds) < 1e-9
            }, "Every recorder must be at zero offset and normal speed, without old cuts or adaptive timing")
            #expect(f.model.proposedWaveformStrokes(for: track).isEmpty)
        }
        #expect(reset == (try before.resettingAlignment(in: f.model.episodeID)))
        let saved = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))
        ).payload
        #expect(saved == reset && saved.episodes[0].cleanup?.transcripts.isEmpty == true)
        undo.undo()
        try await wait { f.document.verifiedModel == before && f.document.store.model == before
            && f.model.waveformMap != nil && !f.model.isLoadingWaveforms }
        #expect(f.model.canResetAlignment && f.model.listening.playback == listening)
        undo.redo()
        try await wait { f.document.verifiedModel == reset && f.document.store.model == reset
            && f.model.waveformMap == nil && !f.model.isLoadingWaveforms }
        #expect(!f.model.canResetAlignment && f.model.listening.playback == listening)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func resetConfirmationCancelAndConcurrentEditPreserveTheShow() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        f.document.addWindowController(NSWindowController(window: window))
        defer { f.close() }
        window.orderFront(nil)
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let before = f.document.store.model
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        f.model.requestResetAlignment()
        try await wait { window.attachedSheet != nil }
        let cancelContent = try #require(window.attachedSheet?.contentView)
        let cancel = try #require(button("Cancel", in: cancelContent))
        cancel.performClick(nil)
        try await wait { window.attachedSheet == nil }
        #expect(f.document.store.model == before && f.model.canResetAlignment)
        f.model.requestResetAlignment()
        try await wait { window.attachedSheet != nil }
        #expect(f.document.store.apply("Concurrent note", { model in
            var changed = model
            changed.episodes[0].notes = "Keep this newer edit"
            return changed
        }))
        let edited = f.document.store.model
        let confirmContent = try #require(window.attachedSheet?.contentView)
        let confirm = try #require(button("Reset Alignment", in: confirmContent))
        confirm.performClick(nil)
        try await wait { f.model.lastError?.contains("show changed while confirming reset") == true }
        #expect(f.document.store.model == edited && f.model.canResetAlignment)
        f.model.analyzeTracks()
        #expect(!f.model.canResetAlignment)
        f.model.resetAlignment(expecting: edited)
        #expect(f.document.store.model == edited)
        f.model.cancelTracksAnalysis()
        try await wait { !f.model.isWorking }
    }

    @Test func resetAndRedoGateOtherWindowsAnalysisUntilVerifiedSave() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        let other = EpisodeAlignmentModel(
            document: f.document, episodeID: f.model.episodeID, runtime: f.runtime
        )
        defer { other.suspend(); f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && f.model.waveformMap != nil }
        let before = f.document.store.model
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.resetAlignment(expecting: before)
        undo.endUndoGrouping()
        let reset = f.document.store.model
        #expect(f.document.verifiedModel == before && reset != before)
        other.analyzeTracks()
        #expect(!other.isWorking && other.lastError?.contains("Save and verify") == true)
        try await wait { f.document.verifiedModel == reset && !f.model.isLoadingWaveforms
            && f.model.waveformMap == nil }
        undo.undo()
        try await wait { f.document.verifiedModel == before && !f.model.isLoadingWaveforms
            && f.model.waveformMap != nil }
        undo.redo()
        #expect(f.document.verifiedModel == before && f.document.store.model == reset)
        other.analyzeTracks()
        #expect(!other.isWorking && other.lastError?.contains("Save and verify") == true,
                "Redo and another window cannot depend on the original model's pending-reset flag")
        try await wait { f.document.verifiedModel == reset && !f.model.isLoadingWaveforms
            && f.model.waveformMap == nil }
    }

    @Test func verifiedSavedWaveformsCanRestoreTimingBeforeTheAcceptanceCallback() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        defer { f.close() }
        let before = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let episode = f.model.episodeID
        let report = try await f.runtime.analyzeTracks(model: before, episode: episode)
        let selected = Set(report.records.compactMap { $0.value.proposal == nil ? nil : $0.key })
        try #require(!selected.isEmpty)
        let accepted = try await f.runtime.acceptTracks(
            model: before, episode: episode, report: report, selected: selected, adaptive: [], estimated: []
        )
        f.document.store.replaceLoadedModel(accepted.model)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try #require(f.document.verifiedModel == accepted.model)
        let saved = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))
        ).payload
        #expect(saved == accepted.model)
        let waveforms = try await f.runtime.waveformTracks(
            model: saved, episode: episode, startSeconds: 0, durationSeconds: 1
        )
        #expect(waveforms.map == accepted.map && waveforms.mapWarning == nil)
        try await f.runtime.activate(accepted)
        #expect(try await f.runtime.pipeline.verifiedAcceptedMap(model: saved, episode: episode) == accepted.map)
        #expect(f.document.store.model == saved && f.document.verifiedModel == saved)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func legacyMonoAssignmentsOfferAndAcceptAlignmentWithoutASeparateChannelEdit() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        defer { f.close() }
        for track in f.model.waveformTracks { f.model.setChannel(nil, for: track) }
        f.model.synchronizeWaveforms()
        try await wait {
            guard !f.model.isLoadingWaveforms,
                  let target = f.model.waveformTracks.first(where: { $0.id == f.target }) else { return false }
            return !f.model.matchOptions(for: target).isEmpty
        }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        let option = try #require(f.model.matchOptions(for: target).first)
        #expect(option.referenceChannel == 0 && option.targetChannel == 0)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let before = f.document.store.model
        #expect(before.episodes[0].speakerAssignments.allSatisfy {
            $0.primary?.channel == .unknown && $0.backups.allSatisfy { $0.channel == .unknown }
        })
        f.model.selectWaveform(target)
        f.model.analyze()
        try await wait { !f.model.isWorking }
        try #require(f.model.canAcceptProposal, "\(f.model.lastError ?? f.model.message)")
        #expect(f.document.store.model == before)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented && !f.model.tracksReviewProposals.isEmpty)
        f.model.selectedTracksProposals = f.model.tracksReviewProposals
        try #require(f.model.canAcceptTracksReview)
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.document.store.model.episodes[0].alignment?.acceptedRevision != nil)
        #expect(f.document.store.model.episodes[0].speakerAssignments == before.episodes[0].speakerAssignments)
    }

    @Test func tracksReviewHasFlexibleNativeResizeLimitsAndGrowingContent() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        let state = ShowWindowState(store: f.document.store)
        let host = NSHostingController(rootView: AudioWorkspaceActions(state: state, alignment: f.model))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer {
            f.model.discardTracksReview()
            window.close()
            f.close()
        }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.center()
        window.orderFront(nil)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking && window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await wait { sheet.isVisible }
        let limits = "style \(sheet.styleMask.rawValue), minimum \(sheet.contentMinSize), maximum \(sheet.contentMaxSize)"
        #expect(sheet.styleMask.contains(.resizable), "\(limits)")
        #expect(sheet.contentMinSize.width <= 600 && sheet.contentMinSize.height <= 420, "\(limits)")
        #expect(sheet.contentMaxSize.width > sheet.contentMinSize.width + 160
            && sheet.contentMaxSize.height > sheet.contentMinSize.height + 100, "\(limits)")
        sheet.setContentSize(NSSize(width: 640, height: 480))
        sheet.contentView?.layoutSubtreeIfNeeded()
        let original = try #require(sheet.contentView?.bounds.size)
        #expect(abs(original.width - 640) <= 1 && abs(original.height - 480) <= 1,
                "Compact content \(original), \(limits)")
        let expanded = NSSize(width: original.width + 160, height: original.height + 100)
        sheet.setContentSize(expanded)
        sheet.contentView?.layoutSubtreeIfNeeded()
        let actual = try #require(sheet.contentView?.bounds.size)
        #expect(actual.width >= expanded.width - 1 && actual.height >= expanded.height - 1,
                "Original \(original), requested \(expanded), actual \(actual), \(limits); frame \(sheet.frame), screen \(String(describing: sheet.screen?.visibleFrame))")
    }

    @Test func changingCallDelayAutomaticallyReviewsAndSavesAdaptiveTimingWithUndoRedo() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 1, durationSeconds: 96, targetStepSeconds: 0.02
        )
        defer { f.close() }
        let before = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(target)
        f.model.selectedMatchOption = nil
        f.model.analyze()
        try await wait(seconds: 90) { !f.model.isWorking }
        let individual = try #require(f.model.currentAdaptiveAnalysis, "\(f.model.lastError ?? f.model.message)")
        #expect(!individual.timing.regions.isEmpty && individual.target.source == f.target)
        #expect(individual.audioPreservationError == nil)
        #expect(!f.model.proposedWaveformStrokes(for: target).isEmpty)
        #expect(f.document.store.model == before)
        f.model.analyzeTracks()
        try await wait(seconds: 90) { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented, "\(f.model.lastError ?? f.model.message)")
        let adaptive = try #require(f.model.tracksAdaptiveRecord(for: target.epoch))
        #expect(!adaptive.timing.regions.isEmpty)
        #expect(f.model.tracksReviewRows.contains {
            $0.epochID == target.epoch && $0.state.heading == "Adaptive file timing proposed"
        })
        #expect(f.model.selectedTracksAdaptive.isEmpty)
        #expect(!f.model.canAcceptTracksReview)
        #expect(f.document.store.model == before && !f.model.isAuditioning)
        f.model.selectedTracksAdaptive = [target.epoch]
        try #require(f.model.canAcceptTracksReview)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        undo.endUndoGrouping()
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let accepted = f.document.store.model
        let correction = try #require(accepted.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(correction.source == f.target && correction.retainsAllAudio)
        #expect(f.model.selectedTracksAdaptive.isEmpty)
        let saved = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))
        ).payload
        #expect(saved == accepted)
        try #require(undo.canUndo)
        undo.undo()
        try await wait { f.document.verifiedModel == before && f.document.store.model == before }
        try #require(undo.canRedo)
        undo.redo()
        try await wait { f.document.verifiedModel == accepted && f.document.store.model == accepted }
        f.model.load()
        f.model.loadWaveforms()
        try await wait {
            !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave && f.model.waveformMap != nil
        }
        let timedTarget = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(timedTarget)
        let map = try #require(f.model.waveformMap)
        #expect(!AlignmentWaveformProjection.hasAcceptedTiming(
            source: f.target, epoch: timedTarget.epoch, group: timedTarget.group, map: map))
        #expect(f.model.sourceHasAcceptedTiming(f.target))
        #expect(f.model.canCompareAligned)
        #expect(f.model.selectedRecordingTimingState?.heading == "Adaptive file timing accepted · pitch preserved")
        let cleanup = EpisodeCleanupModel(
            state: ShowWindowState(store: f.document.store), episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 2, outValue: 20)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let priorRangeRevision = try #require(f.document.store.model.episodes[0].cleanup?.workingRange?.alignmentRevision)
        f.model.saveAdaptiveCorrection(restoringAudio: f.target)
        try await wait {
            !f.model.isWorking && f.document.verifiedModel == f.document.store.model
                && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
        }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let currentRevision = try #require(f.document.store.model.episodes[0].alignment?.acceptedRevision)
        #expect(currentRevision != priorRangeRevision)
        #expect(f.document.store.model.episodes[0].cleanup?.workingRange == EpisodeWorkingRange(
            alignmentRevision: currentRevision, tracksIn: 2, tracksOut: 20))
        await cleanup.refresh()
        #expect(cleanup.plan?.isReady == true, "\(cleanup.transcriptionReadinessMessage)")

        var stale = try #require(f.document.store.model.episodes[0].cleanup)
        stale.workingRange?.alignmentRevision = priorRangeRevision
        try #require(f.document.store.apply("Synthetic older boundaries", { model throws(DomainError) in
            try model.settingCleanup(stale, in: f.model.episodeID)
        }))
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        await cleanup.refresh()
        #expect(cleanup.hasStaleWorkingRange && cleanup.plan?.isReady == false)
        let staleRange = try #require(stale.workingRange)
        cleanup.resolveStaleWorkingRange(keeping: true,
            expectedRange: staleRange, expectedRevision: currentRevision)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        await cleanup.refresh()
        #expect(!cleanup.hasStaleWorkingRange && cleanup.plan?.isReady == true,
                "\(cleanup.transcriptionReadinessMessage)")
        let current = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(
            model: current, episode: f.model.episodeID, modelRevision: "synthetic-buffer-regression",
            transcribeWindow: { _ in
                PCMTranscript(segments: [.init(text: "synthetic", startSeconds: 1, endSeconds: 1.25)])
            }, progress: { _ in })
        #expect(transcripts.count == 1 && transcripts.first?.alignmentRevision == currentRevision)
        f.model.load()
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        f.model.setMuted(false, scope: .source(f.target))
        f.model.setSoloed(true, scope: .source(f.target))
        try #require(f.model.enabledSources == [f.target])
        let clips = try await f.runtime.sourceAuditions(model: current, episode: f.model.episodeID,
            sources: [f.target], outputFrames: 48_000..<96_000)
        #expect(clips[f.target]?.samples.contains { abs($0) > 0.001 } == true)
        f.model.playEnabledTracks(interval: 1...31, repeatInterval: false)
        try await wait { f.model.isAuditioning || f.model.lastError != nil }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? f.model.auditionLabel)")
        #expect(f.model.isAuditioning && f.model.playbackClockForTesting != nil, "\(f.model.auditionLabel)")
        try await wait(seconds: 45) {
            f.model.waveformPlayheadSeconds >= 30 || f.model.lastError != nil
        }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? f.model.auditionLabel)")
        #expect(f.model.isAuditioning && f.model.waveformPlayheadSeconds >= 30,
                "Adaptive audio must keep playing across six cold canonical tile boundaries.")
        f.model.stopAudition()
        #expect(f.document.store.model == current)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func referenceActionsShareSavedSelectionAndOnlyAcceptedReplacementChangesCurrentTiming() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(
            state: ShowWindowState(store: f.document.store), episodeID: f.model.episodeID, runtime: f.runtime
        )
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 1, outValue: 20)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let original = f.document.store.model
        let episode = try #require(original.episode(f.model.episodeID))
        try #require(episode.cleanup?.workingRange != nil)
        let originalMap = try original.timeMap(revision: #require(episode.alignment?.acceptedRevision), in: episode.id)
        let targetGroup = try #require(episode.source(f.target)?.placement.recorderGroupID)
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let setup = EpisodeSetupModel(
            store: f.document.store, episodeID: episode.id, engine: InMemorySourceSetupEngine(),
            preference: AppSettingsDownloadPreference.shared
        )
        defer { setup.stopObserving() }
        @MainActor func saveSelection() async throws {
            try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
            try #require(f.document.verifiedModel == f.document.store.model)
        }
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.useAsTimingReference(targetGroup)
        undo.endUndoGrouping()
        try await saveSelection()
        let selected = f.document.store.model
        #expect(f.model.lastError == nil)
        #expect(f.model.timingReferenceSelection.currentGroup == originalMap.reference.group)
        #expect(f.model.timingReferenceSelection.nextGroup == targetGroup)
        #expect(f.model.referenceGroup == originalMap.reference.group)
        #expect(setup.timingReferenceSelection.currentGroup == originalMap.reference.group)
        #expect(setup.timingReferenceSelection.nextGroup == targetGroup)
        #expect(selected.episodes[0].alignment == episode.alignment && selected.episodes[0].cleanup == episode.cleanup)
        #expect(undo.undoActionName == "Set Timing Reference")
        undo.undo()
        try await saveSelection()
        #expect(f.document.store.model == original)
        undo.redo()
        try await saveSelection()
        #expect(f.document.store.model == selected)
        undo.beginUndoGrouping()
        setup.useAsTimingReference(originalMap.reference.group)
        undo.endUndoGrouping()
        try await saveSelection()
        #expect(f.model.timingReferenceSelection.nextGroup == originalMap.reference.group)
        #expect(f.document.store.model.episodes[0].alignment == episode.alignment)
        undo.undo()
        try await saveSelection()
        #expect(f.document.store.model == selected, "The dialog action restores the editor's selection with one Undo")
        let saved = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))
        ).payload
        #expect(saved.episodes[0].preferredAlignmentReferenceGroupID == targetGroup)
        #expect(saved.episodes[0].alignment == episode.alignment)
        f.model.analyzeTracks()
        try await wait { !f.model.isWorking }
        try #require(f.model.tracksReviewPresented, "\(f.model.lastError ?? "")")
        #expect(f.model.tracksReviewReferenceName == "Target")
        #expect(f.model.tracksReviewRows.contains {
            $0.groupID == originalMap.reference.group
                && $0.state.details?.contains("newly selected reference's original recording clock") == true
        })
        #expect(f.document.store.model == selected)
        #expect(f.model.referenceGroup == originalMap.reference.group)
        f.model.selectedTracksProposals = f.model.tracksReviewProposals
        try #require(!f.model.selectedTracksProposals.isEmpty)
        undo.beginUndoGrouping()
        f.model.acceptTracksReview()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        undo.endUndoGrouping()
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let accepted = f.document.store.model
        let newEpisode = try #require(accepted.episode(episode.id))
        let map = try accepted.timeMap(revision: #require(newEpisode.alignment?.acceptedRevision), in: episode.id)
        #expect(map.reference.group == targetGroup)
        #expect(newEpisode.alignment?.maps.dropLast() == episode.alignment?.maps[...])
        #expect(newEpisode.cleanup?.workingRange == nil)
        #expect(setup.timingReferenceSelection.currentGroup == targetGroup)
        undo.undo()
        try await wait { f.document.verifiedModel == f.document.store.model }
        #expect(f.document.store.model == selected, "One Undo restores the old reference, timing, and IN/OUT")
        #expect(setup.timingReferenceSelection.currentGroup == originalMap.reference.group)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
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
