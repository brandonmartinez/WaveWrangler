import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 11 episode production boundaries")
struct ShowSchema10MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:b714b6fa0d7a8ffaa594a8244240003fe7cf199a8ba7558485ed5607f057f2a3","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[{"id":"00000000-0000-4000-8000-000000001003","mix":{"inputGains":[],"master":{"gainDB":-2,"inserts":[]},"speakers":[]},"notes":"","recorderGroups":[],"sources":[],"speakerAssignments":[],"status":"planned","title":"Episode"}],"history":{"cursor":0,"entries":[]},"schemaVersion":10,"show":{"id":"00000000-0000-4000-8000-000000001001","notes":"","title":"Schema 10 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000001002","revision":12,"schemaVersion":10}"#.utf8)
    static let goldens = ShowSchema9MigrationTests.goldens + [golden]
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    @Test(arguments: 0..<10)
    func allOlderSchemasRequireConsentAndPreserveExactBackups(_ index: Int) throws {
        let bytes = Self.goldens[index]
        #expect(ShowSchemaMigration.migratableSchemas == Set(1..<SchemaVersion.show))
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: index + 1, minimum: SchemaVersion.show)) {
            try coder.decode(bytes)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(upgraded.payload.episodes.allSatisfy { $0.productionRange == nil })
        let failures = index == 0
            ? ShowSchemaMigration.expectationFailures(original: bytes, migrated: upgraded.payload)
            : ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: upgraded.payload)
        #expect(failures.isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try bytes.write(to: url)
        guard case .needsMigration(index + 1, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Old documents require explicit migration")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == bytes)
        #expect(try coder.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test func schema10PreservesCompleteArrangementAndRecoveryCheckpoint() throws {
        var old = try ShowSchema9MigrationTests().audioShow()
        old.schemaVersion = 10
        let bytes = try ShowSchema8MigrationTests().unchecked(old, schema: 10)
        let upgraded = try ShowSchemaMigration.decodeSchema10(bytes)
        var expected = old
        expected.schemaVersion = SchemaVersion.show
        #expect(upgraded.payload == expected)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: expected).isEmpty)
        let rig = Rig(), key = DocumentKey.show(old.show.id), url = rig.url()
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged synthetic canonical value".utf8).write(to: url)
        #expect(ShowSchemaMigrationTests.opener(rig).candidates(url: url, key: key).map(\.document.payload) == [expected])
        let record = try rig.recovery.writeEditCheckpoint(snapshot: bytes, base: RevisionFingerprint(of: bytes),
            schemaVersion: 10, for: key, at: Date(timeIntervalSince1970: 1_790_000_000))
        let offers = EditCheckpointOffer.assess(
            [.init(url: rig.url("edit.wwedit"), record: .success(record))],
            documentID: key.rawValue, onDisk: RevisionFingerprint(of: bytes), coder: .show,
            decodeOlder: ShowSchemaMigration.decodeUpgradingOlder,
            belongsToDocument: { $0.show.id == old.show.id })
        #expect(offers.problems.isEmpty)
        #expect(offers.usable.map(\.payload) == [expected])
    }

    @Test(arguments: 0..<10)
    func olderSchemasRejectEvenNeutralBoundaryState(_ index: Int) throws {
        let helper = ShowSchema8MigrationTests()
        let changed = try helper.rewritingPayload(Self.goldens[index]) { payload in
            var episodes = payload["episodes"] as? [[String: Any]] ?? []
            if episodes.isEmpty {
                episodes = [["id": "00000000-0000-4000-8000-000000001099", "title": "Synthetic",
                    "status": "planned", "notes": "", "sources": [], "recorderGroups": [], "speakerAssignments": []]]
            }
            episodes[0]["productionRange"] = ["restrictSpeech": false]
            payload["episodes"] = episodes
        }
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(changed) }
    }

    @Test func newBoundaryStatePublishesRecoversAndInvalidatesOnlyProgramInputs() throws {
        let original = try ShowSchema9MigrationTests().audioShow(), episode = original.episodes[0]
        let range = EpisodeProductionRange(start: .absolute(frame: -48_000),
                                           end: .programOrigin(frame: 144_000), restrictSpeech: true)
        let changed = try original.settingProductionRange(range, in: episode.id)
        #expect(changed.hasSameMediaInputs(as: original, in: episode.id, includingWorkingRange: true))
        #expect(!EpisodeProcessingInputs(changed.episodes[0]).hasSameProgramInputs(as: .init(episode)))
        #expect(!changed.hasSameProcessingInputs(as: original, in: episode.id))
        #expect(changed.episodes[0].sources == original.episodes[0].sources)
        #expect(changed.episodes[0].audioArrangement == original.episodes[0].audioArrangement)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(changed.show.id)
        _ = try rig.publisher.publish(changed, revision: 1, key: key, to: url, target: .newLocation)
        let bytes = try Data(contentsOf: url)
        #expect(try coder.decode(bytes).payload == changed)
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged".utf8).write(to: url)
        #expect(ShowSchemaMigrationTests.opener(rig).candidates(url: url, key: key).map(\.document.payload) == [changed])
        #expect(try changed.settingProductionRange(.init(), in: episode.id) == original)
    }

    @Test func invalidAnchorsAreRejectedBeforePublication() throws {
        let original = try ShowSchema9MigrationTests().audioShow(), id = original.episodes[0].id
        for anchor in [
            AudioPlacementAnchor.absolute(frame: .max),
            .insertion(region: AudioInsertionRegionID(), offsetFrames: 0),
        ] {
            #expect(throws: DomainError.self) {
                try original.settingProductionRange(.init(start: anchor), in: id)
            }
        }
        #expect(throws: DomainError.self) {
            try original.settingProductionRange(.init(start: .absolute(frame: 48_000),
                                                       end: .absolute(frame: 0)), in: id)
        }
        let missing = EpisodeID()
        #expect(throws: DomainError.episodeNotFound(missing)) {
            try original.settingProductionRange(nil, in: missing)
        }
    }
}
