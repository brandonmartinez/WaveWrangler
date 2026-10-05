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

    /// The newest usable record: what the message bar offers.
    public var candidate: Candidate? { usable.first }
    /// The records an action on the offer resolves: every usable record with the candidate's relation (the
    /// retained previous record is a safety copy of the newest). Records with another relation stay offered.
    public var candidateGroup: [URL] {
        guard let candidate else { return [] }
        return usable.filter { $0.relation == candidate.relation }.map(\.url)
    }

    public var isEmpty: Bool { candidate == nil && problems.isEmpty }

    public static func assess(
        _ stored: [StoredEditCheckpoint],
        documentID: String,
        onDisk: RevisionFingerprint?,
        coder: JSONEnvelopeCoder<Payload>,
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
                decoded = try coder.decode(record.snapshot)
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
