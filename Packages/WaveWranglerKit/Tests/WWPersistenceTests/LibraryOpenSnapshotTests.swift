import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

@Suite("Library open snapshot and recovery")
struct LibraryOpenSnapshotTests {
    @Test(arguments: LibraryDiskCacheState.allCases)
    func buildsIndexFromValidatedLibraryWithoutDiskCacheIO(_ cacheState: LibraryDiskCacheState) async throws {
        let rig = LibraryRig("open-without-cache-io")
        let setup = rig.store()
        #expect(await setup.load() == .created)
        let library = Fixtures.library(shows: (0..<3).map { Fixtures.show(seed: 31_000 + UInt64($0)) }, seed: 42)
        guard case .published = try await setup.update({ _ in library }) else {
            Issue.record("Synthetic library setup failed")
            return
        }
        let original = try Data(contentsOf: rig.containerFile)
        let decoded = try LibraryCoder.library.decode(original)
        switch cacheState {
        case .valid: break
        case .missing: try LocalFileOperations().remove(rig.cacheURL)
        case .damaged: try Data("{damaged-index".utf8).write(to: rig.cacheURL)
        }
        let cacheBytes = cacheState == .missing ? nil : try Data(contentsOf: rig.cacheURL)
        let ops = LibraryOpenOperations(canonical: rig.containerFile, cache: rig.cacheURL)
        let store = makeStore(rig, recovery: rig.recovery, ops: ops)

        #expect(await store.load() == .ready(revision: 2))
        #expect(ops.canonicalReadCount == 1)
        #expect(ops.cacheAccessCount == 0, "Disposable index I/O must not block canonical library opening")
        #expect(await store.index == LibraryIndex.build(from: decoded.payload, libraryDigest: RevisionFingerprint.digest(original)))
        #expect(await store.library == decoded.payload)
        #expect(try Data(contentsOf: rig.containerFile) == original)
        if let cacheBytes {
            #expect(try Data(contentsOf: rig.cacheURL) == cacheBytes, "Opening must not rewrite the disposable cache")
        } else {
            #expect(!LocalFileOperations().exists(rig.cacheURL))
        }
    }

    @Test func retainsTheValidatedLibraryWithOneCanonicalRead() async throws {
        let rig = LibraryRig("open-snapshot")
        #expect(await rig.store().load() == .created)
        let original = try Data(contentsOf: rig.containerFile)
        let ops = LibraryOpenOperations(canonical: rig.containerFile)
        let recovery = RecoveryStore(root: rig.dir.sub("Fresh Recovery"))
        let store = makeStore(rig, recovery: recovery, ops: ops)

        #expect(await store.load() == .ready(revision: 1))
        #expect(ops.canonicalReadCount == 1, "Use the already validated coordinated open, not another file open")
        let current = try #require(recovery.verifiedCurrent(for: .library))
        #expect(try recovery.bytes(of: current) == original)
        #expect(try Data(contentsOf: rig.containerFile) == original)
        #expect(await store.library == (try LibraryCoder.library.decode(original)).payload)
    }

    @Test func replacementAfterOpenCannotChangeTheRetainedSnapshotOrPermitAnOverwrite() async throws {
        let rig = LibraryRig("open-replaced-snapshot")
        #expect(await rig.store().load() == .created)
        let original = try Data(contentsOf: rig.containerFile)
        let decoded = try LibraryCoder.library.decode(original)
        var replacement = decoded.payload
        replacement.collections.append(LibraryCollection(name: "Concurrent version"))
        let replacementBytes = try LibraryCoder.library.encode(replacement, revision: 2)
        let ops = LibraryOpenOperations(canonical: rig.containerFile, replacement: replacementBytes)
        let recovery = RecoveryStore(root: rig.dir.sub("Fresh Recovery"))
        let store = makeStore(rig, recovery: recovery, ops: ops)

        #expect(await store.load() == .ready(revision: 1))
        #expect(ops.canonicalReadCount == 1)
        #expect(await store.library == decoded.payload)
        let current = try #require(recovery.verifiedCurrent(for: .library))
        #expect(current.fingerprint == RevisionFingerprint(of: original))
        #expect(try recovery.bytes(of: current) == original, "Recovery must describe the snapshot actually adopted")
        #expect(try Data(contentsOf: rig.containerFile) == replacementBytes)

        let result = try await store.update { library in
            var edited = library
            edited.collections.append(LibraryCollection(name: "Unsaved edit"))
            return edited
        }
        guard case .failed(.conflict) = result else {
            Issue.record("A changed canonical base must still refuse publication")
            return
        }
        #expect(try Data(contentsOf: rig.containerFile) == replacementBytes)
        #expect(try recovery.bytes(of: current) == original)
        #expect(try recovery.conflictCandidates(for: .library).count == 1)
    }

