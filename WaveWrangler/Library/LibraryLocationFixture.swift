#if DEBUG
import AppKit
import OSLog
import WWCore
import WWPersistence

/// T25 / F-LIBLOC test seam (Debug builds only; UI-test storage only; synthetic data only).
///
/// `-WWUITestLibraryLocation <state>` with `-WWUITestHooks YES -WWUITestResetStorage YES` seeds the **real**
/// persistent library (the canonical `LibraryStore` the app uses, in the isolated UI-test storage) with the F-LIBLOC
/// library: 12 shows, 5 collections, 8 recent items and 3 unavailable entries. `<state>` then puts the current
/// library in a library-level state:
/// - `ready` (L1): nothing more.
/// - `unreachable` (L2) / `permission` (L3): the library is first moved into a folder in the app's temporary
///   directory (a real move); then `LibraryFolderFaults` makes resolving that folder's bookmark report a missing
///   folder (L2) or throw (L3), because a locally attached folder can't be made unreachable or permission-less on
///   demand. The distributed notification `com.brandonmartinez.wavewrangler.uitest.libraryFolder.restore` clears
///   the fault (the folder "comes back"); Grant Access… (a new bookmark) also clears L3.
/// - `conflict` (L4): once the app has loaded the library, a second store publishes a change ("From Another Mac")
///   to the same file, as another Mac would; the app's next library edit then meets the conflict.
/// - `newer` (L5): the library file's schema version is raised to 99 (a newer WaveWrangler's format).
@MainActor
enum LibraryLocationFixture {
    nonisolated static let argument = "WWUITestLibraryLocation"
    static let restoreNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.libraryFolder.restore")
    nonisolated private static let logger = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "UITestLibraryLocation")
    private static var observer: NSObjectProtocol?

    static var requestedState: String? {
        guard PersistenceEnvironment.isUITestRun else { return nil }
        return UserDefaults.standard.string(forKey: argument)
    }

    /// The F-LIBLOC library (deterministic names; fresh identities).
    nonisolated static func library(base: LibraryModel) -> LibraryModel {
        var library = base
        let shows = (1...12).map { _ in ShowID() }
        for (index, id) in shows.enumerated() {
            library = LibraryReconciler.registering(id, title: String(format: "Location Show %02d", index + 1), publication: nil, in: library)
        }
        let seeded = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 9..<12 {
            library.entries[library.entries.firstIndex { $0.showID == shows[index] }!].unavailable =
                UnavailableRecord(note: "Can't find show file", recordedAt: seeded)
        }
        library.collections = [
            LibraryCollection(name: "Alpha", showIDs: [shows[0], shows[1], shows[2]]),
            LibraryCollection(name: "Season 1", showIDs: [shows[0], shows[3], shows[4]]),
            LibraryCollection(name: "Season 2", showIDs: [shows[6], shows[5]]),
            LibraryCollection(name: "Specials", showIDs: [shows[7]]),
            LibraryCollection(name: "Archive", showIDs: [shows[8], shows[9], shows[10]]),
        ]
        library.recentShowIDs = Array(shows[0..<8].reversed())
        return library
    }

    /// Runs before the app's library store loads (from `LaunchFixtures.applyBeforeLaunch`, after storage reset).
    static func applyBeforeLaunch() {
        guard let state = requestedState else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await seed(state: state)
            done.signal()
        }
        done.wait()
        if state == "unreachable" || state == "permission" {
            LibraryFolderFaults.shared.fault = state == "unreachable" ? .unreachable : .permission
            observer = DistributedNotificationCenter.default().addObserver(forName: restoreNotification, object: nil, queue: .main) { _ in
                LibraryFolderFaults.shared.fault = .none
            }
        }
    }

    /// Runs after launch: the L4 external change, once the app has loaded the library.
    static func applyAfterLaunch() {
        guard requestedState == "conflict" else { return }
        Task {
            for _ in 0..<100 where LibraryDocumentStore.shared.library == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await publishExternalChange()
        }
    }

    /// `-WWUITestHoldMoveSteps YES`: after a move, show its steps for a moment each (they last milliseconds on a
    /// local disk), so a test can read "Moving library — checking copy…". The move has already finished; this
    /// only holds the progress the store reported.
    static func holdFinishedMoveSteps(_ show: (LibraryMoveStep?) -> Void) async {
        guard PersistenceEnvironment.isUITestRun, UserDefaults.standard.bool(forKey: "WWUITestHoldMoveSteps") else { return }
        show(.checking)
        try? await Task.sleep(for: .seconds(2))
        show(nil)
    }

    /// Another writer (as another Mac would) publishes a change to the same library file.
    nonisolated private static func publishExternalChange() async {
        let other = makeStore(bookmarks: SecurityScopedFolderBookmarks())
        _ = await other.load()
        let result = try? await other.update { library in
            var library = library
            library.collections.append(LibraryCollection(name: "From Another Mac"))
            return library
        }
        logger.notice("L4 external change: \(String(describing: result), privacy: .public)")
    }

    nonisolated private static func makeStore(bookmarks: any FolderBookmarking) -> LibraryStore {
        LibraryStore(
            containerFolder: PersistenceEnvironment.applicationSupport("Library"),
            settings: UserDefaultsLibraryLocationSettings(suiteName: "com.brandonmartinez.wavewrangler.uitest-preferences"),
            bookmarks: bookmarks,
            recovery: PersistenceEnvironment.recovery,
            indexCache: LibraryIndexCache(url: PersistenceEnvironment.caches("LibraryIndex/index.json"))
        )
    }

    nonisolated private static func seed(state: String) async {
        let store = makeStore(bookmarks: SecurityScopedFolderBookmarks())
        let loaded = await store.load()
        let seeded = try? await store.update { library(base: $0) }
        logger.notice("F-LIBLOC seeded: load \(String(describing: loaded), privacy: .public) update \(String(describing: seeded), privacy: .public)")
        switch state {
        case "unreachable", "permission":
            let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "WWLibraryLocation-Current", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let moved = await store.moveLibrary(to: folder)
            logger.notice("moved into \(folder.path, privacy: .public): \(String(describing: moved), privacy: .public)")
        case "newer":
            guard let url = await store.currentLibraryURL(), var text = try? String(contentsOf: url, encoding: .utf8) else { return }
            text = text.replacingOccurrences(of: "\"schemaVersion\":\(SchemaVersion.library)", with: "\"schemaVersion\":99")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            logger.notice("library file marked newer: \(url.path, privacy: .public)")
        default:
            break
        }
    }
}

