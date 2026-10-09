import Darwin
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

public enum RecoveryRecordKind: Sendable, Equatable {
    case offeredEditCheckpoint
    case priorCheckpoint
    case verifiedCurrent
}

/// The one immutable physical record selected while an offer is displayed, before confirmation.
public struct SelectedRecoveryRecord: Sendable {
    public let kind: RecoveryRecordKind
    public let key: DocumentKey
    public let url: URL
    public let byteDigest: String
    public let itemIdentity: FileItemIdentity
    public let allowsDamagedRecord: Bool
}

/// Device-local recovery records inside the app container (C2 placement decision):
///
/// - `checkpoints/<key>/` — all validated coherent prior revisions, exact envelope bytes.
/// - `edit-checkpoints/<key>/` and `edit-checkpoints-offered/<key>/` — every quiescent unpublished draft.
/// - `conflicts/<key>/` — competing candidates preserved when a save detected another revision on disk.
/// - `migration-backups/<key>/` — non-overwriting copies of pre-migration originals.
/// - `locations/<key>/<path-digest>.json` — historical location hints, used only to find
///   checkpoints for a damaged file. Legacy `locations/<key>.json` hints remain readable.
///
/// Every record is written to `.staging/` and moved into place with an exclusive rename, so a record is
/// either whole or absent. Nothing here is portable across devices (recorded limitation).
public struct RecoveryStore: Sendable {
    public let root: URL
    /// Legacy minimum-retention setting; retained for callers, never an upper bound or pruning rule.
    public let retainCount: Int
    private let ops: any FileOperations

