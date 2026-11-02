import AppKit
import Foundation
import Testing
import WWCommonEdit
import WWCore
import WWDecode
import WWEpisodeSetup
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor @Suite("Inserted-time editor workflows (synthetic only)", .serialized)
struct AudioInsertionHostedTests {
    private let helper = MixerHostedTests()

    private func importBed(_ f: AlignmentWaveformRetentionHostedTests.Fixture, seconds: Int = 40)
        async throws -> (clip: ProgramAudioClip, owner: EpisodeWindowController, engine: WWSourcesSetupEngine, file: URL) {
        let owner = helper.owner(f), editor = f.model.audioEditor
        let file = f.folder.appendingPathComponent("synthetic-bed.wav")
        try AudioClipEditorHostedTests.wave(rate: 48_000, frames: 48_000 * seconds).write(to: file)
        let context = SourceAccessContext(io: SystemSourceIO())
        let engine = WWSourcesSetupEngine(showID: f.document.store.model.show.id,
            store: FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")), context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        editor.importer.sourceEngineForTesting = engine
        editor.importer.scan([file], in: owner.state, programSeconds: 0)
        try await helper.wait { editor.importer.review != nil || editor.importer.error != nil }
        editor.importer.commit(try #require(editor.importer.review))
        try await helper.wait { editor.importer.processing == nil }
        try #require(editor.importer.error == nil, Comment(rawValue: editor.importer.error ?? ""))
        f.model.load()
        try await helper.wait { editor.composition != nil && f.model.trackProcessingOperation == nil }
        let clip = try #require(editor.composition?.clips.first)
        editor.select(clip.clip.id)
        return (clip, owner, engine, file)
    }

    private func undoManager(_ f: AlignmentWaveformRetentionHostedTests.Fixture) throws -> UndoManager {
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        return undo
    }

    @Test func introPreviewRetargetUndoReopenAndProductionKeepAllSpeakersAndSourceBytes() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2, durationSeconds: 4)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await helper.wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        let undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor
        let cleanup = EpisodeCleanupModel(state: bed.owner.state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        bed.owner.state.cleanupModel = cleanup
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let originals = try (f.files + [bed.file]).map { try Data(contentsOf: $0) }
        let before = f.document.store.model
        let episode = try #require(editor.episode)
        let bins = editor.waveforms.mapValues(\.id)
        let choices = f.model.listening.playback
        f.model.waveformPlayheadSeconds = 1
        f.model.listening.selection = 0.5...1
        f.model.listening.cycleRange = 0.5...1
        f.model.listening.cycleEnabled = true
        bed.owner.state.reviewPanelPresented = true
        bed.owner.state.reviewPresentation.detach()
        let reviewWindow = try #require(bed.owner.state.reviewPresentation.detachedWindow?.window)
        #expect(reviewWindow.undoManager === undo)
        #expect(bed.owner.state.cleanupModel === cleanup && bed.owner.state.alignmentModel === f.model)
        editor.requestInsertion(intro: true, programSeconds: nil)
        let session = try #require(editor.insertionSession)
        #expect(session.position == 0 && f.document.store.model == before)
        #expect(!f.model.canStopAudition && f.model.listening.playback == choices)
        let gapOnly = try editor.insertionPreview(session, position: "0", length: "10",
            usingEnd: false, retarget: false, removing: false)
        #expect(gapOnly.after.clips[0].programFrames == 480_000..<2_400_000)
        let preview = try editor.insertionPreview(session, position: "0", length: "10",
            usingEnd: false, retarget: true, removing: false)
        #expect(preview.after.clips[0].programFrames == 0..<1_920_000)
        #expect(f.document.store.model == before && f.model.waveformPlayheadSeconds == 1)
        try #require(editor.commitInsertion(session, position: "0", length: "10",
            usingEnd: false, retarget: true, removing: false), Comment(rawValue: editor.error ?? ""))
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        let after = f.document.store.model
        let current = try #require(editor.episode)
        #expect(current.alignment == episode.alignment && current.cleanup == episode.cleanup)
        #expect(current.sources == episode.sources && current.recorderGroups == episode.recorderGroups)
        #expect(current.speakerAssignments == episode.speakerAssignments)
        #expect(editor.waveforms.mapValues(\.id) == bins, "Insertion reuses measured source bins, never re-decodes them.")
        #expect(f.model.waveformPlayheadSeconds == 11)
        #expect(f.model.listening.selection == nil && f.model.listening.cycleRange == nil && !f.model.listening.cycleEnabled)
        #expect((f.model.waveformFitRange?.upperBound ?? 0) >= 40)
        #expect(f.model.presentationTimeline.editedTime(forAlignedTime: 0) == 10)
        #expect(f.model.presentationTimeline.editedTime(forAlignedTime: 4) == 14)
        let word = TranscriptWord(text: "Synthetic", sourceStartFrame: 48_000, sourceEndFrame: 57_600,
            alignedStart: 1, alignedEnd: 1.2)
        let words = AudioTimelineWordIndex(words: [word], projection: f.model.presentationTimeline)
        #expect(words.words[0].alignedStart == 11 && word.sourceStartFrame == 48_000)
        #expect(undo.undoActionName == "Insert Intro")
        undo.undo()
        f.model.load()
        #expect(f.document.store.model == before)
        undo.redo()
        f.model.load()
        #expect(f.document.store.model == after)
        try await helper.wait { f.model.trackProcessingOperation == nil }
        try await helper.save(f.document)
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))).payload
        #expect(reopened == after)
        #expect(try await f.runtime.programComposition(model: reopened, episode: episode.id) == editor.composition)
        let savedURL = try #require(f.document.fileURL)
        let reopenedDocument = try #require(try NSDocumentController.shared.makeDocument(
            withContentsOf: savedURL, ofType: DocumentTypes.show) as? ShowDocument)
        #expect(reopenedDocument.store.model == after)
        reopenedDocument.close()
        let recipe = try await f.runtime.mixerRecipe(model: after, episode: episode.id, programFrames: 0..<1_920_000)
        let intro = try await f.runtime.productionPCM(recipe: recipe, model: after, frames: 0..<512)
        #expect(intro.channels.count == 2 && intro.channels.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(intro.audioTracks[bed.clip.clip.track]?.contains { $0.contains { $0 != 0 } } == true)
        let dialogue = try await f.runtime.productionPCM(recipe: recipe, model: after, frames: 480_000..<480_512)
        for route in recipe.routes {
            let source = route.reference.sourceID
            let original = try await f.runtime.sourceAuditions(model: before, episode: episode.id,
                sources: [source], outputFrames: 0..<512, applyingCuts: false,
                decodedChannels: [source: 0], applyingInputGain: false)
            #expect(dialogue.channels[route.reference] == original[source]?.samples)
        }
        f.model.listening.cycleEnabled = false
        f.model.playProductionMix(interval: 0...0.5)
        try await helper.wait { f.model.isAuditioning || !f.model.isPreparingAudition }
        try #require(f.model.isAuditioning, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        #expect(f.model.listening.usesProductionMix)
        f.model.stopEnabledTracks()
        bed.owner.state.reviewPresentation.reattach()
        #expect(!bed.owner.state.reviewPresentation.isDetached)
        #expect(try (f.files + [bed.file]).map { try Data(contentsOf: $0) } == originals)
    }

    @Test func midrollShortenRemoveClampPlayheadAndKeepReviewOnlyCutsOutOfInsertion() async throws {
        let f = try await helper.ready(durationSeconds: 4)
        defer { f.close() }
        let undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        let bed = try await importBed(f, seconds: 1)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor
        let initial = try #require(editor.episode)
        let accepted = try #require(initial.alignment?.acceptedMap)
        let cut = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 96_000, endFrame: 144_000)
        try #require(f.document.store.apply("Synthetic cut") { model throws(DomainError) in
            var next = model
            let index = next.episodes.firstIndex { $0.id == initial.id }!
            var cleanup = next.episodes[index].cleanup ?? EpisodeCleanup()
            cleanup.manualCuts = [cut]
            next.episodes[index].cleanup = cleanup
            return next
        })
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        f.model.listening.expandedManualCutID = cut.id
        f.model.synchronizeCuts()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        #expect(f.model.presentationTimeline.programTime(forDisplayTime: 2.5) == nil)
        editor.requestInsertion(intro: false, programSeconds: nil)
        #expect(editor.insertionSession == nil && editor.error?.contains("review-only") == true)
        f.model.listening.expandedManualCutID = nil
        f.model.synchronizeCuts()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        editor.pinSelected(true)
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        f.model.setMuted(true, scope: .source(f.target))
        f.model.listening.workspace.layout = .speakersOnly
        let listening = f.model.listening.playback
        editor.requestInsertion(intro: false, programSeconds: 1)
        let session = try #require(editor.insertionSession)
        try #require(editor.commitInsertion(session, position: "1", length: "4", usingEnd: true,
            retarget: true, removing: false))
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        let region = try #require(editor.composition?.timeline.insertions.first)
        #expect(region.programFrames == 48_000..<192_000)
        #expect(editor.selected?.clip.anchor == .absolute(frame: 48_000),
            "An explicitly retargeted selected pin moves to the shown start and retains its pin.")
        #expect(f.model.listening.playback == listening && !f.model.trackEnabled(f.target))
        let sources = initial.alignmentSources.map(\.id)
        let snapshot = f.document.store.model
        let originalDialogue = try await f.runtime.sourceAuditions(model: snapshot, episode: initial.id,
            sources: sources, outputFrames: 48_000..<48_512, applyingCuts: false)
        let shiftedDialogue = try await f.runtime.sourceAuditions(model: snapshot, episode: initial.id,
            sources: sources, outputFrames: 192_000..<192_512, presentation: f.model.presentationTimeline)
        let gap = try await f.runtime.sourceAuditions(model: snapshot, episode: initial.id,
            sources: sources, outputFrames: 48_000..<48_512, presentation: f.model.presentationTimeline)
        for source in sources {
            #expect(shiftedDialogue[source]?.samples == originalDialogue[source]?.samples,
                "Primary and muted/hidden Backup retain the same source samples after the common insertion.")
            #expect(gap[source]?.samples.allSatisfy { $0 == 0 } == true)
        }
        let originalClip = try #require(editor.selected?.clip)
        var late = originalClip
        late.id = AudioClipID()
        late.anchor = .insertion(region: region.region.id, offsetFrames: 120_000)
        try #require(f.document.store.apply("Synthetic late regional start") { model throws(DomainError) in
            try model.addingAudioClip(late, in: initial.id)
        })
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        f.model.waveformPlayheadSeconds = 3.5
        editor.requestInsertionEdit(region.region.id)
        let resize = try #require(editor.insertionSession)
        let preview = try editor.insertionPreview(resize, position: "1", length: "1", usingEnd: false,
            retarget: false, removing: false)
        #expect(preview.clampedClips == [late.id])
        try #require(editor.commitInsertion(resize, position: "1", length: "1", usingEnd: false,
            retarget: false, removing: false))
        f.model.load()
        try await helper.wait { f.model.trackProcessingOperation == nil }
        #expect(f.model.waveformPlayheadSeconds == 2)
        #expect(editor.composition?.clips.last?.programFrames.lowerBound == 96_000)
        #expect(editor.composition?.clips.last?.clip.trim == late.trim)
        f.model.waveformPlayheadSeconds = 1.5
        editor.requestInsertionEdit(region.region.id)
        let removal = try #require(editor.insertionSession)
        let beforeRemoval = f.document.store.model
        try #require(editor.commitInsertion(removal, position: "unused", length: "unused", usingEnd: false,
            retarget: false, removing: true))
        f.model.load()
        #expect(f.model.waveformPlayheadSeconds == 1)
        #expect(editor.composition?.timeline.insertions.isEmpty == true)
        #expect(editor.selected?.clip.trim == originalClip.trim)
        #expect(f.document.store.model.episode(initial.id)?.alignment == initial.alignment)
        #expect(f.document.store.model.episode(initial.id)?.cleanup?.manualCuts == [cut])
        #expect(undo.undoActionName == "Remove Inserted Time")
        undo.undo()
        f.model.load()
        #expect(f.document.store.model == beforeRemoval)
        undo.redo()
        f.model.load()
        #expect(editor.composition?.timeline.insertions.isEmpty == true)
    }

    @Test func staleGenerationEqualByteRestoreAndInvalidFieldsRefuseWithoutAnUndoAction() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        let owner = helper.owner(f), editor = f.model.audioEditor
        _ = owner
        try await helper.wait {
            f.document.store.canEdit && editor.canPlaceDroppedAudio
                && TrackProcessingOperation.current(alignment: f.model, cleanup: owner.state.cleanupModel) == nil
        }
        for length in ["", "nan", "inf", "0", "-1", "86401", "1e300"] {
            editor.requestInsertion(intro: true, programSeconds: nil)
            let pending = editor.insertionSession, refusal = editor.error
            let session = try #require(pending, Comment(rawValue: refusal ?? "Insertion preview was not presented."))
            let before = f.document.store.model, action = undo.undoActionName
            #expect(!editor.commitInsertion(session, position: "0", length: length,
                usingEnd: false, retarget: false, removing: false))
            #expect(editor.error != nil && f.document.store.model == before && undo.undoActionName == action)
            editor.dismissInsertion()
        }
        for replaceLoaded in [false, true] {
            f.model.load()
            try await helper.wait {
                f.document.store.canEdit && editor.canPlaceDroppedAudio
                    && TrackProcessingOperation.current(alignment: f.model, cleanup: owner.state.cleanupModel) == nil
            }
            editor.requestInsertion(intro: true, programSeconds: nil)
            let pending = editor.insertionSession, refusal = editor.error
            let session = try #require(pending, Comment(rawValue: refusal ?? "Insertion preview was not presented."))
            let before = f.document.store.model
            if replaceLoaded { f.document.store.replaceLoadedModel(before) }
            else {
                try #require(f.document.store.apply("Temporary track") { model throws(DomainError) in
                    try model.addingAudioTrack(.init(name: "Temporary"), in: f.model.episodeID)
                })
                undo.undo()
            }
            editor.refresh()
            #expect(f.document.store.model == before)
            #expect(!editor.commitInsertion(session, position: "0", length: "1",
                usingEnd: false, retarget: false, removing: false))
            #expect(editor.error?.contains("changed") == true && f.document.store.model == before)
            editor.dismissInsertion()
        }
    }

    @Test func uncapturedNativeStateRefusesInsertionInsteadOfBypassingTheDocumentBarrier() async throws {
        let f = try await helper.ready()
        var canCloseFixture = true
        defer { if canCloseFixture { f.close() } }
        let owner = helper.owner(f)
        _ = owner
        let slot = try helper.appleSlot()
        try helper.insert(slot, into: f)
        f.model.audioEditor.refresh()
        _ = try await f.model.mixer.prepare(programFrames: 0..<2048)
        var bodyFailure: (any Error)?
        do {
            try await f.model.mixer.beginEditorObservation(coalescing: "f7.native")
            await f.model.mixer.suspendEditorObservation()
            let processor = try #require(f.model.mixer.processor)
            let parameter = try #require(try await processor.parameters(slot: slot.id).first {
                $0.writable && $0.minimum < $0.maximum
            })
            try await processor.setParameter(slot: slot.id, address: parameter.address,
                value: parameter.value == parameter.minimum ? parameter.maximum : parameter.minimum)
            let editor = f.model.audioEditor
            editor.refresh()
            editor.requestInsertion(intro: true, programSeconds: nil)
            let session = try #require(editor.insertionSession)
            let before = f.document.store.model
            #expect(!editor.commitInsertion(session, position: "0", length: "1",
                usingEnd: false, retarget: false, removing: false))
            #expect(f.document.store.model == before && f.model.mixer.processor != nil)
            #expect(editor.error?.contains("Audio Unit") == true)
        } catch { bodyFailure = error }
        do {
            try await f.model.mixer.endEditorObservation()
        } catch {
            canCloseFixture = false
            Issue.record("Native-observation teardown failed; fixture preserved at \(f.folder.path): \(error)")
            if let bodyFailure { Issue.record("Native-refusal body also failed: \(bodyFailure)") }
            throw error
        }
        if let bodyFailure { throw bodyFailure }
    }
}
