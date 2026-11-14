import AppKit
import Darwin
import Foundation
import Synchronization
import Testing
import WWCore
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Demand-driven native show catalogs", .serialized)
struct LazyCatalogHostedTests {
    private func fixture() throws -> (ShowDocument, URL, ShowDocumentModel) {
        let root = FileManager.default.temporaryDirectory.appending(path: "LazyCatalog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let model = ShowDocumentModel(show: Show(title: "Generated catalog"),
            episodes: (1...3).map { (number: Int) in Episode(title: "Episode \(number)", number: number) })
        let url = root.appending(path: "Generated.wwshow")
        try LocalFileOperations().writeNew(ShowCatalogCoder().encode(ShowCatalog(model), revision: 1), to: url)
        return (try open(url), root, model)
    }

    private func open(_ url: URL) throws -> ShowDocument {
        let document = ShowDocument()
        document.fileURL = url
        document.fileType = DocumentTypes.show
        try document.read(from: url, ofType: DocumentTypes.show)
        document.undoManager?.groupsByEvent = false
        NSDocumentController.shared.addDocument(document)
        return document
    }

    private func save(_ document: ShowDocument) async throws {
        let url = try #require(document.fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: DocumentTypes.show, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func finish(_ document: ShowDocument, root: URL) throws {
        document.updateChangeCount(.changeCleared)
        document.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func catalogOnlyOpenAndSavePreserveEveryUnloadedEpisode() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let before = try #require(document.verifiedCatalog)
        #expect(store.episodeSummaries.count == 3)
        #expect(store.residentModel.episodes.isEmpty)
        #expect(store.librarySummary.episodes?.count == 3)
        try #require(store.apply("Rename Show") { model throws(DomainError) in
            try model.renamingShow(to: "Catalog-only edit")
        })
        try await save(document)
        let after = try ShowCatalogCoder().decode(LocalFileOperations().read(try #require(document.fileURL))).payload
        #expect(after.episodes == before.episodes)
        #expect(store.residentModel.episodes.isEmpty)
        var expected = original
        expected.show.title = "Catalog-only edit"
        let matches = try after.materializedModel() == expected
        #expect(matches)
    }

    @Test func sharedWindowPinsAndArchivedUndoDoNotRetainVisitedPayloads() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let id = original.episodes[0].id
        let first = ShowWindowState(store: store, episodeID: id)
        let second = ShowWindowState(store: store, episodeID: id)
        try await store.ensureEpisodeLoaded(id)
        try #require(store.apply("Rename Episode") { model throws(DomainError) in
            try model.renamingEpisode(id, to: "Edited episode")
        })
        first.reviewWindowDidClose()
        #expect(store.residentModel.episode(id)?.title == "Edited episode")
        second.reviewWindowDidClose()
        try await wait { store.residentRevisionCount == 0 }
        #expect(store.residentModel.episodes.isEmpty)
        let reopened = ShowWindowState(store: store, episodeID: id)
        defer { reopened.reviewWindowDidClose() }
        try await store.ensureEpisodeLoaded(id)
        #expect(store.residentModel.episode(id)?.title == "Edited episode")
        document.undoManager?.undo()
        try await store.ensureEpisodeLoaded(id)
        #expect(store.residentModel.episode(id)?.title == original.episodes[0].title)
        document.undoManager?.redo()
        try await store.ensureEpisodeLoaded(id)
        #expect(store.residentModel.episode(id)?.title == "Edited episode")
        try await save(document)
        let saved = try #require(document.verifiedCatalog)
        let unvisitedMatches = try saved.episodes.dropFirst().map { try $0.load(in: saved.header) }
            == Array(original.episodes.dropFirst())
        #expect(unvisitedMatches)
    }

    @Test func explicitUnpinnedLoadDoesNotWaitForAnEditorOrRetainASavedCache() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let id = original.episodes[0].id
        try await document.store.ensureEpisodeLoaded(id)
        let episode = document.store.residentModel.episode(id)
        #expect(episode == original.episodes[0])
        #expect(document.verifiedModel?.episodes.isEmpty == true)
        try #require(document.store.apply("Rename Show") { model throws(DomainError) in
            try model.renamingShow(to: "Unpinned payload is evictable")
        })
        try await wait { document.store.residentRevisionCount == 0 }
        #expect(document.store.residentModel.episodes.isEmpty)
    }

    @Test func unloadedDeletionReorderAndUndoNeverCreateEmptyEpisodeValues() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let ids = original.episodes.map(\.id)
        try #require(store.moveEpisode(ids[2], by: -1))
        #expect(store.episodeSummaries.map(\.id) == [ids[0], ids[2], ids[1]])
        try #require(store.removeEpisode(ids[0]))
        #expect(!store.containsEpisode(ids[0]))
        document.undoManager?.undo()
        #expect(store.containsEpisode(ids[0]))
        #expect(store.residentModel.episodes.isEmpty)
        document.undoManager?.undo()
        #expect(store.episodeSummaries.map(\.id) == ids)
        try await save(document)
        let matches = try #require(document.verifiedCatalog).materializedModel() == original
        #expect(matches)
    }

    @Test(arguments: [false, true])
    func completeCheckpointRestorePreservesMembershipOrderUndoAndReopen(removingAll: Bool) async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        try #require(PersistenceEnvironment.isUITestRun)
        let store = document.store
        #expect(store.residentModel.episodes.isEmpty)
        var candidate = original
        candidate.episodes = removingAll ? [] : [original.episodes[2], original.episodes[0]]
        let url = try #require(document.fileURL)
        let snapshot = try ShowPackageCoder().encodeDocument(
            candidate, revision: document.revision + 1, publicationID: UUID()).data
        try PersistenceEnvironment.recovery.writeEditCheckpoint(
            snapshot: snapshot, base: RevisionFingerprint(of: LocalFileOperations().read(url)),
            schemaVersion: candidate.schemaVersion, for: document.documentKey)
        try PersistenceEnvironment.recovery.setAsideEditCheckpoints(for: document.documentKey)
        document.refreshEditCheckpointOffer()
        let offered = try #require(document.status.editCheckpointOffer?.candidate?.url)
        defer {
            do {
                if FileManager.default.fileExists(atPath: offered.path) {
                    try PersistenceEnvironment.recovery.discardOfferedEditCheckpoints(
                        [offered], for: document.documentKey)
                }
            } catch { Issue.record(error) }
        }
        document.restoreOfferedEditCheckpoint()
        #expect(document.isEditCheckpointRestoreInEffect)
        #expect(document.isDocumentEdited)
        #expect(store.episodeSummaries.map(\.id) == candidate.episodes.map(\.id))
        try await wait { store.residentRevisionCount == 0 }
        let restoredMatches = try store.captureCatalog().resolved().materializedModel() == candidate
        #expect(restoredMatches)
        document.undoManager?.undo()
        #expect(!document.isEditCheckpointRestoreInEffect)
        #expect(store.episodeSummaries.map(\.id) == original.episodes.map(\.id))
        let undoneMatches = try store.captureCatalog().resolved().materializedModel() == original
        #expect(undoneMatches)
        document.undoManager?.redo()
        #expect(document.isEditCheckpointRestoreInEffect)
        #expect(store.episodeSummaries.map(\.id) == candidate.episodes.map(\.id))
        try await save(document)
        let savedMatches = try #require(document.verifiedCatalog).materializedModel() == candidate
        #expect(savedMatches)
        document.close()
        let reopened = try open(url)
        defer { reopened.updateChangeCount(.changeCleared); reopened.close() }
        #expect(reopened.store.residentModel.episodes.isEmpty)
        #expect(reopened.store.episodeSummaries.map(\.id) == candidate.episodes.map(\.id))
        let reopenedMatches = try #require(reopened.verifiedCatalog).materializedModel() == candidate
        #expect(reopenedMatches)
    }

    @Test func episodeScopedSpeakerRemovalPreservesReferencesInUnloadedEpisodes() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let speaker = Speaker(name: "Shared generated speaker")
        var model = original
        model.speakers = [speaker]
        for index in 0...1 { model.episodes[index].speakerAssignments = [.init(speakerID: speaker.id)] }
        document.store.replaceLoadedCatalog(try ShowCatalog(model))
        let id = model.episodes[0].id
        let window = ShowWindowState(store: document.store, episodeID: id)
        defer { window.reviewWindowDidClose() }
        try await document.store.ensureEpisodeLoaded(id)
        try #require(document.store.apply("Remove Speaker") { model throws(DomainError) in
            try model.removingSpeaker(speaker.id, fromEpisode: id)
        })
        #expect(document.store.header.speakers.map(\.id) == [speaker.id])
        let saved = try document.store.captureCatalog().resolved().materializedModel()
        #expect(saved.episodes[0].speakerAssignments.isEmpty)
        #expect(saved.episodes[1].speakerAssignments.map(\.speakerID) == [speaker.id])
    }

    @Test func pendingHistoricalRevisionsApplyBackpressureThenArchiveAndRelease() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let id = original.episodes[0].id
        let window = ShowWindowState(store: store, episodeID: id)
        defer { window.reviewWindowDidClose() }
        try await store.ensureEpisodeLoaded(id)
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        ShowPersistenceLane.enqueue { entered.withLock { $0 = true }; gate.wait() }
        defer { gate.signal() }
        try await wait { entered.withLock { $0 } }
        for number in 1...5 {
            try #require(store.apply("Rename Episode") { model throws(DomainError) in
                try model.renamingEpisode(id, to: "Edit \(number)")
            })
        }
        #expect(store.residentRevisionCount <= 5)
        #expect(!store.apply("Refused Until Archived") { model throws(DomainError) in
            try model.renamingEpisode(id, to: "Must not apply")
        })
        #expect(store.residentModel.episode(id)?.title == "Edit 5")
        #expect(store.lastError != nil)
        gate.signal()
        try await wait { store.residentRevisionCount == 1 }
        try #require(store.apply("Edit After Archival") { model throws(DomainError) in
            try model.renamingEpisode(id, to: "Archival caught up")
        })
    }

    @Test func deletingAnEpisodeDuringAQueuedLoadRejectsItsStaleResult() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        ShowPersistenceLane.enqueue { entered.withLock { $0 = true }; gate.wait() }
        defer { gate.signal() }
        try await wait { entered.withLock { $0 } }
        let id = original.episodes[0].id
        let window = ShowWindowState(store: store, episodeID: id)
        defer { window.reviewWindowDidClose() }
        try await wait { store.loadingEpisodes.contains(id) }
        try #require(store.removeEpisode(id))
        gate.signal()
        try await ShowCatalogWork.perform {}
        #expect(!store.containsEpisode(id))
        #expect(store.residentModel.episode(id) == nil)
        document.undoManager?.undo()
        try await store.ensureEpisodeLoaded(id)
        #expect(store.residentModel.episode(id)?.title == original.episodes[0].title)
    }

    @Test func closedResidencyCancelsQueuedLoadsAndRefusesNewLoads() async throws {
        let (document, root, original) = try fixture()
        defer { do { try finish(document, root: root) } catch { Issue.record(error) } }
        let store = document.store
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        ShowPersistenceLane.enqueue { entered.withLock { $0 = true }; gate.wait() }
        defer { gate.signal() }
        try await wait { entered.withLock { $0 } }
        let id = original.episodes[0].id
        let window = ShowWindowState(store: store, episodeID: id)
        defer { window.reviewWindowDidClose() }
        try await wait { store.loadingEpisodes.contains(id) }
        store.closeResidency()
        gate.signal()
        try await ShowCatalogWork.perform {}
        await #expect(throws: CancellationError.self) { try await store.ensureEpisodeLoaded(id) }
        #expect(store.loadingEpisodes.isEmpty)
        #expect(store.residentModel.episodes.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LAZY_CATALOG_FIXTURE"] != nil))
    func nativeDocumentStoreMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = URL(filePath: try #require(environment["WW_LAZY_CATALOG_FIXTURE"]))
        let output = URL(filePath: try #require(environment["WW_LAZY_CATALOG_RESULT"]))
        let baseline = try memory()
        let start = ContinuousClock.now
        let document = try autoreleasepool { try open(url) }
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let openSeconds = seconds(.now - start)
        let catalog = try #require(document.verifiedCatalog)
        let count = document.store.episodeSummaries.count
        #expect(document.store.residentModel.episodes.isEmpty)
        var result: [String: Any] = ["scope": "hostedApplicationNativeDocumentStoreWithoutEditorLayoutOrAudio",
            "episodes": count, "baseline": baseline, "catalogRetained": try memory(), "catalogOpenSeconds": openSeconds,
            "peakScope": "getrusage process-lifetime maximum RSS, not phase-local or footprint peak"]
        let id = try #require(catalog.episodes.first?.id)
        let episodeStart = ContinuousClock.now
        let state = ShowWindowState(store: document.store, episodeID: id)
        defer { state.reviewWindowDidClose() }
        try await document.store.ensureEpisodeLoaded(id)
        let episodeSeconds = seconds(.now - episodeStart)
        let loaded = try #require(document.store.residentModel.episode(id))
        let currentWords = loaded.cleanup?.transcripts.reduce(0) { $0 + $1.words.count } ?? 0
        let historyWords = loaded.cleanup?.transcriptHistory?.reduce(0) { $0 + $1.words.count } ?? 0
        #expect(currentWords == 8_000 && historyWords == 8_000)
        #expect(document.store.residentModel.episodes.count == 1)
        result["currentWordsPerEpisode"] = currentWords
        result["historicalWordsPerEpisode"] = historyWords
        result["artworkBytes"] = catalog.header.show.publication?.artwork?.image?.data.count
        result["episodeRetained"] = try memory()
        result["episodeOpenSeconds"] = episodeSeconds
        let saveStart = ContinuousClock.now
        try #require(document.store.apply("Rename Episode") { model throws(DomainError) in
            try model.renamingEpisode(id, to: "Native memory save")
        })
        try await save(document)
        result["saveSeconds"] = seconds(.now - saveStart)
        result["saveRetained"] = try memory()
        let after = try #require(document.verifiedCatalog)
        #expect(Array(after.episodes.dropFirst()) == Array(catalog.episodes.dropFirst()))
        #expect(document.store.residentModel.episodes.count == 1)
        result["unvisitedStoredComponentsPreserved"] = true
        result["residentEpisodes"] = document.store.residentModel.episodes.count
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: output, options: .withoutOverwriting)
        print("LAZY_CATALOG_NATIVE \(String(decoding: bytes, as: UTF8.self))")
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func memory() throws -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(status == KERN_SUCCESS)
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return ["residentBytes": info.resident_size, "physicalFootprintBytes": info.phys_footprint,
            "processPeakResidentBytes": UInt64(usage.ru_maxrss)]
    }
}
