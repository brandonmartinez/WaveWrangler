import Foundation
import WWCore

/// Stable key for a document's device-local recovery records. Derived from logical identity, never from a
/// path, so checkpoints survive moving or renaming the document on this Mac.
public struct DocumentKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = String(rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    public static func show(_ id: ShowID) -> DocumentKey { DocumentKey(rawValue: "show-\(id.rawValue.uuidString)") }
    public static let library = DocumentKey(rawValue: "library")

    public var description: String { rawValue }
}

/// One retained whole coherent revision in the device-local recovery store.
public struct RecoveryCheckpoint: Sendable, Equatable {
    public let key: DocumentKey
    public let url: URL
    public let fingerprint: RevisionFingerprint
}

/// Device-local recovery records inside the app container (C2 placement decision):
///
/// - `checkpoints/<key>/` — the last `retainCount` validated coherent prior revisions, exact envelope bytes.
/// - `drafts/<key>/` — at most one quiescent recovery draft of unsaved edits (not a save).
/// - `conflicts/<key>/` — competing candidates preserved when a save detected another revision on disk.
/// - `migration-backups/<key>/` — non-overwriting copies of pre-migration originals.
/// - `locations/<key>.json` — last known location hint, used only to find checkpoints for a damaged file.
///
/// Every record is written to `.staging/` and moved into place with an exclusive rename, so a record is
/// either whole or absent. Nothing here is portable across devices (recorded limitation).
public struct RecoveryStore: Sendable {
    public let root: URL
    public let retainCount: Int
    private let ops: any FileOperations

    public init(root: URL, retainCount: Int = 3, ops: any FileOperations = LocalFileOperations()) {
        precondition(retainCount >= 2, "Keep at least the last two validated revisions.")
        self.root = root
        self.retainCount = retainCount
        self.ops = ops
    }

