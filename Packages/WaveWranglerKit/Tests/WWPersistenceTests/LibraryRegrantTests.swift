import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

/// Path "bookmarks" whose grants can be revoked, to model Design L3 (needs permission) headlessly.
final class RevocableBookmarks: FolderBookmarking {
    private let revoked = Mutex(Set<String>())

    func revoke(_ folder: URL) { revoked.withLock { _ = $0.insert(folder.standardizedFileURL.path) } }

    func bookmark(for folder: URL) throws -> Data {
        revoked.withLock { _ = $0.remove(folder.standardizedFileURL.path) }   // re-selecting in a panel grants again
        return Data(folder.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        let url = URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true)
        if revoked.withLock({ $0.contains(url.standardizedFileURL.path) }) { throw CocoaError(.fileReadNoPermission) }
        return (url, false)
    }

    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

@Suite("Library Grant Access (L3 regrant) and reload")
struct LibraryRegrantTests {
    struct RegrantRig {
        let rig = LibraryRig("regrant")
        let bookmarks = RevocableBookmarks()
        let folder: URL
        let shows = (0..<4).map { Fixtures.show(seed: 4_000 + UInt64($0)) }

        init() async throws {
            folder = rig.dir.sub("Cloud Library")
            let store = self.store()
            _ = await store.load()
            _ = try await store.update { _ in Fixtures.library(shows: self.shows, seed: 40) }
            guard case .success(.moved) = await store.moveLibrary(to: folder) else { throw CocoaError(.fileWriteUnknown) }
        }

        func store() -> LibraryStore {
            LibraryStore(containerFolder: rig.container, settings: rig.settings, bookmarks: bookmarks,
                         recovery: rig.recovery, indexCache: LibraryIndexCache(url: rig.cacheURL))
        }

        var libraryFile: URL { folder.appending(path: LibraryLocationSetting.defaultFileName) }
    }

