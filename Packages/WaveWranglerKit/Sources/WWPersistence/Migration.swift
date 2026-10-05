import Foundation

/// Upgrades one supported older schema to a whole current-schema payload.
public struct MigrationStep<Payload: Sendable>: Sendable {
    public let fromSchema: Int
    /// Explicitly decodes the complete original bytes. Facts the old schema lacked must stay explicitly
    /// unknown; nothing may be invented. Returns the payload and the original revision.
    public let migrate: @Sendable (Data) throws -> (payload: Payload, originalRevision: Int)
    /// Independently specified expectations for the migrated value (empty = pass).
    public let expectations: @Sendable (_ original: Data, _ migrated: Payload) -> [String]

    public init(
        fromSchema: Int,
        migrate: @escaping @Sendable (Data) throws -> (payload: Payload, originalRevision: Int),
        expectations: @escaping @Sendable (Data, Payload) -> [String] = { _, _ in [] }
    ) {
        self.fromSchema = fromSchema
        self.migrate = migrate
        self.expectations = expectations
    }
}

public struct MigrationReceipt: Sendable, Equatable {
    public let backup: URL
    public let originalFingerprint: RevisionFingerprint
    public let publication: PublicationReceipt
}

/// Migration protocol (C5): preserve the original bytes untouched and a non-overwriting device-local backup,
/// stage a whole new revision, validate it, and publish only after checks through the ordinary publication
/// protocol with the original bytes as the expected base. Cancel or failure before publication leaves the
/// original exactly as it was; retry is idempotent.
public struct DocumentMigrator<Coder: CanonicalDocumentCoding>: Sendable {
    public let publisher: DocumentPublisher<Coder>
    public let steps: [Int: MigrationStep<Coder.Payload>]

    public init(publisher: DocumentPublisher<Coder>, steps: [MigrationStep<Coder.Payload>]) {
        self.publisher = publisher
        self.steps = Dictionary(uniqueKeysWithValues: steps.map { ($0.fromSchema, $0) })
    }

    public var migratableSchemas: Set<Int> { Set(steps.keys) }

    public func migrate(_ url: URL, key: DocumentKey, isCancelled: () -> Bool = { false }) throws -> MigrationReceipt {
        guard let recovery = publisher.recovery else {
            throw PublicationError.failed(stage: .migrationStage, kind: .other, detail: "migration requires a recovery store")
        }
        let ops = publisher.ops
        let original: Data
        do {
            original = try publisher.coordination.coordinateReading(at: url) { try ops.read($0) }
        } catch where !(error is any InjectedInterruption) {
            throw PublicationError.failed(stage: .migrationStage, kind: WriteFailureKind(classifying: error), detail: "\(error)")
        }
        let originalFingerprint = RevisionFingerprint(of: original)
        guard let schema = originalFingerprint.schemaVersion, let step = steps[schema] else {
            throw PublicationError.failed(stage: .migrationStage, kind: .other, detail: "no migration from schema \(originalFingerprint.schemaVersion.map(String.init) ?? "?")")
        }

        try publisher.hooks.willEnter(.migrationStage)
        let backup: URL
        let staged: (payload: Coder.Payload, originalRevision: Int)
        do {
            backup = try recovery.preserveMigrationBackup(original, schemaVersion: schema, for: key)
            guard try ops.read(backup) == original else {
                throw PublicationError.failed(stage: .migrationStage, kind: .other, detail: "backup does not match original bytes")
            }
            staged = try step.migrate(original)
        } catch let error as PublicationError {
            throw error
        } catch let error as PersistenceError {
            throw PublicationError.invalidCandidate(error)
        } catch where !(error is any InjectedInterruption) {
            throw PublicationError.failed(stage: .migrationStage, kind: WriteFailureKind(classifying: error), detail: "\(error)")
        }
        let failures = step.expectations(original, staged.payload)
        guard failures.isEmpty else {
            throw PublicationError.failed(stage: .migrationStage, kind: .other, detail: failures.joined(separator: "; "))
        }
        try publisher.hooks.didComplete(.migrationStage)

        guard !isCancelled() else { throw PublicationError.cancelled }

        let receipt = try publisher.publish(
            staged.payload,
            revision: max(staged.originalRevision, 0) + 1,
            key: key,
            to: url,
            target: .inPlace(expectedBase: RevisionFingerprint(
                revision: nil, schemaVersion: schema, checksum: nil, byteDigest: originalFingerprint.byteDigest
            )),
            retainPrior: false,
            boundaries: (publish: .migrationPublish, stage: .stageWrite),
            isCancelled: isCancelled
        )
        return MigrationReceipt(backup: backup, originalFingerprint: originalFingerprint, publication: receipt)
    }
}
