import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 6 to portable workspace schema")
struct ShowSchema6MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:584110040c3ebbc50af565b51d0b8a39b307c65573c2790faf093c52d474a4c7","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":6,"show":{"id":"00000000-0000-4000-8000-000000000601","notes":"","title":"Schema 6 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000602","revision":9,"schemaVersion":6}"#.utf8)

    @Test func migrationRequiresConsentPreservesEveryOldValueAndBacksUpExactBytes() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 6, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(upgraded.payload.show.profile == nil)
        #expect(upgraded.revision == 9)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url()
        try Self.golden.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: .show(upgraded.payload.show.id))
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test func appearanceOwnedImagesDefinitionsAndPreferencesSurviveCanonicalReopen() throws {
        let host = Speaker(name: "Host")
        let episode = Episode(title: "Episode", speakerAssignments: [SpeakerAssignment(speakerID: host.id)])
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGIoAAAAASUVORK5CYII="))
        var show = ShowDocumentModel(show: Show(title: "Portable"), speakers: [host], episodes: [episode])
        show = try show.settingHost(host.id, isHost: true)
            .settingSpeakerAppearance(.init(color: .blue, avatarPNG: png), for: host.id)
            .settingSpeakerAppearance(.init(color: .purple, avatarPNG: png), for: host.id, in: episode.id)
            .settingEditingPlaybackPolicy(.soloPrimaries, in: episode.id)
        let group = RecorderGroup(name: "Laptop", epochs: [RecordingEpoch(label: "1")], icon: .computer)
        show = try show.addingRecorderGroup(group, to: episode.id)
            .savingRecorderDefinition(from: group.id, in: episode.id)
            .settingPositionLock(true, group: group.id, in: episode.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let reopened = try coder.decode(coder.encode(show, revision: 2)).payload
        #expect(reopened == show)
        #expect(reopened.speakerAppearance(host.id, in: episode.id)?.avatarPNG == png)
        #expect(reopened.episodes[0].workspace?.editingPlaybackPolicy == .soloPrimaries)
        #expect(reopened.episodes[0].positionIsLocked(group.id))
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6]) func olderSchemaCannotCarryWorkspaceFields(_ schema: Int) throws {
        let host = Speaker(name: "Host", appearance: SpeakerAppearance(color: .teal))
        let mislabeled = ShowDocumentModel(schemaVersion: schema, show: Show(title: "Mislabeled"), speakers: [host])
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
            currentSchemaVersion: schema, minimumReadableSchemaVersion: schema)
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(mislabeled, revision: 1)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(bytes) }
    }
}