/// Folder-bookmark resolution with injectable faults (Debug, UI tests): `.unreachable` resolves to a folder that
/// doesn't exist (the store reports L2 "can't reach"), `.permission` fails to resolve (L3). Making a new bookmark
/// (Grant Access…) clears `.permission`. Everything else is the real security-scoped implementation.
final class LibraryFolderFaults: FolderBookmarking, @unchecked Sendable {
    enum Fault { case none, unreachable, permission }

    static let shared = LibraryFolderFaults()

    private let base = SecurityScopedFolderBookmarks()
    private let lock = NSLock()
    private var current = Fault.none

    var fault: Fault {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// The app's library store uses this only in UI-test runs that ask for a fault.
    static var isRequested: Bool {
        guard PersistenceEnvironment.isUITestRun else { return false }
        let state = UserDefaults.standard.string(forKey: LibraryLocationFixture.argument)
        return state == "unreachable" || state == "permission"
    }

    func bookmark(for folder: URL) throws -> Data {
        let data = try base.bookmark(for: folder)
        lock.withLock { if current == .permission { current = .none } }
        return data
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        switch fault {
        case .permission:
            throw CocoaError(.fileReadNoPermission)
        case .unreachable:
            let resolved = try base.resolve(bookmark)
            return (resolved.url.appending(path: "Unreachable (UI test)", directoryHint: .isDirectory), false)
        case .none:
            return try base.resolve(bookmark)
        }
    }

    func startAccessing(_ url: URL) -> Bool { base.startAccessing(url) }
    func stopAccessing(_ url: URL) { base.stopAccessing(url) }
}
#endif