    @Test func regrantSameLibraryReloadsAndReplaysQueuedEdits() async throws {
        let rr = try await RegrantRig()
        rr.bookmarks.revoke(rr.folder)
        let store = rr.store()
        guard case .unavailableShowingPrior = await store.load() else { Issue.record("expected L3"); return }
        #expect(await store.levelState == .needsPermission)
        let identity = try #require(await store.expectedLibraryID())
        #expect(try await store.update(PendingLibraryEditsTests.addCollection("While locked")) == .queued(pendingEdits: 1))

        guard case let .regranted(load, pending) = await store.regrantAccess(to: rr.folder) else { Issue.record("not regranted"); return }
        guard case .ready = load, case .applied? = pending else { Issue.record("load \(load), pending \(String(describing: pending))"); return }
        #expect(await store.levelState == .ready)
        #expect(await store.pendingEditCount == 0)
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: rr.libraryFile)).payload
        #expect(onDisk.collections.contains { $0.name == "While locked" })
        #expect(onDisk.libraryID == identity)
        // The new grant persists: a fresh store loads without regranting.
        let next = rr.store()
        guard case .ready = await next.load() else { Issue.record("grant not persisted"); return }
    }

    @Test func differentLibraryInChosenFolderChangesNothing() async throws {
        let rr = try await RegrantRig()
        rr.bookmarks.revoke(rr.folder)
        let store = rr.store()
        _ = await store.load()
        let settingBefore = rr.rig.settings.load()
        let other = rr.rig.dir.sub("Other Library")
        let otherFile = other.appending(path: LibraryLocationSetting.defaultFileName)
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(Fixtures.library(shows: rr.shows, seed: 41), revision: 3, key: .library, to: otherFile, target: .newLocation)
        let otherBytes = try Data(contentsOf: otherFile)
        guard case .differentLibrary(_, revision: 3) = await store.regrantAccess(to: other) else { Issue.record("expected differentLibrary"); return }
        #expect(rr.rig.settings.load() == settingBefore)
        #expect(try Data(contentsOf: otherFile) == otherBytes)
        #expect(await store.levelState == .needsPermission)
    }

    @Test func sameLibraryAtRenamedFolderIsAccepted() async throws {
        let rr = try await RegrantRig()
        rr.bookmarks.revoke(rr.folder)
        let renamed = rr.rig.dir.url.appending(path: "Renamed Cloud Library", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: rr.folder, to: renamed)
        let store = rr.store()
        _ = await store.load()
        guard case .regranted(.ready, nil) = await store.regrantAccess(to: renamed) else { Issue.record("expected regrant"); return }
        guard case let .folder(_, displayPath) = rr.rig.settings.load().place else { Issue.record("setting"); return }
        #expect(displayPath == renamed.path)
    }

    @Test func emptyNewerOrDamagedFoldersChangeNothing() async throws {
        let rr = try await RegrantRig()
        rr.bookmarks.revoke(rr.folder)
        let store = rr.store()
        _ = await store.load()
        let settingBefore = rr.rig.settings.load()

        guard case .noLibraryThere = await store.regrantAccess(to: rr.rig.dir.sub("Empty")) else { Issue.record("expected noLibraryThere"); return }

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rr.libraryFile)) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.library + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: rr.libraryFile)
        guard case .cannotVerify = await store.regrantAccess(to: rr.folder) else { Issue.record("expected cannotVerify (newer)"); return }
        #expect(try Data(contentsOf: rr.libraryFile) == newer)

        try Data("{damaged".utf8).write(to: rr.libraryFile)
        guard case .cannotVerify = await store.regrantAccess(to: rr.folder) else { Issue.record("expected cannotVerify (damaged)"); return }
        #expect(rr.rig.settings.load() == settingBefore)
    }

    /// #60 review repro 2: after "Use That Library" the old library's higher-revision priors must not be taken
    /// for this library's identity or its read-only prior.
    @Test func regrantAfterUseThatLibraryUsesTheNewIdentity() async throws {
        let rig = LibraryRig("regrant-use-that")
        let bookmarks = RevocableBookmarks()
        func store() -> LibraryStore {
            LibraryStore(containerFolder: rig.container, settings: rig.settings, bookmarks: bookmarks,
                         recovery: rig.recovery, indexCache: LibraryIndexCache(url: rig.cacheURL))
        }
        // Library A in the container, revision 10.
        let a = store()
        _ = await a.load()
        for index in 1...9 {
            _ = try await a.update { var l = $0; l.collections.append(LibraryCollection(name: "A \(index)")); return l }
        }
        guard case .ready(revision: 10) = await a.reload() else { Issue.record("A not at r10"); return }
        let aID = try #require(await a.library?.libraryID)
        // Library B (a different library) in a folder, revision 1.
        let folder = rig.dir.sub("B Folder")
        let b = LibraryModel(collections: [LibraryCollection(name: "B")])
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(b, revision: 1, key: .library, to: folder.appending(path: LibraryLocationSetting.defaultFileName), target: .newLocation)
        guard case .success(.combined) = await a.useLibrary(in: folder) else { Issue.record("combine failed"); return }
        #expect(await a.library?.libraryID == b.libraryID)
        #expect(rig.settings.load().libraryID == b.libraryID)

        bookmarks.revoke(folder)
        let locked = store()
        guard case let .unavailableShowingPrior(_, revision) = await locked.load() else { Issue.record("expected L3"); return }
        #expect(revision == 2, "the read-only prior is B's own verified revision, not A's r10")
        #expect(await locked.library?.libraryID == b.libraryID)
        #expect(await locked.expectedLibraryID() == b.libraryID)
        #expect(aID != b.libraryID)
        guard case .regranted(.ready(revision: 2), nil) = await locked.regrantAccess(to: folder) else { Issue.record("expected regrant of B"); return }
    }

    @Test func reloadReadoptsAfterUseOtherVersion() async throws {
        let rr = try await RegrantRig()
        let store = rr.store()
        _ = await store.load()
        _ = await store.resolveConflictUsingOtherVersion()
        guard case .ready = await store.reload() else { Issue.record("reload"); return }
        #expect(await store.levelState == .ready)
    }
}

