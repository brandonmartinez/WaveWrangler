import Foundation
import Synchronization
import WWCore

/// "As of last open" summary of a show, kept device-locally for the Library window (IA §3.3). Rebuildable
/// and never canonical: the show document is authoritative and refreshes it when it is opened or saved.
public struct ShowLastOpenSummary: Sendable, Equatable, Codable {
    public struct Episode: Sendable, Equatable, Codable {
        public var id: EpisodeID
        public var number: Int?
        public var title: String

        public init(id: EpisodeID, number: Int?, title: String) {
            self.id = id
            self.number = number
            self.title = title
        }
    }

    public var showID: ShowID
    /// Folder display name at the last confirmed location (never a full path).
    public var folderDisplayName: String?
    public var lastOpened: Date?
    /// `nil` when only the location is known (e.g. the show was opened with unsaved edits).
    public var episodes: [Episode]?
    public var sourceReferenceCount: Int?

    public init(showID: ShowID, folderDisplayName: String? = nil, lastOpened: Date? = nil, episodes: [Episode]? = nil, sourceReferenceCount: Int? = nil) {
        self.showID = showID
        self.folderDisplayName = folderDisplayName
        self.lastOpened = lastOpened
        self.episodes = episodes
        self.sourceReferenceCount = sourceReferenceCount
    }
}

/// Metadata-only observation of a show's recorded location. Never reads the show's content.
public enum ShowLocationCheck: Sendable, Equatable {
    /// No location is recorded on this Mac (e.g. the library came from another Mac).
    case unknown
    /// The recorded (or followed) location exists. Identity is verified only when the show is opened.
    case reachable(folderDisplayName: String)
    /// The recorded location no longer has the file.
    case notFound(folderDisplayName: String?)
    /// The saved permission can't be used (unresolvable bookmark or access denied).
    case needsPermission(reason: String)
    /// The location can't be checked right now (e.g. the volume or provider is unavailable).
    case unavailable(reason: String)
}

/// A started security scope for opening a show. Stop it with `LibraryShowLocations.endAccess(_:)` when the
/// show's last window closes. Scopes are permission hints, never locks or identity.
public struct ShowAccessGrant: Sendable, Equatable {
    public let showID: ShowID
    public let url: URL
    public let started: Bool
    /// The bookmark resolved somewhere other than the recorded path; the caller must verify the ShowID
    /// before trusting the file (and then re-record).
    public let followedMove: Bool
}

public enum ShowAccessError: Error, Sendable, Equatable {
    case noRecord
    case needsPermission(String)
    case notFound(folderDisplayName: String?)
}

/// Device-local show locations for the library (WW-011 / #88): read-write document bookmarks via
/// `ShowLocationStore` plus a persisted "as of last open" summary. Everything here is outside canonical
/// documents, keyed by logical `ShowID`; paths and bookmarks are hints only.
public final class LibraryShowLocations: Sendable {
    public let locations: ShowLocationStore
    private let bookmarks: any DocumentBookmarking
    private let summariesURL: URL
    private let summaries: Mutex<[ShowID: ShowLastOpenSummary]>
    private let balance = Mutex((started: 0, stopped: 0))

    /// - Parameters:
    ///   - root: device-local folder for this store (inside the sandbox container in the app).
    ///   - bookmarks: must be the same bookmarking used by `locations` (read-write show bookmarks).
    public init(root: URL, bookmarks: any DocumentBookmarking = SecurityScopedDocumentBookmarks()) {
        locations = ShowLocationStore(root: root.appending(path: "ShowLocations", directoryHint: .isDirectory), bookmarks: bookmarks)
        self.bookmarks = bookmarks
        summariesURL = root.appending(path: "last-open-summaries.json")
        summaries = Mutex(Self.loadSummaries(from: summariesURL))
    }

    /// Scope starts/stops performed by `check` and `beginAccess`/`endAccess` (must balance).
    public var scopeBalance: (started: Int, stopped: Int) { balance.withLock { $0 } }

    // MARK: - Recording

    /// Records `showID` at `url` with a fresh **read-write** bookmark (the caller must have access to `url`,
    /// e.g. the document is open). `summary` replaces the stored one when given; `openedAt` updates the
    /// last-opened time. Location and summary are independent: a failed bookmark still keeps the summary.
    public func record(
        _ showID: ShowID,
        at url: URL,
        summary: ShowLastOpenSummary? = nil,
        openedAt: Date? = nil
    ) throws {
        updateSummary(showID) { current in
            var next = summary ?? current ?? ShowLastOpenSummary(showID: showID)
            next.showID = showID
            next.folderDisplayName = url.deletingLastPathComponent().lastPathComponent
            next.lastOpened = openedAt.map(ShowLocationStore.wholeMilliseconds) ?? current?.lastOpened ?? next.lastOpened
            if summary == nil {
                next.episodes = current?.episodes
                next.sourceReferenceCount = current?.sourceReferenceCount
            }
            return next
        }
        try locations.record(showID, at: url)
    }

