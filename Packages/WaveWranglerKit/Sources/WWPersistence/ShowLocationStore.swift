import Foundation
import Synchronization
import WWCore

/// Creates/resolves read-write document bookmarks. Security scopes are permission hints held only for one
/// operation, never locks, and never identity.
public protocol DocumentBookmarking: Sendable {
    func bookmark(for file: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Read-write security-scoped document bookmarks (app-scoped; inside the sandbox this needs the
/// user-selected read-write and app-scope bookmark entitlements).
public struct SecurityScopedDocumentBookmarks: DocumentBookmarking {
    public init() {}

    public func bookmark(for file: URL) throws -> Data {
        try file.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Device-local record of where a show document was last opened or saved on this Mac.
public struct ShowLocationRecord: Sendable, Equatable, Codable {
    public var recordKind = "show-location"
    public let showID: ShowID
    /// Read-write document bookmark: a location/permission hint, never identity.
    public var bookmark: Data
    /// Last confirmed path (hint only; used to notice that a bookmark now resolves somewhere else).
    public var pathHint: String
    public var recordedAt: Date

    public init(showID: ShowID, bookmark: Data, pathHint: String, recordedAt: Date) {
        self.showID = showID
        self.bookmark = bookmark
        self.pathHint = pathHint
        self.recordedAt = recordedAt
    }
}

/// Result of reopening a show from its device-local location record.
public enum ShowReopenOutcome: Sendable {
    /// Resolved, accessed and opened: the same show (by `ShowID`) at the recorded location.
    case opened(url: URL, document: DecodedDocument<ShowDocumentModel>, fingerprint: RevisionFingerprint, refreshedStaleBookmark: Bool)
    /// The grant can't be used (unresolvable bookmark, access denied). Nothing was read or written.
    case regrantRequired(reason: String)
    /// The bookmark now resolves somewhere else, or a different show is there. Nothing was written; the user
    /// confirms a relink (or regrants) before anything is saved there.
    case relinkRequired(candidate: URL?, reason: String)
    /// The show at the recorded location can't be edited (damaged, newer format…).
    case refused(OpenOutcome<ShowDocumentModel>)
    case noRecord
}

/// Device-local show location records (WW-009 C2 "device-local access records"; M1-DUR-029). Records are
/// whole-file JSON written atomically; nothing here is canonical or portable across devices.
public final class ShowLocationStore: Sendable {
    public let root: URL
    private let ops: any FileOperations
    private let bookmarks: any DocumentBookmarking
    private let balance = Mutex((started: 0, stopped: 0))

    public init(root: URL, ops: any FileOperations = LocalFileOperations(), bookmarks: any DocumentBookmarking = SecurityScopedDocumentBookmarks()) {
        self.root = root
        self.ops = ops
        self.bookmarks = bookmarks
    }

    /// `~/Library/Application Support/WaveWrangler/ShowLocations` (inside the sandbox container when sandboxed).
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WaveWrangler/ShowLocations", directoryHint: .isDirectory)
    }

    /// Scope starts and stops performed by this store (they must balance).
    public var scopeBalance: (started: Int, stopped: Int) { balance.withLock { $0 } }

    /// Records (or replaces) the location of `showID` with a fresh read-write bookmark to `url`.
    public func record(_ showID: ShowID, at url: URL, date: Date = Date()) throws {
        let record = ShowLocationRecord(showID: showID, bookmark: try bookmarks.bookmark(for: url), pathHint: Self.canonicalPath(url), recordedAt: Self.wholeMilliseconds(date))
        try write(record)
    }

    public func record(for showID: ShowID) -> ShowLocationRecord? {
        guard let data = try? ops.read(recordURL(showID)) else { return nil }
        return try? Self.decoder.decode(ShowLocationRecord.self, from: data)
    }

    /// Resolves the record, starts access for the duration of `body` only, opens the show and confirms it is
    /// the same show; `body` (e.g. edit + Save) runs only then. Access is always stopped afterwards.
    public func withReopenedShow<T>(
        _ showID: ShowID,
        opener: DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>,
        body: (URL, DecodedDocument<ShowDocumentModel>, RevisionFingerprint) async throws -> T
    ) async rethrows -> (outcome: ShowReopenOutcome, result: T?) {
        guard var record = record(for: showID) else { return (.noRecord, nil) }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.resolve(record.bookmark)
        } catch {
            return (.regrantRequired(reason: "The saved permission for this show can't be used any more."), nil)
        }
        let url = resolved.url.standardizedFileURL
        guard Self.canonicalPath(url) == record.pathHint else {
            return (.relinkRequired(candidate: url, reason: "The show is no longer where it was last opened."), nil)
        }
        let started = bookmarks.startAccessing(url)
        if started { balance.withLock { $0.started += 1 } }
        defer {
            if started {
                bookmarks.stopAccessing(url)
                balance.withLock { $0.stopped += 1 }
            }
        }
        switch opener.open(url, key: .show(showID)) {
        case let .editable(document, fingerprint):
            var refreshed = false
            if resolved.isStale, let fresh = try? bookmarks.bookmark(for: url) {
                // Refreshed only while access is valid and the identity has been confirmed.
                record.bookmark = fresh
                record.recordedAt = Self.wholeMilliseconds(Date())
                refreshed = (try? write(record)) != nil
            }
            let result = try await body(url, document, fingerprint)
            return (.opened(url: url, document: document, fingerprint: fingerprint, refreshedStaleBookmark: refreshed), result)
        case let .unreadable(kind, detail, _) where kind == .permissionDenied:
            return (.regrantRequired(reason: detail), nil)
        case .unreadable:
            return (.relinkRequired(candidate: nil, reason: "The show can't be found where it was last opened."), nil)
        case let .damaged(.identityMismatch(_, found), _):
            return (.relinkRequired(candidate: url, reason: "A different show (\(found)) is at this show's location."), nil)
        case let other:
            return (.refused(other), nil)
        }
    }

    // MARK: - Internals

    private func recordURL(_ showID: ShowID) -> URL {
        root.appending(path: "\(DocumentKey.show(showID).rawValue).json")
    }

    private func write(_ record: ShowLocationRecord) throws {
        let data = try Self.encoder.encode(record)
        let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
        try ops.createDirectory(staging)
        let staged = staging.appending(path: UUID().uuidString)
        try ops.writeNew(data, to: staged)
        try ops.replace(recordURL(record.showID), withStaged: staged)
    }

    /// Path with symlinks resolved (e.g. `/var` → `/private/var`) so hints compare reliably.
    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func wholeMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64((date.timeIntervalSince1970 * 1000).rounded())) / 1000)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalDate.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
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

extension DocumentOpener where Coder == JSONEnvelopeCoder<ShowDocumentModel> {
    /// A show opener that refuses a different show found at an expected location.
    public static func show(
        ops: any FileOperations = LocalFileOperations(),
        coordination: any FileCoordinating = NSFileCoordination(),
        recovery: RecoveryStore?,
        migratableSchemas: Set<Int> = []
    ) -> DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>> {
        DocumentOpener(coder: .show, ops: ops, coordination: coordination, recovery: recovery,
                       migratableSchemas: migratableSchemas, identityOf: { .show($0.show.id) })
    }
}
