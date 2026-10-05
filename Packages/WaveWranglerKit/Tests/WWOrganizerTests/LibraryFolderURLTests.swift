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
    @Test func reducesLibraryFileURLsToTheirFolder() {
        let folder = URL(filePath: "/tmp/Podcasts Library", directoryHint: .isDirectory)
        let file = folder.appending(path: LibraryLocationSetting.defaultFileName)
        #expect(LibraryFolderURL.folder(for: file).standardizedFileURL == folder.standardizedFileURL)
        #expect(LibraryFolderURL.folder(for: folder).standardizedFileURL == folder.standardizedFileURL)
        #expect(LibraryFolderURL.displayName(for: file) == "Podcasts Library")
        #expect(LibraryFolderURL.displayName(for: folder) == "Podcasts Library")
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
        #expect(LibraryFolderURL.displayName(for: reported) == "Other Mac Library")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(for: reported))
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
        #expect(LibraryFolderURL.displayName(for: reported) == "Someone Else's Library")
        let result = await store.useLibrary(in: LibraryFolderURL.folder(for: reported))
        if case .failure(let error) = result {
            Issue.record("Use That Library with the reduced folder failed: \(error)")
        }
        // The unreduced file URL is exactly what broke before (…/Library.wwlibrary/Library.wwlibrary).
        #expect(reported.appending(path: LibraryLocationSetting.defaultFileName).path(percentEncoded: false).contains("wwlibrary/Library.wwlibrary"))
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
    func otherLibraryFolder(named name: String) async throws -> URL {
        let folder = dir.appending(path: name, directoryHint: .isDirectory)
        let other = LibraryStore(
            containerFolder: folder,
            settings: MemorySettings(),
            bookmarks: PathBookmarks(),
            recovery: RecoveryStore(root: dir.appending(path: "Recovery-\(name)", directoryHint: .isDirectory)),
            indexCache: LibraryIndexCache(url: dir.appending(path: "index-\(name).json"))
        )
        _ = await other.load()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: LibraryLocationSetting.defaultFileName).path(percentEncoded: false)))
        return folder
    }
}

private final class MemorySettings: LibraryLocationSettingsStoring {
    private let value = Mutex(LibraryLocationSetting())
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
