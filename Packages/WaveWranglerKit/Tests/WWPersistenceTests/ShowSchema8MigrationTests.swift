import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 9 mixer persistence and migration")
struct ShowSchema8MigrationTests {
    /// Frozen schema 8 shape, with a retained inactive cut. Synthetic IDs only.
    static let golden = Data(#"{"checksum":"sha256:08fd6e919584d98135dc1a7af898b8b3baf380325bc6378caf3f84a04c06d200","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[{"cleanup":{"manualCuts":[{"alignmentRevision":1,"endFrame":48000,"id":"00000000-0000-4000-8000-000000000804","startFrame":24000}],"transcripts":[]},"id":"00000000-0000-4000-8000-000000000803","notes":"","recorderGroups":[],"sources":[],"speakerAssignments":[],"status":"planned","title":"Episode"}],"history":{"cursor":0,"entries":[]},"schemaVersion":8,"show":{"id":"00000000-0000-4000-8000-000000000801","notes":"","title":"Schema 8 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000802","revision":10,"schemaVersion":8}"#.utf8)

    static let olderGoldens: [Data] = [
        ShowSchema1Fixtures.mixed, ShowSchema2Fixtures.mixed, ShowSchema3MigrationTests.golden,
        ShowSchema4MigrationTests.golden, ShowSchema5MigrationTests.golden,
        ShowSchema6MigrationTests.golden, ShowSchema7MigrationTests.golden, golden,
    ]

    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    func unchecked(_ model: ShowDocumentModel, schema: Int) throws -> Data {
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
                                    currentSchemaVersion: schema, minimumReadableSchemaVersion: schema)
        return try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(model, revision: 4)
    }

