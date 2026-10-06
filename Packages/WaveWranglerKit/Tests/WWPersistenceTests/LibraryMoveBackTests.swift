import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Moving the library back into WaveWrangler after a move out (states §5.1 steps 2 and 4): the container still holds
/// this library's retired copy. It is kept as a dated backup (never deleted, never combined) and the move goes
/// ahead; a different library in the container is still `.destinationHasLibrary`.
@Suite("Library move back into WaveWrangler")
struct LibraryMoveBackTests {
    /// Seeds a library in the container, moves it out to `folder`, then adds a collection there.
    /// Returns the retired container bytes and the edited library.
    private func movedOutAndEdited(_ rig: LibraryRig, _ store: LibraryStore, to folder: URL) async throws -> (retired: Data, edited: LibraryModel) {
        _ = await store.load()
        let library = Fixtures.library(shows: (0..<6).map { Fixtures.show(seed: 900 + UInt64($0)) }, seed: 9)
        _ = try await store.update { _ in library }
        let retired = try Data(contentsOf: rig.containerFile)
        guard case .success(.moved) = await store.moveLibrary(to: folder) else { throw CaseFailure(description: "move out failed") }
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "After The Move")); return l }
        let edited = try #require(await store.library)
        #expect(edited.collections.map(\.name).contains("After The Move"))
        return (retired, edited)
    }

    private func backups(in container: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Library (Backup r") && $0.pathExtension == "wwlibrary" }
    }

    @Test func movingBackKeepsTheRetiredCopyAsABackupAndMoves() async throws {
        let rig = LibraryRig("moveback")
        let store = rig.store()
        let folder = rig.dir.sub("First Library Folder")
        let (retired, edited) = try await movedOutAndEdited(rig, store, to: folder)
        let folderFile = folder.appending(path: LibraryLocationSetting.defaultFileName)
        let folderBytes = try Data(contentsOf: folderFile)

        guard case let .success(.moved(destination, kept)) = await store.moveLibraryToAppContainer() else {
            Issue.record("move back did not move"); return
        }
        #expect(destination.standardizedFileURL == rig.containerFile.standardizedFileURL)
        #expect(kept.standardizedFileURL == folderFile.standardizedFileURL)
        guard case .appContainer = rig.settings.load().place else { Issue.record("setting not switched"); return }
        // The current library is in the container, exactly the verified folder bytes; nothing combined.
        #expect(try Data(contentsOf: rig.containerFile) == folderBytes)
        #expect(await store.library?.content == edited.content)
        // The retired copy is kept byte-for-byte as a dated backup; the folder copy is kept untouched.
        let found = try backups(in: rig.container)
        #expect(found.count == 1)
        #expect(try found.map { try Data(contentsOf: $0) } == [retired])
        #expect(found.first?.lastPathComponent.hasPrefix("Library (Backup r") == true)
        #expect(try Data(contentsOf: folderFile) == folderBytes)
        // Edits publish in the container only.
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Back Home")); return l }
        #expect(try Data(contentsOf: folderFile) == folderBytes)
        #expect(try backups(in: rig.container).map { try Data(contentsOf: $0) } == [retired])
        // A fresh process loads the moved-back library.
        let reopened = rig.store()
        _ = await reopened.load()
        #expect(await reopened.library?.collections.map(\.name).contains("Back Home") == true)
    }

    /// The headless repro: the container chosen as a plain folder (the probe's `--move-to <container>`).
    @Test func movingToTheContainerFolderByPathAlsoMoves() async throws {
        let rig = LibraryRig("moveback-path")
        let store = rig.store()
        let (retired, edited) = try await movedOutAndEdited(rig, store, to: rig.dir.sub("A"))
        guard case .success(.moved) = await store.moveLibrary(to: rig.container) else { Issue.record("expected a move"); return }
        #expect(await store.library?.content == edited.content)
        #expect(try backups(in: rig.container).map { try Data(contentsOf: $0) } == [retired])
    }

    /// Out and back twice: every retired copy is kept, each under its own name.
    @Test func repeatedRoundTripsKeepEveryBackup() async throws {
        let rig = LibraryRig("moveback-twice")
        let store = rig.store()
        let (first, _) = try await movedOutAndEdited(rig, store, to: rig.dir.sub("A"))
        guard case .success(.moved) = await store.moveLibraryToAppContainer() else { Issue.record("first move back"); return }
        let second = try Data(contentsOf: rig.containerFile)
        guard case .success(.moved) = await store.moveLibrary(to: rig.dir.sub("B")) else { Issue.record("second move out"); return }
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Second Edit")); return l }
        guard case .success(.moved) = await store.moveLibraryToAppContainer() else { Issue.record("second move back"); return }
        let kept = Set(try backups(in: rig.container).map { try Data(contentsOf: $0) })
        #expect(kept == [first, second])
        #expect(await store.library?.collections.map(\.name).contains("Second Edit") == true)
    }

    @Test func aDifferentLibraryInTheContainerIsStillOffered() async throws {
        let rig = LibraryRig("moveback-foreign")
        let store = rig.store()
        _ = try await movedOutAndEdited(rig, store, to: rig.dir.sub("A"))
        var rng = SeededGenerator(seed: 77)
        let foreign = try LibraryCoder.library.encode(HoldoutGen.library(HoldoutGen.shows(1...3, &rng), &rng), revision: 1)
        try foreign.write(to: rig.containerFile)
        guard case .success(.destinationHasLibrary) = await store.moveLibraryToAppContainer() else { Issue.record("expected the choice"); return }
        #expect(try Data(contentsOf: rig.containerFile) == foreign)
        #expect(try backups(in: rig.container).isEmpty)
        guard case .folder = rig.settings.load().place else { Issue.record("location changed"); return }
    }

    /// The same identity at an equal or higher revision means the copies diverged: never treated as a backup.
    @Test(arguments: [0, 3])
    func aDivergedCopyOfThisLibraryIsStillOffered(_ ahead: Int) async throws {
        let rig = LibraryRig("moveback-diverged")
        let store = rig.store()
        let (_, edited) = try await movedOutAndEdited(rig, store, to: rig.dir.sub("A"))
        let current = try #require(await store.currentLibraryURL())
        let revision = try #require(RevisionFingerprint(of: Data(contentsOf: current)).revision)
        var other = edited
        other.collections.append(LibraryCollection(name: "Only In The Container"))
        let diverged = try LibraryCoder.library.encode(other, revision: revision + ahead)
        try diverged.write(to: rig.containerFile)
        guard case .success(.destinationHasLibrary) = await store.moveLibraryToAppContainer() else { Issue.record("expected the choice"); return }
        #expect(try Data(contentsOf: rig.containerFile) == diverged)
        #expect(try backups(in: rig.container).isEmpty)
    }

    /// User folders never qualify: another Mac may still be using an older copy there.
    @Test func anOlderCopyInAUserFolderIsStillOffered() async throws {
        let rig = LibraryRig("moveback-folder")
        let store = rig.store()
        let first = rig.dir.sub("A")
        _ = try await movedOutAndEdited(rig, store, to: first)
        let firstFile = first.appending(path: LibraryLocationSetting.defaultFileName)
        guard case .success(.moved) = await store.moveLibrary(to: rig.dir.sub("B")) else { Issue.record("move to B"); return }
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "In B")); return l }
        let retired = try Data(contentsOf: firstFile)
        guard case .success(.destinationHasLibrary) = await store.moveLibrary(to: first) else { Issue.record("expected the choice"); return }
        #expect(try Data(contentsOf: firstFile) == retired)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).sorted() == [LibraryLocationSetting.defaultFileName])
    }

    // MARK: Interruption

    private func store(_ rig: LibraryRig, ops: any FileOperations, hooks: any PublicationHooks = NoPublicationHooks()) -> LibraryStore {
        LibraryStore(containerFolder: rig.container, settings: rig.settings, bookmarks: PlainFolderBookmarks(),
                     recovery: RecoveryStore(root: rig.recovery.root, ops: ops),
                     indexCache: LibraryIndexCache(url: rig.cacheURL, ops: ops), ops: ops, hooks: hooks)
    }

    /// After any interruption the folder library is still the one in use and intact, the retired copy is intact
    /// (in place or as the backup), and trying again completes the move.
    private func checkAfterInterruption(_ rig: LibraryRig, folderFile: URL, folderBytes: Data, retired: Data, edited: LibraryModel) async throws {
        guard case .folder = rig.settings.load().place else { throw CaseFailure(description: "location switched") }
        #expect(try Data(contentsOf: folderFile) == folderBytes)
        let fresh = rig.store()
        _ = await fresh.load()
        #expect(await fresh.library?.content == edited.content)
        let keptRetired = try backups(in: rig.container).map { try Data(contentsOf: $0) }
            + [rig.containerFile].compactMap { try? Data(contentsOf: $0) }.filter { $0 == retired }
        #expect(keptRetired == [retired], "retired copy kept exactly once")
        let retry = await fresh.moveLibraryToAppContainer()
        switch retry {
        case .success(.moved), .success(.adoptedIdentical): break
        default: Issue.record("retry: \(retry)")
        }
        guard case .appContainer = rig.settings.load().place else { throw CaseFailure(description: "retry not switched") }
        #expect(await fresh.library?.content == edited.content)
        #expect(try Data(contentsOf: rig.containerFile) == folderBytes)
        #expect(try backups(in: rig.container).map { try Data(contentsOf: $0) } == [retired])
        #expect(try Data(contentsOf: folderFile) == folderBytes)
    }

    @Test func aFailedBackupRenameChangesNothing() async throws {
        let rig = LibraryRig("moveback-rename")
        let folder = rig.dir.sub("A")
        let (retired, edited) = try await movedOutAndEdited(rig, rig.store(), to: folder)
        let folderFile = folder.appending(path: LibraryLocationSetting.defaultFileName)
        let folderBytes = try Data(contentsOf: folderFile)
        let failing = store(rig, ops: RenameFailingOperations(source: rig.containerFile))
        _ = await failing.load()
        guard case .failure = await failing.moveLibraryToAppContainer() else { Issue.record("expected a failure"); return }
        #expect(try Data(contentsOf: rig.containerFile) == retired, "retired copy untouched in place")
        #expect(try backups(in: rig.container).isEmpty)
        try await checkAfterInterruption(rig, folderFile: folderFile, folderBytes: folderBytes, retired: retired, edited: edited)
    }

    @Test(arguments: PublicationBoundary.library)
    func processDeathDuringTheMoveBackLosesNothing(_ boundary: PublicationBoundary) async throws {
        let rig = LibraryRig("moveback-crash")
        let folder = rig.dir.sub("A")
        let (retired, edited) = try await movedOutAndEdited(rig, rig.store(), to: folder)
        let folderFile = folder.appending(path: LibraryLocationSetting.defaultFileName)
        let folderBytes = try Data(contentsOf: folderFile)
        let faults = FaultState(.crash(at: boundary))
        let faulty = store(rig, ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
        _ = await faulty.load()
        let outcome = await faulty.moveLibraryToAppContainer()
        if faults.fired {
            guard case .failure = outcome else { Issue.record("\(boundary): \(outcome)"); return }
            FaultInjectionHarnessTests.cleanStaging(faults)
            try await checkAfterInterruption(rig, folderFile: folderFile, folderBytes: folderBytes, retired: retired, edited: edited)
        } else {
            // The move publication doesn't pass this boundary (no prior retained for a new location).
            guard case .success(.moved) = outcome else { Issue.record("\(boundary) unfired: \(outcome)"); return }
        }
    }

    @Test func atLeastTheCopyBoundariesAreInterrupted() async throws {
        var fired: [PublicationBoundary] = []
        for boundary in PublicationBoundary.library {
            let rig = LibraryRig("moveback-fired")
            _ = try await movedOutAndEdited(rig, rig.store(), to: rig.dir.sub("A"))
            let faults = FaultState(.crash(at: boundary))
            let faulty = store(rig, ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            _ = await faulty.load()
            _ = await faulty.moveLibraryToAppContainer()
            if faults.fired { fired.append(boundary) }
        }
        #expect(Set(fired).isSuperset(of: [.candidateValidated, .baseChecked, .stagedFlushed, .published, .readBackVerified]), "\(fired)")
    }
}

/// Real file operations, except that moving `source` away (the backup rename) fails.
private struct RenameFailingOperations: FileOperations {
    let base = LocalFileOperations()
    let source: URL

    func read(_ url: URL) throws -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ from: URL, to destination: URL) throws {
        if from.standardizedFileURL == source.standardizedFileURL { throw POSIXError(.EIO) }
        try base.moveNew(from, to: destination)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL { try base.makeStagingDirectory(appropriateFor: destination) }
}
