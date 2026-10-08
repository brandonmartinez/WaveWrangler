import Foundation

/// An edit-checkpoint record file in the device-local recovery store, read or not.
public struct StoredEditCheckpoint: Sendable, Equatable {
    public let url: URL
    public let record: Result<EditCheckpointRecord, EditCheckpointRecord.ReadError>

    public init(url: URL, record: Result<EditCheckpointRecord, EditCheckpointRecord.ReadError>) {
        self.url = url
        self.record = record
    }
}

/// C2b recovery presentation, decided on open/relaunch (contracts C2b, #84). Pure: no I/O.
///
/// - If a usable record is based on exactly the on-disk publication (same bytes, so the same revision and
///   publication), offer **"Restore unsaved changes from <time>"**. A restored document is dirty, not saved.
/// - If it is based on any other publication, offer **"Unsaved changes based on an older revision"**, opened
///   only as a separate untitled copy. Never auto-merged, never auto-published.
/// - Unreadable, damaged, wrong-document and unknown-newer records are reported as problems and retained;
///   they are never applied.
public struct EditCheckpointOffer<Payload: Codable & Sendable>: Sendable {
    public enum Problem: Sendable, Equatable {
        case unreadable(URL)
        case damaged(URL)
        case newerFormat(URL, found: Int, supported: Int)

        public var url: URL {
            switch self {
            case let .unreadable(url), let .damaged(url), let .newerFormat(url, _, _): url
            }
        }
    }

    public struct Candidate: Sendable {
        public let url: URL
        public let record: EditCheckpointRecord
        public let relation: EditCheckpointRecord.Relation
        public let payload: Payload
    }

    /// Every usable record, newest first.
    public let usable: [Candidate]
    public let problems: [Problem]

    /// The newest usable record: what the message bar offers. Every action applies to this record only; other
    /// records (each from a different session, with different edits) are offered one after another.
    public var candidate: Candidate? { usable.first }

    /// How the shown record may be used.
    public enum CandidateMode: Sendable, Equatable {
        /// Based on exactly the publication on disk and no other restore in effect: "Restore unsaved changes".
        case restore
        /// Based on the publication on disk, but another record's restore is in effect in this window. A second
        /// restore would replace the first (and its record could then be resolved by a save that doesn't hold
        /// it), so this record opens only as a separate copy.
        case copyOnlyWhileAnotherRestoreIsInEffect
        /// Based on another (older) publication: opens only as a separate copy; never restored over newer work.
        case copyOnlyOlderRevision
    }

    /// At most one restore is in effect per document; every other record is copy-only.
    public func candidateMode(restoreInEffect: Bool) -> CandidateMode? {
        guard let candidate else { return nil }
        guard candidate.relation == .basedOnCurrent else { return .copyOnlyOlderRevision }
        return restoreInEffect ? .copyOnlyWhileAnotherRestoreIsInEffect : .restore
    }

    public var isEmpty: Bool { candidate == nil && problems.isEmpty }

    public static func assess(
        _ stored: [StoredEditCheckpoint],
        documentID: String,
        onDisk: RevisionFingerprint?,
        coder: JSONEnvelopeCoder<Payload>,
        decodeOlder: ((Data) throws(PersistenceError) -> DecodedDocument<Payload>)? = nil,
        belongsToDocument: (Payload) -> Bool
    ) -> EditCheckpointOffer {
        var usable: [Candidate] = []
        var problems: [Problem] = []
        let supported = coder.format.currentSchemaVersion
        for entry in stored {
            let record: EditCheckpointRecord
            switch entry.record {
            case .success(let value): record = value
            case .failure(.unreadable): problems.append(.unreadable(entry.url)); continue
            case .failure(.damaged): problems.append(.damaged(entry.url)); continue
            }
            guard record.documentID == documentID else { problems.append(.damaged(entry.url)); continue }
            if record.schemaVersion > supported {
                problems.append(.newerFormat(entry.url, found: record.schemaVersion, supported: supported))
                continue
            }
            guard EnvelopeHeaderInfo.peek(record.snapshot)?.checksum == record.payloadChecksum else {
                problems.append(.damaged(entry.url))
                continue
            }
            let decoded: DecodedDocument<Payload>
            do throws(PersistenceError) {
                do throws(PersistenceError) {
                    decoded = try coder.decode(record.snapshot)
                } catch .unsupportedOlderSchema(found: _, minimum: _) where decodeOlder != nil {
                    // A record written before a format change: upgraded in memory (read-only), never "damaged".
                    decoded = try decodeOlder!(record.snapshot)
                }
            } catch {
                if case let .unknownNewerSchema(found, supported) = error {
                    problems.append(.newerFormat(entry.url, found: found, supported: supported))
                } else {
                    problems.append(.damaged(entry.url))
                }
                continue
            }
            guard belongsToDocument(decoded.payload) else { problems.append(.damaged(entry.url)); continue }
            usable.append(Candidate(url: entry.url, record: record, relation: record.relation(to: onDisk), payload: decoded.payload))
        }
        usable.sort { ($0.record.createdAt, $0.record.checkpointSequence) > ($1.record.createdAt, $1.record.checkpointSequence) }
        return EditCheckpointOffer(usable: usable, problems: problems)
    }

