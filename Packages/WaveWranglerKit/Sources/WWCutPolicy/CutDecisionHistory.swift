import Foundation
import WWCore

/// Historical person decisions, not a live approval or an output/render prescription.
public enum CutDecisionStatus: String, Sendable, Equatable, Codable {
    case pending, adjusted, accepted, rejected, restored, abstained, blocked
}

public enum CutAuditFreshness: Sendable, Equatable {
    case unavailable, stale, matchesRecordedKey
}

public enum CutDecisionHistoryError: Error, Sendable, Equatable {
    case invalidIdentity, invalidTransition, duplicateID, duplicateActionID
}

/// The aligned grid is the pre-edit qStart/qEnd interval, not a post-edit output position.
/// This decoded value is an audit of an action; even `.accepted` cannot mint `ApprovedCut`.
public struct CutDecisionState: Sendable, Equatable, Codable {
    public let status: CutDecisionStatus
    public let request: CutRequest
    public let alignedOutputFrames: FrameSpan?
    public let outputRate: Int64?
    public let acceptedActionID: String?

    fileprivate init(status: CutDecisionStatus, request: CutRequest,
                     alignedOutputFrames: FrameSpan? = nil, outputRate: Int64? = nil,
                     acceptedActionID: String? = nil) {
        self.status = status
        self.request = request
        self.alignedOutputFrames = alignedOutputFrames
        self.outputRate = outputRate
        self.acceptedActionID = acceptedActionID
    }
}

public struct CutDecisionRecord: Identifiable, Sendable, Equatable, Codable {
    public let id: EditID
    public let actionName: String
    public let before: CutDecisionState
    public let after: CutDecisionState

    fileprivate init(id: EditID, actionName: String,
                     before: CutDecisionState, after: CutDecisionState) {
        self.id = id
        self.actionName = actionName
        self.before = before
        self.after = after
    }
}

