import AppKit
import Foundation
import SwiftUI
import Testing
import WWCommonEdit
import WWCore
import WWDecode
import WWEpisodeSetup
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor @Suite("Clip fade document workflows (synthetic only)", .serialized)
struct AudioFadeHostedTests {
    private let helper = MixerHostedTests()

    private struct Bed {
        let owner: EpisodeWindowController
        let engine: WWSourcesSetupEngine
        let file: URL
        let clip: ProgramAudioClip
    }

    private func importBed(_ f: AlignmentWaveformRetentionHostedTests.Fixture, extra: Bool = false) async throws -> Bed {
        let owner = helper.owner(f), editor = f.model.audioEditor
        let file = f.folder.appendingPathComponent("synthetic-f8-stereo.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 88_200).write(to: file)
        let context = SourceAccessContext(io: SystemSourceIO())
        let engine = WWSourcesSetupEngine(showID: f.document.store.residentModel.show.id,
            store: FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")), context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        editor.importer.sourceEngineForTesting = engine
        var files = [file]
        if extra {
            let second = f.folder.appendingPathComponent("synthetic-f8-extra.wav")
            try AudioClipEditorHostedTests.wave(rate: 48_000, frames: 48_000).write(to: second)
            files.append(second)
        }
        editor.importer.scan(files, in: owner.state, programSeconds: 2)
        try await helper.wait { editor.importer.review != nil || editor.importer.error != nil }
        editor.importer.commit(try #require(editor.importer.review))
        try await helper.wait { editor.importer.processing == nil }
        try #require(editor.importer.error == nil, Comment(rawValue: editor.importer.error ?? ""))
        f.model.load()
        try await helper.wait { editor.composition != nil && f.model.trackProcessingOperation == nil }
        let clip = try #require(editor.composition?.clips.first)
        editor.select(clip.clip.id)
        return .init(owner: owner, engine: engine, file: file, clip: clip)
    }

    private func undoManager(_ f: AlignmentWaveformRetentionHostedTests.Fixture) throws -> UndoManager {
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        return undo
    }

    private func requireFadeSession(_ editor: AudioClipEditorModel) throws -> AudioFadeSession {
        let session = editor.fadeSession
        let refusal = editor.error
        return try #require(session, Comment(rawValue: refusal ?? "The fade preview did not open."))
    }

    private func fade(_ editor: AudioClipEditorModel, start: Double, duration: String, level: String,
                      direction: AudioFadeDirection = .fadeOut) async throws {
        await editor.requestFade(direction, programSeconds: start)
        let session = try requireFadeSession(editor)
        var draft = AudioFadeDraft(session: session)
        draft.length = duration
        draft.level = level
        draft.silence = level == "0"
        draft.replacing = true
        let applied = editor.commitFade(session, draft: draft)
        let refusal = editor.error
        try #require(applied, Comment(rawValue: refusal ?? "The fade was not applied."))
    }

    @Test func editableEndpointsDefaultToCurrentLevelAndReachProductionWithUndoAndSave() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        let original = f.document.store.residentModel, bytes = try Data(contentsOf: bed.file)
        try await helper.wait {
            editor.canPlaceDroppedAudio && editor.selected != nil && editor.store.canEdit
                && TrackProcessingOperation.current(alignment: f.model, cleanup: bed.owner.state.cleanupModel) == nil
        }
        await editor.requestFade(.fadeIn, programSeconds: 2)
        let incoming = try requireFadeSession(editor)
        var draft = AudioFadeDraft(session: incoming)
        #expect(draft.startSilence && draft.startLevel == "0" && !draft.silence && Double(draft.level) == 1)
        draft.length = "0.5"
        let defaultPreview = try editor.fadePreview(incoming, draft: draft)
        #expect(defaultPreview.envelope.points.map(\.amplitude) == [0, 1])
        #expect(f.document.store.residentModel == original)
        try #require(editor.commitFade(incoming, draft: draft))
        undo.undo()
        editor.refresh()
        try await helper.wait {
            editor.canPlaceDroppedAudio && editor.selected != nil && editor.store.canEdit
                && TrackProcessingOperation.current(alignment: f.model, cleanup: bed.owner.state.cleanupModel) == nil
        }
        let undoneDefault = f.document.store.residentModel
        #expect(undoneDefault == original)

        await editor.requestFade(.fadeIn, programSeconds: 2)
        let custom = try requireFadeSession(editor)
        draft = AudioFadeDraft(session: custom)
        draft.length = "0.5"
        draft.startSilence = false
        draft.startLevel = "0.1"
        draft.level = "0.8"
        try #require(editor.commitFade(custom, draft: draft))
        try await helper.wait {
            editor.canPlaceDroppedAudio && editor.selected != nil && editor.store.canEdit
                && TrackProcessingOperation.current(alignment: f.model, cleanup: bed.owner.state.cleanupModel) == nil
        }
        await editor.requestFade(.fadeOut, programSeconds: 3)
        let outgoing = try requireFadeSession(editor)
        draft = AudioFadeDraft(session: outgoing)
        #expect(!draft.startSilence && Double(draft.startLevel) == 0.8 && draft.silence)
        draft.length = "0.5"
        draft.startLevel = "0.7"
        draft.level = "0.2"
        draft.silence = false
        let beforeOut = f.document.store.residentModel
        try #require(editor.commitFade(outgoing, draft: draft))
        let after = f.document.store.residentModel
        undo.undo()
        let undone = f.document.store.residentModel
        #expect(undone == beforeOut)
        undo.redo()
        editor.refresh()
        let redone = f.document.store.residentModel
        #expect(redone == after)
        let selected = try #require(editor.selected)
        let evaluator = try AudioEnvelopeEvaluator(envelope: selected.clip.envelope, durationFrames: 96_000)
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 0.1)
        #expect(try evaluator.amplitude(atLocalFrame: 47_999) == 0.8)
        #expect(try evaluator.amplitude(atLocalFrame: 48_000) == 0.7)
        #expect(try evaluator.amplitude(atLocalFrame: 72_000) == 0.2)
        let range: Range<Int64> = 96_000..<192_000, episode = f.model.episodeID
        let rawRecipe = try await f.runtime.mixerRecipe(model: original, episode: episode, programFrames: range)
        let raw = try #require(try await f.runtime.productionPCM(recipe: rawRecipe, model: original, frames: range)
            .audioTracks[selected.clip.track])
        let recipe = try await f.runtime.mixerRecipe(model: after, episode: episode, programFrames: range)
        let pcm = try #require(try await f.runtime.productionPCM(recipe: recipe, model: after, frames: range)
            .audioTracks[selected.clip.track])
        for index in 0..<range.count {
            let level = Float(try evaluator.amplitude(atLocalFrame: Int64(index)))
            for channel in 0..<2 { #expect(pcm[channel][index] == raw[channel][index] * level) }
        }
        try await helper.save(f.document)
        let url = try #require(f.document.fileURL)
        let savedMatches = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(LocalFileOperations().read(url)).payload == after
        #expect(savedMatches)
        #expect(try Data(contentsOf: bed.file) == bytes)
    }

