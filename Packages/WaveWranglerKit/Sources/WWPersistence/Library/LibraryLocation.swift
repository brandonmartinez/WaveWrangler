import Foundation

/// Persisted choice of where the canonical library document lives.
public struct LibraryLocationSetting: Sendable, Equatable, Codable {
    public enum Place: Sendable, Equatable, Codable {
        /// The app container (Application Support) on this Mac — the default.
        case appContainer
        /// A user-chosen folder (possibly iCloud Drive/OneDrive/Dropbox), persisted as a security-scoped
        /// bookmark. The bookmark is a permission/location hint, never the library's identity.
        case folder(bookmark: Data, displayPath: String)
    }

    public static let defaultFileName = "Library.wwlibrary"
    public static let userDefaultsKey = "WWLibraryLocation"

    public var place: Place
    public var fileName: String

    public init(place: Place = .appContainer, fileName: String = LibraryLocationSetting.defaultFileName) {
        self.place = place
        self.fileName = fileName
    }
}

/// Where the location setting is stored (UserDefaults in the app; in-memory in tests).
public protocol LibraryLocationSettingsStoring: Sendable {
    func load() -> LibraryLocationSetting
    func save(_ setting: LibraryLocationSetting) throws
}

public struct UserDefaultsLibraryLocationSettings: LibraryLocationSettingsStoring {
    /// `nil` = `UserDefaults.standard`. Stored by name because `UserDefaults` is not `Sendable`.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> LibraryLocationSetting {
        guard let data = defaults.data(forKey: LibraryLocationSetting.userDefaultsKey),
              let setting = try? JSONDecoder().decode(LibraryLocationSetting.self, from: data)
        else { return LibraryLocationSetting() }
        return setting
    }

    public func save(_ setting: LibraryLocationSetting) throws {
        defaults.set(try JSONEncoder().encode(setting), forKey: LibraryLocationSetting.userDefaultsKey)
    }
}

/// Creates/resolves persisted folder grants.
public protocol FolderBookmarking: Sendable {
    func bookmark(for folder: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    /// Begins access for an operation; must be balanced by `stopAccessing`. Not a lock.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Read-write security-scoped folder bookmarks (app-scoped; requires the user-selected read-write and
/// app-scope bookmark entitlements).
public struct SecurityScopedFolderBookmarks: FolderBookmarking {
    public init() {}

    public func bookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Status of the configured library location, for the Settings pane.
public enum LibraryLocationStatus: Sendable, Equatable {
    case appContainer(URL)
    case folder(URL, displayPath: String)
    /// The bookmark could not be resolved or the folder is unreachable; the library is not silently recreated.
    case unavailable(displayPath: String, reason: String)

    public var title: String {
        switch self {
        case .appContainer: "On this Mac (app container)"
        case let .folder(_, path): "In folder: \(path)"
        case let .unavailable(path, reason): "Unavailable — \(path): \(reason)"
        }
    }
}

/// Outcome of moving the library to another folder.
public enum LibraryMoveOutcome: Sendable, Equatable {
    /// Copied, independently verified, setting switched. The previous copy was kept as a backup.
    case moved(to: URL, previousCopyKept: URL)
    /// The destination already held this exact library (e.g. an interrupted earlier move); adopted.
    case adoptedIdentical(URL)
    /// The destination holds a different library. Nothing was overwritten; offer "Use That Library"
    /// (`useLibrary(in:)`, which combines) or cancel.
    case destinationHasLibrary(URL, revision: Int?)
    /// The destination holds something that is not a readable library. Nothing was changed.
    case destinationUnusable(URL, reason: String)
    /// This Mac's library was combined into the destination library, which is now in use. The previous
    /// location was kept as a backup.
    case combined(into: URL, previousCopyKept: URL?, summary: LibraryMergeSummary)
}

/// Library-level states (Design L1–L5) for the Library window message bar and Settings.
public enum LibraryLevelState: Sendable, Equatable {
    case notLoaded
    /// L1.
    case ready
    /// L2: the folder or provider cannot be reached. The last validated prior is shown read-only.
    case unreachable(reason: String)
    /// L3: permission to the folder must be granted again.
    case needsPermission
    /// L4: another writer published a different library; nothing was overwritten. Resolve with
    /// `resolveConflictByCombining()` or `resolveConflictUsingOtherVersion()`.
    case changedElsewhere
    /// L5: newer format; read-only, never saved or down-saved.
    case newerFormat
    /// Damaged/missing with whole checkpoints available (`recoverAsNewCopy(revision:)`).
    case damaged(recoveryRevisions: [Int])
}
