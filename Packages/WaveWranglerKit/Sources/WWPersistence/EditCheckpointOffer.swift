import Foundation
import WWCore

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
/// - If a usable record's base SHA-256 matches the observed on-disk publication, offer
///   **"Restore unsaved changes from <time>"**. A digest match is not a byte-for-byte proof;
///   a restored document is dirty, not saved.
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

    /// Every usable record in shared presentation order (recorded creation time, with stable ties).
    public let usable: [Candidate]
    public let problems: [Problem]
    /// All retained records in shared presentation order, including those whose contents cannot be decoded.
    public let orderedURLs: [URL]

    /// The first usable record: what the message bar offers. Every action applies to this record only; other
    /// records (each from a different session, with different edits) are offered one after another.
    public var candidate: Candidate? { usable.first }

    /// How the shown record may be used.
    public enum CandidateMode: Sendable, Equatable {
        /// Based on exactly the publication on disk and no other restore in effect: "Restore unsaved changes".
        case restore
        /// Based on the publication on disk, but another record's restore is in effect in this window.
        /// A second restore would replace the first, so this record opens only as a separate copy.
        case copyOnlyWhileAnotherRestoreIsInEffect
        /// Based on another (older) publication: opens only as a separate copy; never restored over newer work.
        case copyOnlyOlderRevision
    }

    /// At most one restore is in effect per document; every other record is copy-only.
    public func candidateMode(restoreInEffect: Bool) -> CandidateMode? {
        guard let candidate else { return nil }
        return mode(for: candidate, restoreInEffect: restoreInEffect)
    }

    public func mode(for candidate: Candidate, restoreInEffect: Bool) -> CandidateMode {
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
        let usableURLs = Set(usable.map(\.url))
        let plan = RecoveryChoicePresentation.plan(records: stored.map { entry in
            let record: EditCheckpointRecord? = if case let .success(value) = entry.record { value } else { nil }
            return .init(recordID: entry.url.path,
                         kind: usableURLs.contains(entry.url) ? .unsavedCheckpoint : .damagedUnsaved,
                         documentID: record?.documentID ?? documentID,
                         savedAt: nil, createdAt: record?.createdAt,
                         revision: record.flatMap { EnvelopeHeaderInfo.peek($0.snapshot)?.revision },
                         disposition: usableURLs.contains(entry.url) ? .open : .reveal)
        })
        let order = Dictionary(uniqueKeysWithValues: plan.choices.enumerated().map { ($0.element.record.recordID, $0.offset) })
        func position(_ url: URL) -> Int {
            guard let index = order[url.path] else { preconditionFailure("Recovery choice lost its C2b record") }
            return index
        }
        usable.sort { position($0.url) < position($1.url) }
        problems.sort { position($0.url) < position($1.url) }
        let storedURLs = Dictionary(uniqueKeysWithValues: stored.map { ($0.url.path, $0.url) })
        return EditCheckpointOffer(usable: usable, problems: problems,
                                   orderedURLs: plan.choices.map { choice in
                                       guard let url = storedURLs[choice.record.recordID] else {
                                           preconditionFailure("Recovery choice lost its offered file")
                                       }
                                       return url
                                   })
    }

    /// The same offer with its relation re-checked against what is on disk now (for example after a save
    /// while the offer was still showing). A restore is offered only while the base is still on disk.
    public func reassessed(against onDisk: RevisionFingerprint?) -> EditCheckpointOffer {
        EditCheckpointOffer(
            usable: usable.map { Candidate(url: $0.url, record: $0.record, relation: $0.record.relation(to: onDisk), payload: $0.payload) },
            problems: problems, orderedURLs: orderedURLs
        )
    }

    /// The offer without problem reports explicitly dismissed in this window; no record is removed.
    public func excluding(_ urls: Set<URL>) -> EditCheckpointOffer {
        EditCheckpointOffer(usable: usable.filter { !urls.contains($0.url) }, problems: problems.filter { !urls.contains($0.url) },
                            orderedURLs: orderedURLs.filter { !urls.contains($0) })
    }
}
