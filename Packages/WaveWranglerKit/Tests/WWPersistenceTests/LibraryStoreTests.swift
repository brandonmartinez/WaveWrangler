import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// A library store over temp folders with path-based bookmarks.
struct LibraryRig {
    let dir: TempDirectory
    let settings = InMemoryLibrarySettings()
    let container: URL
    let recovery: RecoveryStore
    let cacheURL: URL

    init(_ label: String = "lib") {
        dir = TempDirectory(label)
        container = dir.sub("Container")
        recovery = RecoveryStore(root: dir.sub("Recovery"))
        cacheURL = dir.sub("Caches").appending(path: "index.json")
    }

    func store() -> LibraryStore {
        LibraryStore(containerFolder: container, settings: settings, bookmarks: PlainFolderBookmarks(),
                     recovery: recovery, indexCache: LibraryIndexCache(url: cacheURL))
    }

    var containerFile: URL { container.appending(path: LibraryLocationSetting.defaultFileName) }
}

@Suite("Canonical library store")
struct LibraryStoreTests {
    @Test func createsPersistsAndRetainsPrior() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        #expect(await store.load() == .created)
        let shows = (0..<6).map { Fixtures.show(seed: 100 + UInt64($0)) }
        let library = Fixtures.library(shows: shows, seed: 1)
        guard case .success = try await store.update({ _ in library }) else { Issue.record("update failed"); return }
        let reopened = rig.store()
        #expect(await reopened.load() == .ready(revision: 2))
        #expect(await reopened.library == library)
        let priors = try rig.recovery.validatedCheckpoints(for: .library, coder: LibraryCoder.library)
        #expect(priors.first?.document.payload == LibraryModel())
    }

    @Test func newerLibraryIsRefusedAndNeverWritten() async throws {
        let rig = LibraryRig()
        #expect(await rig.store().load() == .created)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rig.containerFile)) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.library + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: rig.containerFile)
        let store = rig.store()
        #expect(await store.load() == .refusedNewerFormat(found: SchemaVersion.library + 1, supported: SchemaVersion.library))
        guard case .failure(.readOnly) = try await store.update({ $0 }) else { Issue.record("update allowed"); return }
        #expect(try Data(contentsOf: rig.containerFile) == newer)
    }

    @Test func damagedLibraryRecoversAsNewCopyKeepingSuspectFile() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let library = Fixtures.library(shows: (0..<4).map { Fixtures.show(seed: 200 + UInt64($0)) }, seed: 2)
        _ = try await store.update { _ in library }
        _ = try await store.update { LibraryReconciler.recordingRecent($0.entries[3].showID, in: $0) }
        try Data("{\"truncated".utf8).write(to: rig.containerFile)
        let reopened = rig.store()
        guard case let .damaged(_, revisions) = await reopened.load() else { Issue.record("not damaged"); return }
        #expect(revisions.first == 2)
        guard case .success = await reopened.recoverAsNewCopy(revision: 2) else { Issue.record("recover failed"); return }
        #expect(await reopened.library == library)
        #expect(try Data(contentsOf: rig.containerFile) == Data("{\"truncated".utf8))
        #expect(rig.settings.load().fileName.hasPrefix("Library (Recovered r2"))
    }

    @Test func reconciliationRetainsEveryEntry() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let shows = (0..<6).map { Fixtures.show(seed: 300 + UInt64($0)) }
        let library = Fixtures.library(shows: shows, seed: 3)
        _ = try await store.update { _ in library }
        let stamp = PublicationStamp(revision: 7, publicationID: UUID(), checksum: "sha256:synthetic")
        let observations: [ShowID: ShowObservation] = [
            shows[0].show.id: .missing, shows[1].show.id: .newerFormat(found: 9), shows[2].show.id: .conflicted(versionCount: 2),
            shows[3].show.id: .accessDenied, shows[4].show.id: .available(title: "Renamed", publication: stamp), shows[5].show.id: .identityMismatch,
        ]
        _ = await store.reconcile(observations, at: Date(timeIntervalSince1970: 5_000))
        let reconciled = try #require(await store.library)
        #expect(reconciled.entries.map(\.showID) == library.entries.map(\.showID))
        #expect(reconciled.collections == library.collections && reconciled.recentShowIDs == library.recentShowIDs)
        #expect(reconciled.entries.filter { $0.unavailable != nil }.count == 5)
        #expect(reconciled.entries[4].lastKnownPublication == stamp && reconciled.entries[4].lastKnownTitle == "Renamed")
        #expect(reconciled.entries.map(\.alias) == library.entries.map(\.alias))
        #expect(LibraryReconciler.hasChanged(reconciled.entries[4], observed: stamp) == false)
        #expect(LibraryReconciler.hasChanged(reconciled.entries[4], observed: PublicationStamp(revision: 7, publicationID: UUID(), checksum: stamp.checksum)))
        // Re-observing the same states publishes nothing new.
        #expect(await store.reconcile(observations, at: Date(timeIntervalSince1970: 9_000)) == nil)
    }

    @Test func deletingTheDerivedIndexLosesNothing() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let library = Fixtures.library(shows: (0..<30).map { Fixtures.show(seed: 400 + UInt64($0)) }, seed: 4)
        _ = try await store.update { _ in library }
        let canonicalBefore = try Data(contentsOf: rig.containerFile)
        let indexBefore = try #require(await store.index)
        #expect(FileManager.default.fileExists(atPath: rig.cacheURL.path))

        LibraryIndexCache(url: rig.cacheURL).invalidate()
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
        let reopened = rig.store()
        _ = await reopened.load()
        #expect(await reopened.index == indexBefore)
        #expect(await reopened.library == library)
        #expect(try Data(contentsOf: rig.containerFile) == canonicalBefore)
        // Every semantic collection/alias/order is in the canonical library, not only in the index.
        let rebuilt = try #require(await reopened.index)
        for collection in library.collections { #expect(rebuilt.showsByCollection[collection.id] == collection.showIDs) }
        #expect(Set(rebuilt.shows.map(\.displayName)) == Set(library.entries.map { $0.alias ?? $0.lastKnownTitle }))

        // A damaged cache is ignored and rebuilt.
        try Data("not an index".utf8).write(to: rig.cacheURL)
        let third = rig.store()
        _ = await third.load()
        #expect(await third.index == indexBefore)
    }

    @Test func moveCopiesVerifiesSwitchesAndKeepsOldCopy() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let library = Fixtures.library(shows: (0..<5).map { Fixtures.show(seed: 500 + UInt64($0)) }, seed: 5)
        _ = try await store.update { _ in library }
        let original = try Data(contentsOf: rig.containerFile)
        let folder = rig.dir.sub("Chosen Folder")
        guard case let .success(.moved(destination, kept)) = await store.moveLibrary(to: folder) else { Issue.record("move failed"); return }
        #expect(try Data(contentsOf: destination) == original, "exact verified copy")
        #expect(try Data(contentsOf: kept) == original, "old copy kept")
        guard case .folder = rig.settings.load().place else { Issue.record("setting not switched"); return }
        #expect(await store.library == library)
        // Edits now publish in the new location only.
        _ = try await store.update { LibraryReconciler.recordingRecent($0.entries[4].showID, in: $0) }
        #expect(try Data(contentsOf: rig.containerFile) == original)
        // Moving back finds a different library in the container: never overwritten.
        guard case .success(.destinationHasLibrary) = await store.moveLibraryToAppContainer() else { Issue.record("expected refusal"); return }
        #expect(try Data(contentsOf: rig.containerFile) == original)
    }

    @Test func movingOntoAnIdenticalCopyAdoptsIt() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let folder = rig.dir.sub("Chosen")
        _ = await store.moveLibrary(to: folder)
        guard case .success(.adoptedIdentical) = await store.moveLibraryToAppContainer() else { Issue.record("expected adopt"); return }
        guard case .appContainer = rig.settings.load().place else { Issue.record("not switched"); return }
    }

    @Test func useThatLibraryCombinesWithoutDroppingAnything() async throws {
        let rig = LibraryRig()
        let shows = (0..<6).map { Fixtures.show(seed: 600 + UInt64($0)) }
        let ids = shows.map(\.show.id)
        // This Mac: shows 0–3, "Active" = [0,1], "Archive" = [3], one unavailable entry.
        var mine = LibraryModel(
            entries: shows[0...3].map { LibraryShowEntry(showID: $0.show.id, lastKnownTitle: $0.show.title) },
            collections: [LibraryCollection(name: "Active", showIDs: [ids[0], ids[1]]), LibraryCollection(name: "Archive", showIDs: [ids[3]])],
            recentShowIDs: [ids[1], ids[0]]
        )
        mine.entries[0].unavailable = UnavailableRecord(note: "Offline", recordedAt: Date(timeIntervalSince1970: 10))
        mine.entries[2].alias = "Mine alias"
        // Target: shows 2–5, "Active" = [1… no: [2,4]], "Archive" identical name+members = [3].
        let theirs = LibraryModel(
            entries: shows[2...5].map { LibraryShowEntry(showID: $0.show.id, lastKnownTitle: $0.show.title) },
            collections: [LibraryCollection(name: "Active", showIDs: [ids[2], ids[4]]), LibraryCollection(name: "Archive", showIDs: [ids[3]]),
                          LibraryCollection(name: "Active (from this Mac)", showIDs: [ids[5]])],
            recentShowIDs: [ids[5]]
        )
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { _ in mine }
        let mineBytes = try Data(contentsOf: rig.containerFile)
        let folder = rig.dir.sub("Shared")
        let target = folder.appending(path: LibraryLocationSetting.defaultFileName)
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil).publish(theirs, revision: 4, key: .library, to: target, target: .newLocation)

        guard case .success(.destinationHasLibrary) = await store.moveLibrary(to: folder) else { Issue.record("expected choice"); return }
        guard case .success(.combined(_, let kept)) = await store.useLibrary(in: folder) else { Issue.record("combine failed"); return }
        let combined = try #require(await store.library)
        #expect(Set(combined.entries.map(\.showID)) == Set(ids))
        #expect(combined.entries.first { $0.showID == ids[0] }?.unavailable != nil)
        #expect(combined.entries.first { $0.showID == ids[2] }?.alias == "Mine alias")
        #expect(combined.collections.map(\.name) == ["Active", "Archive", "Active (from this Mac)", "Active (from this Mac 2)"])
        #expect(combined.collections.last?.showIDs == [ids[0], ids[1]])
        #expect(combined.recentShowIDs == [ids[5], ids[1], ids[0]])
        #expect(await store.lastLoad == .ready(revision: 5))
        #expect(try Data(contentsOf: try #require(kept)) == mineBytes, "old location kept as backup")
    }

    @Test func useThatLibraryWritesNothingForNewerOrUnreachableTargets() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let mineBytes = try Data(contentsOf: rig.containerFile)
        // Unreachable.
        guard case .failure = await store.useLibrary(in: rig.dir.url.appending(path: "Nowhere")) else { Issue.record("expected failure"); return }
        // Newer format.
        let folder = rig.dir.sub("Newer")
        let target = folder.appending(path: LibraryLocationSetting.defaultFileName)
        var object = try #require(JSONSerialization.jsonObject(with: mineBytes) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.library + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: target)
        guard case .failure(.readOnly) = await store.useLibrary(in: folder) else { Issue.record("expected refusal"); return }
        #expect(try Data(contentsOf: target) == newer)
        #expect(try Data(contentsOf: rig.containerFile) == mineBytes)
        guard case .appContainer = rig.settings.load().place else { Issue.record("setting changed"); return }
    }

    @Test func unreachableFolderShowsLastPriorReadOnly() async throws {
        let rig = LibraryRig()
        let store = rig.store()
        _ = await store.load()
        let library = Fixtures.library(shows: (0..<3).map { Fixtures.show(seed: 700 + UInt64($0)) }, seed: 7)
        _ = try await store.update { _ in library }
        let folder = rig.dir.sub("Removable")
        _ = await store.moveLibrary(to: folder)
        try FileManager.default.removeItem(at: folder)
        let reopened = rig.store()
        guard case let .unavailableShowingPrior(_, revision) = await reopened.load() else { Issue.record("expected read-only prior"); return }
        #expect(revision == 2)
        #expect(await reopened.library == library)
        guard case .failure(.readOnly) = try await reopened.update({ $0 }) else { Issue.record("edit allowed"); return }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing silently recreated")
    }

    @Test func combineNameSuffixesAreNumbered() {
        let name = LibraryMerge.uniqueName(for: "A", existing: ["A", "A (from this Mac)", "A (from this Mac 2)"])
        #expect(name == "A (from this Mac 3)")
    }
}

