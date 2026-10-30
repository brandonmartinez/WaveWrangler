import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
import WWCommonEdit
import WWCore
import WWDecode
import WWEpisodeSetup
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor @Suite("Audio clip editor workflows (synthetic only)", .serialized)
struct AudioClipEditorHostedTests {
    @MainActor private struct Fixture {
        let folder: URL
        let file: URL
        let document: ShowDocument
        let model: EpisodeAlignmentModel
        let owner: EpisodeWindowController
        let access: FileDeviceAccessStore
        let engine: WWSourcesSetupEngine
        let runtime: AlignmentRuntime
        var editor: AudioClipEditorModel { model.audioEditor }
        func close() {
            model.suspend()
            owner.close()
            NSDocumentController.shared.removeDocument(document)
            document.close()
            Task { await engine.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func fixture() async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ww-f5-hosted-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("synthetic-stereo.wav")
        try Self.wave(rate: 44_100, frames: 44_100).write(to: file)
        let initial = ShowDocumentModel(show: Show(title: "Synthetic audio editor"), episodes: [Episode(title: "Empty episode")])
        let url = folder.appendingPathComponent("show.wwshow")
        try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(initial, revision: 1, publicationID: UUID()).data.write(to: url)
        let document = try #require(try NSDocumentController.shared.makeDocument(
            withContentsOf: url, ofType: DocumentTypes.show) as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        document.undoManager?.groupsByEvent = false
        let access = FileDeviceAccessStore(fileURL: folder.appendingPathComponent("access.json"))
        let context = SourceAccessContext(io: SystemSourceIO())
        let runtime = try await AlignmentRuntime.make(showID: initial.show.id, accessStore: access, access: context)
        let model = EpisodeAlignmentModel(document: document, episodeID: initial.episodes[0].id, runtime: runtime)
        let state = ShowWindowState(store: document.store, episodeID: model.episodeID)
        state.alignmentModel = model
        state.select(.alignment)
        let owner = EpisodeWindowController(state: state)
        document.addWindowController(owner)
        if let window = owner.window { state.attach(to: window) }
        let engine = WWSourcesSetupEngine(showID: initial.show.id, store: access, context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        model.audioEditor.importer.sourceEngineForTesting = engine
        model.load()
        return .init(folder: folder, file: file, document: document, model: model,
                     owner: owner, access: access, engine: engine, runtime: runtime)
    }

    private func review(_ f: Fixture, files: [URL]? = nil) async throws -> AudioImportReview {
        f.editor.importer.scan(files ?? [f.file], in: f.owner.state, programSeconds: 0)
        try await wait { f.editor.importer.review != nil || f.editor.importer.error != nil }
        return try #require(f.editor.importer.review, Comment(rawValue: f.editor.importer.error ?? "Missing review"))
    }

    private func imported(_ f: Fixture) async throws -> ProgramAudioClip {
        f.editor.importer.commit(try await review(f))
        try await wait { f.editor.importer.processing == nil }
        try #require(f.editor.importer.error == nil, Comment(rawValue: f.editor.importer.error ?? ""))
        f.editor.refresh()
        return try #require(f.editor.composition?.clips.first)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "The bounded editor workflow did not finish.")
    }

    @Test func addAudioIntoEmptyEpisodeIsOneUndoAndReopensWithImmutableSources() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.model.loadWaveforms()
        #expect(f.model.trackProcessingOperation?.kind != .waveforms,
                "An episode without recorders must not be blocked by a recording-only preparation.")
        let original = try Data(contentsOf: f.file), before = f.document.store.model
        let review = try await review(f)
        #expect(f.document.store.model == before)
        #expect(try await f.access.allRecords().isEmpty)
        f.editor.importer.commit(review)
        try await wait { f.editor.importer.processing == nil }
        try #require(f.editor.importer.error == nil, Comment(rawValue: f.editor.importer.error ?? ""))
        f.editor.refresh()
        let after = f.document.store.model
        let episode = try #require(after.episode(f.model.episodeID))
        #expect(episode.alignment == nil && episode.recorderGroups.isEmpty && episode.speakerAssignments.isEmpty)
        #expect(episode.alignmentSources.isEmpty && episode.sources.count == 1)
        #expect(episode.audioArrangement?.assets.first?.frameCount == 44_100)
        #expect(f.editor.waveforms.values.first?.envelope.bins.isEmpty == false)
        #expect(f.document.undoManager?.undoActionName == "Add Audio")
        f.document.undoManager?.undo()
        #expect(f.document.store.model == before)
        f.document.undoManager?.redo()
        #expect(f.document.store.model == after)
        try await MixerHostedTests().save(f.document)
        let bytes = try Data(contentsOf: #require(f.document.fileURL))
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes)
        #expect(reopened.payload == after)
        let savedURL = try #require(f.document.fileURL)
        let reopenedDocument = try #require(try NSDocumentController.shared.makeDocument(
            withContentsOf: savedURL, ofType: DocumentTypes.show) as? ShowDocument)
        #expect(reopenedDocument.store.model == after)
        reopenedDocument.close()
        let recovery = RecoveryStore(root: f.folder.appendingPathComponent("recovery"))
        let checkpoint = try recovery.retainCheckpoint(bytes, for: .show(after.show.id))
        let recoveredURL = f.folder.appendingPathComponent("recovered.wwshow")
        try recovery.bytes(of: checkpoint).write(to: recoveredURL)
        let recovered = try #require(try NSDocumentController.shared.makeDocument(
            withContentsOf: recoveredURL, ofType: DocumentTypes.show) as? ShowDocument)
        #expect(recovered.store.model == after)
        recovered.close()
        #expect(try Data(contentsOf: f.file) == original)
        let source = try #require(episode.sources.first)
        try await f.access.removeRecord(for: .init(showID: after.show.id, sourceID: source.id))
        f.editor.reloadWaveforms()
        try await wait { !f.editor.isPreparingWaveforms }
        #expect(f.editor.waveforms[source.id] == nil && f.editor.error?.contains("blocked") == true)
    }

    @Test func multiFileOverlapTrackMovesPinsTrimsAndSplitsKeepExactOutputAndUndo() async throws {
        let f = try await fixture()
        defer { f.close() }
        let other = f.folder.appendingPathComponent("second.wav")
        try Self.wave(rate: 44_100, frames: 441).write(to: other)
        f.editor.importer.commit(try await review(f, files: [f.file, other]))
        try await wait { f.editor.importer.processing == nil }
        try #require(f.editor.importer.error == nil)
        f.editor.refresh()
        #expect(f.editor.composition?.clips.count == 2)
        #expect(f.editor.composition?.clips.map(\.programFrames.lowerBound) == [0, 0])
        let original = try #require(f.editor.composition?.clips.last)
        f.editor.select(original.clip.id)
        var automated = original.clip
        automated.envelope = .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)])
        try #require(f.document.store.apply("Synthetic curve") { model throws(DomainError) in
            try model.replacingAudioClip(automated, in: f.model.episodeID)
        })
        f.editor.refresh()
        f.editor.splitSelected(atProgramSeconds: 2.0 / 48_000)
        let clips = try #require(f.editor.composition?.clips)
        #expect(clips.suffix(2).map(\.programFrames) == [0..<2, 2..<480])
        #expect(clips[1].clip.id == original.clip.id && clips[2].clip.id != original.clip.id)
        #expect(clips[1].clip.trim == clips[2].clip.trim)
        f.editor.select(clips[2].clip.id)
        f.editor.addTrack()
        let track = try #require(f.editor.tracks.last)
        f.editor.moveSelected(start: "1.25", track: track.id)
        f.editor.pinSelected(true)
        #expect(f.editor.selected?.clip.anchor == .absolute(frame: 60_000))
        #expect(f.editor.selected?.clip.envelope == clips[2].clip.envelope)
        f.editor.pinSelected(false)
        #expect(f.editor.selected?.programFrames.lowerBound == 60_000)
        f.editor.resizeSelected(start: "3", end: "479")
        #expect(f.editor.selected?.clip.outputWindow == .init(offsetFrames: 3, countFrames: 476))
        let cropped = try #require(f.editor.selected)
        f.editor.resizeSelected(start: "2", end: "479")
        #expect(f.editor.selected == cropped && f.editor.error?.contains("discarded") == true)
        f.editor.resizeSelected(start: String(Int64.min), end: String(Int64.max))
        #expect(f.editor.selected == cropped)
        f.editor.duplicateSelected()
        #expect(f.editor.composition?.clips.count == 4)
        f.editor.renameTrack(track.id, name: "Bed")
        f.editor.reorderTrack(track.id, by: -1)
        #expect(f.editor.tracks.first?.name == "Bed")
        let beforeGesture = f.document.store.model
        let moving = try #require(f.editor.selected)
        f.editor.beginGesture(moving)
        f.editor.previewGesture(start: 70_000, track: track.id)
        #expect(f.document.store.model == beforeGesture)
        f.editor.cancelGesture()
        #expect(f.document.store.model == beforeGesture)
        f.editor.beginGesture(moving)
        f.editor.previewGesture(start: 70_000, track: track.id)
        f.editor.refuseGesture("Synthetic invalid final edge")
        f.editor.completeGesture()
        #expect(f.document.store.model == beforeGesture)
        f.editor.beginGesture(moving)
        f.editor.previewGesture(start: 70_000, track: track.id)
        f.editor.completeGesture()
        #expect(f.document.undoManager?.undoActionName == "Move Audio Clip")
        f.document.undoManager?.undo()
        #expect(f.document.store.model == beforeGesture)
        f.document.undoManager?.redo()
        f.editor.refresh()
        #expect(f.editor.selected?.programFrames.lowerBound == 70_000)
        try await MixerHostedTests().save(f.document)
    }

    @Test func canceledStaleRestoredAndReplacedDestinationsCannotPublish() async throws {
        for scenario in 0..<4 {
            let f = try await fixture()
            let before = f.document.store.model
            let review = try await review(f)
            switch scenario {
            case 0:
                try #require(f.document.store.apply("Temporary edit") { model throws(DomainError) in
                    try model.addingAudioTrack(.init(name: "Temporary"), in: f.model.episodeID)
                })
                f.document.undoManager?.undo()
            case 1: f.document.store.replaceLoadedModel(before)
            case 2:
                f.owner.state.alignmentModel = nil
            default: f.editor.importer.cancel()
            }
            f.editor.importer.commit(review)
            try await wait { f.editor.importer.processing == nil }
            #expect(f.document.store.model == before)
            #expect(try await f.access.allRecords().isEmpty)
            f.close()
        }
        let f = try await fixture()
        defer { f.close() }
        let gate = AudioImportGate()
        f.editor.importer.beforeQualificationForTesting = { await gate.pause() }
        let before = f.document.store.model
        f.editor.importer.commit(try await review(f))
        try await wait { gate.entered }
        f.editor.importer.cancel()
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.document.store.model == before && f.editor.importer.completedClips.isEmpty)
        #expect(try await f.access.allRecords().isEmpty)
        f.editor.importer.beforeQualificationForTesting = nil
        _ = try await imported(f)
        let first = AudioImportGate(), replacement = AudioImportGate()
        var preparations = 0
        f.editor.beforeWaveformPreparationForTesting = {
            preparations += 1
            if preparations == 1 { await first.pause() } else { await replacement.pause() }
        }
        f.editor.reloadWaveforms()
        try await wait { first.entered }
        f.editor.reloadWaveforms()
        try await wait { replacement.entered }
        first.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.editor.isPreparingWaveforms, "A canceled same-input job must not clear its replacement's blocking state.")
        #expect(f.editor.error == nil)
        replacement.release()
        try await wait { !f.editor.isPreparingWaveforms }
        #expect(f.editor.waveforms.count == 1)
    }

    @Test func unsupportedMediaInBatchNeverPublishesKnownDurationPlaceholders() async throws {
        let f = try await fixture()
        defer { f.close() }
        let unsupported = f.folder.appendingPathComponent("unsupported.mp3")
        try Data("Not an MPEG stream".utf8).write(to: unsupported)
        let before = f.document.store.model
        f.editor.importer.commit(try await review(f, files: [f.file, unsupported]))
        try await wait { f.editor.importer.processing == nil }
        #expect(f.editor.importer.error != nil)
        #expect(f.document.store.model == before && f.editor.importer.completedClips.isEmpty)
        #expect(try await f.access.allRecords().isEmpty)
    }

    @Test func nativeEditorCapturePrecedesImportSnapshotAndLaterChangesRefusePublication() async throws {
        let f = try await fixture()
        defer { f.close() }
        let clip = try await imported(f)
        let slot = try MixerHostedTests().appleSlot()
        try #require(f.document.store.apply("Synthetic insert") { model throws(DomainError) in
            try model.settingAudioTrackMix(.init(track: clip.clip.track, inserts: [slot]), in: f.model.episodeID)
        })
        _ = try await f.model.mixer.prepare(programFrames: 0..<2048)
        try await f.model.mixer.beginEditorObservation(coalescing: "f5.native")
        let processor = try #require(f.model.mixer.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first { $0.writable && $0.minimum < $0.maximum })
        try await processor.setParameter(slot: slot.id, address: parameter.address,
                                        value: parameter.value == parameter.minimum ? parameter.maximum : parameter.minimum)
        let other = f.folder.appendingPathComponent("other.wav")
        try Self.wave(rate: 48_000, frames: 4800).write(to: other)
        let review = try await review(f, files: [other])
        #expect(f.document.store.model.episode(f.model.episodeID)?.mix?.audioTracks?.first?.inserts.first?.documentState != nil)
        #expect(f.model.mixer.processor == nil)
        let captured = f.document.store.model
        f.document.store.replaceLoadedModel(captured)
        f.editor.importer.commit(review)
        try await wait { f.editor.importer.processing == nil }
        #expect(f.document.store.model == captured)
        #expect(f.editor.importer.error?.contains("changed") == true)
    }

    @Test func productionChoiceSurvivesPauseSeekLayoutSelectionAndProgramOutro() async throws {
        let f = try await fixture()
        defer { f.close() }
        let clip = try await imported(f)
        f.editor.select(clip.clip.id)
        f.editor.moveSelected(start: "2", track: clip.clip.track)
        f.model.waveformPlayheadSeconds = 2
        f.model.playProductionMix()
        try await wait { f.model.isAuditioning || !f.model.isPreparingAudition }
        try #require(f.model.isAuditioning, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        try #require(f.model.listening.usesProductionMix)
        #expect(f.model.listeningMode == .productionMix)
        f.model.pauseEnabledTracks()
        f.model.seekEnabledTracks(to: 2.1)
        for layout in AlignmentWaveformLayout.allCases { f.model.listening.workspace.layout = layout }
        f.editor.select(clip.clip.id)
        #expect(f.model.listening.usesProductionMix && !f.model.canStopAudition)
        f.model.playTransport()
        try await wait { f.model.isAuditioning || !f.model.isPreparingAudition }
        try #require(f.model.isAuditioning, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        #expect(f.model.listeningMode == .productionMix)
        f.model.stopEnabledTracks()
        #expect(f.model.listening.usesProductionMix)
        f.model.selectSourceAudition()
        #expect(!f.model.listening.usesProductionMix)
    }

    @Test func droppedSequentialBatchUsesReviewOrderAndExactDurationsWithOneUndo() async throws {
        let f = try await fixture()
        defer { f.close() }
        let second = f.folder.appendingPathComponent("short.wav")
        try Self.wave(rate: 44_100, frames: 441).write(to: second)
        let before = f.document.store.model
        f.editor.importer.scan([f.file, second], in: f.owner.state,
            destination: .init(frame: 123_457, track: .newTrack))
        try await wait { f.editor.importer.review != nil || f.editor.importer.error != nil }
        var review = try #require(f.editor.importer.review)
        #expect(review.layout == .sequential && review.track == .newTrack)
        #expect(try AudioClipEditorModel.programFrame(review.programSeconds) == 123_457)
        #expect(try await f.access.allRecords().isEmpty && f.document.store.model == before)
        let last = try #require(review.order.last)
        review.move(last, by: -1)
        f.editor.importer.commit(review)
        try await wait { f.editor.importer.processing == nil }
        try #require(f.editor.importer.error == nil, Comment(rawValue: f.editor.importer.error ?? ""))
        f.editor.refresh()
        let clips = try #require(f.editor.composition?.clips)
        #expect(clips.map(\.programFrames) == [123_457..<123_937, 123_937..<171_937])
        #expect(f.editor.episode?.source(clips[0].clip.source)?.displayNameHint == second.lastPathComponent)
        #expect(f.document.undoManager?.undoActionName == "Add Audio")
        let after = f.document.store.model
        f.document.undoManager?.undo()
        #expect(f.document.store.model == before)
        f.document.undoManager?.redo()
        #expect(f.document.store.model == after)
        try await MixerHostedTests().save(f.document)
        let saved = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(
            Data(contentsOf: #require(f.document.fileURL))).payload
        #expect(saved == after)
        let recipe = try await f.runtime.mixerRecipe(model: after, episode: f.model.episodeID,
            programFrames: 123_457..<171_937)
        #expect(recipe.composition?.programFrames == 123_457..<171_937)
    }

    @Test func droppedSameEpisodeAssetAndNewFileShareOneBatchWithoutDuplicateAccess() async throws {
        let f = try await fixture()
        defer { f.close() }
        let first = try await imported(f)
        let original = try Data(contentsOf: f.file)
        let record = try #require(try await f.access.record(for: .init(showID: f.document.store.model.show.id,
                                                                     sourceID: first.clip.source)))
        let fresh = f.folder.appendingPathComponent("fresh.wav")
        try Self.wave(rate: 48_000, frames: 480).write(to: fresh)
        let before = f.document.store.model
        f.editor.importer.scan([f.file, fresh], in: f.owner.state,
            destination: .init(frame: 96_000, track: .existing(first.clip.track)))
        try await wait { f.editor.importer.review != nil || f.editor.importer.error != nil }
        let review = try #require(f.editor.importer.review)
        #expect(review.track == .existing(first.clip.track))
        #expect(review.choices[try #require(review.order.first)] == .reuse(source: first.clip.source))
        f.editor.importer.commit(review)
        try await wait { f.editor.importer.processing == nil }
        try #require(f.editor.importer.error == nil, Comment(rawValue: f.editor.importer.error ?? ""))
        f.editor.refresh()
        #expect(f.editor.episode?.sources.count == 2 && f.editor.episode?.audioArrangement?.assets.count == 2)
        #expect(try await f.access.allRecords().count == 2)
        #expect(try await f.access.record(for: record.key) == record)
        #expect(f.editor.composition?.clips.map(\.programFrames.lowerBound) == [0, 96_000, 144_000])
        #expect(f.editor.composition?.clips.prefix(2).map(\.clip.source) == [first.clip.source, first.clip.source])
        f.document.undoManager?.undo()
        #expect(f.document.store.model == before)
        f.document.undoManager?.redo()
        #expect(try Data(contentsOf: f.file) == original)
    }

    @Test func droppedAssetCrossEpisodeCopyKeepsOriginAndIndependentProductionRoutes() async throws {
        let f = try await fixture()
        var mayClose = true
        defer { if mayClose { f.close() } }
        let first = try await imported(f)
        let originalBytes = try Data(contentsOf: f.file)
        let firstEpisodeID = f.model.episodeID
        let originRecord = try #require(try await f.access.record(for: .init(showID: f.document.store.model.show.id,
                                                                           sourceID: first.clip.source)))
        let second = Episode(title: "Second synthetic episode")
        try #require(f.document.store.apply("Synthetic episode") { model throws(DomainError) in
            var next = model
            next.episodes.append(second)
            return next
        })
        let slot = try MixerHostedTests().appleSlot()
        try #require(f.document.store.apply("Synthetic origin insert") { model throws(DomainError) in
            try model.settingAudioTrackMix(.init(track: first.clip.track, inserts: [slot]), in: firstEpisodeID)
        })
        let model = EpisodeAlignmentModel(document: f.document, episodeID: second.id, runtime: f.runtime)
        let state = ShowWindowState(store: f.document.store, episodeID: second.id)
        state.alignmentModel = model
        state.select(.alignment)
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        if let window = owner.window { state.attach(to: window) }
        defer { model.suspend(); owner.close() }
        model.audioEditor.importer.sourceEngineForTesting = f.engine
        model.load()
        let outcome: Result<Void, any Error>
        do {
            _ = try await f.model.mixer.prepare(programFrames: 0..<2048)
            try await f.model.mixer.beginEditorObservation(coalescing: "f6.origin")
            let originProcessor = try #require(f.model.mixer.processor)
            let firstEpisode = try #require(f.editor.episode)
            model.audioEditor.importer.scan([f.file], in: state, destination: .init(frame: 24_000, track: .newTrack))
            try await wait { model.audioEditor.importer.review != nil || model.audioEditor.importer.error != nil }
            let review = try #require(model.audioEditor.importer.review)
            guard case .copy = review.choices[try #require(review.order.first)] else {
                throw StagedAudioImportCoordinator.Refusal(
                    "Cross-episode reuse must be explicitly reviewed as a new episode-owned reference.")
            }
            model.audioEditor.importer.commit(review)
            try await wait { model.audioEditor.importer.processing == nil }
            try #require(model.audioEditor.importer.error == nil, Comment(rawValue: model.audioEditor.importer.error ?? ""))
            model.audioEditor.refresh()
            let copied = try #require(model.audioEditor.composition?.clips.first)
            #expect(copied.clip.source != first.clip.source && copied.clip.id != first.clip.id)
            #expect(f.document.store.model.episode(firstEpisode.id) == firstEpisode)
            #expect(f.model.mixer.processor === originProcessor && f.model.mixer.editorObservationKey == "f6.origin")
            #expect(try await f.access.record(for: originRecord.key) == originRecord)
            #expect(try await f.access.allRecords().count == 2)
            let singleModel = f.document.store.model
            let singleRecipe = try await f.runtime.mixerRecipe(model: singleModel, episode: second.id,
                programFrames: 24_000..<24_480)
            let singlePCM = try await f.runtime.productionPCM(recipe: singleRecipe, model: singleModel,
                frames: 24_000..<24_480)
            model.audioEditor.select(copied.clip.id)
            model.audioEditor.duplicateSelected()
            let composition = try #require(model.audioEditor.composition)
            let recipe = try await f.runtime.mixerRecipe(model: f.document.store.model, episode: second.id,
                programFrames: 24_000..<24_480)
            let pcm = try await f.runtime.productionPCM(recipe: recipe, model: f.document.store.model, frames: 24_000..<24_480)
            let trackPCM = try #require(pcm.audioTracks[copied.clip.track])
            #expect(composition.clips.count == 2 && trackPCM.flatMap { $0 }.contains { $0 != 0 })
            let singleTrack = try #require(singlePCM.audioTracks[copied.clip.track])
            for channel in trackPCM.indices {
                #expect(zip(trackPCM[channel], singleTrack[channel]).allSatisfy { abs($0 - 2 * $1) < 0.000_001 })
            }
            #expect(Set(composition.clips.map(\.clip.source)) == [copied.clip.source])
            #expect(composition.programFrames == 24_000..<72_000)
            model.audioEditor.moveSelected(start: "2", track: copied.clip.track)
            #expect(model.audioEditor.composition?.clips.map(\.programFrames.lowerBound) == [24_000, 96_000])
            #expect(f.document.store.model.episode(firstEpisode.id) == firstEpisode)
            try await MixerHostedTests().save(f.document)
            #expect(try Data(contentsOf: f.file) == originalBytes)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        do {
            try await f.model.mixer.endEditorObservation()
        } catch {
            mayClose = false
            Issue.record("Native editor teardown failed; synthetic fixture preserved at \(f.folder.path): \(error)")
            throw error
        }
        try outcome.get()
    }

    @Test func droppedLocationsCancelPromptlyAndRefuseClosedOrABADestinations() async throws {
        for scenario in 0..<3 {
            let f = try await fixture()
            let transfer = DeferredAudioDropLocation()
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) {
                transfer.begin($0)
            }
            let before = f.document.store.model
            #expect(f.editor.importer.receiveDrop([provider], in: f.owner.state,
                destination: .init(frame: 12_345, track: .newTrack)))
            try await wait { transfer.started }
            if scenario == 0 {
                f.document.store.replaceLoadedModel(before)
            } else if scenario == 1 {
                f.owner.close()
            } else {
                f.editor.importer.cancel()
                f.editor.importer.scan([f.file], in: f.owner.state,
                    destination: .init(frame: 96_000, track: .newTrack))
                try await wait { f.editor.importer.review != nil || f.editor.importer.error != nil }
            }
            let replacement = f.editor.importer.review?.id
            transfer.finish(f.file)
            try await wait { f.editor.importer.processing == nil }
            if scenario == 2 {
                #expect(f.editor.importer.review?.id == replacement && replacement != nil)
                #expect(try AudioClipEditorModel.programFrame(
                    #require(f.editor.importer.review?.programSeconds)) == 96_000)
            } else {
                #expect(f.editor.importer.review == nil)
            }
            #expect(f.document.store.model == before && f.editor.importer.completedClips.isEmpty)
            #expect(try await f.access.allRecords().isEmpty)
            f.close()
        }
    }

    @Test func locationLoaderCancellationDoesNotWaitForAnUnresponsiveProvider() async throws {
        let transfer = DeferredAudioDropLocation(), provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) {
            transfer.begin($0)
        }
        let loading = Task { try await AudioFileLocationLoader.load(from: provider) }
        try await wait { transfer.started }
        loading.cancel()
        await #expect(throws: CancellationError.self) { try await loading.value }
        transfer.finish(URL(filePath: "/synthetic/late-location.wav"))
    }

    @Test func mixedReusedNewAndUnsupportedBatchLeavesTheExistingEpisodeUntouched() async throws {
        let f = try await fixture()
        defer { f.close() }
        _ = try await imported(f)
        let fresh = f.folder.appendingPathComponent("new-before-failure.wav")
        try Self.wave(rate: 48_000, frames: 480).write(to: fresh)
        let unsupported = f.folder.appendingPathComponent("unsupported-mixed.mp3")
        try Data("Synthetic unsupported MPEG stream".utf8).write(to: unsupported)
        let before = f.document.store.model, records = try await f.access.allRecords()
        f.editor.importer.scan([fresh, f.file, unsupported], in: f.owner.state,
            destination: .init(frame: 48_000, track: .newTrack))
        try await wait { f.editor.importer.review != nil || f.editor.importer.error != nil }
        let review = try #require(f.editor.importer.review)
        #expect(review.selected.count == 3)
        f.editor.importer.commit(review)
        try await wait { f.editor.importer.processing == nil }
        #expect(f.editor.importer.error != nil && f.editor.importer.completedClips.isEmpty)
        #expect(f.document.store.model == before)
        #expect(try await f.access.allRecords() == records)
    }

    static func wave(rate: Int, frames: Int, explicitLayout: Bool = false) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32((explicitLayout ? 60 : 36) + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(explicitLayout ? 40 : 16))
        append(UInt16(explicitLayout ? 0xfffe : 1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        if explicitLayout {
            append(UInt16(22)); append(UInt16(16)); append(UInt32(3))
            data.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
        }
        data.append(contentsOf: "data".utf8); append(UInt32(frames * 4))
        for frame in 0..<frames {
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 330) * 12_000))
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 517) * 7_000))
        }
        return data
    }
}

@MainActor private final class AudioImportGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class DeferredAudioDropLocation: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?, (any Error)?) -> Void)?
    var started: Bool { lock.withLock { completion != nil } }
    func begin(_ completion: @escaping (Data?, (any Error)?) -> Void) -> Progress {
        lock.withLock { self.completion = completion }
        return Progress(totalUnitCount: 1)
    }
    func finish(_ url: URL) {
        let callback = lock.withLock {
            defer { completion = nil }
            return completion
        }
        callback?(url.dataRepresentation, nil)
    }
}
