import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
import WWCore
import WWEpisodeSetup
@testable import WaveWrangler

private final class DropDownloadPreference: SourceDownloadPreference {
    var downloadsAutomatically = false
}

@MainActor
@Suite("Source imports and recorder-group drag routing", .serialized)
struct SourceDragDropHostedTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func load<T: Transferable>(_ type: T.Type, from provider: NSItemProvider) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: type) { continuation.resume(with: $0) }
        }
    }

    private func makeModel(_ model: ShowDocumentModel, scan: ImportScan? = nil)
        -> (ShowDocument, EpisodeSetupModel, InMemorySourceSetupEngine) {
        let document = ShowDocument()
        document.undoManager = UndoManager()
        document.store.replaceLoadedModel(model)
        let engine = InMemorySourceSetupEngine(scanResult: scan ?? ImportScan(
            candidates: [], chosenDisplayName: "Synthetic", folderCount: 0, fileCount: 0))
        let setup = EpisodeSetupModel(store: document.store, episodeID: model.episodes[0].id,
            engine: engine, preference: DropDownloadPreference())
        return (document, setup, engine)
    }

    @Test func transferRepresentationsDecodeLocationsAndOwnedIDsWithoutFileContents() async throws {
        let drag = SetupSourceDrag(showID: ShowID(), episodeID: EpisodeID(), sourceID: SourceID())
        let provider = NSItemProvider()
        provider.register(drag)
        let received = try await load(SetupSourceDrop.self, from: provider)
        guard case let .recording(value) = received else {
            Issue.record("Recording IDs must not be interpreted as a file import")
            return
        }
        #expect(value.showID == drag.showID && value.episodeID == drag.episodeID && value.sourceID == drag.sourceID)
        let url = URL(filePath: "/synthetic/not-opened/recording.wav")
        let file = NSItemProvider()
        file.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        let location = try await load(SetupFileDrop.self, from: file)
        #expect(location.url == url)
        let rowLocation = try await load(SetupSourceDrop.self, from: file)
        guard case let .file(value) = rowLocation else {
            Issue.record("File locations must not be interpreted as existing recording IDs")
            return
        }
        #expect(value.url == url)
        let nativeURL = try await load(SetupFileDrop.self, from: NSItemProvider(object: url as NSURL))
        #expect(nativeURL.url == url)
    }

    @Test func fileAndFolderDropsOpenReviewAndCancelChangesNothing() async throws {
        let episode = Episode(title: "Synthetic import")
        let original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let scan = ImportScan(candidates: [
            .init(details: .init(name: "one.wav"), kind: .recording(typeFromNameOnly: true)),
            .init(details: .init(name: "two.aiff"), kind: .recording(typeFromNameOnly: true)),
        ], chosenDisplayName: "2 items", folderCount: 1, fileCount: 2)
        let (document, setup, engine) = makeModel(original, scan: scan)
        defer { setup.stopObserving(); document.close() }
        #expect(setup.importDroppedURLs([
            URL(filePath: "/synthetic/one.wav"), URL(filePath: "/synthetic/folder", directoryHint: .isDirectory),
        ]))
        #expect(!setup.canImportSources)
        try await wait { !setup.isScanning && setup.sheet != nil }
        guard case let .importReview(review) = setup.sheet else {
            Issue.record("Drops must enter the existing import review rather than importing immediately")
            return
        }
        #expect(engine.calls.contains(.scan(count: 2)))
        #expect(document.store.model == original)
        #expect(!setup.importDroppedURLs([URL(filePath: "/synthetic/another.wav")]))
        setup.cancelImport(review)
        #expect(document.store.model == original && setup.sheet == nil)
        #expect(!engine.calls.contains { if case .commitImport = $0 { true } else { false } })
    }

    @Test func aNewReviewedGroupCommitsOnlyWithImportAndSharesItsUndoStep() async throws {
        let episode = Episode(title: "Synthetic import")
        let original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let scan = ImportScan(candidates: [
            .init(details: .init(name: "one.wav"), kind: .recording(typeFromNameOnly: true)),
        ], chosenDisplayName: "one.wav", folderCount: 0, fileCount: 1)
        let (document, setup, engine) = makeModel(original, scan: scan)
        defer { setup.stopObserving(); document.close() }
        var review = ImportReview(scan: scan, episodeTitle: episode.title, knownSpeakerNames: [])
        let row = try #require(review.rows.first)
        review.setGroup(row.id, "Rodecaster")
        #expect(review.groupOptions(existing: []).contains("Rodecaster"))
        #expect(document.store.model == original)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        setup.commitImport(review)
        undo.endUndoGrouping()
        let imported = document.store.model
        let group = try #require(imported.episodes[0].recorderGroups.first)
        #expect(group.name == "Rodecaster" && imported.episodes[0].sources.count == 1)
        #expect(imported.episodes[0].sources[0].placement.recorderGroupID == group.id)
        try await wait { engine.calls.contains(.commitImport(count: 1)) }
        undo.undo()
        #expect(document.store.model == original)
        undo.redo()
        #expect(document.store.model == imported)
    }

    @Test func regroupingPreservesEpochSpeakerChannelAndRoleAndIsUndoable() async throws {
        let a = RecorderGroup(name: "First", epochs: (1...3).map { RecordingEpoch(label: "\($0)") })
        let b = RecorderGroup(name: "Second")
        let source = SourceRecord(displayNameHint: "recording.wav",
            placement: SourcePlacement(recorderGroupID: a.id, epochID: a.epochs[2].id))
        let target = SourceRecord(displayNameHint: "target.wav", placement: SourcePlacement(recorderGroupID: b.id))
        let episode = Episode(title: "Synthetic", recorderGroups: [a, b], sources: [source, target])
        let speaker = Speaker(name: "Synthetic speaker")
        var original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        original = try original.addingSpeaker(speaker, toEpisode: episode.id)
        original = try original.assigningSpeaker(speaker.id, toSource: source.id, in: episode.id)
        original = try original.settingStatedChannel(0, forSource: source.id, in: episode.id)
        original = try original.usingAsPrimary(ChannelReference(sourceID: source.id, channel: .known(0)),
            for: speaker.id, in: episode.id)
        let (document, setup, _) = makeModel(original)
        defer { setup.stopObserving(); document.close() }
        setup.collapsedRows = [.group(b.id)]
        let drag = SetupSourceDrag(showID: original.show.id, episodeID: episode.id, sourceID: source.id)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(setup.acceptSourceRowDrop([.recording(drag), .recording(drag)], on: .source(target.id)))
        undo.endUndoGrouping()
        let moved = document.store.model
        let actual = try #require(moved.episodes[0].source(source.id))
        var expected = try #require(original.episodes[0].source(source.id))
        expected.placement.recorderGroupID = b.id
        expected.placement.epochID = actual.placement.epochID
        #expect(actual == expected)
        #expect(moved.episodes[0].epochNumber(of: source.id) == 3)
        #expect(moved.episodes[0].speakerAssignments == original.episodes[0].speakerAssignments)
        #expect(setup.selection == [.source(source.id)] && !setup.collapsedRows.contains(.group(b.id)))
        undo.undo()
        #expect(document.store.model == original)
        undo.redo()
        #expect(document.store.model == moved)
        #expect(setup.acceptSourceRowDrop([.recording(drag)], on: .group(nil)))
        #expect(document.store.model.episodes[0].source(source.id)?.placement.recorderGroupID == nil)
    }

    @Test func foreignMissingAndMixedDragsAreRejectedAtomically() throws {
        let source = SourceRecord(displayNameHint: "one.wav")
        let group = RecorderGroup(name: "Target")
        let episode = Episode(title: "Synthetic", recorderGroups: [group], sources: [source])
        let original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let (document, setup, engine) = makeModel(original)
        defer { setup.stopObserving(); document.close() }
        let valid = SetupSourceDrag(showID: original.show.id, episodeID: episode.id, sourceID: source.id)
        for invalid in [
            SetupSourceDrag(showID: ShowID(), episodeID: episode.id, sourceID: source.id),
            SetupSourceDrag(showID: original.show.id, episodeID: EpisodeID(), sourceID: source.id),
            SetupSourceDrag(showID: original.show.id, episodeID: episode.id, sourceID: SourceID()),
        ] {
            #expect(!setup.acceptSourceRowDrop([.recording(valid), .recording(invalid)], on: .group(group.id)))
            #expect(document.store.model == original && setup.message != nil)
        }
        #expect(!setup.acceptSourceRowDrop([.recording(valid), .file(.init(url: URL(filePath: "/synthetic/new.wav")))],
            on: .group(group.id)))
        #expect(!setup.acceptSourceRowDrop([.recording(valid)], on: .group(RecorderGroupID())))
        #expect(!setup.importDroppedURLs([try #require(URL(string: "https://example.invalid/recording.wav"))]))
        #expect(document.store.model == original && engine.calls.isEmpty)
    }
}
