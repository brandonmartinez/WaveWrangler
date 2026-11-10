import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Schema 10 supplemental audio persistence")
struct ShowSchema9MigrationTests {
    static let golden = Data(#"{"checksum":"sha256:02764283aebffdbfc011d1cbcd0b538990df6a6757cfc11d68ac174c0369606d","format":"com.brandonmartinez.wavewrangler.show","payload":{"episodes":[{"id":"00000000-0000-4000-8000-000000000903","mix":{"inputGains":[],"master":{"gainDB":-2,"inserts":[]},"speakers":[]},"notes":"","recorderGroups":[],"sources":[],"speakerAssignments":[],"status":"planned","title":"Episode"}],"history":{"cursor":0,"entries":[]},"schemaVersion":9,"show":{"id":"00000000-0000-4000-8000-000000000901","notes":"","title":"Schema 9 golden"},"speakers":[]},"publicationID":"00000000-0000-4000-8000-000000000902","revision":11,"schemaVersion":9}"#.utf8)
    static let goldens = ShowSchema8MigrationTests.olderGoldens + [golden]
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    @Test(arguments: 0..<9)
    func schemas1Through9MigrateDirectlyWithExactBackupsAndNeutralAbsence(_ index: Int) throws {
        let bytes = Self.goldens[index], schema = index + 1
        #expect(ShowSchemaMigration.migratableSchemas == Set(1..<SchemaVersion.show))
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: schema, minimum: SchemaVersion.show)) { try coder.decode(bytes) }
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        #expect(upgraded.payload.schemaVersion == SchemaVersion.show)
        #expect(upgraded.payload.episodes.allSatisfy {
            $0.audioArrangement == nil && $0.mix?.audioTracks == nil
                && $0.sources.allSatisfy { $0.purpose == nil && $0.isRecording }
        })
        let failures = schema == 1
            ? ShowSchemaMigration.expectationFailures(original: bytes, migrated: upgraded.payload)
            : ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: upgraded.payload)
        #expect(failures.isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(upgraded.payload.show.id)
        try bytes.write(to: url)
        guard case .needsMigration(schema, _) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Older canonical documents must require migration consent")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == bytes)
        let reopened = try coder.decode(Data(contentsOf: url))
        #expect(reopened.payload == upgraded.payload)
        #expect(reopened.revision == upgraded.revision + 1)
    }

    @Test(arguments: 0..<9)
    func everySupportedOlderRecoveryAndEditCheckpointUpgradesWithoutRewriting(_ index: Int) throws {
        let bytes = Self.goldens[index], schema = index + 1
        let upgraded = try ShowSchemaMigration.decodeUpgradingOlder(bytes)
        let rig = Rig(), key = DocumentKey.show(upgraded.payload.show.id), url = rig.url()
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged synthetic canonical value".utf8).write(to: url)
        guard case let .damaged(_, candidates) = ShowSchemaMigrationTests.opener(rig).open(url, key: key) else {
            Issue.record("Expected an older whole-value recovery offer")
            return
        }
        #expect(candidates.map(\.document.payload) == [upgraded.payload])
        #expect(try rig.recovery.bytes(of: #require(candidates.first).checkpoint) == bytes)
        let record = try rig.recovery.writeEditCheckpoint(snapshot: bytes, base: RevisionFingerprint(of: bytes),
            schemaVersion: schema, for: key, at: Date(timeIntervalSince1970: 1_790_000_000))
        let offers = EditCheckpointOffer.assess(
            [StoredEditCheckpoint(url: rig.url("edit.wwedit"), record: .success(record))],
            documentID: key.rawValue, onDisk: RevisionFingerprint(of: bytes), coder: .show,
            decodeOlder: ShowSchemaMigration.decodeUpgradingOlder,
            belongsToDocument: { $0.show.id == upgraded.payload.show.id })
        #expect(offers.problems.isEmpty)
        #expect(offers.usable.map(\.payload) == [upgraded.payload])
    }

    @Test func schema9UpgradePreservesMapsTranscriptsCutsMixAndHistoryExactly() throws {
        let fixture = AlignmentPersistenceFixture()
        var old = fixture.show(with: .init(maps: [try fixture.version(1, map: fixture.map())], acceptedRevision: 1))
        old.schemaVersion = 9
        old.episodes[0].cleanup = .init(
            transcripts: [.init(speaker: SpeakerID(), primary: .init(sourceID: fixture.host, statedChannel: 0),
                sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
                model: "synthetic", workingRange: nil,
                words: [.init(text: "Preserved words", sourceStartFrame: 0, sourceEndFrame: 24_000,
                              alignedStart: 0, alignedEnd: 0.5)])],
            manualCuts: [.init(alignmentRevision: 1, startFrame: 24_000, endFrame: 48_000)])
        old.episodes[0].mix = .init(master: .init(gainDB: -4))
        old.history = .init(entries: [.init(actionName: "Synthetic prior edit", timestamp: Date(timeIntervalSince1970: 0))])
        let helper = ShowSchema8MigrationTests()
        let bytes = try helper.unchecked(old, schema: 9)
        let upgraded = try ShowSchemaMigration.decodeSchema9(bytes).payload
        var expected = old
        expected.schemaVersion = SchemaVersion.show
        #expect(upgraded == expected)
        #expect(upgraded.hasSameMediaInputs(as: old, in: fixture.episodeID, includingWorkingRange: true))
        #expect(upgraded.hasSameProcessingInputs(as: old, in: fixture.episodeID))
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: bytes, migrated: upgraded).isEmpty)
    }

    @Test(arguments: 1...9)
    func oldSchemasRejectEvenNeutralPurposeArrangementAndTrackMixFields(_ schema: Int) throws {
        let bytes = Self.goldens[schema - 1]
        let helper = ShowSchema8MigrationTests()
        for field in ["purpose", "audioArrangement", "audioTracks"] {
            let changed = try helper.rewritingPayload(bytes) { payload in
                var episodes = payload["episodes"] as? [[String: Any]] ?? []
                if episodes.isEmpty {
                    episodes = [["id": "00000000-0000-4000-8000-000000000999", "title": "Synthetic",
                        "status": "planned", "notes": "", "sources": [], "recorderGroups": [], "speakerAssignments": []]]
                }
                switch field {
                case "purpose":
                    let source = SourceRecord(displayNameHint: "Generated", purpose: .recording)
                    episodes[0]["sources"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))]
                case "audioArrangement":
                    episodes[0]["audioArrangement"] = ["assets": [], "tracks": [], "clips": [], "insertionRegions": []]
                case "audioTracks":
                    episodes[0]["mix"] = ["inputGains": [], "speakers": [], "master": ["gainDB": 0, "inserts": []],
                        "audioTracks": []]
                default: Issue.record("Unknown synthetic new field")
                }
                payload["episodes"] = episodes
            }
            #expect(throws: PersistenceError.self) { try ShowSchemaMigration.decodeUpgradingOlder(changed) }
        }
    }

    func audioShow() throws -> ShowDocumentModel {
        let source = SourceRecord(displayNameHint: "Generated stereo", observations:
            .init(durationSeconds: .known(2), channelCount: .known(2), sampleRate: .known(44_100)),
            purpose: .supplementalAudio)
        let track = AudioTrack(name: "Intro")
        let region = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 96_000)
        let clip = AudioClip(track: track.id, source: source.id,
            trim: .init(startFrame: 0, endFrame: 88_200), channels: [0, 1],
            anchor: .insertion(region: region.id, offsetFrames: 0),
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 24_000, amplitude: 1),
                                   .init(frame: 96_000, amplitude: 0)]))
        let episode = Episode(title: "Audio only", sources: [source],
            mix: .init(audioTracks: [.init(track: track.id, gainDB: -6, balance: 0.25)]),
            audioArrangement: .init(assets: [.init(source: source.id, frameCount: 88_200, sampleRate: 44_100, channelCount: 2)],
                tracks: [track], clips: [clip], insertionRegions: [region]))
        return .init(show: Show(title: "Synthetic"), episodes: [episode])
    }

    @Test func currentShapePublishesAndRecoversWithoutSyntheticRecorderTiming() throws {
        let model = try audioShow(), rig = Rig(), url = rig.url(), key = DocumentKey.show(model.show.id)
        #expect(model.validationIssues().isEmpty)
        #expect(model.episodes[0].alignment == nil && model.episodes[0].recorderGroups.isEmpty)
        let receipt = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let bytes = try Data(contentsOf: url)
        #expect(receipt.publication.revision == 1)
        #expect(try coder.decode(bytes).payload == model)
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"amplitude\":0"))
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged".utf8).write(to: url)
        #expect(ShowSchemaMigrationTests.opener(rig).candidates(url: url, key: key).map(\.document.payload) == [model])
    }

    @Test func persistedFollowAnchorRetainsExactCanonicalBindingAndOriginalRecordingState() throws {
        let fixture = AlignmentPersistenceFixture()
        let original = fixture.show(with: .init(maps: [try fixture.version(1, map: fixture.map())], acceptedRevision: 1))
        let asset = SourceRecord(displayNameHint: "Generated asset", purpose: .supplementalAudio)
        let track = AudioTrack(name: "Audio")
        let anchor = try AudioDialogueAnchor(map: #require(original.episodes[0].alignment?.acceptedMap), frame: 48_000)
        let arrangement = AudioArrangement(
            assets: [.init(source: asset.id, frameCount: 48_000, sampleRate: 48_000, channelCount: 2)],
            tracks: [track], clips: [.init(track: track.id, source: asset.id,
                trim: .init(startFrame: 0, endFrame: 48_000), anchor: .dialogue(anchor))])
        let model = try original.settingAudioState(arrangement, mix: original.episodes[0].mix,
            sources: original.episodes[0].sources + [asset], in: fixture.episodeID)
        let reopened = try coder.decode(coder.encode(model, revision: 1)).payload
        #expect(reopened == model)
        #expect(try anchor.isCurrent(in: reopened.episodes[0]))
        #expect(reopened.episodes[0].alignment == original.episodes[0].alignment)
        #expect(reopened.episodes[0].cleanup == original.episodes[0].cleanup)
        #expect(reopened.hasSameMediaInputs(as: original, in: fixture.episodeID))
    }

    @Test func exactEnvelopeWindowAndFractionPublishAndRecoverInSchema10() throws {
        var model = try audioShow()
        model.episodes[0].audioArrangement?.clips[0].trim.startFrame = 1
        model.episodes[0].audioArrangement?.clips[0].envelope = .init(points: [
            .init(frame: 0, amplitude: 0),
            .init(frame: 11, amplitude: 0.5, fraction: try .init(numerator: 13, denominator: 147)),
            .init(frame: 96_000, amplitude: 0)
        ], window: .init(offset: try .init(numerator: 160, denominator: 147)))
        #expect(model.validationIssues().isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(model.show.id)
        _ = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let bytes = try Data(contentsOf: url)
        #expect(try coder.decode(bytes).payload == model)
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged synthetic canonical value".utf8).write(to: url)
        #expect(ShowSchemaMigrationTests.opener(rig).candidates(url: url, key: key).map(\.document.payload) == [model])
        var invalid = model
        invalid.episodes[0].audioArrangement?.clips[0].envelope.points[1].fraction = try .init(numerator: 4, denominator: 3)
        #expect(throws: PersistenceError.self) { try coder.encode(invalid, revision: 1) }
        #expect(throws: PersistenceError.self) {
            try coder.decode(ShowSchema8MigrationTests().unchecked(invalid, schema: SchemaVersion.show))
        }
    }

    @Test func malformedCurrentAudioCannotBePublishedOrReopenedAndNewerIsRefused() throws {
        let model = try audioShow(), helper = ShowSchema8MigrationTests()
        for damage in ["source", "track", "envelope", "asset", "mix"] {
            var changed = model
            switch damage {
            case "source": changed.episodes[0].audioArrangement?.clips[0].source = SourceID()
            case "track": changed.episodes[0].audioArrangement?.tracks = []
            case "envelope": changed.episodes[0].audioArrangement?.clips[0].envelope.points[1].frame = -1
            case "asset": changed.episodes[0].audioArrangement?.assets[0].frameCount = .max
            case "mix": changed.episodes[0].mix?.audioTracks?[0].balance = 2
            default: Issue.record("Unknown synthetic damage")
            }
            #expect(throws: PersistenceError.self) { try coder.encode(changed, revision: 1) }
            #expect(throws: PersistenceError.self) { try coder.decode(helper.unchecked(changed, schema: SchemaVersion.show)) }
        }
        let version = SchemaVersion.show + 1
        let future = Data("{\"format\":\"com.brandonmartinez.wavewrangler.show\",\"schemaVersion\":\(version),\"payload\":\"future\"}".utf8)
        #expect(throws: PersistenceError.unknownNewerSchema(found: version, supported: SchemaVersion.show)) {
            try ShowSchemaMigration.decodeUpgradingOlder(future)
        }

    }

    @Test func retainedOutputWindowPublishesRecoversAndRejectsInvalidOwnership() throws {
        var model = try audioShow()
        model.episodes[0].audioArrangement?.clips[0].outputWindow = .init(offsetFrames: 2, countFrames: 95_998)
        model.episodes[0].audioArrangement?.clips[0].envelope.window = .init(offset: try .init(numerator: 2))
        #expect(model.validationIssues().isEmpty)
        let rig = Rig(), url = rig.url(), key = DocumentKey.show(model.show.id)
        _ = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let bytes = try Data(contentsOf: url)
        #expect(try coder.decode(bytes).payload == model)
        try rig.recovery.retainCheckpoint(bytes, for: key)
        try Data("damaged synthetic canonical".utf8).write(to: url)
        #expect(ShowSchemaMigrationTests.opener(rig).candidates(url: url, key: key).map(\.document.payload) == [model])
        for window in [
            AudioClipOutputWindow(offsetFrames: -1, countFrames: 1),
            .init(offsetFrames: 0, countFrames: 0), .init(offsetFrames: 95_999, countFrames: 2),
            .init(offsetFrames: .max, countFrames: .max),
        ] {
            var invalid = model
            invalid.episodes[0].audioArrangement?.clips[0].outputWindow = window
            #expect(throws: PersistenceError.self) { try coder.encode(invalid, revision: 1) }
            #expect(throws: PersistenceError.self) {
                try coder.decode(ShowSchema8MigrationTests().unchecked(invalid, schema: SchemaVersion.show))
            }
        }
    }
}