@Suite("Scale (headless, this host)", .serialized)
struct LibraryScaleTests {
    /// 100 show documents carrying 1,000 logical source references, a 100-entry library; p95 timings.
    @Test(.enabled(if: TimingGate.enabled, "timing pass (WW_TIMING_TESTS=1)"))
    func hundredShowsThousandSourceRefs() async throws {
        let rig = LibraryRig("scale")
        let docs = rig.dir.sub("Shows")
        let shows = (0..<100).map { Fixtures.show(seed: 10_000 + UInt64($0), episodes: 2, sourcesPerEpisode: 5) }
        #expect(shows.reduce(0) { $0 + $1.episodes.flatMap(\.sources).count } == 1_000)
        let publisher = DocumentPublisher(coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: rig.recovery)
        var urls: [ShowID: URL] = [:]
        for show in shows {
            let url = docs.appending(path: "\(show.show.id).wwshow")
            _ = try publisher.publish(show, revision: 1, key: .show(show.show.id), to: url, target: .newLocation)
            urls[show.show.id] = url
        }
        let setup = rig.store()
        _ = await setup.load()
        _ = try await setup.update { _ in Fixtures.library(shows: shows, seed: 99) }

        let opener = DocumentOpener(coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: rig.recovery)
        var openTimes: [Double] = [], rebuildTimes: [Double] = [], reconcileTimes: [Double] = []
        for _ in 0..<20 {
            var start = ContinuousClock.now
            let store = rig.store()
            _ = await store.load()
            openTimes.append(Stats.seconds(.now - start))

            LibraryIndexCache(url: rig.cacheURL).invalidate()
            start = .now
            let rebuilt = rig.store()
            _ = await rebuilt.load()
            rebuildTimes.append(Stats.seconds(.now - start))

            start = .now
            var observations: [ShowID: ShowObservation] = [:]
            for (id, url) in urls {
                if case let .editable(document, _) = opener.open(url, key: .show(id)) {
                    observations[id] = .available(title: document.payload.show.title, publication: document.publication)
                }
            }
            _ = await rebuilt.reconcile(observations)
            reconcileTimes.append(Stats.seconds(.now - start))
            #expect(observations.count == 100)
        }
        Evidence.record("scale 100 shows/1000 source refs: library open (cached index) \(Stats.summary(openTimes))")
        Evidence.record("scale 100 shows/1000 source refs: library open + index rebuild after cache deletion \(Stats.summary(rebuildTimes))")
        Evidence.record("scale 100 shows/1000 source refs: open+validate all 100 shows + reconcile \(Stats.summary(reconcileTimes))")
        #expect(Stats.percentile(openTimes, 95) < 1.0)
        #expect(Stats.percentile(rebuildTimes, 95) < 1.0)
    }
}