    public init(root: URL, retainCount: Int = 3, ops: any FileOperations = LocalFileOperations()) {
        precondition(retainCount >= 2, "The minimum retained-prior setting must be at least two.")
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

    /// Retains a validated prior without removing any other record. Names are never reused after Discard.
    @discardableResult
    public func retainCheckpoint(_ bytes: Data, for key: DocumentKey) throws -> RecoveryCheckpoint {
        try withMutationLock { try retainCheckpointUnlocked(bytes, for: key) }
    }

    private func retainCheckpointUnlocked(_ bytes: Data, for key: DocumentKey) throws -> RecoveryCheckpoint {
        let fingerprint = RevisionFingerprint(of: bytes)
        for existing in try checkpoints(for: key) where existing.fingerprint.byteDigest == fingerprint.byteDigest {
            if try ops.read(existing.url) == bytes { return existing }
        }
        let directory = folder("checkpoints", key)
        var url: URL
        repeat {
            url = directory.appending(path: String(format: "%010d", fingerprint.revision ?? 0)
                + "-\(fingerprint.shortDigest)-\(UUID().uuidString).wwcheckpoint")
        } while ops.exists(url)
        let staged = try stage(bytes)
        try ops.createDirectory(directory)
        try ops.moveNew(staged, to: url)
        guard try ops.read(url) == bytes else { throw CocoaError(.fileWriteUnknown) }
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

    /// UI listing: a directory/read failure is reported instead of concealing a retained prior.
    public func checkedCheckpoints(for key: DocumentKey) throws -> [RecoveryCheckpoint] {
        try records(in: folder("checkpoints", key), extension: "wwcheckpoint")
            .map { url in RecoveryCheckpoint(key: key, url: url, fingerprint: RevisionFingerprint(of: try ops.read(url))) }
            .sorted { ($0.fingerprint.revision ?? 0, $0.url.lastPathComponent) > ($1.fingerprint.revision ?? 0, $1.url.lastPathComponent) }
    }

    /// Whole validated revisions that can be recovered, newest first: the verified-current record (if any)
    /// plus retained priors, de-duplicated by SHA-256 digest. Each value comes from one whole file.
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
        try withMutationLock {
            let url = folder("verified-current", key).appending(path: "current.wwcheckpoint")
            if ops.exists(url) {
                let previous = try ops.read(url)
                if previous == bytes { return }
                if key == .library {
                    _ = try LibraryCoder.library.decode(previous)
                } else {
                    _ = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(previous)
                }
                _ = try retainCheckpointUnlocked(previous, for: key)
            }
            try replaceRecord(bytes, at: url)
        }
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
        let digest = RevisionFingerprint.digest(Data(url.standardizedFileURL.path.utf8))
        let destination = folder("locations", key).appending(path: "\(digest).json")
        try withMutationLock {
            if ops.exists(destination) {
                guard try ops.read(destination) == data else { throw CocoaError(.fileWriteUnknown) }
                return
            }
            let staged = try stage(data)
            try ops.createDirectory(destination.deletingLastPathComponent())
            try ops.moveNew(staged, to: destination)
            guard try ops.read(destination) == data else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    public func keys(forLocation url: URL) -> [DocumentKey] {
        (try? checkedKeys(forLocation: url)) ?? []
    }

    /// Unlike the legacy convenience lookup, this surfaces an unreadable or malformed hint so the
    /// damaged-file recovery UI cannot report "no copies" when it failed to inspect the index.
    public func checkedKeys(forLocation url: URL) throws -> [DocumentKey] {
        let directory = root.appending(path: "locations", directoryHint: .isDirectory)
        let path = url.standardizedFileURL.path
        guard ops.exists(directory) else { return [] }
        let entries = try ops.contentsOfDirectory(directory)
        var found: [DocumentKey] = []
        for entry in entries {
            let kind = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard kind.isSymbolicLink != true else { continue }
            let hints: [URL]
            if entry.pathExtension == "json", kind.isRegularFile == true {
                hints = [entry] // Legacy <key>.json hint.
            } else if kind.isDirectory == true {
                hints = try ops.contentsOfDirectory(entry)
            } else {
                continue
            }
            let key = DocumentKey(rawValue: entry.deletingPathExtension().lastPathComponent)
            for hintURL in hints where hintURL.pathExtension == "json" {
                let hint = try JSONDecoder().decode(LocationHint.self, from: ops.read(hintURL))
                if hint.path == path {
                    found.append(key)
                    break
                }
            }
        }
        return Array(Set(found)).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Conflict candidates, migration backups, drafts

    /// Preserves a competing in-memory candidate that could not be published because of a conflict.
    @discardableResult
    public func preserveConflictCandidate(_ bytes: Data, for key: DocumentKey) throws -> URL {
        let fingerprint = RevisionFingerprint(of: bytes)
        let url = folder("conflicts", key).appending(path: "\(fingerprint.shortDigest).wwconflict")
        try writeRecord(bytes, to: url)
        guard try ops.read(url) == bytes else { throw CocoaError(.fileWriteUnknown) }
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

    /// Atomically writes one new unpublished record. Neither active nor offered records are pruned.
    @discardableResult
    public func writeEditCheckpoint(
        snapshot: Data,
        base: RevisionFingerprint?,
        schemaVersion: Int,
        for key: DocumentKey,
        at date: Date = Date()
    ) throws -> EditCheckpointRecord {
        try withMutationLock {
            let existing = try records(in: folder("edit-checkpoints", key), extension: "wwedit")
                + records(in: folder("edit-checkpoints-offered", key), extension: "wwedit")
            let sequenceURL = root.appending(path: "edit-sequences/\(key.rawValue).txt")
            let last: Int
            if ops.exists(sequenceURL) {
                guard let stored = Int(String(decoding: try ops.read(sequenceURL), as: UTF8.self)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                last = stored
            } else { last = 0 }
            let prior = max(existing.compactMap { Self.sequence(of: $0) }.max() ?? 0, last)
            guard prior < Int.max else { throw CocoaError(.fileWriteOutOfSpace) }
            let sequence = prior + 1
            let date = Date(timeIntervalSince1970: TimeInterval(Int64((date.timeIntervalSince1970 * 1000).rounded())) / 1000)
            let record = EditCheckpointRecord(
                documentID: key.rawValue, baseRevision: base?.revision, baseChecksum: base?.checksum,
                basePublicationID: base?.publicationID, baseByteDigest: base?.byteDigest,
                checkpointSequence: sequence, createdAt: date, schemaVersion: schemaVersion,
                payloadChecksum: EnvelopeHeaderInfo.peek(snapshot)?.checksum ?? "", snapshot: snapshot
            )
            let bytes = try record.encoded()
            let url = folder("edit-checkpoints", key).appending(path: String(format: "%010d", sequence) + "-\(UUID().uuidString).wwedit")
            let staged = try stage(bytes)
            guard try ops.read(staged) == bytes, (try? EditCheckpointRecord.decode(bytes)) == record else {
                throw CocoaError(.fileWriteUnknown)
            }
            try ops.createDirectory(url.deletingLastPathComponent())
            try ops.moveNew(staged, to: url)
            guard (try? EditCheckpointRecord.decode(ops.read(url))) == record else { throw CocoaError(.fileWriteUnknown) }
            try replaceRecord(Data(String(sequence).utf8), at: sequenceURL)
            return record
        }
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

    private func editCheckpointFiles(for key: DocumentKey) -> [URL] {
        ((try? records(in: folder("edit-checkpoints", key), extension: "wwedit")) ?? [])
    }

    // MARK: Offered edit checkpoints (C2b recovery presentation)

    /// Moves this document's edit-checkpoint records (valid or not) aside when the document is opened, so that
    /// an unresolved "Restore unsaved changes" offer survives later saves, new checkpoints and Don't Save.
    /// Each move is a same-volume rename; an existing name is never overwritten.
    public func setAsideEditCheckpoints(for key: DocumentKey) throws {
        try withMutationLock {
            let files = try records(in: folder("edit-checkpoints", key), extension: "wwedit")
            guard !files.isEmpty else { return }
            let held = folder("edit-checkpoints-offered", key)
            try ops.createDirectory(held)
            for url in files {
                let name = "\(Int64((Date().timeIntervalSince1970 * 1000).rounded()))-\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).wwedit"
                try ops.moveNew(url, to: held.appending(path: name))
            }
        }
    }

    /// Records set aside by `setAsideEditCheckpoints(for:)`, each with its location. Unreadable or damaged
    /// records are reported, never deleted here.
    public func offeredEditCheckpoints(for key: DocumentKey) -> [StoredEditCheckpoint] {
        (try? checkedOfferedEditCheckpoints(for: key)) ?? []
    }

    /// UI listing: individual unreadable records remain visible as problems; directory errors are thrown.
    public func checkedOfferedEditCheckpoints(for key: DocumentKey) throws -> [StoredEditCheckpoint] {
        try records(in: folder("edit-checkpoints-offered", key), extension: "wwedit").map { url in
            guard let data = try? ops.read(url) else { return StoredEditCheckpoint(url: url, record: .failure(.unreadable(url))) }
            do { return StoredEditCheckpoint(url: url, record: .success(try EditCheckpointRecord.decode(data))) } catch {
                return StoredEditCheckpoint(url: url, record: .failure(.damaged(url)))
            }
        }
    }

    /// Capture one record and its full-record digest before an asynchronous native confirmation.
    public func selectRecord(
        _ kind: RecoveryRecordKind, at url: URL, for key: DocumentKey, allowingDamagedRecord: Bool = false
    ) throws -> SelectedRecoveryRecord {
        try withMutationLock {
            let bytes = try validatedSelectionBytes(kind, at: url, for: key, allowingDamagedRecord: allowingDamagedRecord)
            guard let identity = FileItemIdentity.observe(at: url) else { throw CocoaError(.fileReadUnknown) }
            return SelectedRecoveryRecord(kind: kind, key: key, url: url, byteDigest: RevisionFingerprint.digest(bytes),
                                          itemIdentity: identity, allowsDamagedRecord: allowingDamagedRecord)
        }
    }

    /// Recheck exactly the selected record under the same cross-process mutation lock as every store writer.
    /// A stale, replaced, unreadable, or unowned record is an error, never a successful no-op.
    public func discardSelectedRecord(_ selection: SelectedRecoveryRecord) throws {
        guard selection.kind != .verifiedCurrent else { throw CocoaError(.fileWriteNoPermission) }
        try withMutationLock {
            _ = try readSelectedRecordUnlocked(selection)
            try ops.remove(selection.url)
            guard !ops.exists(selection.url) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Re-read one selected record without permitting a newer record at the same path to substitute its bytes.
    public func readSelectedRecord(_ selection: SelectedRecoveryRecord) throws -> Data {
        try withMutationLock { try readSelectedRecordUnlocked(selection) }
    }

    private func readSelectedRecordUnlocked(_ selection: SelectedRecoveryRecord) throws -> Data {
        let bytes = try validatedSelectionBytes(selection.kind, at: selection.url, for: selection.key,
                                                allowingDamagedRecord: selection.allowsDamagedRecord)
        guard FileItemIdentity.observe(at: selection.url) == selection.itemIdentity,
              RevisionFingerprint.digest(bytes) == selection.byteDigest else { throw CocoaError(.fileReadUnknown) }
        return bytes
    }

    private func validatedSelectionBytes(
        _ kind: RecoveryRecordKind, at url: URL, for key: DocumentKey, allowingDamagedRecord: Bool
    ) throws -> Data {
        let kindFolder: String = switch kind {
            case .offeredEditCheckpoint: "edit-checkpoints-offered"
            case .priorCheckpoint: "checkpoints"
            case .verifiedCurrent: "verified-current"
        }
        let directory = folder(kindFolder, key).standardizedFileURL
        let expectedExtension = kind == .offeredEditCheckpoint ? "wwedit" : "wwcheckpoint"
        guard url.standardizedFileURL.deletingLastPathComponent() == directory,
              url.pathExtension == expectedExtension,
              kind != .verifiedCurrent || url.lastPathComponent == "current.wwcheckpoint"
        else { throw CocoaError(.fileReadNoPermission) }
        let bytes = try ops.read(url)
        if kind == .offeredEditCheckpoint {
            let record = try? EditCheckpointRecord.decode(bytes)
            guard record != nil || allowingDamagedRecord else { throw CocoaError(.fileReadCorruptFile) }
            if let record, record.documentID != key.rawValue { throw CocoaError(.fileReadCorruptFile) }
        } else {
            if key == .library {
                if !allowingDamagedRecord { _ = try LibraryCoder.library.decode(bytes) }
            } else {
                let decoded = try? JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes)
                if let decoded {
                    guard DocumentKey.show(decoded.payload.show.id) == key else { throw CocoaError(.fileReadCorruptFile) }
                } else if !allowingDamagedRecord {
                    _ = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes)
                }
            }
        }
        return bytes
    }

    static func sequence(of url: URL) -> Int? {
        let components = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        return components.first(where: { $0.count == 10 }).flatMap { Int($0) }
    }

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appending(path: ".recovery.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError.current() }
        defer { flock(fd, LOCK_UN) }
        return try operation()
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

    public static func decode(_ data: Data) throws -> EditCheckpointRecord {
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
