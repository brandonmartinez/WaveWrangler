import Foundation
import Testing
import WWCore
import WWCutPolicy
@testable import WWPersistence

private struct RefusingCutMapper: CutFootprintMapping {
    func footprint(for request: CutRequest, primary: SourceOccurrence) throws -> CutFootprint {
        throw CutRefusal.invalidGrid
    }
}

@Suite("Canonical cut decision audit")
struct CutAuditPersistenceTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
    let unchecked = JSONEnvelopeCoder<ShowDocumentModel>(format: .show) { _, _ in [] }
    let episodeID = EpisodeID()

    var show: ShowDocumentModel {
        ShowDocumentModel(show: Show(title: "Synthetic show"),
                          episodes: [Episode(id: episodeID, title: "Synthetic episode")])
    }

    static let primary = SourceOccurrence(source: "source", channel: 0, occurrence: "take", epoch: "epoch")

    static func key(model: String = "model-1", map: String = "map-1",
                    primary: SourceOccurrence = primary, manifest: String = "backup-1",
                    format: String = "format-1", asset: String = "asset-1",
                    correction: String = "correction-1") -> EvidenceKey {
        EvidenceKey(primary: primary, primaryAuthorization: .authorizedSelectedPrimary,
                    sourceRevision: "source-1", modelRevision: model, transcriptRevision: "words-1",
                    correctionRevision: correction, alignmentRevision: map, assetRevision: asset,
                    formatRevision: format, protectionRevision: "protected-1",
                    outputRecipeRevision: "recipe-1", otherCutsRevision: "cuts-1",
                    laneManifestRevision: manifest)
    }

    static func history() throws -> CutDecisionHistory {
        try CutDecisionHistory(proposal: CutProposal(
            id: "proposal-1", key: key(),
            words: [CandidateWord(tokenID: "word-1", timing: .supported(start: 100, end: 110))],
            context: .contextualFiller,
            request: CutRequest(sourceFrames: try FrameSpan(100, 110))))
    }

    func reopened(_ model: ShowDocumentModel, current: EvidenceKey? = key()) throws -> ReopenedCutAudit {
        let disk = try coder.encode(model, revision: 2)
        let decoded = try coder.decode(disk).payload
        return try CutAuditPersistence.reopening(try #require(decoded.cutAudits?.first), currentKey: current)
    }

    @Test func saveReopenUndoRedoAndRedoTail() throws {
        var history = try Self.history()
        let first = CutRequest(sourceFrames: try FrameSpan(101, 109), mode: .lift,
                               fadeOutFrames: 2, fadeInFrames: 3)
        try history.adjust(first)
        let id = EditID()
        var model = try CutAuditPersistence.inserting(history, in: episodeID, id: id, into: show)
        #expect(try reopened(model).history == history)
        #expect(try reopened(model).disposition == .freshAdmissionRequired)
        #expect(throws: CutAuditDisposition.freshAdmissionRequired) {
            try reopened(model).requireCutAuthority()
        }
        let previous = history
        try history.reject()
        model = try CutAuditPersistence.updating(history, id: id, replacing: previous, in: model)
        let rejected = history
        try history.undo()
        model = try CutAuditPersistence.updating(history, id: id, replacing: rejected, in: model)
        var reopenedHistory = try reopened(model).history
        #expect(reopenedHistory.cursor == 1 && reopenedHistory.redoActionName == "Reject proposal-1")
        try reopenedHistory.redo()
        #expect(reopenedHistory == rejected)
        let second = CutRequest(sourceFrames: try FrameSpan(102, 108), mode: .shorten)
        try history.adjust(second)
        model = try CutAuditPersistence.updating(history, id: id, replacing: try reopened(model).history, in: model)
        #expect(try reopened(model).history == history)
        #expect(history.entries.count == 2 && !history.canRedo)
        #expect(history.auditState.request == second)
        #expect(model.history.entries.isEmpty, "the M1 edit history is unchanged")

        let deletedEpisode = try model.removingEpisode(episodeID)
        #expect(try reopened(deletedEpisode).history == history, "episode removal retains audit evidence")
    }

    @Test func identityAndConcurrentReplacementRefuseWithoutLosingAudit() throws {
        let initial = try Self.history()
        let id = EditID()
        let model = try CutAuditPersistence.inserting(initial, in: episodeID, id: id, into: show)
        #expect(throws: CutAuditPersistenceError.duplicateID) {
            try CutAuditPersistence.inserting(initial, in: episodeID, id: id, into: model)
        }
        #expect(throws: CutAuditPersistenceError.duplicateProposal) {
            try CutAuditPersistence.inserting(initial, in: episodeID, into: model)
        }
        var duplicateProposal = model
        let stored = try #require(model.cutAudits?.first)
        duplicateProposal.cutAudits?.append(StoredCutAudit(
            id: EditID(), episodeID: episodeID, proposalID: "proposal-1",
            version: 1, historyJSON: stored.historyJSON))
        #expect(throws: PersistenceError.self) { try coder.encode(duplicateProposal, revision: 1) }
        #expect(throws: CutAuditPersistenceError.missingEpisode) {
            try CutAuditPersistence.inserting(initial, in: EpisodeID(), into: show)
        }
        var changed = initial
        try changed.reject()
        let updated = try CutAuditPersistence.updating(changed, id: id, replacing: initial, in: model)
        #expect(throws: CutAuditPersistenceError.concurrentChange) {
            try CutAuditPersistence.updating(initial, id: id, replacing: initial, in: updated)
        }
        let different = try CutDecisionHistory(proposal: CutProposal(
            id: "proposal-2", key: Self.key(),
            words: initial.proposal.words, context: .contextualFiller,
            request: initial.proposal.request))
        #expect(throws: CutAuditPersistenceError.identityChanged) {
            try CutAuditPersistence.updating(different, id: id, replacing: changed, in: updated)
        }
        #expect(try reopened(updated).history == changed)
    }

    @Test func revisedDependenciesRetainAuditAndRefuseAuthority() throws {
        var history = try Self.history()
        try history.reject()
        let model = try CutAuditPersistence.inserting(history, in: episodeID, into: show)
        let changes = [
            Self.key(model: "model-2"), Self.key(map: "map-2"),
            Self.key(primary: .init(source: "backup", channel: 0, occurrence: "take", epoch: "epoch")),
            Self.key(manifest: "backup-activated"), Self.key(format: "format-2"),
            Self.key(asset: "asset-2"), Self.key(correction: "correction-2"),
        ]
        for key in changes {
            let audit = try reopened(model, current: key)
            #expect(audit.history == history)
            #expect(audit.disposition == .staleEvidence)
            #expect(throws: CutAuditDisposition.staleEvidence) { try audit.requireCutAuthority() }
        }
        #expect(try reopened(model, current: nil).disposition == .evidenceUnavailable)
        #expect(throws: CutAuditDisposition.evidenceUnavailable) {
            try reopened(model, current: nil).requireCutAuthority()
        }
    }

    @Test func malformedDuplicateUnknownAndNewerAuditsRefuseOnOpenAndSave() throws {
        var history = try Self.history()
        try history.reject()
        let good = try CutAuditPersistence.inserting(history, in: episodeID, into: show)
        let stored = try #require(good.cutAudits?.first)
        var duplicate = good
        duplicate.cutAudits?.append(stored)
        #expect(throws: PersistenceError.self) { try coder.encode(duplicate, revision: 1) }
        #expect(throws: PersistenceError.self) {
            try coder.decode(try unchecked.encode(duplicate, revision: 1))
        }

        func tampered(_ data: Data, version: Int = 1) -> ShowDocumentModel {
            var model = good
            model.cutAudits = [StoredCutAudit(id: stored.id, episodeID: episodeID,
                proposalID: stored.proposalID, version: version, historyJSON: data)]
            return model
        }
        var object = try #require(JSONSerialization.jsonObject(with: stored.historyJSON) as? [String: Any])
        object["cursor"] = 9
        let invalidCursor = tampered(try JSONSerialization.data(withJSONObject: object))
        #expect(throws: PersistenceError.self) { try coder.encode(invalidCursor, revision: 1) }
        #expect(throws: PersistenceError.self) {
            try coder.decode(try unchecked.encode(invalidCursor, revision: 1))
        }
        object["cursor"] = 1
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(entries[0])
        object["entries"] = entries
        let repeated = tampered(try JSONSerialization.data(withJSONObject: object))
        #expect(throws: PersistenceError.self) {
            try coder.decode(try unchecked.encode(repeated, revision: 1))
        }
        object["entries"] = Array(entries.prefix(1))
        object["futureAuditField"] = true
        let unknown = tampered(try JSONSerialization.data(withJSONObject: object))
        #expect(throws: PersistenceError.self) {
            try coder.decode(try unchecked.encode(unknown, revision: 1))
        }
        let newer = tampered(stored.historyJSON, version: 2)
        #expect(throws: PersistenceError.unknownNewerSchema(found: 2, supported: 1)) {
            try coder.decode(try unchecked.encode(newer, revision: 1))
        }
        #expect(throws: PersistenceError.self) { try coder.encode(newer, revision: 1) }
        object.removeValue(forKey: "futureAuditField")
        object["version"] = 2
        let embeddedNewer = tampered(try JSONSerialization.data(withJSONObject: object))
        #expect(throws: PersistenceError.unknownNewerSchema(found: 2, supported: 1)) {
            try coder.decode(try unchecked.encode(embeddedNewer, revision: 1))
        }
    }

    @Test func forgedAcceptedHistoryRemainsHistoricalOnly() throws {
        var history = try Self.history()
        try history.reject()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        var after = try #require(entries[0]["after"] as? [String: Any])
        after["status"] = "accepted"
        after["alignedOutputFrames"] = ["start": 200, "end": 210]
        after["outputRate"] = 48_000
        after["acceptedActionID"] = "forged-person-action"
        entries[0]["after"] = after
        entries[0]["actionName"] = "Accept proposal-1"
        object["entries"] = entries
        let forged = try JSONDecoder().decode(CutDecisionHistory.self,
                    from: JSONSerialization.data(withJSONObject: object))
        let model = try CutAuditPersistence.inserting(forged, in: episodeID, into: show)
        let audit = try reopened(model)
        #expect(audit.history.auditState.status == .accepted)
        #expect(audit.history.auditState.acceptedActionID == "forged-person-action")
        #expect(audit.disposition == .freshAdmissionRequired)
        #expect(throws: CutAuditDisposition.freshAdmissionRequired) { try audit.requireCutAuthority() }
        #expect(throws: CutRefusal.missingLaneAuthority) {
            try CutPolicy.admit(audit.history.proposal, request: audit.history.auditState.request,
                                current: nil, review: nil, mapping: RefusingCutMapper())
        }
        #expect(model.history.entries.isEmpty)
    }

    // Frozen synthetic schema 3 wire fixture; checksum is over the sorted-key payload.
    static let legacy = Data(#"{"checksum":"sha256:97582c17ca16d1ca299eb0b7518adf8637601481454a89f6a0512d2339c8c6fa","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[{"id":"00000000-0000-4000-8000-000000000302","notes":"","recorderGroups":[],"sources":[],"speakerAssignments":[],"status":"planned","title":"Legacy Episode"}],"history":{"cursor":0,"entries":[]},"schemaVersion":3,"show":{"id":"00000000-0000-4000-8000-000000000301","notes":"","title":"Legacy Show"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000303","revision":1,"schemaVersion":3}"#.utf8)

    @Test func schema3LegacyMigratesWithoutInventingAudits() throws {
        #expect(try JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV3>(
            format: ShowSchemaMigration.schema3Format) { _, _ in [] }
            .decode(Self.legacy).payload.schemaVersion == 3)
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 3, minimum: 4)) {
            try coder.decode(Self.legacy)
        }
        let migrated = try ShowSchemaMigration.decodeSchema3(Self.legacy).payload
        #expect(migrated.cutAudits == nil)
        #expect(migrated.schemaVersion == 4)
        #expect(ShowSchemaMigration.schema3ExpectationFailures(original: Self.legacy, migrated: migrated).isEmpty)
        #expect(try ShowSchemaMigration.decodeUpgradingOlder(Self.legacy).payload == migrated)
        let rig = Rig()
        let url = rig.url()
        try Self.legacy.write(to: url)
        guard case .needsMigration(fromSchema: 3, _) = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>
            .show(recovery: rig.recovery).open(url, key: .show(migrated.show.id)) else {
            Issue.record("schema 3 must need explicit migration")
            return
        }
        let receipt = try DocumentMigrator.show(publisher: rig.publisher)
            .migrate(url, key: .show(migrated.show.id))
        #expect(try Data(contentsOf: receipt.backup) == Self.legacy)
        #expect(try coder.decode(Data(contentsOf: url)).payload == migrated)
        #expect(throws: PersistenceError.unknownNewerSchema(found: 4, supported: 3)) {
            try JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV3>(
                format: ShowSchemaMigration.schema3Format) { _, _ in [] }
                .decode(Data(contentsOf: url))
        }
    }

    @Test func schema3CannotSmuggleAuditData() throws {
        var envelope = try #require(JSONSerialization.jsonObject(with: Self.legacy) as? [String: Any])
        var payload = try #require(envelope["payload"] as? [String: Any])
        payload["cutAudits"] = [["unknown": true]]
        envelope["payload"] = payload
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: PersistenceError.unrecognizedContent) {
            try ShowSchemaMigration.decodeSchema3(bytes)
        }
    }

    @Test func schema3AlignmentSurvivesMigration() throws {
        let fixture = AlignmentPersistenceFixture()
        let aligned = fixture.show(with: EpisodeAlignment(
            maps: [try fixture.version(1, map: try fixture.map())], acceptedRevision: 1))
        let legacy = ShowSchemaMigration.ShowDocumentModelV3(
            schemaVersion: 3, show: aligned.show, speakers: aligned.speakers,
            episodes: aligned.episodes, history: aligned.history)
        let oldCoder = JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV3>(
            format: ShowSchemaMigration.schema3Format) { _, _ in [] }
        let bytes = try oldCoder.encode(legacy, revision: 1)
        let migrated = try ShowSchemaMigration.decodeSchema3(bytes).payload
        #expect(migrated.episodes[0].alignment == aligned.episodes[0].alignment)
        #expect(migrated.cutAudits == nil)
        #expect(ShowSchemaMigration.schema3ExpectationFailures(original: bytes, migrated: migrated).isEmpty)
        #expect(try coder.decode(coder.encode(migrated, revision: 2)).payload == migrated)
    }

    @Test func schema3NewerEmbeddedMapRefusesAsNewer() throws {
        let withNewerMap = try AlignmentPersistenceTests().showWithNewerMap(nested: false)
        let legacy = ShowSchemaMigration.ShowDocumentModelV3(
            schemaVersion: 3, show: withNewerMap.show, speakers: withNewerMap.speakers,
            episodes: withNewerMap.episodes, history: withNewerMap.history)
        let bytes = try JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV3>(
            format: ShowSchemaMigration.schema3Format) { _, _ in [] }
            .encode(legacy, revision: 1)
        #expect(throws: PersistenceError.unknownNewerSchema(found: 2, supported: 1)) {
            try ShowSchemaMigration.decodeSchema3(bytes)
        }
    }
}