/// One proposal's versioned, independently serializable decision audit. It is deliberately
/// separate from the M1 `EditHistory` cursor and cannot be substituted for a policy permit.
public struct CutDecisionHistory: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let proposal: CutProposal
    public private(set) var entries: [CutDecisionRecord]
    public private(set) var cursor: Int

    public init(proposal: CutProposal) throws {
        guard Self.validIdentity(proposal) else { throw CutDecisionHistoryError.invalidIdentity }
        version = Self.currentVersion
        self.proposal = proposal
        entries = []
        cursor = 0
    }

    public var auditState: CutDecisionState {
        cursor == 0 ? Self.initialState(for: proposal) : entries[cursor - 1].after
    }

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < entries.count }
    public var undoActionName: String? { canUndo ? entries[cursor - 1].actionName : nil }
    public var redoActionName: String? { canRedo ? entries[cursor].actionName : nil }

    /// Equality of untrusted dependency strings only. A match is NOT approval or export eligibility.
    public func auditFreshness(comparedWith key: EvidenceKey?) -> CutAuditFreshness {
        guard let key else { return .unavailable }
        return key == proposal.key && key.hasCompleteIdentity ? .matchesRecordedKey : .stale
    }

    public mutating func adjust(_ request: CutRequest, id: EditID = EditID()) throws {
        let before = auditState
        guard before.status == .pending || before.status == .adjusted,
              request != before.request, Self.validRequest(request, within: proposal) else {
            throw CutDecisionHistoryError.invalidTransition
        }
        try append(id: id, action: "Adjust", after: CutDecisionState(status: .adjusted, request: request))
    }

    /// Accepts only an already-admitted in-memory policy result. Saving it retains no proof or permit.
    public mutating func accept(_ cut: ApprovedCut, id: EditID = EditID()) throws {
        let before = auditState
        guard before.status == .pending || before.status == .adjusted,
              cut.request == before.request, cut.key == proposal.key,
              cut.footprint.key == proposal.key,
              cut.footprint.manifestRevision == proposal.key.laneManifestRevision,
              cut.review.proposalID == proposal.id, cut.review.request == cut.request,
              cut.review.key == proposal.key,
              cut.review.manifestRevision == proposal.key.laneManifestRevision,
              !cut.review.actionID.isEmpty, cut.footprint.outputRate > 0,
              Self.validRequest(cut.request, within: proposal) else {
            throw CutDecisionHistoryError.invalidTransition
        }
        guard !entries.contains(where: {
            $0.after.status == .accepted && $0.after.acceptedActionID == cut.review.actionID
        }) else { throw CutDecisionHistoryError.duplicateActionID }
        try append(id: id, action: "Accept",
                   after: CutDecisionState(status: .accepted, request: before.request,
                                           alignedOutputFrames: cut.footprint.grid,
                                           outputRate: cut.footprint.outputRate,
                                           acceptedActionID: cut.review.actionID))
    }

    public mutating func reject(id: EditID = EditID()) throws {
        let before = auditState
        guard before.status == .pending || before.status == .adjusted else {
            throw CutDecisionHistoryError.invalidTransition
        }
        try append(id: id, action: "Reject",
                   after: CutDecisionState(status: .rejected, request: before.request))
    }

    public mutating func abstain(id: EditID = EditID()) throws {
        let before = auditState
        guard before.status == .pending || before.status == .adjusted || before.status == .blocked else {
            throw CutDecisionHistoryError.invalidTransition
        }
        try append(id: id, action: "Abstain",
                   after: CutDecisionState(status: .abstained, request: before.request))
    }

    public mutating func restore(id: EditID = EditID()) throws {
        let before = auditState
        guard before.status == .accepted else { throw CutDecisionHistoryError.invalidTransition }
        try append(id: id, action: "Restore",
                   after: CutDecisionState(status: .restored, request: before.request,
                                           alignedOutputFrames: before.alignedOutputFrames,
                                           outputRate: before.outputRate,
                                           acceptedActionID: before.acceptedActionID))
    }

    /// Moves only the audit cursor. Reactivation requires a NEW `CutPolicy.admit` with
    /// current trusted episode state, person action and complete final all-lane footprint.
    public mutating func undo() throws {
        guard canUndo else { throw CutDecisionHistoryError.invalidTransition }
        cursor -= 1
    }

    public mutating func redo() throws {
        guard canRedo else { throw CutDecisionHistoryError.invalidTransition }
        cursor += 1
    }

    private mutating func append(id: EditID, action: String, after: CutDecisionState) throws {
        guard !entries.contains(where: { $0.id == id }) else { throw CutDecisionHistoryError.duplicateID }
        let record = CutDecisionRecord(id: id, actionName: "\(action) \(proposal.id)",
                                       before: auditState, after: after)
        entries = Array(entries.prefix(cursor)) + [record]
        cursor = entries.count
    }

    private static func initialState(for proposal: CutProposal) -> CutDecisionState {
        let eligible = proposal.context == .contextualFiller && CutPolicy.supportsWords(proposal)
        return CutDecisionState(status: eligible ? .pending : .blocked, request: proposal.request)
    }

    private static func validIdentity(_ proposal: CutProposal) -> Bool {
        !proposal.id.isEmpty && proposal.key.hasCompleteIdentity &&
        !proposal.words.isEmpty && proposal.words.allSatisfy { !$0.tokenID.isEmpty } &&
        Set(proposal.words.map(\.tokenID)).count == proposal.words.count &&
        validRequest(proposal.request, within: proposal)
    }

    private static func validRequest(_ request: CutRequest, within proposal: CutProposal) -> Bool {
        proposal.request.sourceFrames.contains(request.sourceFrames) &&
        request.fadeOutFrames >= 0 && request.fadeInFrames >= 0
    }

    private static func valid(_ state: CutDecisionState, for proposal: CutProposal) -> Bool {
        guard validRequest(state.request, within: proposal) else { return false }
        switch state.status {
        case .accepted, .restored:
            return state.alignedOutputFrames != nil &&
                (state.outputRate ?? 0) > 0 && !(state.acceptedActionID ?? "").isEmpty
        case .pending, .adjusted, .rejected, .abstained, .blocked:
            return state.alignedOutputFrames == nil && state.outputRate == nil &&
                state.acceptedActionID == nil
        }
    }

    private static func valid(_ record: CutDecisionRecord, for proposal: CutProposal) -> Bool {
        guard valid(record.before, for: proposal), valid(record.after, for: proposal),
              record.actionName == "\(recordAction(record)) \(proposal.id)" else { return false }
        let before = record.before
        let after = record.after
        switch (before.status, after.status) {
        case (.pending, .adjusted), (.adjusted, .adjusted):
            return after.request != before.request
        case (.pending, .accepted), (.adjusted, .accepted):
            return after.request == before.request
        case (.pending, .rejected), (.adjusted, .rejected),
             (.pending, .abstained), (.adjusted, .abstained), (.blocked, .abstained):
            return after.request == before.request
        case (.accepted, .restored):
            return after.request == before.request &&
                after.alignedOutputFrames == before.alignedOutputFrames &&
                after.outputRate == before.outputRate &&
                after.acceptedActionID == before.acceptedActionID
        default:
            return false
        }
    }

    private static func recordAction(_ record: CutDecisionRecord) -> String {
        switch record.after.status {
        case .adjusted: "Adjust"
        case .accepted: "Accept"
        case .rejected: "Reject"
        case .abstained: "Abstain"
        case .restored: "Restore"
        case .pending, .blocked: ""
        }
    }

    private enum CodingKeys: String, CodingKey { case version, proposal, entries, cursor }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                                                   debugDescription: "Unsupported cut history version")
        }
        let proposal = try values.decode(CutProposal.self, forKey: .proposal)
        let entries = try values.decode([CutDecisionRecord].self, forKey: .entries)
        let cursor = try values.decode(Int.self, forKey: .cursor)
        guard Self.validIdentity(proposal), (0...entries.count).contains(cursor),
              Set(entries.map(\.id)).count == entries.count else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: values,
                                                   debugDescription: "Invalid cut history identity or cursor")
        }
        var previous = Self.initialState(for: proposal)
        var acceptedIDs = Set<String>()
        for entry in entries {
            guard entry.before == previous, Self.valid(entry, for: proposal) else {
                throw DecodingError.dataCorruptedError(forKey: .entries, in: values,
                                                       debugDescription: "Invalid cut history transition")
            }
            if entry.after.status == .accepted {
                guard let actionID = entry.after.acceptedActionID,
                      acceptedIDs.insert(actionID).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: .entries, in: values,
                                                           debugDescription: "Duplicate person action")
                }
            }
            previous = entry.after
        }
        self.version = version
        self.proposal = proposal
        self.entries = entries
        self.cursor = cursor
    }
}