    /// Updates only the last-opened time (no bookmark needed).
    public func noteOpened(_ showID: ShowID, at date: Date = Date()) {
        updateSummary(showID) { current in
            var next = current ?? ShowLastOpenSummary(showID: showID)
            next.lastOpened = ShowLocationStore.wholeMilliseconds(date)
            return next
        }
    }

    /// The last confirmed path of the recorded location (a hint for Show in Finder; never identity).
    public func pathHint(for showID: ShowID) -> String? {
        locations.record(for: showID)?.pathHint
    }

    public func summary(for showID: ShowID) -> ShowLastOpenSummary? {
        summaries.withLock { $0[showID] }
    }

    public func allSummaries() -> [ShowID: ShowLastOpenSummary] {
        summaries.withLock { $0 }
    }

    public func hasRecord(_ showID: ShowID) -> Bool {
        locations.record(for: showID) != nil
    }

    // MARK: - Checking (metadata only)

    /// Resolves the recorded bookmark and checks the file is reachable, holding the scope only for the
    /// check. Reads no content. Call off the main thread (bookmark resolution can block on providers).
    public func check(_ showID: ShowID) -> ShowLocationCheck {
        guard let record = locations.record(for: showID) else { return .unknown }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.resolve(record.bookmark)
        } catch {
            return Self.isMissingFile(error)
                ? .notFound(folderDisplayName: Self.folderName(ofPathHint: record.pathHint))
                : .needsPermission(reason: "The saved permission for this show can't be used any more.")
        }
        let url = resolved.url.standardizedFileURL
        let started = startAccessing(url)
        defer { if started { stopAccessing(url) } }
        do {
            _ = try url.checkResourceIsReachable()
            return .reachable(folderDisplayName: url.deletingLastPathComponent().lastPathComponent)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .needsPermission(reason: "WaveWrangler doesn't have permission to open this show's folder.")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .notFound(folderDisplayName: Self.folderName(ofPathHint: record.pathHint))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
                return .notFound(folderDisplayName: Self.folderName(ofPathHint: record.pathHint))
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return .needsPermission(reason: "WaveWrangler doesn't have permission to open this show's folder.")
            }
            return .unavailable(reason: "The show's location can't be checked right now.")
        }
    }

    // MARK: - Opening

    /// Resolves the bookmark and starts its scope for opening the show. The scope stays active until
    /// `endAccess` (the open document needs it to save). The caller must verify the ShowID of what it opens.
    public func beginAccess(_ showID: ShowID) throws(ShowAccessError) -> ShowAccessGrant {
        guard let record = locations.record(for: showID) else { throw .noRecord }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.resolve(record.bookmark)
        } catch {
            if Self.isMissingFile(error) { throw .notFound(folderDisplayName: Self.folderName(ofPathHint: record.pathHint)) }
            throw .needsPermission("The saved permission for this show can't be used any more.")
        }
        let url = resolved.url.standardizedFileURL
        let started = startAccessing(url)
        guard (try? url.checkResourceIsReachable()) == true else {
            if started { stopAccessing(url) }
            throw .notFound(folderDisplayName: Self.folderName(ofPathHint: record.pathHint))
        }
        let followedMove = ShowLocationStore.canonicalPath(url) != record.pathHint
        return ShowAccessGrant(showID: showID, url: url, started: started, followedMove: followedMove)
    }

    public func endAccess(_ grant: ShowAccessGrant) {
        if grant.started { stopAccessing(grant.url) }
    }

    // MARK: - Internals

    /// A bookmark to a file that no longer exists fails to resolve with "no such file", which is a missing
    /// file, not a permission problem (denied ≠ missing).
    static func isMissingFile(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileNoSuchFile.rawValue || nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    static func folderName(ofPathHint path: String) -> String {
        URL(filePath: path).deletingLastPathComponent().lastPathComponent
    }

    private func startAccessing(_ url: URL) -> Bool {
        let started = bookmarks.startAccessing(url)
        if started { balance.withLock { $0.started += 1 } }
        return started
    }

    private func stopAccessing(_ url: URL) {
        bookmarks.stopAccessing(url)
        balance.withLock { $0.stopped += 1 }
    }

    private func updateSummary(_ showID: ShowID, _ transform: (ShowLastOpenSummary?) -> ShowLastOpenSummary) {
        let snapshot = summaries.withLock { all -> [ShowID: ShowLastOpenSummary] in
            all[showID] = transform(all[showID])
            return all
        }
        try? Self.saveSummaries(snapshot, to: summariesURL)
    }

    private struct SummaryFile: Codable {
        var kind = "library-last-open-summaries"
        var version = 1
        var summaries: [ShowLastOpenSummary]
    }

    private static func loadSummaries(from url: URL) -> [ShowID: ShowLastOpenSummary] {
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(SummaryFile.self, from: data), file.version == 1 else { return [:] }
        return Dictionary(file.summaries.map { ($0.showID, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func saveSummaries(_ all: [ShowID: ShowLastOpenSummary], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ordered = all.values.sorted { $0.showID.rawValue.uuidString < $1.showID.rawValue.uuidString }
        try encoder.encode(SummaryFile(summaries: ordered)).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalDate.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = CanonicalDate.date(from: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "timestamp")
            }
            return date
        }
        return decoder
    }()
}
