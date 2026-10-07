import Foundation
import WWCore

/// Result of opening a canonical document. Opening never writes to the document.
public enum OpenOutcome<Payload: Sendable>: Sendable {
    /// Decoded, checksum-verified and validated; editable. `fingerprint` is the expected base for the next save.
    case editable(DecodedDocument<Payload>, fingerprint: RevisionFingerprint)
    /// Written by a newer WaveWrangler: refused. Edit, save, autosave, migration and downsave are all refused.
    case refusedNewerFormat(found: Int, supported: Int, fingerprint: RevisionFingerprint)
    /// A supported older schema; must be migrated (see `DocumentMigrator`) before editing.
    case needsMigration(fromSchema: Int, fingerprint: RevisionFingerprint)
    /// The current file is damaged/unreadable. Each candidate is one whole validated checkpoint, offered
    /// read-only (recover as a new copy); the damaged file is left untouched.
    case damaged(PersistenceError, recoveryCandidates: [RecoveryCandidate<Payload>])
    /// Could not read the bytes at all (permission, offline, missing).
    case unreadable(kind: WriteFailureKind, detail: String, recoveryCandidates: [RecoveryCandidate<Payload>])
}

public struct RecoveryCandidate<Payload: Sendable>: Sendable {
    public let checkpoint: RecoveryCheckpoint
    public let document: DecodedDocument<Payload>
}

/// Unresolved provider conflict versions of a file, surfaced as evidence only (never auto-resolved).
public struct ProviderConflictReport: Sendable, Equatable {
    public let unresolvedVersionCount: Int
    public let hasUnresolvedConflicts: Bool
    public let versionModificationDates: [Date]

    public static let none = ProviderConflictReport(unresolvedVersionCount: 0, hasUnresolvedConflicts: false, versionModificationDates: [])

    /// Reads `NSFileVersion` conflict state for `url`. Does not resolve, remove or download anything.
    public static func inspect(_ url: URL) -> ProviderConflictReport {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        let flagged = (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?.ubiquitousItemHasUnresolvedConflicts ?? false
        return ProviderConflictReport(
            unresolvedVersionCount: versions.count,
            hasUnresolvedConflicts: flagged || !versions.isEmpty,
            versionModificationDates: versions.compactMap(\.modificationDate)
        )
    }
}

/// Opens canonical documents with strict refusal and whole-checkpoint recovery offers.
public struct DocumentOpener<Coder: CanonicalDocumentCoding>: Sendable {
    public let coder: Coder
    public let ops: any FileOperations
    public let coordination: any FileCoordinating
    public let recovery: RecoveryStore?
    /// Schemas older than the coder's minimum that a registered migration can upgrade.
    public let migratableSchemas: Set<Int>
    /// Logical identity of a decoded payload. When set and the caller passes the expected `key`, a valid
    /// document of a *different* identity at that location is refused as damaged (`identityMismatch`).
    public let identityOf: (@Sendable (Coder.Payload) -> DocumentKey)?
    /// Decodes recovery records offered read-only (default: `coder`). A format with a migration may also
    /// upgrade supported older records in memory here; the canonical file itself still needs the migration.
    public let recoveryDecode: (@Sendable (Data) throws -> DecodedDocument<Coder.Payload>)?

    public init(
        coder: Coder,
        ops: any FileOperations = LocalFileOperations(),
        coordination: any FileCoordinating = NSFileCoordination(),
        recovery: RecoveryStore?,
        migratableSchemas: Set<Int> = [],
        identityOf: (@Sendable (Coder.Payload) -> DocumentKey)? = nil,
        recoveryDecode: (@Sendable (Data) throws -> DecodedDocument<Coder.Payload>)? = nil
    ) {
        self.coder = coder
        self.ops = ops
        self.coordination = coordination
        self.recovery = recovery
        self.migratableSchemas = migratableSchemas
        self.identityOf = identityOf
        self.recoveryDecode = recoveryDecode
    }

    /// Opens `url`. `key` (when known, e.g. from the library) locates recovery checkpoints; otherwise the
    /// last-known location hint is used.
    public func open(_ url: URL, key: DocumentKey? = nil) -> OpenOutcome<Coder.Payload> {
        let data: Data
        do {
            data = try coordination.coordinateReading(at: url) { try ops.read($0) }
        } catch {
            return .unreadable(kind: WriteFailureKind(classifying: error), detail: "\(error)", recoveryCandidates: candidates(url: url, key: key))
        }
        return outcome(for: data, url: url, key: key)
    }

    /// Classifies bytes already read by the caller (e.g. inside NSDocument's coordinated read).
    public func outcome(for data: Data, url: URL?, key: DocumentKey? = nil) -> OpenOutcome<Coder.Payload> {
        let fingerprint = RevisionFingerprint(of: data)
        do {
            let decoded = try coder.decode(data)
            if let key, let identityOf, identityOf(decoded.payload) != key {
                return .damaged(.identityMismatch(expected: key.rawValue, found: identityOf(decoded.payload).rawValue),
                                recoveryCandidates: candidates(url: nil, key: key))
            }
            return .editable(decoded, fingerprint: fingerprint)
        } catch let .unknownNewerSchema(found, supported) {
            return .refusedNewerFormat(found: found, supported: supported, fingerprint: fingerprint)
        } catch let .unsupportedOlderSchema(found, _) where migratableSchemas.contains(found) {
            // A migratable older document of a *different* identity is refused exactly like a current one, so it
            // can't be adopted (or migrated) as the expected document. Read-only decode; nothing is written.
            if let key, let identityOf, let recoveryDecode, let older = try? recoveryDecode(data), identityOf(older.payload) != key {
                return .damaged(.identityMismatch(expected: key.rawValue, found: identityOf(older.payload).rawValue),
                                recoveryCandidates: candidates(url: nil, key: key))
            }
            return .needsMigration(fromSchema: found, fingerprint: fingerprint)
        } catch {
            return .damaged(error, recoveryCandidates: candidates(url: url, key: key))
        }
    }

    public func candidates(url: URL?, key: DocumentKey?) -> [RecoveryCandidate<Coder.Payload>] {
        guard let recovery else { return [] }
        var keys: [DocumentKey] = key.map { [$0] } ?? []
        if let url { keys += recovery.keys(forLocation: url).filter { !keys.contains($0) } }
        return keys.flatMap { key in
            let records = recoveryDecode.map { try? recovery.validatedCheckpoints(for: key, decode: $0) }
                ?? (try? recovery.validatedCheckpoints(for: key, coder: coder))
            return (records ?? []).map {
                RecoveryCandidate(checkpoint: $0.checkpoint, document: $0.document)
            }
        }
    }
}
