import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 4 to cleanup schema")
struct ShowSchema4MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:0d2778357123b3083227cb2d4beda89d781bf20a74b920dd3bb0589b8cb5bfae","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":4,"show":{"id":"00000000-0000-4000-8000-000000000401","notes":"","title":"Schema 4 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000402","revision":7,"schemaVersion":4}"#.utf8)

    @Test func oldDocumentsRequireConsentAndPreserveEveryValue() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 4, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(upgraded.revision == 7)
        #expect(upgraded.payload.show.title == "Schema 4 golden")
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        #expect(ShowSchemaMigration.steps.map(\.fromSchema) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func markersAndSourceBoundTextRoundTripAndCannotBeMislabeledAsSchema4() throws {
        let fixture = AlignmentPersistenceFixture()
        var model = fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: fixture.map())], acceptedRevision: 1))
        let transcript = SpeakerTranscript(speaker: SpeakerID(),
            primary: ChannelReference(sourceID: fixture.host, statedChannel: 0), sourceRate: 48_000,
            sourceIdentity: String(repeating: "b", count: 64), alignmentRevision: 1,
            model: "test-engine", workingRange: nil, words: [
                TranscriptWord(text: "um", sourceStartFrame: 4800, sourceEndFrame: 9600, alignedStart: 0.1, alignedEnd: 0.2),
            ])
        model.episodes[0].cleanup = EpisodeCleanup(workingRange:
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 0.1, tracksOut: 1.5), transcripts: [transcript])
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(coder.encode(model, revision: 2)).payload == model)
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
            currentSchemaVersion: 4, minimumReadableSchemaVersion: 4)
        model.schemaVersion = 4
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(model, revision: 2)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeSchema4(bytes) }
    }

    @Test func migrationBacksUpExactSchema4Bytes() throws {
        let rig = Rig(), url = rig.url()
        let key = DocumentKey.show(ShowID(UUID(uuidString: "00000000-0000-4000-8000-000000000401")!))
        try Self.golden.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url)).payload.schemaVersion == SchemaVersion.show)
    }

    @Test func existingFileLocalCorrectionsSurviveMigrationUnchanged() throws {
        let f = AlignmentPersistenceFixture()
        var version = try f.version(1, map: f.map())
        version.sourceCorrections = [SourceTimingCorrection(source: f.guest, group: f.group,
            epoch: f.epoch, reference: f.host, sourceRate: 48000, sourceFrames: 96000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 2, alignedStart: 1, rateRatio: 1.0001)])]
        var old = f.show(with: EpisodeAlignment(maps: [version], acceptedRevision: 1))
        old.schemaVersion = 4
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
            currentSchemaVersion: 4, minimumReadableSchemaVersion: 4)
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(old, revision: 3)
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes).payload
        #expect(upgraded.episodes[0].alignment == old.episodes[0].alignment)
        #expect(upgraded.episodes[0].cleanup == nil)
        #expect(upgraded.schemaVersion == SchemaVersion.show)
    }
}