    @Test(arguments: RefusedLibrarySnapshot.allCases)
    func refusedLibraryNeverBecomesVerifiedCurrent(_ kind: RefusedLibrarySnapshot) async throws {
        let rig = LibraryRig("open-refused-snapshot")
        #expect(await rig.store().load() == .created)
        let valid = try Data(contentsOf: rig.containerFile)
        let bytes: Data
        switch kind {
        case .damaged: bytes = Data("{truncated".utf8)
        case .newer:
            var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            object["schemaVersion"] = SchemaVersion.library + 1
            bytes = try JSONSerialization.data(withJSONObject: object)
        case .differentIdentity: bytes = try LibraryCoder.library.encode(LibraryModel(), revision: 1)
        }
        try bytes.write(to: rig.containerFile)
        let ops = LibraryOpenOperations(canonical: rig.containerFile)
        let recovery = RecoveryStore(root: rig.dir.sub("Fresh Recovery"))
        let store = makeStore(rig, recovery: recovery, ops: ops)

        let outcome = await store.load()
        switch (kind, outcome) {
        case (.damaged, .damaged), (.differentIdentity, .damaged), (.newer, .refusedNewerFormat): break
        default: Issue.record("Unexpected refusal: \(outcome)")
        }
        #expect(recovery.verifiedCurrent(for: .library) == nil)
        #expect(await store.library == nil)
        #expect(try Data(contentsOf: rig.containerFile) == bytes)
    }

    private func makeStore(
        _ rig: LibraryRig, recovery: RecoveryStore, ops: LibraryOpenOperations
    ) -> LibraryStore {
        LibraryStore(
            containerFolder: rig.container, settings: rig.settings, bookmarks: PlainFolderBookmarks(),
            recovery: recovery, indexCache: LibraryIndexCache(url: rig.cacheURL, ops: ops), ops: ops,
            providerVersions: NoProviderVersions()
        )
    }
}

enum LibraryDiskCacheState: Sendable, CaseIterable {
    case valid
    case missing
    case damaged
}

enum RefusedLibrarySnapshot: Sendable, CaseIterable {
    case damaged
    case newer
    case differentIdentity
}

private final class LibraryOpenOperations: FileOperations {
    private struct State {
        var reads = 0
        var cacheAccesses = 0
        var replacement: Data?
    }

    private let canonical: URL
    private let cache: URL?
    private let state: Mutex<State>
    private let base = LocalFileOperations()

    init(canonical: URL, replacement: Data? = nil, cache: URL? = nil) {
        self.canonical = canonical.standardizedFileURL
        self.cache = cache?.standardizedFileURL
        self.state = Mutex(State(replacement: replacement))
    }

    var canonicalReadCount: Int { state.withLock { $0.reads } }
    var cacheAccessCount: Int { state.withLock { $0.cacheAccesses } }

    private func noteCacheAccess(_ url: URL) {
        if let cache, url.standardizedFileURL == cache {
            state.withLock { $0.cacheAccesses += 1 }
        }
    }

    func read(_ url: URL) throws -> Data {
        noteCacheAccess(url)
        let bytes = try base.read(url)
        if url.standardizedFileURL == canonical {
            let replacement = state.withLock { state in
                state.reads += 1
                defer { state.replacement = nil }
                return state.replacement
            }
            if let replacement {
                let staged = url.deletingLastPathComponent().appending(path: "replacement-\(UUID().uuidString)")
                try base.writeNew(replacement, to: staged)
                try base.replace(url, withStaged: staged)
            }
        }
        return bytes
    }

    func exists(_ url: URL) -> Bool { noteCacheAccess(url); return base.exists(url) }
    func createDirectory(_ url: URL) throws { noteCacheAccess(url); try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { noteCacheAccess(url); try base.writeNew(data, to: url) }
    func replace(_ destination: URL, withStaged staged: URL) throws {
        noteCacheAccess(destination)
        try base.replace(destination, withStaged: staged)
    }
    func moveNew(_ source: URL, to destination: URL) throws {
        noteCacheAccess(source)
        noteCacheAccess(destination)
        try base.moveNew(source, to: destination)
    }
    func remove(_ url: URL) throws { noteCacheAccess(url); try base.remove(url) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { noteCacheAccess(url); return try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        noteCacheAccess(destination)
        return try base.makeStagingDirectory(appropriateFor: destination)
    }
}