@Suite("Library schema 1 → 2")
struct LibrarySchemaUpgradeTests {
    /// Writes a genuine schema 1 library envelope (no `libraryID`).
    static func schema1Bytes(entries: [LibraryShowEntry], revision: Int = 3) throws -> Data {
        let v1 = JSONEnvelopeCoder<LibraryCoder.LibraryModelV1>(format: LibraryCoder.schema1Format) { _, _ in [] }
        return try v1.encode(LibraryCoder.LibraryModelV1(schemaVersion: 1, entries: entries, collections: [LibraryCollection(name: "Old", showIDs: entries.map(\.showID))], recentShowIDs: []), revision: revision)
    }

    @Test func schema1IsUpgradedWithStableIdentityAndBackedUp() async throws {
        let rig = LibraryRig("schema1")
        let shows = (0..<3).map { Fixtures.show(seed: 5_000 + UInt64($0)) }
        let original = try Self.schema1Bytes(entries: shows.map { LibraryShowEntry(showID: $0.show.id, lastKnownTitle: $0.show.title) })
        try original.write(to: rig.containerFile)

        let first = rig.store()
        guard case .ready(revision: 3) = await first.load() else { Issue.record("schema 1 not readable"); return }
        let id = try #require(await first.library?.libraryID)
        let second = rig.store()
        _ = await second.load()
        #expect(await second.library?.libraryID == id, "derived identity is stable across reads")

        _ = try await second.update { var l = $0; l.collections.append(LibraryCollection(name: "New")); return l }
        let upgraded = try LibraryCoder.library.decode(Data(contentsOf: rig.containerFile))
        #expect(EnvelopeHeaderInfo.peek(try Data(contentsOf: rig.containerFile))?.schemaVersion == SchemaVersion.library)
        #expect(upgraded.payload.libraryID == id && upgraded.payload.collections.map(\.name) == ["Old", "New"])
        let backups = try rig.recovery.migrationBackups(for: .library)
        #expect(try backups.map { try Data(contentsOf: $0) }.contains(original), "schema 1 bytes kept as a non-overwriting backup")
    }

    /// #60 review repro 1: two stores upgrade the same schema 1 file; the second must see a conflict (L4),
    /// not a permanent "couldn't be backed up" failure.
    @Test func concurrentSchema1UpgradeIsAConflict() async throws {
        let rig = LibraryRig("schema1-conflict")
        let shows = (0..<2).map { Fixtures.show(seed: 6_000 + UInt64($0)) }
        let original = try Self.schema1Bytes(entries: shows.map { LibraryShowEntry(showID: $0.show.id, lastKnownTitle: $0.show.title) })
        try original.write(to: rig.containerFile)
        let a = rig.store(), b = rig.store()
        _ = await a.load()
        _ = await b.load()
        guard case .published = try await b.update({ var l = $0; l.collections.append(LibraryCollection(name: "From B")); return l })
        else { Issue.record("B failed"); return }
        let afterB = try Data(contentsOf: rig.containerFile)
        guard case .failed(.conflict) = try await a.update({ var l = $0; l.collections.append(LibraryCollection(name: "From A")); return l })
        else { Issue.record("expected conflict"); return }
        #expect(await a.levelState == .changedElsewhere)
        #expect(try Data(contentsOf: rig.containerFile) == afterB, "nothing overwritten")
        #expect(try rig.recovery.migrationBackups(for: .library).map { try Data(contentsOf: $0) } == [original],
                "only the genuine original was backed up")
        guard case .success = await a.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        let names = try LibraryCoder.library.decode(Data(contentsOf: rig.containerFile)).payload.collections.map(\.name)
        #expect(names.contains("From A") && names.contains("From B"))
    }

    @Test func schema1TamperingIsRefused() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Self.schema1Bytes(entries: [])) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        payload["recentShowIDs"] = [UUID().uuidString]
        object["payload"] = payload
        #expect(throws: PersistenceError.self) { try LibraryCoder.library.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func strictCoderRefusesSchema1() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 1, minimum: SchemaVersion.library)) {
            try JSONEnvelopeCoder<LibraryModel>.library.decode(Self.schema1Bytes(entries: []))
        }
    }
}