    @Test func sequencesUndoSaveReopenAndProductionShareTheExactCurrentLocalCurve() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        let editor = f.model.audioEditor, before = f.document.store.residentModel
        let episode = try #require(editor.episode)
        let bytes = try (f.files + [bed.file]).map { try Data(contentsOf: $0) }
        let bins = editor.waveforms.mapValues(\.id), overview = f.model.waveformOverviewSnapshotID
        try await fade(editor, start: 2.25, duration: "0.5", level: "0.25")
        let low = f.document.store.residentModel
        try await fade(editor, start: 3, duration: "0.5", level: "0")
        let after = f.document.store.residentModel
        #expect(undo.undoActionName == "Fade Out")
        undo.undo()
        f.model.load()
        #expect(f.document.store.residentModel == low)
        undo.redo()
        f.model.load()
        #expect(f.document.store.residentModel == after)
        #expect(editor.episode?.alignment == episode.alignment && editor.episode?.cleanup == episode.cleanup)
        #expect(editor.episode?.sources == episode.sources && editor.episode?.recorderGroups == episode.recorderGroups)
        #expect(editor.waveforms.mapValues(\.id) == bins && f.model.waveformOverviewSnapshotID == overview)
        let clip = try #require(editor.selected)
        let evaluator = try AudioEnvelopeEvaluator(envelope: clip.clip.envelope, durationFrames: 96_000)
        #expect(try evaluator.amplitude(atLocalFrame: 24_000) == 0.625)
        #expect(try evaluator.amplitude(atLocalFrame: 42_000) == 0.25)
        #expect(try evaluator.amplitude(atLocalFrame: 84_000) == 0)
        let range: Range<Int64> = 118_000..<120_048
        let rawRecipe = try await f.runtime.mixerRecipe(model: before, episode: episode.id, programFrames: range)
        let raw = try #require(try await f.runtime.productionPCM(recipe: rawRecipe, model: before, frames: range)
            .audioTracks[clip.clip.track])
        let recipe = try await f.runtime.mixerRecipe(model: after, episode: episode.id, programFrames: range)
        let actual = try #require(try await f.runtime.productionPCM(recipe: recipe, model: after, frames: range)
            .audioTracks[clip.clip.track])
        for index in 0..<Int(range.count) {
            let gain = Float(try evaluator.amplitude(atLocalFrame: range.lowerBound + Int64(index) - 96_000))
            for channel in 0..<2 { #expect(actual[channel][index] == raw[channel][index] * gain) }
        }
        let seek: Range<Int64> = 118_017..<118_531
        let chunk = try #require(try await f.runtime.productionPCM(recipe: recipe, model: after, frames: seek)
            .audioTracks[clip.clip.track])
        #expect(chunk == actual.map { Array($0[17..<531]) })
        try await helper.save(f.document)
        let url = try #require(f.document.fileURL)
        let savedMatches = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(LocalFileOperations().read(url)).payload == after
        #expect(savedMatches)
        let reopened = try #require(try NSDocumentController.shared.makeDocument(
            withContentsOf: url, ofType: DocumentTypes.show) as? ShowDocument)
        #expect(reopened.store.residentModel == after)
        reopened.close()
        #expect(try (f.files + [bed.file]).map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func graphicalAutomationLocksAxesPreviewsWithoutSavingAndCommitsOneUndo() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        try await fade(editor, start: 2.25, duration: "0.5", level: "0.25")
        try await fade(editor, start: 3.5, duration: "0.25", level: "0")
        let before = f.document.store.residentModel, original = try #require(editor.selected?.clip)
        let samples = try Data(contentsOf: bed.file)
        let bins = editor.waveforms.mapValues(\.id)
        let action = undo.undoActionName
        let began = await editor.beginAutomationGesture(clip: original.id, target: .point(1))
        let refusal = editor.error
        try #require(began, Comment(rawValue: refusal ?? "Automation did not begin."))
        let openedSheet = editor.fadeSession != nil
        #expect(!openedSheet)
        for frames: Int64 in [480, 1200, 2400] {
            let previewed = editor.previewAutomationGesture(frames: frames, levelDelta: 0.5)
            let live = f.document.store.residentModel
            #expect(previewed && live == before && undo.undoActionName == action)
            let levels = editor.automationGesture?.previewClip.envelope.points.map(\.amplitude)
            #expect(levels == original.envelope.points.map(\.amplitude))
        }
        let committed = editor.completeAutomationGesture()
        try #require(committed)
        let afterTime = f.document.store.residentModel, moved = try #require(editor.selected?.clip)
        #expect(undo.undoActionName == "Move Fade Point")
        #expect(moved.envelope.points[1].frame == original.envelope.points[1].frame + 2400)
        #expect(moved.anchor == original.anchor && moved.trim == original.trim && moved.outputWindow == original.outputWindow)
        undo.undo()
        let undone = f.document.store.residentModel
        #expect(undone == before)
        undo.redo()
        editor.refresh()
        let redone = f.document.store.residentModel
        #expect(redone == afterTime)
        let levelBegan = await editor.beginAutomationGesture(clip: original.id, target: .level(first: 1, last: 2))
        try #require(levelBegan)
        let levelPreviewed = editor.previewAutomationGesture(frames: 50_000, levelDelta: 0.25)
        #expect(levelPreviewed)
        let levelCommitted = editor.completeAutomationGesture()
        try #require(levelCommitted)
        let adjusted = try #require(editor.selected?.clip)
        #expect(adjusted.envelope.points.map(\.frame) == moved.envelope.points.map(\.frame))
        #expect(adjusted.envelope.points.map(\.amplitude) == [1, 0.5, 0.5, 0])
        #expect(undo.undoActionName == "Adjust Fade Level")
        #expect(editor.waveforms.mapValues(\.id) == bins)
        try await helper.save(f.document)
        let savedURL = f.document.fileURL, savedModel = f.document.store.residentModel
        let saved = try LocalFileOperations().read(#require(savedURL))
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(saved).payload == savedModel)
        #expect(try Data(contentsOf: bed.file) == samples)
    }

    @Test func graphicalAutomationCancelNoOpAndReplacedContextNeverPublish() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        try await fade(editor, start: 2.25, duration: "0.5", level: "0.25")
        let before = f.document.store.residentModel, action = undo.undoActionName
        let began = await editor.beginAutomationGesture(clip: bed.clip.clip.id, target: .point(1))
        try #require(began)
        let previewed = editor.previewAutomationGesture(frames: 2400)
        #expect(previewed)
        editor.cancelAutomationGesture()
        let canceled = f.document.store.residentModel
        let hasGesture = editor.automationGesture != nil
        #expect(canceled == before && undo.undoActionName == action && !hasGesture)
        let noOp = await editor.beginAutomationGesture(clip: bed.clip.clip.id, target: .point(1))
        try #require(noOp)
        let noOpCommitted = editor.completeAutomationGesture()
        #expect(noOpCommitted)
        let unchanged = f.document.store.residentModel
        #expect(unchanged == before && undo.undoActionName == action)
        for ownerChanged in [false, true] {
            try await helper.wait {
                editor.canPlaceDroppedAudio && f.document.store.canEdit
                    && TrackProcessingOperation.current(alignment: f.model, cleanup: bed.owner.state.cleanupModel) == nil
            }
            let active = await editor.beginAutomationGesture(clip: bed.clip.clip.id, target: .point(1))
            try #require(active)
            let previewed = editor.previewAutomationGesture(frames: 2400)
            #expect(previewed)
            if ownerChanged { bed.owner.state.alignmentModel = nil }
            else { f.document.store.replaceLoadedModel(before) }
            let committed = editor.completeAutomationGesture()
            let current = f.document.store.residentModel, refusal = editor.error
            #expect(!committed && current == before && refusal?.contains("changed") == true)
            bed.owner.state.alignmentModel = f.model
            editor.refresh()
        }
    }

    @Test func automationInputCancellationDiscardsAnInFlightPointDrag() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor
        try await fade(editor, start: 2.25, duration: "0.5", level: "0.25")
        let clip = try #require(editor.selected)
        let key = AudioEnvelopeGeometryKey(envelope: clip.clip.envelope, durationFrames: 96_000,
            programStart: 2, viewportStart: 2, viewportDuration: 2, viewportWidth: 640,
            left: 0, width: 640, height: 100, projection: .unedited)
        let geometry = try AudioEnvelopeGeometry.make(key)
        let item = AudioAutomationCanvas.Item(projected: clip,
            frame: .init(x: 0, y: 0, width: 640, height: 100), key: key, geometry: geometry)
        let input = AudioAutomationInput(editor: editor)
        let before = f.document.store.residentModel
        input.begin(item, target: .point(1))
        try await helper.wait { editor.automationGesture != nil }
        input.change(.init(x: 40, y: 20))
        try await helper.wait { editor.automationGesture.map { $0.previewClip != clip.clip } == true }
        let during = f.document.store.residentModel
        let preview = editor.automationGesture?.previewClip
        #expect(during == before && preview != clip.clip)
        input.cancel()
        input.end(.zero)
        let after = f.document.store.residentModel
        let stillDragging = editor.automationGesture != nil
        #expect(after == before && !stillDragging)
        input.begin(item, target: .point(1))
        input.end(.init(x: 40, y: 20))
        try await helper.wait { f.document.store.residentModel != before }
        let finished = f.document.store.residentModel
        #expect(finished != before && !input.tracking)
    }

    @Test func invalidInputsConflictReviewAndStaleSelectionDocumentAndOwnerNeverPublish() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        for text in ["", "nan", "inf", "0", "-1", "86401", "1e300"] {
            await editor.requestFade(.fadeOut, programSeconds: 2)
            let session = try requireFadeSession(editor)
            var draft = AudioFadeDraft(session: session)
            draft.length = text
            let before = f.document.store.residentModel, action = undo.undoActionName
            #expect(!editor.commitFade(session, draft: draft))
            #expect(editor.error != nil && f.document.store.residentModel == before && undo.undoActionName == action)
            editor.dismissFade()
        }
        for position: Double? in [nil, .nan, .infinity, 1.99, 4] {
            await editor.requestFade(.fadeOut, programSeconds: position)
            #expect(editor.fadeSession == nil && editor.error != nil)
        }
        for scenario in 0..<5 {
            await editor.requestFade(.fadeOut, programSeconds: 2)
            let session = try requireFadeSession(editor)
            let before = f.document.store.residentModel
            switch scenario {
            case 0:
                editor.selectedClip = nil
                editor.select(bed.clip.clip.id)
            case 1: f.document.store.replaceLoadedModel(before)
            case 2:
                try #require(f.document.store.apply("Temporary") { model throws(DomainError) in
                    try model.addingAudioTrack(.init(name: "Temporary"), in: f.model.episodeID)
                })
                undo.undo()
            case 3: bed.owner.state.alignmentModel = nil
            default: editor.suspend()
            }
            editor.refresh()
            #expect(!editor.commitFade(session, draft: AudioFadeDraft(session: session)))
            #expect(editor.error?.contains("changed") == true && f.document.store.residentModel == before)
            bed.owner.state.alignmentModel = f.model
            editor.dismissFade()
        }
        try await fade(editor, start: 2, duration: "1", level: "0.25")
        await editor.requestFade(.fadeOut, programSeconds: 2.5)
        let session = try requireFadeSession(editor)
        var draft = AudioFadeDraft(session: session)
        draft.length = "0.25"
        draft.level = "0"
        draft.silence = true
        let before = f.document.store.residentModel
        #expect(try editor.fadePreview(session, draft: draft).requiresReplacement)
        #expect(!editor.commitFade(session, draft: draft) && f.document.store.residentModel == before)
        draft.replacing = true
        #expect(editor.commitFade(session, draft: draft))
    }

    @Test func numericPointEditsRemovalAndFractionalTrimRetainOutputOwnershipAndUndo() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, undo = try undoManager(f)
        defer { undo.groupsByEvent = true }
        try await fade(editor, start: 2, duration: "1", level: "1", direction: .fadeIn)
        let original = try #require(editor.selected)
        var trimmed = original.clip
        trimmed.trim.startFrame = 1
        trimmed.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: original.clip, asset: original.asset, to: trimmed.trim)
        try #require(f.document.store.apply("Synthetic native trim") { model throws(DomainError) in
            try model.replacingAudioClip(trimmed, in: f.model.episodeID)
        })
        editor.refresh()
        editor.resizeSelected(start: "2", end: "90000")
        let before = f.document.store.residentModel, selected = try #require(editor.selected)
        let point = try #require(try editor.fadePoints().get().first(where: \.editable))
        await editor.requestFadePoint(point.index)
        let session = try requireFadeSession(editor)
        var draft = AudioFadeDraft(session: session)
        #expect(draft.localFrame.contains("/"))
        draft.level = "0.75"
        draft.silence = false
        draft.replacing = true
        let edited = editor.commitFade(session, draft: draft)
        let editRefusal = editor.error
        try #require(edited, Comment(rawValue: editRefusal ?? "The fade point was not edited."))
        #expect(editor.selected?.clip.trim == selected.clip.trim && editor.selected?.clip.outputWindow == selected.clip.outputWindow)
        #expect(try editor.selected?.clip.envelope.points[point.index].coordinate() == selected.clip.envelope.points[point.index].coordinate())
        #expect(undo.undoActionName == "Edit Fade Point")
        undo.undo()
        editor.refresh()
        #expect(f.document.store.residentModel == before)
        undo.redo()
        editor.refresh()
        await editor.requestFadePoint(point.index)
        let removal = try requireFadeSession(editor)
        var removing = AudioFadeDraft(session: removal)
        removing.removing = true
        removing.replacing = true
        let removed = editor.commitFade(removal, draft: removing)
        let removalRefusal = editor.error
        try #require(removed, Comment(rawValue: removalRefusal ?? "The fade point was not removed."))
        #expect(undo.undoActionName == "Remove Fade Point")
        #expect(editor.selected?.clip.envelope.points.first == selected.clip.envelope.points.first,
                "The outside-trim support point is not discarded by local point removal.")
    }

    @Test func actualPlayheadTicksReuseOverlayAndSourceGeometryWithoutRelayoutOrDecode() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor
        try await fade(editor, start: 2, duration: "1", level: "0.25")
        let selected = try #require(editor.selected?.clip)
        try #require(f.document.store.apply("Synthetic overlapping placements") { model throws(DomainError) in
            var next = model
            for _ in 0..<(AudioEnvelopeGeometryCache.maximumEntries + 3) {
                var copy = selected
                copy.id = AudioClipID()
                next = try next.addingAudioClip(copy, in: f.model.episodeID)
            }
            return next
        })
        editor.refresh()
        let track = try #require(editor.tracks.first)
        let host = HostedTimelineWindow(width: 1000, height: 150,
            content: AudioFadeTrackHarness(model: f.model, track: track))
        defer { host.close() }
        try await host.settle()
        let count = editor.envelopeGeometryCache.buildCount, frame = editor.trackFrames[track.id]
        let bins = editor.waveforms.mapValues(\.id), overview = f.model.waveformOverviewSnapshotID
        try #require(count > 0 && frame != nil)
        #expect(editor.envelopeGeometryCache.entryCount <= AudioEnvelopeGeometryCache.maximumEntries)
        for tick in 0..<12 {
            f.model.waveformPlayheadSeconds = 2 + Double(tick) / 20
            try await host.settle()
        }
        #expect(editor.envelopeGeometryCache.buildCount == count, "Playhead-only publications must reuse the cached curve.")
        #expect(editor.envelopeGeometryCache.entryCount <= AudioEnvelopeGeometryCache.maximumEntries)
        #expect(editor.trackFrames[track.id] == frame)
        #expect(editor.waveforms.mapValues(\.id) == bins && f.model.waveformOverviewSnapshotID == overview)
    }

    @Test func coldPreparationBlocksButWarmRefinementKeepsFadeEditingInteractive() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let bed = try await importBed(f, extra: true)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor
        let cold = FadePreparationGate()
        defer { cold.release() }
        var pausedCold = false
        editor.beforeWaveformPreparationForTesting = {
            if !pausedCold { pausedCold = true; await cold.pause() }
        }
        editor.reloadWaveforms()
        try await helper.wait { cold.entered }
        #expect(editor.processing?.kind == .waveforms && editor.waveforms.isEmpty)
        await editor.requestFade(.fadeOut, programSeconds: 2)
        #expect(editor.fadeSession == nil && editor.error != nil)
        cold.release()
        try await helper.wait { !editor.isPreparingWaveforms }
        #expect(editor.waveforms.count == 2)
        let warm = FadePreparationGate()
        defer { warm.release() }
        editor.beforeWaveformPreparationForTesting = { await warm.pause() }
        try #require(f.document.store.apply("Rename supplemental source") { model throws(DomainError) in
            var next = model
            guard let episode = next.episodes.firstIndex(where: { $0.id == f.model.episodeID }),
                  let source = next.episodes[episode].sources.firstIndex(where: { $0.id == bed.clip.clip.source }) else {
                throw .invalidAudio("The synthetic source was removed.")
            }
            next.episodes[episode].sources[source].displayNameHint = "Renamed synthetic bed"
            return next
        })
        editor.refresh()
        try await helper.wait { warm.entered }
        #expect(editor.isPreparingWaveforms && editor.waveforms.count == 1 && editor.processing == nil)
        try await fade(editor, start: 2, duration: "0.5", level: "0.25")
        #expect(editor.error == nil && editor.selected?.clip.envelope.points.count == 2)
        warm.release()
        try await helper.wait { !editor.isPreparingWaveforms }
        #expect(editor.waveforms.count == 2)
        editor.beforeWaveformPreparationForTesting = nil
    }

    @Test func nativeStateIsCapturedBeforePreviewAndLateNativeStateStillRefusesReplacement() async throws {
        let f = try await helper.ready()
        var mayClose = true
        defer { if mayClose { f.close() } }
        let bed = try await importBed(f)
        defer { Task { await bed.engine.shutdown() } }
        let editor = f.model.audioEditor, slot = try helper.appleSlot()
        try helper.insert(slot, into: f)
        editor.refresh()
        let outcome: Result<Void, any Error>
        do {
            _ = try await f.model.mixer.prepare(programFrames: 96_000..<98_048)
            try await f.model.mixer.beginEditorObservation(coalescing: "f8.native")
            await f.model.mixer.suspendEditorObservation()
            let processor = try #require(f.model.mixer.processor)
            let parameter = try #require(try await processor.parameters(slot: slot.id).first { $0.writable && $0.minimum < $0.maximum })
            try await processor.setParameter(slot: slot.id, address: parameter.address,
                value: parameter.value == parameter.minimum ? parameter.maximum : parameter.minimum)
            await editor.requestFade(.fadeOut, programSeconds: 2)
            let captured = try requireFadeSession(editor)
            let capturedState = editor.episode?.mix?.master.inserts.first?.documentState
            let captureEndedObservation = !f.model.mixer.hasObservedState && f.model.mixer.processor == nil
            #expect(capturedState != nil && captureEndedObservation)
            let applied = editor.commitFade(captured, draft: AudioFadeDraft(session: captured))
            let applyRefusal = editor.error
            try #require(applied, Comment(rawValue: applyRefusal ?? "The captured fade was not applied."))
            f.model.load()
            try await helper.wait("Waiting for the editable fade projection; \(editor.error ?? "no refusal")") {
                editor.store.canEdit && bed.owner.state.canEdit && editor.selected != nil
                    && editor.canPlaceDroppedAudio
                    && TrackProcessingOperation.current(alignment: f.model, cleanup: bed.owner.state.cleanupModel) == nil
            }
            await editor.requestFade(.fadeIn, programSeconds: 3.5)
            let late = try requireFadeSession(editor)
            var draft = AudioFadeDraft(session: late)
            draft.length = "0.25"
            draft.level = "1"
            draft.silence = false
            _ = try await f.model.mixer.prepare(programFrames: 96_000..<98_048)
            try await f.model.mixer.beginEditorObservation(coalescing: "f8.late")
            await f.model.mixer.suspendEditorObservation()
            let lateProcessor = try #require(f.model.mixer.processor)
            let ownsPendingObservation = f.model.mixer.hasObservedState && f.model.mixer.processor === lateProcessor
            #expect(ownsPendingObservation)
            try await lateProcessor.setParameter(slot: slot.id, address: parameter.address, value: parameter.value)
            let before = f.document.store.residentModel
            let lateApplied = editor.commitFade(late, draft: draft)
            let lateRefusal = editor.error
            let after = f.document.store.residentModel
            #expect(!lateApplied)
            #expect(lateRefusal?.contains("Audio Unit") == true && after == before)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // The first fade barrier already captured and discarded its observation. Only a still-owned
        // pending observation needs another capture before fixture files can be removed.
        if f.model.mixer.hasObservedState {
            do { try await f.model.mixer.endEditorObservation() }
            catch {
                mayClose = false
                Issue.record("Native-observation teardown failed; F8 fixture preserved at \(f.folder.path): \(error)")
                try outcome.get()
                throw error
            }
        }
        try outcome.get()
    }
}

private struct AudioFadeTrackHarness: View {
    @Bindable var model: EpisodeAlignmentModel
    let track: AudioTrack
    var body: some View {
        AudioClipTrackView(editor: model.audioEditor, track: track, start: 0, duration: 6,
            playhead: model.waveformPlayheadSeconds, height: 100, headerWidth: 140,
            normalized: false, projection: model.presentationTimeline, showInspector: {})
    }
}

@MainActor private final class FadePreparationGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
