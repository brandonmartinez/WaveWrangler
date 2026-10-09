import Foundation
import Testing
import WWCore
@testable import WWCutPolicy

private struct HistoryMapper: CutFootprintMapping {
    let proof: CutFootprint

    func footprint(for request: CutRequest, primary: SourceOccurrence) throws -> CutFootprint {
        proof
    }
}

@Suite("Versioned per-cut decision audit")
struct CutDecisionHistoryTests {
    private let proposal = CutPolicyTests.proposal()

    private func approved(_ proposal: CutProposal, request: CutRequest? = nil,
                          proof: CutFootprint? = nil) throws -> ApprovedCut {
        let request = request ?? proposal.request
        return try CutPolicy.admit(
            proposal, request: request, current: CutPolicyTests.state(),
            review: CutPolicyTests.review(proposal, request: request),
            mapping: HistoryMapper(proof: proof ?? CutPolicyTests.proof())
        )
    }

    @Test("Accepted and restored decisions round-trip with exact occurrence, revisions and frames")
    func versionedRoundTrip() throws {
        var history = try CutDecisionHistory(proposal: proposal)
        #expect(history.version == 1)
        #expect(history.auditState.status == .pending)
        var blocked = try CutDecisionHistory(proposal: CutPolicyTests.proposal(context: .meaningful))
        #expect(blocked.auditState.status == .blocked)
        #expect(throws: CutDecisionHistoryError.invalidTransition) {
            try blocked.accept(approved(proposal))
        }
        try blocked.abstain()
        #expect(blocked.auditState.status == .abstained)
        let cut = try approved(proposal)
        try history.accept(cut)
        let accepted = history.auditState
        #expect(accepted.status == .accepted)
        #expect(accepted.request.sourceFrames == CutPolicyTests.span(100, 110))
        #expect(accepted.alignedOutputFrames == CutPolicyTests.span(200, 210))
        #expect(accepted.outputRate == 48_000)
        #expect(accepted.acceptedActionID == "person-action-1")
        #expect(history.proposal.key.primary == CutPolicyTests.primary)
        #expect(history.proposal.key.correctionRevision == "c1")
        try history.restore()
        #expect(history.auditState.status == .restored)
        #expect(history.auditState.request == accepted.request)
        #expect(history.auditState.alignedOutputFrames == accepted.alignedOutputFrames)
        #expect(history.auditState.acceptedActionID == accepted.acceptedActionID)
        var reopened = try JSONDecoder().decode(CutDecisionHistory.self, from: JSONEncoder().encode(history))
        #expect(reopened == history)
        #expect(reopened.entries.map(\.actionName) == ["Accept proposal-1", "Restore proposal-1"])
        #expect(reopened.undoActionName == "Restore proposal-1")
        #expect(reopened.auditState.status == .restored)
        try reopened.undo()
        #expect(reopened.auditState == accepted)
        try reopened.redo()
        #expect(reopened == history)
    }

    @Test("Adjustments retain mode, source boundaries, fade lengths and undo/redo replay")
    func adjustmentAndReplay() throws {
        var history = try CutDecisionHistory(proposal: proposal)
        let lift = CutRequest(sourceFrames: CutPolicyTests.span(101, 109), mode: .lift,
                              fadeOutFrames: 2, fadeInFrames: 3)
        try history.adjust(lift)
        let adjusted = history.auditState
        #expect(adjusted.status == .adjusted)
        #expect(adjusted.request == lift)
        #expect(adjusted.alignedOutputFrames == nil)
        try history.reject()
        let rejected = history.auditState
        try history.undo()
        #expect(history.auditState == adjusted)
        #expect(history.redoActionName == "Reject proposal-1")
        try history.redo()
        #expect(history.auditState == rejected)
        try history.undo()
        let reopened = try JSONDecoder().decode(CutDecisionHistory.self, from: JSONEncoder().encode(history))
        #expect(reopened == history)
        var replay = reopened
        try replay.redo()
        #expect(replay.auditState == rejected)
        let newID = EditID()
        try history.adjust(CutRequest(sourceFrames: CutPolicyTests.span(102, 108), mode: .shorten),
                           id: newID)
        #expect(history.entries.map(\.actionName) == ["Adjust proposal-1", "Adjust proposal-1"])
        #expect(history.entries[1].id == newID)
        #expect(!history.canRedo)
        #expect(history.auditState.request.sourceFrames == CutPolicyTests.span(102, 108))
        #expect(throws: CutDecisionHistoryError.invalidTransition) {
            try history.adjust(CutRequest(sourceFrames: CutPolicyTests.span(99, 109)))
        }
    }

    @Test("Admitted Lift/fades capture the policy's exact common grid, not a guessed output position")
    func admittedModeAndFades() throws {
        let request = CutRequest(sourceFrames: proposal.request.sourceFrames, mode: .lift,
                                 fadeOutFrames: 2, fadeInFrames: 2)
        let fades: [String: FadeFootprint] = Dictionary(uniqueKeysWithValues:
            [("primary", Int64(100)), ("backup", 120), ("other", 140)].map { id, start in
                let out = CutPolicyTests.span(start - 2, start)
                let fadeIn = CutPolicyTests.span(start + 10, start + 12)
                return (id, FadeFootprint(fadeOut: out, fadeIn: fadeIn,
                                          mergedFinal: [out, fadeIn]))
            })
        var history = try CutDecisionHistory(proposal: proposal)
        try history.adjust(request)
        let proof = CutPolicyTests.proof(mode: .lift, fadeLength: 2, fadeInLength: 2,
                                         fadeOverrides: fades)
        try history.accept(approved(proposal, request: request, proof: proof))
        #expect(history.auditState.request.mode == .lift)
        #expect(history.auditState.request.fadeOutFrames == 2)
        #expect(history.auditState.request.fadeInFrames == 2)
        #expect(history.auditState.alignedOutputFrames == proof.grid)
        #expect(try JSONDecoder().decode(CutDecisionHistory.self,
                                         from: JSONEncoder().encode(history)) == history)
    }

    @Test("Every key change including Backup activation, correction and other cuts stales audit")
    func dependencyChanges() throws {
        var history = try CutDecisionHistory(proposal: proposal)
        try history.accept(approved(proposal))
        #expect(history.auditFreshness(comparedWith: nil) == .unavailable)
        #expect(history.auditFreshness(comparedWith: proposal.key) == .matchesRecordedKey)
        let changed: [EvidenceKey] = [
            CutPolicyTests.key(source: "s2"), CutPolicyTests.key(model: "local2"),
            CutPolicyTests.key(primary: CutPolicyTests.backup),
            CutPolicyTests.key(correction: "c2"), CutPolicyTests.key(map: "m2"),
            CutPolicyTests.key(asset: "a2"), CutPolicyTests.key(format: "f2"),
            CutPolicyTests.key(protection: "p2"), CutPolicyTests.key(transcript: "t2"),
            CutPolicyTests.key(recipe: "r2"), CutPolicyTests.key(cuts: "cuts2"),
            CutPolicyTests.key(manifest: "backup-activated"),
            CutPolicyTests.key(authorization: .notAuthorized),
        ]
        let reopened = try JSONDecoder().decode(CutDecisionHistory.self, from: JSONEncoder().encode(history))
        for key in changed {
            #expect(reopened.auditFreshness(comparedWith: key) == .stale)
            #expect(reopened.proposal.key.primary == CutPolicyTests.primary)
            #expect(reopened.auditState.status == .accepted)
        }
    }

    @Test("Duplicate edit IDs and malformed saved cursors, versions or transitions refuse")
    func malformedAudit() throws {
        var history = try CutDecisionHistory(proposal: proposal)
        let id = EditID()
        try history.adjust(CutRequest(sourceFrames: proposal.request.sourceFrames, mode: .lift), id: id)
        #expect(throws: CutDecisionHistoryError.duplicateID) { try history.reject(id: id) }
        #expect(history.entries.count == 1)
        var accepted = try CutDecisionHistory(proposal: proposal)
        try accepted.accept(approved(proposal))
        try accepted.undo()
        #expect(throws: CutDecisionHistoryError.duplicateActionID) {
            try accepted.accept(approved(proposal))
        }
        #expect(accepted.canRedo)
        let data = try JSONEncoder().encode(history)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 2
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CutDecisionHistory.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        }
        object["version"] = 1
        object["cursor"] = 2
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CutDecisionHistory.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        }
        object["cursor"] = 1
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(entries[0])
        object["entries"] = entries
        object["cursor"] = 2
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CutDecisionHistory.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        }
        var invalidFrame = try #require(object["proposal"] as? [String: Any])
        var request = try #require(invalidFrame["request"] as? [String: Any])
        request["sourceFrames"] = ["start": 110, "end": 100]
        invalidFrame["request"] = request
        object["proposal"] = invalidFrame
        object["entries"] = Array(entries.prefix(1))
        object["cursor"] = 1
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CutDecisionHistory.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("Duplicate candidate token IDs cannot acquire a durable decision identity")
    func duplicateTokenIdentities() throws {
        let duplicated = CutProposal(
            id: proposal.id, key: proposal.key,
            words: [
                CandidateWord(tokenID: "same", timing: .supported(start: 100, end: 105)),
                CandidateWord(tokenID: "same", timing: .supported(start: 105, end: 110)),
            ],
            context: .contextualFiller, request: proposal.request)
        #expect(throws: CutDecisionHistoryError.invalidIdentity) {
            try CutDecisionHistory(proposal: duplicated)
        }
    }

    @Test("A forged decoded accepted audit cannot satisfy missing private human review")
    func forgedAcceptedRemainsInert() throws {
        var history = try CutDecisionHistory(proposal: proposal)
        try history.accept(approved(proposal))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        var after = try #require(entries[0]["after"] as? [String: Any])
        after["acceptedActionID"] = "attacker-claimed-acceptance"
        entries[0]["after"] = after
        object["entries"] = entries
        let forged = try JSONDecoder().decode(
            CutDecisionHistory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(forged.auditState.status == .accepted)
        #expect(forged.auditFreshness(comparedWith: proposal.key) == .matchesRecordedKey)
        #expect(throws: CutRefusal.missingHumanReview) {
            try CutPolicy.admit(
                forged.proposal, request: forged.auditState.request,
                current: CutPolicyTests.state(), review: nil,
                mapping: HistoryMapper(proof: CutPolicyTests.proof()))
        }
        #expect(throws: CutRefusal.missingLaneAuthority) {
            try CutPolicy.admit(
                forged.proposal, request: forged.auditState.request,
                current: nil, review: nil,
                mapping: HistoryMapper(proof: CutPolicyTests.proof()))
        }
    }
}
