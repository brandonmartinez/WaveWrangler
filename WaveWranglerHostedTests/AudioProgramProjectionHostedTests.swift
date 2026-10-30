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

@MainActor @Suite("Audio editor program and review coordinates", .serialized)
struct AudioProgramProjectionHostedTests {
    @Test func exteriorAddAudioMoveAndUnpinFollowCutsWithoutInventingDialogue() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 10)
        defer { f.close() }
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initial = try #require(f.document.store.model.episode(f.model.episodeID))
        let accepted = try #require(initial.alignment?.acceptedMap)
        let source = try #require(initial.speakerAssignments.first?.primary?.sourceID)
        let url = f.folder.appendingPathComponent("outro.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 44_100).write(to: url)
        let original = try Data(contentsOf: url)
        let context = SourceAccessContext(io: SystemSourceIO())
        let engine = WWSourcesSetupEngine(showID: f.document.store.model.show.id,
            store: FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")), context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        defer { Task { await engine.shutdown() } }
        editor.importer.sourceEngineForTesting = engine
        editor.importer.scan([url], in: owner.state, programSeconds: 12)
        try await helper.wait { editor.importer.review != nil || editor.importer.error != nil }
        editor.importer.commit(try #require(editor.importer.review))
        try await helper.wait { editor.importer.processing == nil }
        try #require(editor.importer.error == nil, Comment(rawValue: editor.importer.error ?? ""))
        editor.refresh()
        let unpinned = try #require(editor.composition?.clips.first)
        #expect(editor.composition?.timeline.dialogueFrames == 0..<480_000)
        #expect(unpinned.programFrames.lowerBound == 576_000)
        editor.select(unpinned.clip.id)
        editor.duplicateSelected()
        editor.pinSelected(true)
        let pinned = try #require(editor.selected)
        let cut = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 96_000, endFrame: 192_000)
        try #require(f.document.store.apply("Synthetic earlier cut") { model throws(DomainError) in
            var next = model
            let index = next.episodes.firstIndex { $0.id == initial.id }!
            var cleanup = next.episodes[index].cleanup ?? EpisodeCleanup()
            cleanup.manualCuts = [cut]
            next.episodes[index].cleanup = cleanup
            return next
        })
        editor.refresh()
        #expect(editor.composition?.clips.first { $0.clip.id == unpinned.clip.id }?.programFrames.lowerBound == 480_000)
        #expect(editor.composition?.clips.first { $0.clip.id == pinned.clip.id }?.programFrames.lowerBound == 576_000)
        editor.select(unpinned.clip.id)
        editor.moveSelected(start: "11", track: unpinned.clip.track)
        editor.pinSelected(true)
        editor.pinSelected(false)
        #expect(editor.selected?.programFrames.lowerBound == 528_000)
        var origin = unpinned.clip
        origin.id = AudioClipID()
        origin.anchor = .programOrigin(frame: 576_000)
        var reconciled = origin
        reconciled.id = AudioClipID()
        try #require(f.document.store.apply("Synthetic saved origin placements") { model throws(DomainError) in
            try model.addingAudioClip(origin, in: initial.id).addingAudioClip(reconciled, in: initial.id)
        })
        editor.refresh()
        #expect(editor.composition?.clips.first { $0.clip.id == origin.id }?.programFrames.lowerBound == 576_000)
        reconciled.anchor = try #require(editor.composition).timeline.reconciledAnchor(for: reconciled.anchor)
        try #require(f.document.store.apply("Explicitly reconcile audio origin") { model throws(DomainError) in
            try model.replacingAudioClip(reconciled, in: initial.id)
        })
        editor.refresh()
        #expect(editor.composition?.clips.first { $0.clip.id == reconciled.id }?.programFrames.lowerBound == 576_000)
        let earlier = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 0, endFrame: 48_000)
        let beforeAdditionalCut = f.document.store.model
        try #require(f.document.store.apply("Synthetic additional earlier cut") { model throws(DomainError) in
            var next = model
            let index = next.episodes.firstIndex { $0.id == initial.id }!
            var cleanup = next.episodes[index].cleanup ?? EpisodeCleanup()
            cleanup.manualCuts = (cleanup.manualCuts ?? []) + [earlier]
            next.episodes[index].cleanup = cleanup
            return next
        })
        editor.refresh()
        #expect(editor.selected?.programFrames.lowerBound == 480_000)
        #expect(editor.composition?.clips.first { $0.clip.id == pinned.clip.id }?.programFrames.lowerBound == 576_000)
        #expect(editor.composition?.clips.first { $0.clip.id == origin.id }?.programFrames.lowerBound == 576_000)
        #expect(editor.composition?.clips.first { $0.clip.id == reconciled.id }?.programFrames.lowerBound == 528_000)
        let afterAdditionalCut = f.document.store.model
        #expect(undo.undoActionName == "Synthetic additional earlier cut")
        undo.undo()
        editor.refresh()
        #expect(f.document.store.model == beforeAdditionalCut)
        #expect(editor.selected?.programFrames.lowerBound == 528_000)
        undo.redo()
        editor.refresh()
        #expect(f.document.store.model == afterAdditionalCut)
        let composition = try #require(editor.composition)
        #expect(editor.selected?.programFrames.lowerBound == 480_000)
        #expect(try composition.timeline.inverse(atProgramFrame: 480_000) == .outsideCoverage)
        let projection = AudioTimelineProjection(program: composition.timeline)
        #expect(projection.originalTime(forDisplayTime: 10) == nil)
        let audition = try await f.runtime.sourceAuditions(model: f.document.store.model, episode: initial.id,
            sources: [source], outputFrames: 480_000..<484_800, presentation: projection)
        let samples = try #require(audition[source]?.samples)
        #expect(samples.count == 4_800 && samples.allSatisfy { $0 == 0 })
        try await helper.save(f.document)
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))).payload
        #expect(reopened == f.document.store.model)
        let reopenedComposition = try await f.runtime.programComposition(model: reopened, episode: initial.id)
        #expect(reopenedComposition == composition)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func sequentialDropsInverseAnchorEveryClipAfterExistingCutsAndInsertions() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 10)
        defer { f.close() }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initial = try #require(f.document.store.model.episode(f.model.episodeID))
        let accepted = try #require(initial.alignment?.acceptedMap)
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: accepted, frame: 48_000)),
                                             durationFrames: 24_000)
        let cut = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 96_000, endFrame: 192_000)
        try #require(f.document.store.apply("Synthetic edited program") { model throws(DomainError) in
            var next = model
            let index = next.episodes.firstIndex { $0.id == initial.id }!
            var cleanup = next.episodes[index].cleanup ?? EpisodeCleanup()
            cleanup.manualCuts = [cut]
            next.episodes[index].cleanup = cleanup
            return try next.settingAudioArrangement(.init(insertionRegions: [region]), in: initial.id)
        })
        let first = f.folder.appendingPathComponent("first-drop.wav")
        let second = f.folder.appendingPathComponent("second-drop.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 44_100).write(to: first)
        try AudioClipEditorHostedTests.wave(rate: 48_000, frames: 48_000).write(to: second)
        let context = SourceAccessContext(io: SystemSourceIO())
        let engine = WWSourcesSetupEngine(showID: f.document.store.model.show.id,
            store: FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")), context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        defer { Task { await engine.shutdown() } }
        editor.importer.sourceEngineForTesting = engine
        for start in [Int64(60_000), 132_000, 576_000] {
            let before = try #require(f.document.store.model.episode(initial.id))
            editor.importer.scan([first, second], in: owner.state,
                destination: .init(frame: start, track: .newTrack))
            try await helper.wait { editor.importer.review != nil || editor.importer.error != nil }
            editor.importer.commit(try #require(editor.importer.review))
            try await helper.wait { editor.importer.processing == nil }
            try #require(editor.importer.error == nil, Comment(rawValue: editor.importer.error ?? ""))
            editor.refresh()
            let ids = Set(editor.importer.completedClips)
            let placed = try #require(editor.composition?.clips.filter { ids.contains($0.clip.id) })
            #expect(placed.map(\.programFrames.lowerBound) == [start, start + 48_000])
            if start == 60_000 {
                let expectedSecond = try AudioDialogueAnchor(map: accepted, frame: 84_000)
                #expect(placed[0].clip.anchor == .insertion(region: region.id, offsetFrames: 12_000))
                #expect(placed[1].clip.anchor == .dialogue(expectedSecond))
            }
            let after = try #require(f.document.store.model.episode(initial.id))
            #expect(after.alignment == initial.alignment && after.cleanup == before.cleanup)
            #expect(after.speakerAssignments == initial.speakerAssignments && after.recorderGroups == initial.recorderGroups)
            #expect(after.sources.filter(\.isRecording) == initial.sources)
        }
    }

    @Test func dialogueImportProjectsWordsMarkersAndOverlappingCutReviewWithoutChangingPins() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready()
        defer { f.close() }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initialTiming = f.document.store.model.episode(f.model.episodeID)?.alignment
        let url = f.folder.appendingPathComponent("intro.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 44_100).write(to: url)
        let context = SourceAccessContext(io: SystemSourceIO())
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        let engine = WWSourcesSetupEngine(showID: f.document.store.model.show.id, store: access, context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        defer { Task { await engine.shutdown() } }
        editor.importer.sourceEngineForTesting = engine
        editor.importer.scan([url], in: owner.state, programSeconds: 0.5)
        try await helper.wait { editor.importer.review != nil || editor.importer.error != nil }
        editor.importer.commit(try #require(editor.importer.review))
        try await helper.wait { editor.importer.processing == nil }
        try #require(editor.importer.error == nil, Comment(rawValue: editor.importer.error ?? ""))
        editor.refresh()
        let clip = try #require(editor.composition?.clips.first)
        editor.select(clip.clip.id)
        editor.pinSelected(true)
        let accepted = try #require(initialTiming?.acceptedMap)
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: accepted, frame: 48_000)),
                                             durationFrames: 24_000)
        let first = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 96_000, endFrame: 144_000)
        let second = ManualEpisodeCut(alignmentRevision: accepted.revision, startFrame: 120_000, endFrame: 168_000)
        try #require(f.document.store.apply("Synthetic program geometry") { model throws(DomainError) in
            var next = model
            let index = next.episodes.firstIndex { $0.id == f.model.episodeID }!
            next.episodes[index].audioArrangement?.insertionRegions = [region]
            var cleanup = next.episodes[index].cleanup ?? EpisodeCleanup()
            cleanup.manualCuts = [first, second]
            next.episodes[index].cleanup = cleanup
            return try next.settingAudioArrangement(next.episodes[index].audioArrangement, in: f.model.episodeID)
        })
        editor.refresh()
        f.model.load()
        let canonical = f.document.store.model
        let production = try #require(editor.composition)
        let projection = f.model.presentationTimeline
        #expect(projection.editedTime(forAlignedTime: 3.5) == 2.5)
        #expect(projection.originalTime(forDisplayTime: 1.25) == nil)
        #expect(f.model.dialogueTime(atDisplayTime: 1.25) == nil)
        #expect(production.clips[0].programFrames == 24_000..<72_000)
        let word = TranscriptWord(text: "Synthetic", sourceStartFrame: 168_000, sourceEndFrame: 177_600,
                                  alignedStart: 3.5, alignedEnd: 3.7)
        let index = AudioTimelineWordIndex(words: [word], projection: projection)
        #expect(index.words[0].alignedStart == 2.5)
        #expect(abs((index.words[0].alignedEnd ?? 0) - 2.7) < 1 / 48_000)
        f.model.listening.expandedManualCutID = first.id
        f.model.synchronizeCuts()
        let review = f.model.presentationTimeline
        #expect(review.originalTime(forDisplayTime: 2.75) == 2.25)
        #expect(review.programTime(forDisplayTime: 2.75) == nil)
        #expect(review.editedTime(forAlignedTime: 3.5) == 3)
        #expect(f.document.store.model == canonical)
        #expect(editor.composition == production, "Show cut must not reproject saved clip anchors or production inputs.")
        #expect(editor.composition?.clips[0].clip.anchor == .absolute(frame: 24_000))
        #expect(f.document.store.model.episode(f.model.episodeID)?.alignment == initialTiming)
        let choices = f.model.listening.playback
        for layout in AlignmentWaveformLayout.allCases { f.model.listening.workspace.layout = layout }
        #expect(f.model.listening.playback == choices)
        #expect(editor.tracks.count == 1 && editor.composition?.clips.count == 1)
        try await helper.save(f.document)
        let reopenedListening = EpisodeListeningState()
        reopenedListening.workspace.startSeconds = 1.5
        reopenedListening.workspace.playheadSeconds = 1.75
        let reopened = EpisodeAlignmentModel(document: f.document, episodeID: f.model.episodeID,
                                             runtime: f.runtime, listening: reopenedListening)
        defer { reopened.suspend() }
        reopened.load()
        try await helper.wait { reopened.audioEditor.composition != nil }
        reopened.synchronizeCuts()
        #expect(reopened.waveformStartSeconds == 1.5 && reopened.waveformPlayheadSeconds == 1.75)
    }

    @Test func sourceAuditionUsesProgramPartitionsAndNeverInventsRecordingAudioInInsertions() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready()
        defer { f.close() }
        let episode = try #require(f.document.store.model.episode(f.model.episodeID))
        let accepted = try #require(episode.alignment?.acceptedMap)
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: accepted, frame: 48_000)),
                                             durationFrames: 24_000)
        try #require(f.document.store.apply("Synthetic insertion fixture") { model throws(DomainError) in
            try model.settingAudioArrangement(.init(insertionRegions: [region]), in: episode.id)
        })
        f.model.audioEditor.refresh()
        f.model.load()
        try await helper.save(f.document)
        let composition = try await f.runtime.programComposition(model: f.document.store.model, episode: episode.id)
        let projection = AudioTimelineProjection(program: composition.timeline)
        let source = try #require(episode.speakerAssignments.first?.primary?.sourceID)
        let expected = try await f.runtime.sourceAuditions(model: f.document.store.model, episode: episode.id,
            sources: [source], outputFrames: 24_000..<72_000, applyingCuts: false)
        let displayed = try await f.runtime.sourceAuditions(model: f.document.store.model, episode: episode.id,
            sources: [source], outputFrames: 24_000..<96_000, presentation: projection)
        let samples = try #require(displayed[source]?.samples), original = try #require(expected[source]?.samples)
        #expect(Array(samples.prefix(24_000)) == Array(original.prefix(24_000)))
        #expect(samples[24_000..<48_000].allSatisfy { $0 == 0 })
        #expect(Array(samples.suffix(24_000)) == Array(original.suffix(24_000)))
        #expect(f.model.selectionHasDialogueOnly(0.5...2) == false)
        #expect(f.model.selectionHasDialogueOnly(1.5...2) == true)
        let drag = AlignmentWaveformDrag(startX: 0, width: 100, durationSeconds: 1,
            initialMilliseconds: 0, group: episode.recorderGroups[0].id, snapshot: UUID(),
            originalTime: 0.75, displayTime: 0.75)
        #expect(drag.previewMilliseconds(at: 50, projection: projection) == nil)
        #expect(drag.previewMilliseconds(at: 100, projection: projection) == 500)
    }
}