    /// The same offer with its relation re-checked against what is on disk now (for example after a save
    /// while the offer was still showing). A restore is offered only while the base is still on disk.
    public func reassessed(against onDisk: RevisionFingerprint?) -> EditCheckpointOffer {
        EditCheckpointOffer(
            usable: usable.map { Candidate(url: $0.url, record: $0.record, relation: $0.record.relation(to: onDisk), payload: $0.payload) },
            problems: problems
        )
    }

    /// The offer without the given records (restored, discarded, copied or hidden); everything else remains.
    public func excluding(_ urls: Set<URL>) -> EditCheckpointOffer {
        EditCheckpointOffer(usable: usable.filter { !urls.contains($0.url) }, problems: problems.filter { !urls.contains($0.url) })
    }
}

/// Tracks an offered restore across undo, reload and verified publication. The offered record is deleted
/// only when the exact restored model is independently published while the same restore is still in effect.
public enum RestoredEditCheckpoints {
    public struct State<Payload: Equatable> {
        private var snapshots: [URL: Payload] = [:]
        private var generation: UInt64 = 0
        private var retiredURLs: Set<URL> = []

        public init() {}

        public var urls: Set<URL> { Set(snapshots.keys) }
        public var isEmpty: Bool { snapshots.isEmpty }
        public var currentGeneration: UInt64 { generation }

        /// A disk read supersedes all in-memory restores, including their old undo callbacks.
        public mutating func supersede() {
            generation &+= 1
            snapshots.removeAll()
            retiredURLs.removeAll()
        }

        /// A deleted offer must not be re-marked by an older Undo/Redo callback in this generation.
        public mutating func retire(_ url: URL) {
            snapshots.removeValue(forKey: url)
            retiredURLs.insert(url)
        }

        public func acceptsCallback(for url: URL, generation expected: UInt64) -> Bool {
            generation == expected && !retiredURLs.contains(url)
        }

        public mutating func mark(_ url: URL, snapshot: Payload, generation expected: UInt64) {
            guard acceptsCallback(for: url, generation: expected) else { return }
            snapshots[url] = snapshot
        }

        public mutating func unmark(_ url: URL, generation expected: UInt64) {
            guard acceptsCallback(for: url, generation: expected) else { return }
            snapshots.removeValue(forKey: url)
        }

        public struct SaveStart {
            fileprivate let snapshots: [URL: Payload]
            fileprivate let generation: UInt64
        }

        public func startingSave() -> SaveStart { SaveStart(snapshots: snapshots, generation: generation) }

        /// A verified save may resolve only the one restore whose exact snapshot it published. A later
        /// edit, revert, undo, or second restore cannot make an unrelated publication resolve it.
        public func resolved(started: SaveStart, published: Payload, current: Payload) -> Set<URL> {
            guard generation == started.generation, snapshots.count == 1, started.snapshots.count == 1,
                  published == current,
                  let (url, snapshot) = started.snapshots.first,
                  snapshot == published, snapshots[url] == snapshot
            else { return [] }
            return [url]
        }
    }
}
