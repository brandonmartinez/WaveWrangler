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
