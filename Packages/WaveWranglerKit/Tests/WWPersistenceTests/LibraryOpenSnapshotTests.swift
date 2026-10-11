import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

@Suite("Library open snapshot and recovery")
struct LibraryOpenSnapshotTests {
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
            recovery: recovery, indexCache: LibraryIndexCache(url: rig.cacheURL), ops: ops,
            providerVersions: NoProviderVersions()
        )
    }
}

enum RefusedLibrarySnapshot: Sendable, CaseIterable {
    case damaged
    case newer
    case differentIdentity
}

private final class LibraryOpenOperations: FileOperations {
    private struct State {
        var reads = 0
        var replacement: Data?
    }

    private let canonical: URL
    private let state: Mutex<State>
    private let base = LocalFileOperations()

    init(canonical: URL, replacement: Data? = nil) {
        self.canonical = canonical.standardizedFileURL
        self.state = Mutex(State(replacement: replacement))
    }

    var canonicalReadCount: Int { state.withLock { $0.reads } }

    func read(_ url: URL) throws -> Data {
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

    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try base.makeStagingDirectory(appropriateFor: destination)
    }
}
