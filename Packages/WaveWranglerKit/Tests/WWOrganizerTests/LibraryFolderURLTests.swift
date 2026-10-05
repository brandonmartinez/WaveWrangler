import Foundation
import Synchronization
import Testing
import WWCore
import WWOrganizer
import WWPersistence

/// The library UI passes persistence's outcome URLs back into `useLibrary(in:)` and shows folder names.
/// Persistence reports *file* URLs, so these run real `WWPersistence.LibraryStore` flows in temporary
/// folders (synthetic libraries only) and check the folder reduction end to end.
@Suite("Library folder URLs from persistence outcomes")
struct LibraryFolderURLTests {
    @Test func reducesOutcomeFileURLsByDroppingTheFileWhateverItsName() {
        let folder = URL(filePath: "/tmp/Shows.wwlibrary", directoryHint: .isDirectory)
        for name in [LibraryLocationSetting.defaultFileName, "Library (Recovered r3 1A2B3C4D).wwlibrary"] {
            let file = folder.appending(path: name)
            #expect(LibraryFolderURL.folder(ofLibraryFile: file).standardizedFileURL == folder.standardizedFileURL)
            #expect(LibraryFolderURL.displayName(ofLibraryFile: file) == "Shows.wwlibrary", "a folder named *.wwlibrary is kept")
        }
    }

    @Test func useThatLibraryWorksForAFolderNamedLikeALibrary() async throws {
        let rig = try Rig()
        let store = rig.store()
        _ = await store.load()
        let other = try await rig.otherLibraryFolder(named: "Shows.wwlibrary")
        guard case .success(.destinationHasLibrary(let reported, _)) = await store.moveLibrary(to: other) else {
            Issue.record("expected destinationHasLibrary")
            return
        }
        #expect(LibraryFolderURL.displayName(ofLibraryFile: reported) == "Shows.wwlibrary")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(ofLibraryFile: reported))
        guard case .success(.combined) = result else {
            Issue.record("expected combined, got \(result)")
            return
        }
    }

    @Test func destinationHasLibraryThenUseThatLibrarySucceedsWithFolderName() async throws {
        let rig = try Rig()
        let store = rig.store()
        _ = await store.load()
        let other = try await rig.otherLibraryFolder(named: "Other Mac Library")

        guard case .success(.destinationHasLibrary(let reported, _)) = await store.moveLibrary(to: other) else {
            Issue.record("expected destinationHasLibrary")
            return
        }
        #expect(reported.lastPathComponent == LibraryLocationSetting.defaultFileName, "persistence reports the file URL")
        #expect(LibraryFolderURL.displayName(ofLibraryFile: reported) == "Other Mac Library")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(ofLibraryFile: reported))
        guard case .success(.combined) = result else {
            Issue.record("Use That Library with the reduced folder should combine, got \(result)")
            return
        }
    }

