import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 13 speaker mute regions")
struct ShowSchema12MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:3ed32ddc3980002dea8b4304951537b7c773258057919fc942738e6ed54633c3","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":12,"show":{"id":"00000000-0000-4000-8000-000000001201","notes":"","title":"Schema 12 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000001202","revision":13,"schemaVersion":12}"#.utf8)

    @Test func schema12RequiresConsentAndAnExactBackupWithoutInventingMutes() throws {
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 12, minimum: SchemaVersion.show)) {
            try coder.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try Self.golden.write(to: url)
        guard case .needsMigration(12, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Schema 12 must require explicit migration")
            return
        }
        #expect(try Data(contentsOf: url) == Self.golden)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try coder.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test(arguments: ShowSchema10MigrationTests.goldens + [ShowSchema11MigrationTests.golden, golden])
    func olderDocumentsMigrateWithoutUnrelatedEdits(_ bytes: Data) throws {
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(upgraded.payload.episodes.allSatisfy { $0.cleanup?.speakerMuteRegions == nil })
    }

    @Test func mutesRoundTripAndCannotBeSilentlyOpenedByASchema12Reader() throws {
        let region = SpeakerMuteRegion(speaker: SpeakerID(), alignmentRevision: 1, startFrame: 12, endFrame: 120)
        let episode = Episode(title: "Synthetic", cleanup: .init(speakerMuteRegions: [region]))
        let model = ShowDocumentModel(show: .init(title: "Synthetic"), episodes: [episode])
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(model, revision: 1, publicationID: UUID()).data
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes).payload == model)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeSchema12(bytes) }
        var disguised = model
        disguised.schemaVersion = 12
        let disguisedBytes = try ShowSchema8MigrationTests().unchecked(disguised, schema: 12)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeSchema12(disguisedBytes) }
    }
}
