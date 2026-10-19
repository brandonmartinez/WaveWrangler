import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 3 to source-local timing schema")
struct ShowSchema3MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:72298d835deb70c50f7208b844510425060e4cbb45a58dd962fc921158ed8bad","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":3,"show":{"id":"00000000-0000-4000-8000-000000000301","notes":"","title":"Schema 3 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000302","revision":7,"schemaVersion":3}"#.utf8)

    @Test func previousSchemaRequiresExplicitMigrationAndPreservesItsValue() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 3, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Self.golden)
        }
        let migrated = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(migrated.payload.schemaVersion == SchemaVersion.show)
        #expect(migrated.payload.show.title == "Schema 3 golden")
        #expect(migrated.revision == 7)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: migrated.payload).isEmpty)
        #expect(ShowSchemaMigration.migratableSchemas == [1, 2, 3, 4, 5])
        #expect(ShowSchemaMigration.steps.contains { $0.fromSchema == 3 })
    }

    @Test func schema3WithExistingMapsPreservesThemAndCurrentCorrectionRoundTrips() throws {
        let fixture = AlignmentPersistenceFixture()
        var version = try fixture.version(1, map: fixture.map())
        var old = fixture.show(with: EpisodeAlignment(maps: [version], acceptedRevision: 1))
        old.schemaVersion = 3
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
                                    currentSchemaVersion: 3, minimumReadableSchemaVersion: 3)
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(old, revision: 2)
        let migrated = try ShowSchemaMigration.decodeSchema3(bytes)
        #expect(migrated.payload.episodes[0].alignment == old.episodes[0].alignment)
        version.sourceCorrections = [SourceTimingCorrection(source: fixture.guest, group: fixture.group,
            epoch: fixture.epoch, reference: fixture.host, sourceRate: 48000, sourceFrames: 96000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 2, alignedStart: 1, rateRatio: 1.0001)])]
        let current = fixture.show(with: EpisodeAlignment(maps: [version], acceptedRevision: 1))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(coder.encode(current, revision: 3)).payload == current)
        var mislabeled = current
        mislabeled.schemaVersion = 3
        let mislabeledBytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(mislabeled, revision: 3)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeSchema3(mislabeledBytes) }
    }

    @Test func openerNeverSilentlyUpgradesAndMigrationBacksUpOriginalBytes() throws {
        let rig = Rig()
        let url = rig.url()
        let key = DocumentKey.show(ShowID(UUID(uuidString: "00000000-0000-4000-8000-000000000301")!))
        try Self.golden.write(to: url)
        guard case let .needsMigration(schema, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Schema 3 must require explicit migration")
            return
        }
        #expect(schema == 3)
        #expect(try Data(contentsOf: url) == Self.golden)
        #expect(try rig.recovery.migrationBackups(for: key).isEmpty)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(receipt.publication.revision == 8)
        guard case let .editable(document, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Migrated current schema must be editable")
            return
        }
        #expect(document.payload.schemaVersion == SchemaVersion.show)
    }
}
