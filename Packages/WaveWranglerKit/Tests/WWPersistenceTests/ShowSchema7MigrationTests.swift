import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 7 to manual cut schema")
struct ShowSchema7MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:ff56b9be06d505860b4bfbaa7c5948ee5415bba41fbc438e56bd6f04a0c13275","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":7,"show":{"id":"00000000-0000-4000-8000-000000000701","notes":"","title":"Schema 7 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000702","revision":9,"schemaVersion":7}"#.utf8)

    @Test func migrationRequiresConsentAndPreservesExactOriginalBytes() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 7, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show && upgraded.revision == 9)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url()
        try Self.golden.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: .show(upgraded.payload.show.id))
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test func savedCutKeepsItsOriginAndOlderSchemasRefuseIt() throws {
        let fixture = AlignmentPersistenceFixture()
        var model = fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: fixture.map())], acceptedRevision: 1))
        let cut = ManualEpisodeCut(markerID: UUID(), alignmentRevision: 1, startFrame: 24_000, endFrame: 48_000)
        model.episodes[0].cleanup = EpisodeCleanup(manualCuts: [cut])
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let reopened = try coder.decode(coder.encode(model, revision: 2)).payload
        #expect(reopened == model)
        #expect(reopened.episodes[0].activeManualCuts == [cut])
        var stale = reopened.episodes[0]
        stale.alignment?.acceptedRevision = nil
        #expect(stale.activeManualCuts.isEmpty && stale.cleanup?.manualCuts == [cut])
        for schema in 3...7 {
            model.schemaVersion = schema
            let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
                currentSchemaVersion: schema, minimumReadableSchemaVersion: schema)
            let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(model, revision: 1)
            #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(bytes) }
        }
    }
}