    /// `~/Library/Application Support/WaveWrangler/Recovery` (inside the sandbox container when sandboxed).
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WaveWrangler/Recovery", directoryHint: .isDirectory)
    }

    // MARK: - Prior checkpoints

    /// Retains `bytes` (a revision the caller has already validated) as a checkpoint, then prunes older ones.
    /// Idempotent for identical bytes. Pruning only happens after the new checkpoint is in place.
    @discardableResult
    public func retainCheckpoint(_ bytes: Data, for key: DocumentKey) throws -> RecoveryCheckpoint {
        let fingerprint = RevisionFingerprint(of: bytes)
        let directory = folder("checkpoints", key)
        let name = String(format: "%010d", fingerprint.revision ?? 0) + "-\(fingerprint.shortDigest).wwcheckpoint"
        let url = directory.appending(path: name)
        try writeRecord(bytes, to: url)
        let all = try checkpoints(for: key)
        for stale in all.dropFirst(retainCount) where stale.url.lastPathComponent != url.lastPathComponent {
            try ops.remove(stale.url)
        }
        return RecoveryCheckpoint(key: key, url: url, fingerprint: fingerprint)
    }

    /// Retained checkpoints, newest revision first. Bytes are fingerprinted but not decoded here.
    public func checkpoints(for key: DocumentKey) throws -> [RecoveryCheckpoint] {
        try records(in: folder("checkpoints", key), extension: "wwcheckpoint")
            .compactMap { url in
                guard let data = try? ops.read(url) else { return nil }
                return RecoveryCheckpoint(key: key, url: url, fingerprint: RevisionFingerprint(of: data))
            }
            .sorted { ($0.fingerprint.revision ?? 0, $0.url.lastPathComponent) > ($1.fingerprint.revision ?? 0, $1.url.lastPathComponent) }
    }

    /// Whole validated revisions that can be recovered, newest first: the verified-current record (if any)
    /// plus retained priors, de-duplicated by bytes. Never a mixture: each value comes from one whole file.
    public func validatedCheckpoints<Coder: CanonicalDocumentCoding>(
        for key: DocumentKey,
        coder: Coder
    ) throws -> [(checkpoint: RecoveryCheckpoint, document: DecodedDocument<Coder.Payload>)] {
        try validatedCheckpoints(for: key) { try coder.decode($0) }
    }

    /// As above, decoding each record with `decode` (for example a read-only in-memory upgrade of a supported
    /// older schema, so records written before a format change stay offerable).
    public func validatedCheckpoints<Payload: Sendable>(
        for key: DocumentKey,
        decode: (Data) throws -> DecodedDocument<Payload>
    ) throws -> [(checkpoint: RecoveryCheckpoint, document: DecodedDocument<Payload>)] {
        var all = try checkpoints(for: key)
        if let current = verifiedCurrent(for: key), !all.contains(where: { $0.fingerprint.byteDigest == current.fingerprint.byteDigest }) {
            all.append(current)
        }
        return all
            .compactMap { checkpoint in
                guard let data = try? ops.read(checkpoint.url), let decoded = try? decode(data) else { return nil }
                return (checkpoint, decoded)
            }
            .sorted { $0.document.revision > $1.document.revision }
    }

    /// Records the latest read-back-verified revision (used by the library so an unreachable location can
    /// show the newest verified value). Kept apart from prior checkpoints so prior retention is unchanged.
    public func recordVerifiedCurrent(_ bytes: Data, for key: DocumentKey) throws {
        let url = folder("verified-current", key).appending(path: "current.wwcheckpoint")
        if (try? ops.read(url)) == bytes { return }
        try replaceRecord(bytes, at: url)
    }

    public func verifiedCurrent(for key: DocumentKey) -> RecoveryCheckpoint? {
        let url = folder("verified-current", key).appending(path: "current.wwcheckpoint")
        guard let data = try? ops.read(url) else { return nil }
        return RecoveryCheckpoint(key: key, url: url, fingerprint: RevisionFingerprint(of: data))
    }

    public func bytes(of checkpoint: RecoveryCheckpoint) throws -> Data {
        try ops.read(checkpoint.url)
    }

    // MARK: - Location hints (only for finding recovery records of a damaged file)

    public func recordLocation(_ url: URL, for key: DocumentKey) throws {
        let data = try JSONEncoder().encode(LocationHint(path: url.standardizedFileURL.path))
        let destination = root.appending(path: "locations/\(key.rawValue).json")
        try replaceRecord(data, at: destination)
    }

    public func keys(forLocation url: URL) -> [DocumentKey] {
        let directory = root.appending(path: "locations", directoryHint: .isDirectory)
        let path = url.standardizedFileURL.path
        guard let entries = try? ops.contentsOfDirectory(directory) else { return [] }
        return entries.compactMap { entry in
            guard entry.pathExtension == "json", let data = try? ops.read(entry),
                  let hint = try? JSONDecoder().decode(LocationHint.self, from: data), hint.path == path
            else { return nil }
            return DocumentKey(rawValue: entry.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Conflict candidates, migration backups, drafts

    /// Preserves a competing in-memory candidate that could not be published because of a conflict.
    @discardableResult
    public func preserveConflictCandidate(_ bytes: Data, for key: DocumentKey) throws -> URL {
        let fingerprint = RevisionFingerprint(of: bytes)
        let url = folder("conflicts", key).appending(path: "\(fingerprint.shortDigest).wwconflict")
        try writeRecord(bytes, to: url)
        return url
    }

    public func conflictCandidates(for key: DocumentKey) throws -> [URL] {
        try records(in: folder("conflicts", key), extension: "wwconflict")
    }

    /// Non-overwriting copy of a pre-migration original. Re-preserving identical bytes is a no-op.
    @discardableResult
    public func preserveMigrationBackup(_ original: Data, schemaVersion: Int, for key: DocumentKey) throws -> URL {
        let url = folder("migration-backups", key)
            .appending(path: "schema\(schemaVersion)-\(RevisionFingerprint(of: original).shortDigest).wwbackup")
        try writeRecord(original, to: url)
        return url
    }

    public func migrationBackups(for key: DocumentKey) throws -> [URL] {
        try records(in: folder("migration-backups", key), extension: "wwbackup")
    }

    // MARK: - Unpublished edit checkpoints (C2b)

    /// Atomically writes an unpublished edit-checkpoint record (stage → verify → exclusive move), then prunes
    /// older records only after the new one is read back. Never touches the canonical location.
    @discardableResult
    public func writeEditCheckpoint(
        snapshot: Data,
        base: RevisionFingerprint?,
        schemaVersion: Int,
        for key: DocumentKey,
        at date: Date = Date()
    ) throws -> EditCheckpointRecord {
        let existing = editCheckpointFiles(for: key)
        let sequence = (existing.compactMap { Self.sequence(of: $0) }.max() ?? 0) + 1
        // Whole milliseconds, so the record round-trips exactly through its canonical timestamp.
        let date = Date(timeIntervalSince1970: TimeInterval(Int64((date.timeIntervalSince1970 * 1000).rounded())) / 1000)
        let record = EditCheckpointRecord(
            documentID: key.rawValue, baseRevision: base?.revision, baseChecksum: base?.checksum,
            basePublicationID: base?.publicationID, baseByteDigest: base?.byteDigest,
            checkpointSequence: sequence, createdAt: date, schemaVersion: schemaVersion,
            payloadChecksum: EnvelopeHeaderInfo.peek(snapshot)?.checksum ?? "", snapshot: snapshot
        )
        let bytes = try record.encoded()
        let url = folder("edit-checkpoints", key).appending(path: String(format: "%010d", sequence) + ".wwedit")
        let staged = try stage(bytes)
        guard try ops.read(staged) == bytes, (try? EditCheckpointRecord.decode(bytes)) == record else {
            throw CocoaError(.fileWriteUnknown)
        }
        try ops.createDirectory(url.deletingLastPathComponent())
        try ops.moveNew(staged, to: url)
        guard (try? EditCheckpointRecord.decode(ops.read(url))) == record else { throw CocoaError(.fileWriteUnknown) }
        for older in existing where older.lastPathComponent != url.lastPathComponent {
            try ops.remove(older)
        }
        return record
    }

    /// Edit-checkpoint records for `key`, newest first. Unreadable records are reported, not deleted.
    public func editCheckpoints(for key: DocumentKey) -> [Result<EditCheckpointRecord, EditCheckpointRecord.ReadError>] {
        editCheckpointFiles(for: key).map { url in
            guard let data = try? ops.read(url) else { return .failure(.unreadable(url)) }
            do { return .success(try EditCheckpointRecord.decode(data)) } catch { return .failure(.damaged(url)) }
        }
    }

    public func latestEditCheckpoint(for key: DocumentKey) -> EditCheckpointRecord? {
        for result in editCheckpoints(for: key) { if case let .success(record) = result { return record } }
        return nil
    }

    /// Deletes edit checkpoints once a verified publication contains all their edits, or after an explicit
    /// Don't Save/Discard.
    public func discardEditCheckpoints(for key: DocumentKey) throws {
        for url in editCheckpointFiles(for: key) { try ops.remove(url) }
    }

    private func editCheckpointFiles(for key: DocumentKey) -> [URL] {
        ((try? records(in: folder("edit-checkpoints", key), extension: "wwedit")) ?? [])
    }

    // MARK: Offered edit checkpoints (C2b recovery presentation)

    /// Moves this document's edit-checkpoint records (valid or not) aside when the document is opened, so that
    /// an unresolved "Restore unsaved changes" offer survives later saves, new checkpoints and Don't Save.
    /// Each move is a same-volume rename; an existing name is never overwritten.
    public func setAsideEditCheckpoints(for key: DocumentKey) throws {
        let files = editCheckpointFiles(for: key)
        guard !files.isEmpty else { return }
        let held = folder("edit-checkpoints-offered", key)
        try ops.createDirectory(held)
        for url in files {
            let name = "\(Int64((Date().timeIntervalSince1970 * 1000).rounded()))-\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).wwedit"
            try ops.moveNew(url, to: held.appending(path: name))
        }
    }

    /// Records set aside by `setAsideEditCheckpoints(for:)`, each with its location. Unreadable or damaged
    /// records are reported, never deleted here.
    public func offeredEditCheckpoints(for key: DocumentKey) -> [StoredEditCheckpoint] {
        ((try? records(in: folder("edit-checkpoints-offered", key), extension: "wwedit")) ?? []).map { url in
            guard let data = try? ops.read(url) else { return StoredEditCheckpoint(url: url, record: .failure(.unreadable(url))) }
            do { return StoredEditCheckpoint(url: url, record: .success(try EditCheckpointRecord.decode(data))) } catch {
                return StoredEditCheckpoint(url: url, record: .failure(.damaged(url)))
            }
        }
    }

    /// Deletes the given offered records only (after an explicit, confirmed Discard, a verified publication
    /// that contains a restored record, or Don't Save after a restore). Never deletes records it wasn't given.
    public func discardOfferedEditCheckpoints(_ urls: [URL], for key: DocumentKey) throws {
        let held = folder("edit-checkpoints-offered", key).standardizedFileURL.path
        for url in urls where url.standardizedFileURL.deletingLastPathComponent().path == held && ops.exists(url) {
            try ops.remove(url)
        }
    }

    private static func sequence(of url: URL) -> Int? {
        Int(url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Pending library edits journal (Design L2/L3)

    private var pendingLibraryEditsURL: URL { root.appending(path: "library-journal/pending-edits.json") }

    /// Atomically replaces the pending library-edits journal and verifies it by read-back.
    public func writePendingLibraryEdits(_ record: PendingLibraryEdits) throws {
        let bytes = try record.encoded()
        try replaceRecord(bytes, at: pendingLibraryEditsURL)
        guard (try? PendingLibraryEdits.decode(ops.read(pendingLibraryEditsURL))) == record else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The journal, if any. A damaged journal is reported (`.failure`), never silently discarded.
    public func pendingLibraryEdits() -> Result<PendingLibraryEdits, EditCheckpointRecord.ReadError>? {
        let url = pendingLibraryEditsURL
        guard ops.exists(url) else { return nil }
        guard let data = try? ops.read(url) else { return .failure(.unreadable(url)) }
        guard let record = try? PendingLibraryEdits.decode(data) else { return .failure(.damaged(url)) }
        return .success(record)
    }

    /// Clears the journal — only after a verified publication contains every queued edit.
    public func clearPendingLibraryEdits() throws {
        if ops.exists(pendingLibraryEditsURL) { try ops.remove(pendingLibraryEditsURL) }
    }

    /// Removes interrupted staging leftovers (app-owned, never canonical).
    public func removeStagingLeftovers() {
        let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
        for url in (try? ops.contentsOfDirectory(staging)) ?? [] {
            try? ops.remove(url)
        }
    }

    // MARK: - Internals

    private struct LocationHint: Codable { let path: String }

    private func folder(_ kind: String, _ key: DocumentKey) -> URL {
        root.appending(path: "\(kind)/\(key.rawValue)", directoryHint: .isDirectory)
    }

    private func records(in directory: URL, extension pathExtension: String) throws -> [URL] {
        guard ops.exists(directory) else { return [] }
        return try ops.contentsOfDirectory(directory)
            .filter { $0.pathExtension == pathExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Whole-or-absent write of a content-addressed record; an existing identical record is accepted.
    private func writeRecord(_ bytes: Data, to url: URL) throws {
        if ops.exists(url) {
            if (try? ops.read(url)) == bytes { return }
            // A damaged leftover with the same name: keep it aside rather than overwrite silently.
            try ops.moveNew(url, to: url.appendingPathExtension("damaged-\(UUID().uuidString)"))
        }
        let staged = try stage(bytes)
        try ops.createDirectory(url.deletingLastPathComponent())
        try ops.moveNew(staged, to: url)
    }

    /// Whole replacement of a small mutable record (location hints).
    private func replaceRecord(_ bytes: Data, at url: URL) throws {
        let staged = try stage(bytes)
        try ops.createDirectory(url.deletingLastPathComponent())
        try ops.replace(url, withStaged: staged)
    }

    private func stage(_ bytes: Data) throws -> URL {
        let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
        try ops.createDirectory(staging)
        let staged = staging.appending(path: UUID().uuidString)
        try ops.writeNew(bytes, to: staged)
        return staged
    }
}

/// C2b unpublished edit-checkpoint record: a whole-model snapshot of not-yet-published edits. Explicitly
/// `unpublished`; never a revision or a save, never written to the canonical location, never advances the
/// library/index, never clears dirty state.
public struct EditCheckpointRecord: Sendable, Equatable, Codable {
    public enum ReadError: Error, Sendable, Equatable {
        case unreadable(URL)
        case damaged(URL)
    }

    /// How a record relates to what is on disk now.
    public enum Relation: Sendable, Equatable {
        /// Based on the current on-disk publication: offer "Restore unsaved changes" (restored = dirty, not saved).
        case basedOnCurrent
        /// Based on another publication: offer to open as a separate untitled copy or compare; never auto-merge.
        case basedOnOtherRevision
    }

    public var recordKind = "edit-checkpoint"
    public let documentID: String
    public let baseRevision: Int?
    public let baseChecksum: String?
    public let basePublicationID: UUID?
    public let baseByteDigest: String?
    public let checkpointSequence: Int
    public let createdAt: Date
    public let schemaVersion: Int
    public var unpublished = true
    public let payloadChecksum: String
    /// The whole model snapshot as a validated canonical envelope (decode with the document's coder).
    public let snapshot: Data

    public func relation(to onDisk: RevisionFingerprint?) -> Relation {
        baseByteDigest != nil && baseByteDigest == onDisk?.byteDigest ? .basedOnCurrent : .basedOnOtherRevision
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalDate.string(from: date))
        }
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> EditCheckpointRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = CanonicalDate.date(from: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "timestamp")
            }
            return date
        }
        let record = try decoder.decode(EditCheckpointRecord.self, from: data)
        guard record.recordKind == "edit-checkpoint", record.unpublished else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an unpublished edit checkpoint"))
        }
        return record
    }
}

/// Device-local journal of library edits made while the library location was unreachable or needed
/// permission (Design L2/L3, "Edits waiting"). It holds the whole edited library as a validated envelope
/// snapshot plus the exact on-disk identity the edits started from, so that on reconnection the edits are
/// either published directly (disk unchanged) or combined with ST-36 (disk diverged). Never dropped silently.
public struct PendingLibraryEdits: Sendable, Equatable, Codable {
    public var recordKind = "library-pending-edits"
    /// The library identity the queued edits were made on top of (`nil` if none was known).
    public let base: RevisionFingerprint?
    /// The number of queued edits ("<n> library changes not saved yet").
    public let editCount: Int
    public let firstQueuedAt: Date
    public let lastQueuedAt: Date
    /// The whole edited library as a validated canonical envelope (decode with `LibraryCoder.library`).
    public let snapshot: Data
    /// The exact bytes of the library the edits were made on, so replay can tell this Mac's changes apart
    /// (three-way merge). `nil` if no verified library was known.
    public let baseSnapshot: Data?

    public init(base: RevisionFingerprint?, baseSnapshot: Data?, editCount: Int, firstQueuedAt: Date, lastQueuedAt: Date, snapshot: Data) {
        self.base = base
        self.baseSnapshot = baseSnapshot
        self.editCount = editCount
        self.firstQueuedAt = Self.wholeMilliseconds(firstQueuedAt)
        self.lastQueuedAt = Self.wholeMilliseconds(lastQueuedAt)
        self.snapshot = snapshot
    }

    static func wholeMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64((date.timeIntervalSince1970 * 1000).rounded())) / 1000)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalDate.string(from: date))
        }
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PendingLibraryEdits {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = CanonicalDate.date(from: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "timestamp")
            }
            return date
        }
        let record = try decoder.decode(PendingLibraryEdits.self, from: data)
        guard record.recordKind == "library-pending-edits" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a pending library edits journal"))
        }
        return record
    }
}
