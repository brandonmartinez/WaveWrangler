import Foundation
import WWCore
import WWCutPolicy

/// An audit's currentness is informational. Even a matching key cannot authorize a cut.
public enum CutAuditDisposition: Sendable, Equatable {
    case evidenceUnavailable
    case staleEvidence
    case freshAdmissionRequired
}

public enum CutAuditPersistenceError: Error, Sendable, Equatable {
    case missingEpisode
    case duplicateID
    case duplicateProposal
    case notFound
    case concurrentChange
    case identityChanged
    case invalidContinuation
}

public struct ReopenedCutAudit: Sendable {
    public let history: CutDecisionHistory
    public let disposition: CutAuditDisposition

    /// No path from historical data to a permit. Matching revisions still need a *new*
    /// person action and current independent policy admission.
    public func requireCutAuthority() throws(CutAuditDisposition) -> Never {
        throw disposition
    }
}

extension CutAuditDisposition: Error {}

/// Typed show-scope storage for an untrusted per-proposal WWCutPolicy audit.
/// No API here produces ApprovedCut, HumanReviewAction or an applied edit.
public enum CutAuditPersistence {
    public static func inserting(_ history: CutDecisionHistory, in episodeID: EpisodeID,
                                 id: EditID = EditID(), into show: ShowDocumentModel) throws -> ShowDocumentModel {
        guard show.episode(episodeID) != nil else { throw CutAuditPersistenceError.missingEpisode }
        guard !(show.cutAudits ?? []).contains(where: { $0.id == id }) else {
            throw CutAuditPersistenceError.duplicateID
        }
        for audit in show.cutAudits ?? [] where audit.episodeID == episodeID &&
            audit.proposalID == history.proposal.id {
            guard try decode(audit).proposal.key != history.proposal.key else {
                throw CutAuditPersistenceError.duplicateProposal
            }
        }
        var copy = show
        copy.cutAudits = (copy.cutAudits ?? []) + [try stored(history, episodeID: episodeID, id: id)]
        return copy
    }

    /// Optimistic replacement retains the audit prefix through the old cursor. Only a new
    /// action after Undo may discard the redo tail, exactly as CutDecisionHistory does.
    public static func updating(_ history: CutDecisionHistory, id: EditID,
                                replacing previous: CutDecisionHistory,
                                in show: ShowDocumentModel) throws -> ShowDocumentModel {
        guard let index = show.cutAudits?.firstIndex(where: { $0.id == id }),
              let original = show.cutAudits?[index] else { throw CutAuditPersistenceError.notFound }
        let current = try decode(original)
        guard current == previous else { throw CutAuditPersistenceError.concurrentChange }
        guard current.proposal == history.proposal else { throw CutAuditPersistenceError.identityChanged }
        guard Array(history.entries.prefix(current.cursor)) == Array(current.entries.prefix(current.cursor)),
              (history.entries == current.entries ||
               (history.cursor == history.entries.count && history.entries.count > current.cursor))
        else { throw CutAuditPersistenceError.invalidContinuation }
        var copy = show
        copy.cutAudits?[index] = try stored(history, episodeID: original.episodeID, id: id)
        return copy
    }

    public static func reopening(_ stored: StoredCutAudit, currentKey: EvidenceKey?) throws -> ReopenedCutAudit {
        let history = try decode(stored)
        let disposition: CutAuditDisposition
        switch history.auditFreshness(comparedWith: currentKey) {
        case .unavailable: disposition = .evidenceUnavailable
        case .stale: disposition = .staleEvidence
        case .matchesRecordedKey: disposition = .freshAdmissionRequired
        }
        return ReopenedCutAudit(history: history, disposition: disposition)
    }

    private static func stored(_ history: CutDecisionHistory, episodeID: EpisodeID,
                               id: EditID) throws -> StoredCutAudit {
        StoredCutAudit(id: id, episodeID: episodeID, proposalID: history.proposal.id,
                       version: history.version, historyJSON: try JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(history))
    }

    static func decode(_ stored: StoredCutAudit) throws -> CutDecisionHistory {
        try StrictJSON.validate(stored.historyJSON)
        let decoder = JSONEnvelopeCoder<ShowDocumentModel>.makeDecoder()
        let history = try decoder.decode(CutDecisionHistory.self, from: stored.historyJSON)
        guard stored.version == history.version, stored.proposalID == history.proposal.id else {
            throw PersistenceError.invalidPayload([.init(.invalidCutAudit, "cut audit \(stored.id) identity/version mismatch")])
        }
        let canonical = try JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(history)
        guard canonical == stored.historyJSON else {
            throw PersistenceError.unrecognizedContent
        }
        return history
    }
}

extension ShowDocumentModel {
    func newerEmbeddedCutAuditSchema() -> (found: Int, supported: Int)? {
        for audit in cutAudits ?? [] {
            if audit.version > CutDecisionHistory.currentVersion {
                return (audit.version, CutDecisionHistory.currentVersion)
            }
            if (try? StrictJSON.validate(audit.historyJSON)) != nil,
               let embedded = try? JSONDecoder().decode(CutAuditVersionHeader.self, from: audit.historyJSON),
               embedded.version > CutDecisionHistory.currentVersion {
                return (embedded.version, CutDecisionHistory.currentVersion)
            }
        }
        return nil
    }

    func embeddedCutAuditIssues() -> [ValidationIssue] {
        var seen = [String: [EvidenceKey]]()
        return (cutAudits ?? []).compactMap { audit in
            do {
                let history = try CutAuditPersistence.decode(audit)
                let identity = "\(audit.episodeID)/\(audit.proposalID)"
                let keys = seen[identity] ?? []
                guard !keys.contains(history.proposal.key) else {
                    return .init(.invalidCutAudit, "duplicate episode/proposal/revision audit \(audit.id)")
                }
                seen[identity, default: []].append(history.proposal.key)
                return nil
            } catch {
                return .init(.invalidCutAudit, "cut audit \(audit.id): \(error)")
            }
        }
    }
}

private struct CutAuditVersionHeader: Decodable {
    let version: Int
}
