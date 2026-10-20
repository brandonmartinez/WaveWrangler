import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 5 to filler review schema")
struct ShowSchema5MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:0a67d55f3d1ab15747b4fbddbd34f1b1cc321af7b4b7a6afa5b8688b9ef4694d","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[],"history":{"cursor":0,"entries":[]},"schemaVersion":5,"show":{"id":"00000000-0000-4000-8000-000000000501","notes":"","title":"Schema 5 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000502","revision":8,"schemaVersion":5}"#.utf8)

    @Test func requiresConsentAndBacksUpExactSchema5Bytes() throws {
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 5, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Self.golden)
        }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(Self.golden)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show && upgraded.revision == 8)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: Self.golden, migrated: upgraded.payload).isEmpty)
        let rig = Rig(), url = rig.url()
        let key = DocumentKey.show(upgraded.payload.show.id)
        try Self.golden.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == Self.golden)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url)).payload == upgraded.payload)
    }

    @Test func oldCleanupMigratesWithoutInventingReviewsAndNewReviewsRoundTrip() throws {
        let source = SourceID()
        let transcript = SpeakerTranscript(speaker: SpeakerID(), primary: .init(sourceID: source, statedChannel: 0),
            sourceRate: 16_000, sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
            model: "synthetic", workingRange: nil, words: [
                TranscriptWord(text: "um,", sourceStartFrame: 16_000, sourceEndFrame: 20_000,
                               alignedStart: 1, alignedEnd: 1.25),
            ])
        var old = ShowDocumentModel(schemaVersion: 5, show: Show(title: "Synthetic"), episodes: [
            Episode(title: "Episode", cleanup: EpisodeCleanup(transcripts: [transcript])),
        ])
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
            currentSchemaVersion: 5, minimumReadableSchemaVersion: 5)
        let oldCoder = JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }
        let bytes = try oldCoder.encode(old, revision: 2)
        var migrated = try ShowSchemaMigration.decodeUpgradingOlder(bytes).payload
        #expect(migrated.episodes == old.episodes)
        #expect(migrated.episodes[0].cleanup?.fillerReviews == nil)
        migrated.episodes[0].cleanup = migrated.episodes[0].cleanup?.proposingFillers()
        migrated.episodes[0].cleanup?.fillerReviews?[0].humanBounds = .init(
            sourceStartFrame: 15_840, sourceEndFrame: 20_160, alignedStart: 0.99, alignedEnd: 1.26)
        migrated.episodes[0].cleanup?.fillerReviews?[0].decision = .reviewed
        migrated.episodes[0].cleanup?.fillerReviews?.append(FillerTimingReview(
            origin: .manual, speaker: transcript.speaker, primary: transcript.primary,
            sourceRate: transcript.sourceRate, sourceIdentity: transcript.sourceIdentity, alignmentRevision: 1,
            initialBounds: .init(sourceStartFrame: 32_000, sourceEndFrame: 33_600, alignedStart: 2, alignedEnd: 2.1),
            decision: .rejected))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(coder.encode(migrated, revision: 3)).payload == migrated)
        old.episodes = migrated.episodes
        #expect(throws: PersistenceError.self) {
            try ShowSchemaMigration.decodeSchema5(oldCoder.encode(old, revision: 3))
        }
    }

    @Test func acceptedMapsCorrectionsAndRawCleanupSurviveSchema5MigrationUnchanged() throws {
        let fixture = AlignmentPersistenceFixture()
        var version = try fixture.version(1, map: fixture.map())
        version.sourceCorrections = [SourceTimingCorrection(source: fixture.guest, group: fixture.group,
            epoch: fixture.epoch, reference: fixture.host, sourceRate: 48_000, sourceFrames: 96_000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [.init(sourceStart: 0, sourceEnd: 2, alignedStart: 1, rateRatio: 1.0001)])]
        var old = fixture.show(with: .init(maps: [version], acceptedRevision: 1))
        old.schemaVersion = 5
        old.episodes[0].cleanup = EpisodeCleanup(
            workingRange: .init(alignmentRevision: 1, tracksIn: 0.1, tracksOut: 1.5),
            transcripts: [.init(speaker: SpeakerID(), primary: .init(sourceID: fixture.host, statedChannel: 0),
                sourceRate: 48_000, sourceIdentity: String(repeating: "b", count: 64), alignmentRevision: 1,
                model: "captured-recipe", workingRange: nil, words: [
                    .init(text: " Um, ", sourceStartFrame: 4800, sourceEndFrame: 9600, alignedStart: 0.1, alignedEnd: 0.2),
                ])])
        let format = DocumentFormat(identifier: DocumentFormat.show.identifier, filenameExtension: "wwshow",
            currentSchemaVersion: 5, minimumReadableSchemaVersion: 5)
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>(format: format) { _, _ in [] }.encode(old, revision: 4)
        let migrated = try ShowSchemaMigration.decodeUpgradingOlder(bytes).payload
        #expect(migrated.episodes == old.episodes)
        #expect(migrated.episodes[0].cleanup?.fillerReviews == nil)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: migrated).isEmpty)
    }

    @Test func schema5StillVerifiesItsOriginalCanonicalChecksum() {
        let tampered = Data(String(decoding: Self.golden, as: UTF8.self)
            .replacingOccurrences(of: "Schema 5 golden", with: "Tampered").utf8)
        #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(tampered) }
    }
}
