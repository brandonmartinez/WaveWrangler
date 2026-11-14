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
    @Test func exclusiveDialogueEndpointsDistinguishContiguousInsertionsCutSeamsAndExpandedReview() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 20)
        defer { f.close() }
        var episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let map = try #require(episode.alignment?.acceptedMap)
        let first = try AudioInsertionRegion(anchor: .dialogue(.init(map: map, frame: 240_000)),
                                            durationFrames: 192_000)
        let second = AudioInsertionRegion(anchor: first.anchor, durationFrames: 288_000)
        episode.audioArrangement = .init(insertionRegions: [first, second])
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: 0..<960_000)
        let projection = AudioTimelineProjection(program: timeline)
        let reviewRows = [FillerReviewRow(id: UUID(), speakerID: Speaker(name: "Host").id,
            speaker: "Host", phrase: "um", status: "Needs review", category: .pending,
            start: 5, end: 6, issue: nil, cutID: nil)]
        #expect(ReviewPlaybackPosition.locate(projection.originalTime(forDisplayTime: 9), in: reviewRows) == nil)
        #expect(ReviewPlaybackPosition.locate(projection.originalTime(forDisplayTime: 15.5), in: reviewRows)
            == .init(row: 0, fraction: 0.5))
        #expect(projection.originalTime(forDisplayTime: 5) == nil)
        #expect(projection.originalTime(forExclusiveDisplayEnd: 5) == 5)
        #expect(projection.originalTime(forDisplayTime: 15) == 5)
        #expect(projection.originalTime(forExclusiveDisplayEnd: 16) == 6)
        for time in [5.5, 9, 14.5, 15] {
            #expect(projection.originalTime(forExclusiveDisplayEnd: time) == nil)
        }
        #expect(projection.originalTime(forExclusiveDisplayEnd: 25) == 15)
        #expect(projection.originalTime(forExclusiveDisplayEnd: 30) == 20)
        #expect(projection.originalTime(forExclusiveDisplayEnd: 30.5) == nil)

        let cut = ManualEpisodeCut(alignmentRevision: map.revision, startFrame: 96_000, endFrame: 144_000)
        episode.cleanup = .init(manualCuts: [cut])
        let edited = try ProgramTimeline(episode: episode, dialogueFrames: 0..<960_000)
        let collapsed = AudioTimelineProjection(cuts: edited.cuts, program: edited)
        #expect(collapsed.originalTime(forDisplayTime: 2) == 3)
        #expect(collapsed.originalTime(forExclusiveDisplayEnd: 2) == 2)
        #expect(collapsed.originalTime(forExclusiveDisplayEnd: 4) == 5)
        let review = AudioTimelineProjection(cuts: .unedited, program: edited, expanded: cut)
        #expect(review.originalTime(forDisplayTime: 2.5) == 2.5)
        #expect(review.originalTime(forExclusiveDisplayEnd: 2) == 2)
        #expect(review.originalTime(forExclusiveDisplayEnd: 2.5) == nil)
        #expect(review.originalTime(forExclusiveDisplayEnd: 3) == nil)
        #expect(review.originalTime(forExclusiveDisplayEnd: 5) == 5)
        #expect(review.programTime(forDisplayTime: 2.5) == nil)

        try #require(f.document.store.apply("Synthetic expanded-cut boundary fixture") { model throws(DomainError) in
            try model.settingAudioArrangement(episode.audioArrangement, in: episode.id)
                .settingCleanup(episode.cleanup, in: episode.id)
        })
        f.model.audioEditor.refresh()
        f.model.load()
        try await helper.wait { f.model.audioEditor.composition?.timeline.cuts.removals == [96_000..<144_000] }
        f.model.listening.expandedManualCutID = cut.id
        f.model.synchronizeCuts()
        let reviewInterior = f.model.selectionHasDialogueOnly(2.1...2.9)
        let crossingReview = f.model.selectionHasDialogueOnly(1.5...3.5)
        let beforeReview = f.model.selectionHasDialogueOnly(1...2)
        let afterReview = f.model.selectionHasDialogueOnly(3...4)
        let crossingInsertion = f.model.selectionHasDialogueOnly(4...5.5)
        #expect(!reviewInterior && !crossingReview && !crossingInsertion)
        #expect(beforeReview && afterReview)
    }

    @Test func manualCutsBeforeInsertionRetainExclusiveDialogueEndpoints() async throws {
        try await verifyInsertionEdgeCut(beforeInsertion: true)
    }

    @Test func manualCutsAfterInsertionRetainExclusiveDialogueEndpoints() async throws {
        try await verifyInsertionEdgeCut(beforeInsertion: false)
    }

    private func verifyInsertionEdgeCut(beforeInsertion: Bool) async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 20)
        defer { f.close() }
        let episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let map = try #require(episode.alignment?.acceptedMap)
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: map, frame: 240_000)),
                                             durationFrames: 480_000)
        try #require(f.document.store.apply("Synthetic insertion-edge cut fixture") { model throws(DomainError) in
            try model.settingAudioArrangement(.init(insertionRegions: [region]), in: episode.id)
        })
        f.model.audioEditor.refresh()
        f.model.load()
        try await helper.wait { f.model.canApplyManualCuts && f.model.audioEditor.composition?.timeline.insertions.count == 1 }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: episode.id, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        let range = beforeInsertion ? 4.0...5.0 : 15.0...16.0
        let dialogueOnly = f.model.selectionHasDialogueOnly(range)
        #expect(dialogueOnly)
        cleanup.listening.select(from: range.lowerBound, to: range.upperBound, within: 0...30)
        let canApply = cleanup.canApplyManualCut
        try #require(canApply)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let before = f.document.store.residentModel
        undo.beginUndoGrouping()
        cleanup.applyManualCut()
        undo.endUndoGrouping()
        let error = cleanup.error
        try #require(error == nil, Comment(rawValue: error ?? ""))
        let cuts = cleanup.activeManualCuts
        let cut = try #require(cuts.last)
        #expect(cut.startFrame == (beforeInsertion ? 192_000 : 240_000))
        #expect(cut.endFrame == (beforeInsertion ? 240_000 : 288_000))
        let after = f.document.store.residentModel
        let unchangedAlignment = after.episode(episode.id)?.alignment == episode.alignment
        #expect(unchangedAlignment)
        undo.undo()
        let restored = f.document.store.residentModel == before
        #expect(restored)
        undo.redo()
        let redone = f.document.store.residentModel == after
        #expect(redone)
        try await helper.save(f.document)
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            LocalFileOperations().read(#require(f.document.fileURL))).payload
        let saved = reopened == after
        #expect(saved)
    }

    @Test func exteriorAddAudioMoveAndUnpinFollowCutsWithoutInventingDialogue() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 10)
        defer { f.close() }
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initial = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let accepted = try #require(initial.alignment?.acceptedMap)
        let source = try #require(initial.speakerAssignments.first?.primary?.sourceID)
        let url = f.folder.appendingPathComponent("outro.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 44_100).write(to: url)
        let original = try Data(contentsOf: url)
        let context = SourceAccessContext(io: SystemSourceIO())
        let engine = WWSourcesSetupEngine(showID: f.document.store.residentModel.show.id,
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
        let beforeAdditionalCut = f.document.store.residentModel
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
        let afterAdditionalCut = f.document.store.residentModel
        #expect(undo.undoActionName == "Synthetic additional earlier cut")
        undo.undo()
        editor.refresh()
        #expect(f.document.store.residentModel == beforeAdditionalCut)
        #expect(editor.selected?.programFrames.lowerBound == 528_000)
        undo.redo()
        editor.refresh()
        #expect(f.document.store.residentModel == afterAdditionalCut)
        let composition = try #require(editor.composition)
        #expect(editor.selected?.programFrames.lowerBound == 480_000)
        #expect(try composition.timeline.inverse(atProgramFrame: 480_000) == .outsideCoverage)
        let projection = AudioTimelineProjection(program: composition.timeline)
        #expect(projection.originalTime(forDisplayTime: 10) == nil)
        let audition = try await f.runtime.sourceAuditions(model: f.document.store.residentModel, episode: initial.id,
            sources: [source], outputFrames: 480_000..<484_800, presentation: projection)
        let samples = try #require(audition[source]?.samples)
        #expect(samples.count == 4_800 && samples.allSatisfy { $0 == 0 })
        try await helper.save(f.document)
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            LocalFileOperations().read(#require(f.document.fileURL))).payload
        #expect(reopened == f.document.store.residentModel)
        let reopenedComposition = try await f.runtime.programComposition(model: reopened, episode: initial.id)
        #expect(reopenedComposition == composition)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func sequentialDropsInverseAnchorEveryClipAfterExistingCutsAndInsertions() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready(durationSeconds: 10)
        defer { f.close() }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initial = try #require(f.document.store.residentModel.episode(f.model.episodeID))
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
        let engine = WWSourcesSetupEngine(showID: f.document.store.residentModel.show.id,
            store: FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")), context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        defer { Task { await engine.shutdown() } }
        editor.importer.sourceEngineForTesting = engine
        for start in [Int64(60_000), 132_000, 576_000] {
            let before = try #require(f.document.store.residentModel.episode(initial.id))
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
            let after = try #require(f.document.store.residentModel.episode(initial.id))
            #expect(after.alignment == initial.alignment && after.cleanup == before.cleanup)
            #expect(after.speakerAssignments == initial.speakerAssignments && after.recorderGroups == initial.recorderGroups)
            #expect(after.sources.filter(\.isRecording) == initial.sources)
        }
    }

    @Test func dialogueImportProjectsWordsMarkersAndOverlappingCutReviewWithoutChangingPins() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready()
        defer { f.close() }
        let owner = helper.owner(f), editor = f.model.audioEditor
        let initialTiming = f.document.store.residentModel.episode(f.model.episodeID)?.alignment
        let url = f.folder.appendingPathComponent("intro.wav")
        try AudioClipEditorHostedTests.wave(rate: 44_100, frames: 44_100).write(to: url)
        let context = SourceAccessContext(io: SystemSourceIO())
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        let engine = WWSourcesSetupEngine(showID: f.document.store.residentModel.show.id, store: access, context: context,
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
        let canonical = f.document.store.residentModel
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
        #expect(f.document.store.residentModel == canonical)
        #expect(editor.composition == production, "Show cut must not reproject saved clip anchors or production inputs.")
        #expect(editor.composition?.clips[0].clip.anchor == .absolute(frame: 24_000))
        #expect(f.document.store.residentModel.episode(f.model.episodeID)?.alignment == initialTiming)
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
        let episode = try #require(f.document.store.residentModel.episode(f.model.episodeID))
        let accepted = try #require(episode.alignment?.acceptedMap)
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: accepted, frame: 48_000)),
                                             durationFrames: 24_000)
        try #require(f.document.store.apply("Synthetic insertion fixture") { model throws(DomainError) in
            try model.settingAudioArrangement(.init(insertionRegions: [region]), in: episode.id)
        })
        f.model.audioEditor.refresh()
        f.model.load()
        try await helper.save(f.document)
        let composition = try await f.runtime.programComposition(model: f.document.store.residentModel, episode: episode.id)
        let projection = AudioTimelineProjection(program: composition.timeline)
        let source = try #require(episode.speakerAssignments.first?.primary?.sourceID)
        let expected = try await f.runtime.sourceAuditions(model: f.document.store.residentModel, episode: episode.id,
            sources: [source], outputFrames: 24_000..<72_000, applyingCuts: false)
        let displayed = try await f.runtime.sourceAuditions(model: f.document.store.residentModel, episode: episode.id,
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