    func rewritingPayload(_ bytes: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var payload = try #require(envelope["payload"] as? [String: Any])
        try change(&payload)
        envelope["payload"] = payload
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        envelope["checksum"] = JSONEnvelopeCoder<ShowDocumentModel>.checksum(of: raw)
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func mixedShow() throws -> ShowDocumentModel {
        let speaker = Speaker(name: "Synthetic speaker")
        let source = SourceRecord(displayNameHint: "Generated recording", observations: .init(channelCount: .known(2)))
        let episode = Episode(title: "Episode", sources: [source],
                              speakerAssignments: [.init(speakerID: speaker.id,
                                  primary: .init(sourceID: source.id, statedChannel: 1))])
        let state = try PropertyListSerialization.data(fromPropertyList:
            ["parameters": ["amount": 0.5], "opaque": Data([1, 0, 255])], format: .binary, options: 0)
        let effect = AudioUnitSlot(component: .init(type: 0x61756678, subtype: 0x74657374, manufacturer: 0x74657374),
                                  bypassed: true, productName: "Unavailable synthetic plug-in", version: "2.3",
                                  documentState: state)
        let mix = EpisodeMixState(inputGains: [.init(source: source.id, channel: 1, gainDB: 12)],
                                 speakers: [.init(speaker: speaker.id, gainDB: -4, pan: 0.25, inserts: [effect])],
                                 master: .init(gainDB: -2))
        let show = ShowDocumentModel(show: Show(title: "Synthetic"), speakers: [speaker], episodes: [episode])
        return try show.settingMix(mix, in: episode.id)
    }

    @Test(arguments: 0..<8)
    func everySupportedOlderSchemaNeedsConsentAndExactByteBackup(_ index: Int) throws {
        let bytes = Self.olderGoldens[index], schema = index + 1
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: schema, minimum: 9)) {
            try coder.decode(bytes)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        #expect(upgraded.payload.schemaVersion == 9)
        #expect(upgraded.payload.episodes.allSatisfy { $0.mix == nil })
        let failures = schema == 1
            ? ShowSchemaMigration.expectationFailures(original: bytes, migrated: upgraded.payload)
            : ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: upgraded.payload)
        #expect(failures.isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try bytes.write(to: url)
        guard case .needsMigration(schema, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("An old show must require consent")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try rig.recovery.migrationBackups(for: key).isEmpty)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == bytes)
        let reopened = try coder.decode(Data(contentsOf: url))
        #expect(reopened.payload == upgraded.payload)
        #expect(reopened.revision == upgraded.revision + 1)
    }

    @Test func schema8MigrationLeavesAcceptedTimingTranscriptsCutsAndHistoryUnchanged() throws {
        let f = AlignmentPersistenceFixture()
        var model = f.show(with: .init(maps: [try f.version(1, map: f.map())], acceptedRevision: 1))
        let transcript = SpeakerTranscript(speaker: SpeakerID(), primary: .init(sourceID: f.host, statedChannel: 0),
            sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
            model: "synthetic", workingRange: nil,
            words: [.init(text: "Original words", sourceStartFrame: 0, sourceEndFrame: 24_000,
                          alignedStart: 0, alignedEnd: 0.5)])
        model.episodes[0].cleanup = .init(workingRange: .init(alignmentRevision: 1, tracksIn: 0, tracksOut: 2),
                                        transcripts: [transcript],
                                        manualCuts: [.init(alignmentRevision: 1, startFrame: 24_000, endFrame: 48_000)])
        model.history = .init(entries: [.init(actionName: "Cut Across Tracks", timestamp: Date(timeIntervalSince1970: 0))])
        model.schemaVersion = 8
        let bytes = try unchecked(model, schema: 8)
        let upgraded = try ShowSchemaMigration.decodeSchema8(bytes).payload
        var expected = model
        expected.schemaVersion = 9
        #expect(upgraded == expected)
        #expect(upgraded.episodes[0].mix == nil)
        #expect(upgraded.episodes[0].activeManualCuts == model.episodes[0].cleanup?.manualCuts)
        #expect(upgraded.hasSameMediaInputs(as: model, in: f.episodeID, includingWorkingRange: true))
        #expect(try coder.decode(coder.encode(upgraded, revision: 5)).payload == upgraded)
        let gained = try upgraded.settingMasterMix(.init(gainDB: -2), in: f.episodeID)
        #expect(gained.episodes[0].alignment == upgraded.episodes[0].alignment)
        #expect(gained.episodes[0].cleanup == upgraded.episodes[0].cleanup)
        #expect(gained.hasSameMediaInputs(as: upgraded, in: f.episodeID, includingWorkingRange: true))
        #expect(!gained.hasSameProcessingInputs(as: upgraded, in: f.episodeID))
        var changedCut = gained
        changedCut.episodes[0].cleanup?.manualCuts = [.init(alignmentRevision: 1, startFrame: 12_000, endFrame: 48_000)]
        #expect(!changedCut.hasSameProcessingInputs(as: gained, in: f.episodeID))
        #expect(changedCut.hasSameMediaInputs(as: gained, in: f.episodeID))
    }

    @Test func canonicalRoundTripAndVerifiedPublicationRetainOpaqueMissingUnitState() throws {
        let model = try mixedShow(), rig = Rig(), url = rig.url()
        let bytes = try coder.encode(model, revision: 1)
        #expect(try coder.decode(bytes).payload == model)
        let receipt = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id),
                                                to: url, target: .newLocation)
        #expect(receipt.publication.revision == 1)
        #expect(try coder.decode(Data(contentsOf: url)).payload == model)
        let reopened = try coder.decode(Data(contentsOf: url)).payload
        #expect(reopened.episodes[0].mix?.speakers[0].inserts[0].documentState
                == model.episodes[0].mix?.speakers[0].inserts[0].documentState)
        #expect(reopened.episodes[0].mix?.speakers[0].inserts[0].bypassed == true)
    }

    @Test(arguments: 3...8)
    func olderSchemasCannotSmuggleEvenNeutralMixState(_ schema: Int) throws {
        var model = Fixtures.show(seed: 464)
        model.schemaVersion = schema
        model.episodes[0].mix = .init()
        let bytes = try unchecked(model, schema: schema)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(bytes) }
        #expect(model.validationIssues(expectedSchemaVersion: schema).contains { $0.code == .invalidMix })
    }

    @Test(arguments: [ShowSchema1Fixtures.mixed, ShowSchema2Fixtures.mixed])
    func schema1And2StrictMirrorsRefuseNewMixKeys(_ bytes: Data) throws {
        let changed = try rewritingPayload(bytes) { payload in
            var episodes = try #require(payload["episodes"] as? [[String: Any]])
            episodes[0]["mix"] = ["inputGains": [], "speakers": [], "master": ["gainDB": 0, "inserts": []]]
            payload["episodes"] = episodes
        }
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(changed) }
    }

    @Test func newerSchemaIsRefusedBeforeDecodingFutureOrCorruptState() {
        let future = Data(#"{"format":"com.brandonmartinez.wavewrangler.show","schemaVersion":10,"payload":"future"}"#.utf8)
        #expect(throws: PersistenceError.unknownNewerSchema(found: 10, supported: 9)) {
            try coder.decode(future)
        }
        #expect(throws: PersistenceError.unknownNewerSchema(found: 10, supported: 9)) {
            try ShowSchemaMigration.decodeUpgradingOlder(future)
        }
    }

    @Test func invalidCanonicalMixCannotBeSavedOrReopened() throws {
        let original = try mixedShow()
        var invalid = original
        invalid.episodes[0].mix?.inputGains[0].channel = 2
        #expect(throws: PersistenceError.self) { try coder.encode(invalid, revision: 2) }
        #expect(throws: PersistenceError.self) { try coder.decode(unchecked(invalid, schema: 9)) }
        invalid = original
        invalid.episodes[0].mix?.speakers[0].inserts[0].documentState = Data([0, 1])
        #expect(throws: PersistenceError.self) { try coder.decode(unchecked(invalid, schema: 9)) }
        invalid = original
        invalid.episodes[0].mix?.master.inserts = original.episodes[0].mix?.speakers[0].inserts ?? []
        #expect(throws: PersistenceError.self) { try coder.decode(unchecked(invalid, schema: 9)) }
        invalid = original
        invalid.episodes[0].mix?.master.gainDB = .nan
        #expect(throws: PersistenceError.self) { try coder.encode(invalid, revision: 2) }
    }

    @Test func malformedIDsBase64UnknownStateKeysAndPayloadDamageAreRefused() throws {
        let model = try mixedShow()
        let bytes = try coder.encode(model, revision: 1)
        for field in ["id", "documentState", "runtimeAvailability"] {
            let damaged = try rewritingPayload(bytes) { payload in
                var episodes = try #require(payload["episodes"] as? [[String: Any]])
                var mix = try #require(episodes[0]["mix"] as? [String: Any])
                var speakers = try #require(mix["speakers"] as? [[String: Any]])
                var inserts = try #require(speakers[0]["inserts"] as? [[String: Any]])
                inserts[0][field] = "invalid"
                speakers[0]["inserts"] = inserts
                mix["speakers"] = speakers
                episodes[0]["mix"] = mix
                payload["episodes"] = episodes
            }
            #expect(throws: PersistenceError.self) { try coder.decode(damaged) }
        }
        var damaged = bytes
        damaged.removeLast(20)
        #expect(throws: PersistenceError.self) { try coder.decode(damaged) }
    }
}
