import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 14 publication metadata")
struct ShowSchema13MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:241634430ded57c37c8ec4f3f4c37a83c482eb0c08ee51716d1347e03aedfa8c","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":13,"show":{"id":"00000000-0000-4000-8000-000000001301","notes":"Private notes stay private","title":"Schema 13 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000001302","revision":14,"schemaVersion":13}"#.utf8)

    @Test func schema13RequiresConsentExactBackupAndNoInventedPublicationProperties() throws {
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 13, minimum: SchemaVersion.show)) {
            try coder.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.show.publication == nil)
        #expect(upgraded.payload.show.notes == "Private notes stay private")
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try Self.golden.write(to: url)
        guard case .needsMigration(13, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Schema 13 must require explicit migration")
            return
        }
        #expect(try Data(contentsOf: url) == Self.golden)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try coder.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test(arguments: ShowSchema10MigrationTests.goldens + [
        ShowSchema11MigrationTests.golden, ShowSchema12MigrationTests.golden, golden,
    ])
    func everySupportedOlderSchemaMigratesWithoutCopyingNotesOrDatingEpisodes(_ bytes: Data) throws {
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        #expect(upgraded.payload.show.publication == nil)
        #expect(upgraded.payload.episodes.allSatisfy { $0.publication == nil })
        #expect(ShowSchemaMigration.migratableSchemas == Set(1..<SchemaVersion.show))
    }

    @Test func publicationRoundTripsAndOldOrDisguisedReadersRefuseIt() throws {
        let episode = Episode(title: "Synthetic episode", publication: .init(
            metadata: .init(creator: "", publicDescription: "Public episode", artwork: PublicationArtworkSelection.none),
            season: 2, episodeType: .trailer))
        let model = ShowDocumentModel(show: .init(title: "Show", notes: "Private", publication: .init(
            creator: "Artist", publicDescription: "Public show", explicitContent: true)), episodes: [episode])
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let bytes = try coder.encodeDocument(model, revision: 1, publicationID: UUID()).data
        #expect(try coder.decode(bytes).payload == model)
        #expect(throws: PersistenceError.unknownNewerSchema(found: 14, supported: 13)) {
            try ShowSchemaMigration.decodeSchema13(bytes)
        }
        for schema in 1...13 {
            for episodeOnly in [false, true] {
                var disguised = model
                disguised.schemaVersion = schema
                if episodeOnly { disguised.show.publication = nil }
                let disguisedBytes = try ShowSchema8MigrationTests().unchecked(disguised, schema: schema)
                #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(disguisedBytes) }
            }
        }
    }

    @Test func invalidPublicationCannotBePublishedOrDecoded() throws {
        var invalid = ShowDocumentModel.untitled()
        invalid.show.publication = .init(website: "file:///local")
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(throws: PersistenceError.self) {
            try coder.encodeDocument(invalid, revision: 1, publicationID: UUID())
        }
        #expect(throws: PersistenceError.self) {
            try coder.decode(ShowSchema8MigrationTests().unchecked(invalid, schema: SchemaVersion.show))
        }
    }

    @Test func newerArtworkRefusesBeforeUnknownFieldsAndChecksumWithoutOfferingRecovery() throws {
        let model = ShowDocumentModel(show: .init(title: "Synthetic show", publication: .init()))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let encoded = try coder.encodeDocument(model, revision: 1, publicationID: UUID()).data
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        var show = try #require(payload["show"] as? [String: Any])
        show["publication"] = ["artwork": ["image": ["_0": ["schemaVersion": 2, "future": "unknown image shape"]]]]
        payload["show"] = show
        object["payload"] = payload
        let future = try JSONSerialization.data(withJSONObject: object)
        let expected = PersistenceError.unknownNewerSchema(found: 2, supported: 1)
        #expect(throws: expected) { try coder.decode(future) }
        #expect(throws: expected) { try ShowSchemaMigration.decodeUpgradingOlder(future) }
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(model.show.id)
        try future.write(to: url)
        try rig.recovery.retainCheckpoint(encoded, for: key)
        try rig.recovery.recordLocation(url, for: key)
        guard case .refusedNewerFormat(found: 2, supported: 1, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Newer artwork must be refused without a damaged-file recovery path")
            return
        }
        #expect(try Data(contentsOf: url) == future)
    }
}