    @Test func regrantDifferentLibraryThenUseThatLibrarySucceedsWithFolderName() async throws {
        let rig = try Rig()
        // Configure the library in a folder, then revoke access to it (L3).
        let configured = rig.dir.appending(path: "Cloud Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let first = rig.store()
        _ = await first.load()
        guard case .success = await first.moveLibrary(to: configured) else {
            Issue.record("setup: move to folder failed")
            return
        }
        rig.bookmarks.revoke(configured)
        let store = rig.store()
        _ = await store.load()
        let other = try await rig.otherLibraryFolder(named: "Someone Else's Library")

        guard case .differentLibrary(let reported, _) = await store.regrantAccess(to: other) else {
            Issue.record("expected differentLibrary")
            return
        }
        #expect(LibraryFolderURL.displayName(ofLibraryFile: reported) == "Someone Else's Library")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(ofLibraryFile: reported))
        if case .failure(let error) = result {
            Issue.record("Use That Library with the reduced folder failed: \(error)")
        }
        // The unreduced file URL is exactly what broke before (…/Library.wwlibrary/Library.wwlibrary).
        #expect(reported.appending(path: LibraryLocationSetting.defaultFileName).path(percentEncoded: false).contains("wwlibrary/Library.wwlibrary"))
    }
}

extension LibraryFolderURLTests {
    @Test func afterRecoveryUseThatLibraryStillGetsTheFolder() async throws {
        let rig = try Rig()
        let first = rig.store()
        _ = await first.load()
        // A few published revisions give whole checkpoints to recover from.
        for name in ["One", "Two", "Three"] {
            _ = try await first.update { library in
                var copy = library
                copy.collections.append(LibraryCollection(name: name))
                return copy
            }
        }
        // Damage the canonical file, reopen, recover an earlier version (renames the library file).
        let container = rig.dir.appending(path: "Container", directoryHint: .isDirectory)
        try Data("not a library".utf8).write(to: container.appending(path: rig.settings.load().fileName))
        let store = rig.store()
        guard case .damaged(_, let revisions) = await store.load(), let newest = revisions.max() else {
            Issue.record("expected a damaged library with recovery revisions")
            return
        }
        guard case .success = await store.recoverAsNewCopy(revision: newest) else {
            Issue.record("recovery failed")
            return
        }
        let recoveredName = rig.settings.load().fileName
        #expect(recoveredName != LibraryLocationSetting.defaultFileName, "recovery renames the library file")

        // A different library in another folder under the current (recovered) file name.
        let other = try await rig.otherLibraryFolder(named: "Other Mac Library", fileName: recoveredName)
        guard case .success(.destinationHasLibrary(let reported, _)) = await store.moveLibrary(to: other) else {
            Issue.record("expected destinationHasLibrary")
            return
        }
        #expect(reported.lastPathComponent == recoveredName)
        #expect(LibraryFolderURL.displayName(ofLibraryFile: reported) == "Other Mac Library")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(ofLibraryFile: reported))
        if case .failure(let error) = result { Issue.record("Use That Library after recovery failed: \(error)") }
    }
}

// MARK: - Synthetic rig

private final class Rig: Sendable {
    let dir: URL
    let settings = MemorySettings()
    let bookmarks = PathBookmarks()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ww-organizer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func store(container: String = "Container") -> LibraryStore {
        LibraryStore(
            containerFolder: dir.appending(path: container, directoryHint: .isDirectory),
            settings: settings,
            bookmarks: bookmarks,
            recovery: RecoveryStore(root: dir.appending(path: "Recovery-\(container)", directoryHint: .isDirectory)),
            indexCache: LibraryIndexCache(url: dir.appending(path: "index-\(container).json"))
        )
    }

    /// Creates a different, valid library in `name` by letting a separate store publish its default library.
    func otherLibraryFolder(named name: String, fileName: String = LibraryLocationSetting.defaultFileName) async throws -> URL {
        let folder = dir.appending(path: name, directoryHint: .isDirectory)
        let other = LibraryStore(
            containerFolder: folder,
            settings: MemorySettings(LibraryLocationSetting(fileName: fileName)),
            bookmarks: PathBookmarks(),
            recovery: RecoveryStore(root: dir.appending(path: "Recovery-\(name)", directoryHint: .isDirectory)),
            indexCache: LibraryIndexCache(url: dir.appending(path: "index-\(name).json"))
        )
        _ = await other.load()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: fileName).path(percentEncoded: false)))
        return folder
    }
}

private final class MemorySettings: LibraryLocationSettingsStoring {
    private let value: Mutex<LibraryLocationSetting>
    init(_ initial: LibraryLocationSetting = LibraryLocationSetting()) { value = Mutex(initial) }
    func load() -> LibraryLocationSetting { value.withLock { $0 } }
    func save(_ setting: LibraryLocationSetting) throws { value.withLock { $0 = setting } }
}

/// Plain path "bookmarks" for unsandboxed tests, with revocation to simulate L3.
private final class PathBookmarks: FolderBookmarking {
    private let revoked = Mutex(Set<String>())

    func revoke(_ folder: URL) { revoked.withLock { _ = $0.insert(folder.standardizedFileURL.path(percentEncoded: false)) } }

    func bookmark(for folder: URL) throws -> Data {
        revoked.withLock { _ = $0.remove(folder.standardizedFileURL.path(percentEncoded: false)) }
        return Data(folder.standardizedFileURL.path(percentEncoded: false).utf8)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        let path = String(decoding: bookmark, as: UTF8.self)
        if revoked.withLock({ $0.contains(path) }) { throw CocoaError(.fileReadNoPermission) }
        return (URL(filePath: path, directoryHint: .isDirectory), false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
