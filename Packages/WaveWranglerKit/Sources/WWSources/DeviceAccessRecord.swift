import Foundation
import WWCore

/// Identifies a device-local access record. Source IDs are show-scoped (a duplicated show keeps them),
/// so records are keyed by show *and* source: relinking or forgetting a source in one show never touches
/// the same logical source in another show.
public struct DeviceAccessKey: Sendable, Codable, Hashable, CustomStringConvertible {
    public var showID: ShowID
    public var sourceID: SourceID

    public init(showID: ShowID, sourceID: SourceID) {
        self.showID = showID
        self.sourceID = sourceID
    }

    public var description: String { "\(showID)/\(sourceID)" }
}

/// Device-local mapping from a show's logical source to this machine's location hint, read-only grant and
/// identity baseline. Never written into canonical (portable) show or library documents: a show opened
/// on another Mac has no records there and every source starts as "relink required".
public struct DeviceAccessRecord: Sendable, Codable, Equatable, Identifiable {
    /// Independently versioned access-record schema (see WW-009 C2 version records).
    public static let schemaVersion = 1

    public var showID: ShowID
    public var sourceID: SourceID
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

    public var key: DeviceAccessKey { DeviceAccessKey(showID: showID, sourceID: sourceID) }
    public var id: DeviceAccessKey { key }

    public init(
        showID: ShowID,
        sourceID: SourceID,
        bookmark: Data? = nil,
        lastKnownPath: String? = nil,
        lastKnownVolumeUUID: String? = nil,
        recordedIdentity: RecordedIdentity? = nil,
        createdAt: Date,
        lastBookmarkRefreshAt: Date? = nil,
        latestObservation: AvailabilityObservation? = nil,
        relinkHistory: [RelinkEvent] = []
    ) {
        self.showID = showID
        self.sourceID = sourceID
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

/// Storage seam for device-local access records, keyed by (show, source).
public protocol DeviceAccessStore: Sendable {
    func record(for key: DeviceAccessKey) async throws -> DeviceAccessRecord?
    func records(in showID: ShowID) async throws -> [DeviceAccessRecord]
    func allRecords() async throws -> [DeviceAccessRecord]
    func save(_ record: DeviceAccessRecord) async throws
    func save(_ records: [DeviceAccessRecord]) async throws
    func removeRecord(for key: DeviceAccessKey) async throws
    func removeRecords(in showID: ShowID) async throws
}

/// Opaque store-issued mutation identity. It is not source identity, permission, or content consent.
/// In particular, callers cannot create one from a bookmark or from a decoded DeviceAccessRecord.
public struct DeviceAccessGeneration: Sendable, Hashable {
    fileprivate let value: UUID

    fileprivate init(_ value: UUID) { self.value = value }
}

/// A single actor read of one device-local record and its store-issued mutation identity.
/// Legacy records have no generation. A future content opener must re-fetch the current snapshot
/// after every await and compare it with its earlier snapshot; neither snapshot grants an open.
public struct DeviceAccessSnapshot: Sendable, Equatable {
    public let record: DeviceAccessRecord
    public let mutationGeneration: DeviceAccessGeneration?

    fileprivate init(record: DeviceAccessRecord, mutationGeneration: DeviceAccessGeneration?) {
        self.record = record
        self.mutationGeneration = mutationGeneration
    }
}

/// Additive snapshot seam; legacy DeviceAccessStore conformers do not silently gain authority.
public protocol DeviceAccessSnapshotStore: DeviceAccessStore {
    func snapshot(for key: DeviceAccessKey) async throws -> DeviceAccessSnapshot?
}

extension Array where Element == DeviceAccessRecord {
    func sortedByKey() -> [DeviceAccessRecord] {
        sorted { $0.key.description < $1.key.description }
    }
}

public enum DeviceAccessStoreError: Error, Equatable, Sendable {
    /// The store was written by a newer app version; it is left untouched and not overwritten.
    case unsupportedNewerSchema(Int)
    case unreadable(SourceErrorDescriptor)
}

public actor InMemoryDeviceAccessStore: DeviceAccessSnapshotStore {
    private var records: [DeviceAccessKey: DeviceAccessSnapshot] = [:]

    public init(_ records: [DeviceAccessRecord] = []) {
        for record in records { self.records[record.key] = DeviceAccessSnapshot(record: record, mutationGeneration: nil) }
    }

    public func snapshot(for key: DeviceAccessKey) -> DeviceAccessSnapshot? { records[key] }
    public func record(for key: DeviceAccessKey) -> DeviceAccessRecord? { records[key]?.record }
    public func records(in showID: ShowID) -> [DeviceAccessRecord] {
        records.values.map(\.record).filter { $0.showID == showID }.sortedByKey()
    }
    public func allRecords() -> [DeviceAccessRecord] { records.values.map(\.record).sortedByKey() }
    public func save(_ record: DeviceAccessRecord) {
        records[record.key] = DeviceAccessSnapshot(record: record, mutationGeneration: DeviceAccessGeneration(UUID()))
    }
    public func save(_ records: [DeviceAccessRecord]) { for record in records { save(record) } }
    public func removeRecord(for key: DeviceAccessKey) { records[key] = nil }
    public func removeRecords(in showID: ShowID) { records = records.filter { $0.key.showID != showID } }
}

/// JSON-file store in the app container (Application Support). The store file is the only thing it
/// ever writes; it never touches sources.
public actor FileDeviceAccessStore: DeviceAccessSnapshotStore {
    private static let storeSchemaVersion = 2

    private struct LegacyEnvelope: Decodable {
        var schemaVersion: Int
        var records: [DeviceAccessRecord]
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [StoredEntry]
    }

    private struct StoredEntry: Codable {
        var record: DeviceAccessRecord
        var generation: UUID?

        private enum CodingKeys: String, CodingKey { case record, generation }

        init(record: DeviceAccessRecord, generation: UUID?) {
            self.record = record
            self.generation = generation
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            record = try container.decode(DeviceAccessRecord.self, forKey: .record)
            guard container.contains(.generation) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.generation,
                    .init(codingPath: container.codingPath, debugDescription: "Missing access-record generation")
                )
            }
            generation = try container.decodeIfPresent(UUID.self, forKey: .generation)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(record, forKey: .record)
            try container.encode(generation, forKey: .generation)
        }
    }

