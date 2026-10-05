import Foundation
import WWCore

/// Device-local mapping from a logical source to this machine's location hint, read-only grant and
/// identity baseline. Never written into canonical (portable) show or library documents: a show opened
/// on another Mac has no records there and every source starts as "relink required".
public struct DeviceAccessRecord: Sendable, Codable, Equatable, Identifiable {
    /// Independently versioned access-record schema (see WW-009 C2 version records).
    public static let schemaVersion = 1

    public var sourceID: SourceID
    /// Owning show document, when known (diagnostics and cleanup; not identity).
    public var showID: ShowID?
    /// Read-only security-scoped bookmark: a permission/location hint, never identity.
    public var bookmark: Data?
    /// Last confirmed absolute path (hint for relink UI only).
    public var lastKnownPath: String?
    /// Last confirmed volume (hint only; part of identity evidence lives in `recordedIdentity`).
    public var lastKnownVolumeUUID: String?
    public var recordedIdentity: RecordedIdentity?
    public var createdAt: Date
    public var lastBookmarkRefreshAt: Date?
    public var latestObservation: AvailabilityObservation?
    /// Explicit relinks, newest last (audit of user decisions; no paths).
    public var relinkHistory: [RelinkEvent]

    public var id: SourceID { sourceID }

    public init(
        sourceID: SourceID,
        showID: ShowID? = nil,
        bookmark: Data? = nil,
        lastKnownPath: String? = nil,
        lastKnownVolumeUUID: String? = nil,
        recordedIdentity: RecordedIdentity? = nil,
        createdAt: Date,
        lastBookmarkRefreshAt: Date? = nil,
        latestObservation: AvailabilityObservation? = nil,
        relinkHistory: [RelinkEvent] = []
    ) {
        self.sourceID = sourceID
        self.showID = showID
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.lastKnownVolumeUUID = lastKnownVolumeUUID
        self.recordedIdentity = recordedIdentity
        self.createdAt = createdAt
        self.lastBookmarkRefreshAt = lastBookmarkRefreshAt
        self.latestObservation = latestObservation
        self.relinkHistory = relinkHistory
    }
}

/// One explicit relink decision.
public struct RelinkEvent: Sendable, Codable, Equatable {
    public var at: Date
    public var comparison: IdentityComparison
    public var userConfirmed: Bool

    public init(at: Date, comparison: IdentityComparison, userConfirmed: Bool) {
        self.at = at
        self.comparison = comparison
        self.userConfirmed = userConfirmed
    }
}

/// Storage seam for device-local access records.
public protocol DeviceAccessStore: Sendable {
    func record(for sourceID: SourceID) async throws -> DeviceAccessRecord?
    func allRecords() async throws -> [DeviceAccessRecord]
    func save(_ record: DeviceAccessRecord) async throws
    func save(_ records: [DeviceAccessRecord]) async throws
    func removeRecord(for sourceID: SourceID) async throws
}

public enum DeviceAccessStoreError: Error, Equatable, Sendable {
    /// The store was written by a newer app version; it is left untouched and not overwritten.
    case unsupportedNewerSchema(Int)
    case unreadable(SourceErrorDescriptor)
}

public actor InMemoryDeviceAccessStore: DeviceAccessStore {
    private var records: [SourceID: DeviceAccessRecord] = [:]

    public init(_ records: [DeviceAccessRecord] = []) {
        for record in records { self.records[record.sourceID] = record }
    }

    public func record(for sourceID: SourceID) -> DeviceAccessRecord? { records[sourceID] }
    public func allRecords() -> [DeviceAccessRecord] { records.values.sorted { $0.sourceID.description < $1.sourceID.description } }
    public func save(_ record: DeviceAccessRecord) { records[record.sourceID] = record }
    public func save(_ records: [DeviceAccessRecord]) { for record in records { self.records[record.sourceID] = record } }
    public func removeRecord(for sourceID: SourceID) { records[sourceID] = nil }
}

/// JSON-file store in the app container (Application Support). The store file is the only thing it
/// ever writes; it never touches sources.
public actor FileDeviceAccessStore: DeviceAccessStore {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [DeviceAccessRecord]
    }

    private struct Header: Codable {
        var schemaVersion: Int
    }

    public let fileURL: URL
    private var cache: [SourceID: DeviceAccessRecord]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/WaveWrangler/DeviceAccess/source-access-records.json` (inside the
    /// sandbox container when sandboxed).
    public static func defaultFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("WaveWrangler/DeviceAccess/source-access-records.json", isDirectory: false)
    }

    public func record(for sourceID: SourceID) throws -> DeviceAccessRecord? {
        try load()[sourceID]
    }

    public func allRecords() throws -> [DeviceAccessRecord] {
        try load().values.sorted { $0.sourceID.description < $1.sourceID.description }
    }

    public func save(_ record: DeviceAccessRecord) throws {
        try save([record])
    }

    public func save(_ records: [DeviceAccessRecord]) throws {
        var all = try load()
        for record in records { all[record.sourceID] = record }
        try persist(all)
    }

    public func removeRecord(for sourceID: SourceID) throws {
        var all = try load()
        guard all.removeValue(forKey: sourceID) != nil else { return }
        try persist(all)
    }

    private func load() throws -> [SourceID: DeviceAccessRecord] {
        if let cache { return cache }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            cache = [:]
            return [:]
        } catch {
            throw DeviceAccessStoreError.unreadable(SourceErrorDescriptor(error))
        }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw DeviceAccessStoreError.unreadable(SourceErrorDescriptor(error))
        }
        guard header.schemaVersion <= DeviceAccessRecord.schemaVersion else {
            throw DeviceAccessStoreError.unsupportedNewerSchema(header.schemaVersion)
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            let records = Dictionary(envelope.records.map { ($0.sourceID, $0) }, uniquingKeysWith: { _, newer in newer })
            cache = records
            return records
        } catch {
            throw DeviceAccessStoreError.unreadable(SourceErrorDescriptor(error))
        }
    }

    private func persist(_ records: [SourceID: DeviceAccessRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(
            schemaVersion: DeviceAccessRecord.schemaVersion,
            records: records.values.sorted { $0.sourceID.description < $1.sourceID.description }
        )
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        cache = records
    }
}
