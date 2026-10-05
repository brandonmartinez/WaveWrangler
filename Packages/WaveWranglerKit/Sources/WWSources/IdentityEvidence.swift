import Foundation
import WWCore

/// Identity evidence gathered from file-system metadata only (URL resource values). Nothing here reads
/// file content, headers or hashes.
///
/// `fileIdentifier` is the persistent per-volume file number (`URLResourceKey.fileIdentifierKey`), not the
/// boot-scoped `fileResourceIdentifierKey`, which Apple documents as not persistent across restarts.
/// `contentType` is derived from the filename extension via the system type database, not by sniffing.
public struct FileSystemFingerprint: Sendable, Codable, Equatable, Hashable {
    public var fileSize: Knowledge<Int64>
    public var creationDate: Knowledge<Date>
    public var contentModificationDate: Knowledge<Date>
    public var fileIdentifier: Knowledge<UInt64>
    public var volumeUUID: Knowledge<String>
    public var contentType: Knowledge<String>

    public init(
        fileSize: Knowledge<Int64> = .unknown,
        creationDate: Knowledge<Date> = .unknown,
        contentModificationDate: Knowledge<Date> = .unknown,
        fileIdentifier: Knowledge<UInt64> = .unknown,
        volumeUUID: Knowledge<String> = .unknown,
        contentType: Knowledge<String> = .unknown
    ) {
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        self.fileIdentifier = fileIdentifier
        self.volumeUUID = volumeUUID
        self.contentType = contentType
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fileSize.value)
        hasher.combine(creationDate.value)
        hasher.combine(contentModificationDate.value)
        hasher.combine(fileIdentifier.value)
        hasher.combine(volumeUUID.value)
        hasher.combine(contentType.value)
    }

    /// Fields that identify the *file object* rather than its current content state.
    static let objectFields: Set<FingerprintField> = [.fileIdentifier, .volumeUUID]

    /// Timestamp comparison tolerance: 1 ms.
    ///
    /// Observed (sources holdout M1-SRC-ON-PROV-001, iCloud Drive, 2026-10-05): after a provider
    /// evicts and rematerializes an unchanged file, its creation/modification dates move by ±1.19e-7 s
    /// (sub-microsecond precision noise; bytes identical), so exact comparison reported a false
    /// "changed". 1 ms is ~8,400x the largest observed shift and far below any genuine edit's timestamp
    /// change. Size, file identifier, volume and type are always compared exactly; dates never match
    /// when unknown on either side.
    ///
    /// Baselines are device-local and recorded from each Mac's own file, which is what makes 1 ms safe:
    /// iCloud Drive carries dates to another Mac at whole-second precision (observed in M1-DUR-025,
    /// #121), so a baseline recorded on one Mac must never be compared with the other Mac's copy.
    /// Persisted baselines must keep full precision (`FileDeviceAccessStore` uses the default encoder).
    public static let timestampTolerance: TimeInterval = 0.001

    /// Compares every field. Equal known values match (timestamps within `timestampTolerance`); any
    /// known difference is reported; a field unknown on either side is reported as unknown. Exact match
    /// requires every field known and equal.
    public func compare(to candidate: FileSystemFingerprint) -> IdentityComparison {
        var differing: [FingerprintField] = []
        var unknown: [FingerprintField] = []
        func check<T>(_ field: FingerprintField, _ lhs: Knowledge<T>, _ rhs: Knowledge<T>, equal: (T, T) -> Bool) {
            guard let left = lhs.value, let right = rhs.value else {
                unknown.append(field)
                return
            }
            if !equal(left, right) { differing.append(field) }
        }
        func check<T: Equatable>(_ field: FingerprintField, _ lhs: Knowledge<T>, _ rhs: Knowledge<T>) {
            check(field, lhs, rhs, equal: ==)
        }
        func sameInstant(_ a: Date, _ b: Date) -> Bool {
            abs(a.timeIntervalSince(b)) <= Self.timestampTolerance
        }
        check(.fileSize, fileSize, candidate.fileSize)
        check(.creationDate, creationDate, candidate.creationDate, equal: sameInstant)
        check(.contentModificationDate, contentModificationDate, candidate.contentModificationDate, equal: sameInstant)
        check(.fileIdentifier, fileIdentifier, candidate.fileIdentifier)
        check(.volumeUUID, volumeUUID, candidate.volumeUUID)
        check(.contentType, contentType, candidate.contentType)
        if !differing.isEmpty { return .differs(differing.sorted(), unknown: unknown.sorted()) }
        if !unknown.isEmpty { return .unknown(unknown.sorted()) }
        return .matches
    }
}

/// Evidence that would need content access. Always `unknown` in M1 (no hashing, header reads, previews
/// or decoding); listed so the UI and reports can say exactly what was *not* checked.
public enum ContentEvidenceField: String, Sendable, Codable, Equatable, CaseIterable {
    /// Hash of file bytes: requires reading content.
    case contentDigest
    /// Codec/sample rate/channel layout/duration: requires reading the container header.
    case audioFormat
    /// Embedded BWF/iXML/timecode chunks: requires reading the container.
    case embeddedRecorderMetadata
}

/// Result of comparing recorded evidence with a candidate.
public enum IdentityComparison: Sendable, Codable, Equatable {
    case matches
    case differs([FingerprintField], unknown: [FingerprintField])
    case unknown([FingerprintField])

    public var isExactMatch: Bool { self == .matches }
}

/// The identity baseline recorded on this device for a logical source.
public struct RecordedIdentity: Sendable, Codable, Equatable {
    public var fingerprint: FileSystemFingerprint
    /// Import records a provisional baseline; only an explicit user confirmation (or a confirmed relink)
    /// makes it user-confirmed.
    public var confirmation: Confirmation
    public var recordedAt: Date

    public init(fingerprint: FileSystemFingerprint, confirmation: Confirmation, recordedAt: Date) {
        self.fingerprint = fingerprint
        self.confirmation = confirmation
        self.recordedAt = recordedAt
    }

    /// Maps a comparison against this baseline to the identity dimension.
    public func identityState(for comparison: IdentityComparison) -> IdentityState {
        switch comparison {
        case .matches:
            confirmation == .userConfirmed ? .matchesRecorded : .unverified(.baselineNotUserConfirmed)
        case let .differs(fields, _):
            fields.contains(where: FileSystemFingerprint.objectFields.contains) ? .mismatch(fields) : .changed(fields)
        case let .unknown(fields):
            .unverified(.insufficientEvidence(fields))
        }
    }
}