    private struct Header: Codable {
        var schemaVersion: Int
    }

    public let fileURL: URL
    private var hasObservedFile = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/WaveWrangler/DeviceAccess/source-access-records.json` (inside the
    /// sandbox container when sandboxed).
    public static func defaultFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("WaveWrangler/DeviceAccess/source-access-records.json", isDirectory: false)
    }

    public func snapshot(for key: DeviceAccessKey) throws -> DeviceAccessSnapshot? { try load()[key] }
    public func record(for key: DeviceAccessKey) throws -> DeviceAccessRecord? { try load()[key]?.record }

    public func records(in showID: ShowID) throws -> [DeviceAccessRecord] {
        try load().values.map(\.record).filter { $0.showID == showID }.sortedByKey()
    }

    public func allRecords() throws -> [DeviceAccessRecord] {
        try load().values.map(\.record).sortedByKey()
    }

    public func save(_ record: DeviceAccessRecord) throws {
        try save([record])
    }

    public func save(_ records: [DeviceAccessRecord]) throws {
        var all = try load()
        for record in records {
            all[record.key] = DeviceAccessSnapshot(record: record, mutationGeneration: DeviceAccessGeneration(UUID()))
        }
        try persist(all)
    }

    public func removeRecord(for key: DeviceAccessKey) throws {
        var all = try load()
        guard all.removeValue(forKey: key) != nil else { return }
        try persist(all)
    }

    public func removeRecords(in showID: ShowID) throws {
        let all = try load()
        let kept = all.filter { $0.key.showID != showID }
        guard kept.count != all.count else { return }
        try persist(kept)
    }

    private func load() throws -> [DeviceAccessKey: DeviceAccessSnapshot] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            if hasObservedFile { throw DeviceAccessStoreError.unreadable(SourceErrorDescriptor(error)) }
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
        guard header.schemaVersion <= Self.storeSchemaVersion else {
            throw DeviceAccessStoreError.unsupportedNewerSchema(header.schemaVersion)
        }
        do {
            let entries: [DeviceAccessSnapshot]
            switch header.schemaVersion {
            case 1:
                entries = try decoder.decode(LegacyEnvelope.self, from: data).records.map {
                    DeviceAccessSnapshot(record: $0, mutationGeneration: nil)
                }
            case Self.storeSchemaVersion:
                entries = try decoder.decode(Envelope.self, from: data).records.map {
                    DeviceAccessSnapshot(
                        record: $0.record,
                        mutationGeneration: $0.generation.map(DeviceAccessGeneration.init)
                    )
                }
            default:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Unsupported access-record schema")
                )
            }
            var records: [DeviceAccessKey: DeviceAccessSnapshot] = [:]
            for entry in entries {
                guard records.updateValue(entry, forKey: entry.record.key) == nil else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Duplicate device access key")
                    )
                }
            }
            hasObservedFile = true
            return records
        } catch {
            throw DeviceAccessStoreError.unreadable(SourceErrorDescriptor(error))
        }
    }

    private func persist(_ records: [DeviceAccessKey: DeviceAccessSnapshot]) throws {
        // Keep the default (full-precision) date encoding: identity baselines compare dates within 1 ms, so a
        // lossy strategy such as `.iso8601` (whole seconds) would turn every source "changed" (#121).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(
            schemaVersion: Self.storeSchemaVersion,
            records: records.values.sorted { $0.record.key.description < $1.record.key.description }.map {
                StoredEntry(record: $0.record, generation: $0.mutationGeneration?.value)
            }
        )
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        hasObservedFile = true
    }
}
