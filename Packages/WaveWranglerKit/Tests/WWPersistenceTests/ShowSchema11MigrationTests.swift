import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 12 positioned inserts")
struct ShowSchema11MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:add86fc9a6a178060b1898eb697e8ff6ca16a91acc6cb9d6dc324e261ecd7572","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":11,"show":{"id":"00000000-0000-4000-8000-000000001101","notes":"","title":"Schema 11 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000001102","revision":12,"schemaVersion":11}"#.utf8)

    @Test func schema11RequiresConsentAndExactBackup() throws {
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 11, minimum: SchemaVersion.show)) {
            try coder.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try Self.golden.write(to: url)
        guard case .needsMigration(11, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Schema 11 requires explicit migration")
            return
        }
        #expect(try Data(contentsOf: url) == Self.golden)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try coder.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test func legacyEffectsRetainBytesOrderAndConsecutiveRows() throws {
        var old = try ShowSchema9MigrationTests().audioShow()
        old.schemaVersion = 11
        let bytes = try ShowSchema8MigrationTests().unchecked(old, schema: 11)
        let upgraded = try ShowSchemaMigration.decodeSchema11(bytes)
        var expected = old
        expected.schemaVersion = SchemaVersion.show
        #expect(upgraded.payload == expected)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: expected).isEmpty)
    }

    @Test func positionedInsertsRoundTripAndOlderSchemasRejectThem() throws {
        let f = EpisodeMixTestsFixture()
        var slot = AudioUnitSlot(component: .init(type: 0x61756678, subtype: 1, manufacturer: 1), rackPosition: 3)
        slot.bypassed = true
        let changed = try f.model.settingMasterMix(.init(inserts: [slot]), in: f.episode.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let encoded = try coder.encodeDocument(changed, revision: 1, publicationID: UUID())
        #expect(try coder.decode(encoded.data).payload == changed)
        var old = changed
        old.schemaVersion = 11
        let oldBytes = try ShowSchema8MigrationTests().unchecked(old, schema: 11)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeSchema11(oldBytes) }
    }

    private struct EpisodeMixTestsFixture {
        let episode = Episode(title: "Synthetic")
        var model: ShowDocumentModel { .init(show: .init(title: "Synthetic"), episodes: [episode]) }
    }
}
