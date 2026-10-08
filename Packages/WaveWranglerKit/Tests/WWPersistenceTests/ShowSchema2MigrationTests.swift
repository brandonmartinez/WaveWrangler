import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Show schema 2 → 3 (WW-020, review #182 finding 2): schema 3 adds `Episode.alignment`. A schema 2 show (#175)
/// migrates through the same C5 migrator, backup and C3 order as schema 1; a schema 2 build refuses schema 3 as
/// unknown-newer. Golden schema 2 bytes are frozen (`ShowSchema2Fixtures`). Synthetic fixtures only.
@Suite("Show schema 2 → 3 migration (C5, WW-020)")
struct ShowSchema2MigrationTests {
    typealias Golden = ShowSchemaMigrationTests.Golden
    typealias V1 = ShowSchemaMigrationTests

    /// Each schema 2 golden is the schema 1 golden of the same show migrated once (revision + 1).
    static let goldens = [
        (Golden(name: "placeholderOnly", bytes: ShowSchema2Fixtures.placeholderOnly, showID: ShowID(V1.uuid(1)), revision: 8), ShowSchema1Fixtures.placeholderOnly),
        (Golden(name: "statedChannels", bytes: ShowSchema2Fixtures.statedChannels, showID: ShowID(V1.uuid(2)), revision: 5), ShowSchema1Fixtures.statedChannels),
        (Golden(name: "mixed", bytes: ShowSchema2Fixtures.mixed, showID: ShowID(V1.uuid(3)), revision: 13), ShowSchema1Fixtures.mixed),
    ].map(\.0)

    static func schema1Bytes(_ golden: Golden) -> Data {
        switch golden.name {
        case "placeholderOnly": ShowSchema1Fixtures.placeholderOnly
        case "statedChannels": ShowSchema1Fixtures.statedChannels
        default: ShowSchema1Fixtures.mixed
        }
    }

    static func backupURL(_ rig: Rig, _ golden: Golden) -> URL {
        rig.dir.sub("Recovery").appending(path: "migration-backups/\(golden.key.rawValue)/schema2-\(RevisionFingerprint(of: golden.bytes).shortDigest).wwbackup")
    }

    /// The #175 (schema 2) build's show reader.
    static let schema2Reader = JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV2>(format: ShowSchemaMigration.schema2Format) { payload, schema in
        payload.schemaVersion == schema ? [] : [ValidationIssue(.schemaVersionMismatch, "payload")]
    }

    // MARK: - Golden schema 2 files and the upgrade rule

    @Test(arguments: goldens)
    func goldenFilesAreSchema2AndUpgradeToTheSameShowWithOnlyTheSchemaChanged(_ golden: Golden) throws {
        #expect(RevisionFingerprint(of: golden.bytes).schemaVersion == 2)
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 2, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(golden.bytes)
        }
        let decoded = try ShowSchemaMigration.decodeSchema2(golden.bytes)
        #expect(decoded.revision == golden.revision)
        #expect(decoded.payload.schemaVersion == SchemaVersion.show)
        #expect(decoded.payload.episodes.allSatisfy { $0.alignment == nil })
        #expect(decoded.payload == (try ShowSchemaMigration.decodeSchema1(Self.schema1Bytes(golden)).payload), "the same show as its schema 1 ancestor")
        #expect(try ShowSchemaMigration.decodeUpgradingOlder(golden.bytes).payload == decoded.payload)
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: golden.bytes, migrated: decoded.payload).isEmpty)
        // The #175 reader the goldens stand in for still reads them.
        #expect(try Self.schema2Reader.decode(golden.bytes).revision == golden.revision)
    }

    @Test func schema2ExpectationsAreIndependentAndCatchATamperedMigration() throws {
        let original = ShowSchema2Fixtures.mixed
        let honest = try ShowSchemaMigration.decodeSchema2(original).payload
        #expect(ShowSchemaMigration.schema2ExpectationFailures(original: original, migrated: honest).isEmpty)

        var renamed = honest
        renamed.show.title += " (edited)"
        #expect(!ShowSchemaMigration.schema2ExpectationFailures(original: original, migrated: renamed).isEmpty)

        var withAlignment = honest
        withAlignment.episodes[0].alignment = EpisodeAlignment()
        #expect(!ShowSchemaMigration.schema2ExpectationFailures(original: original, migrated: withAlignment).isEmpty, "migration adds no maps")

        var channelChanged = honest
        channelChanged.episodes[0].speakerAssignments[1].primary = ChannelReference(sourceID: V1.s2, channel: .known(0))
        #expect(!ShowSchemaMigration.schema2ExpectationFailures(original: original, migrated: channelChanged).isEmpty)

        #expect(!ShowSchemaMigration.schema2ExpectationFailures(original: Data("{}".utf8), migrated: honest).isEmpty)
        let unrelated = try ShowSchemaMigration.decodeSchema2(ShowSchema2Fixtures.placeholderOnly).payload
        #expect(!ShowSchemaMigration.schema2ExpectationFailures(original: original, migrated: unrelated).isEmpty)
    }

    /// Schema 2 never had `alignment`: a schema 2 file carrying it is refused (unknown content), not upgraded.
    @Test func aSchema2FileCarryingAlignmentIsRefused() throws {
        // The checksum covers the typed schema 2 payload, which has no `alignment`: the key is unrecognized content.
        var envelope = try #require(try JSONSerialization.jsonObject(with: ShowSchema2Fixtures.mixed) as? [String: Any])
        var payload = try #require(envelope["payload"] as? [String: Any])
        var episodes = try #require(payload["episodes"] as? [[String: Any]])
        episodes[0]["alignment"] = ["maps": [] as [Any]]
        payload["episodes"] = episodes
        envelope["payload"] = payload
        let data = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        #expect(throws: PersistenceError.unrecognizedContent) { try ShowSchemaMigration.decodeSchema2(data) }

        let rig = Rig()
        let url = rig.url()
        try data.write(to: url)
        let key = Self.goldens[2].key
        #expect(throws: PublicationError.self) { try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key) }
        #expect(try Data(contentsOf: url) == data, "never rewritten")
    }

    // MARK: - Opening and migrating

    @Test(arguments: goldens)
    func opensAsNeedsMigrationNeverDamagedAndNeverWrites(_ golden: Golden) throws {
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        guard case let .needsMigration(schema, fingerprint) = V1.opener(rig).open(url, key: golden.key) else {
            Issue.record("expected needsMigration")
            return
        }
        #expect(schema == 2 && fingerprint.byteDigest == RevisionFingerprint(of: golden.bytes).byteDigest)
        #expect(try Data(contentsOf: url) == golden.bytes)
        #expect(try rig.recovery.migrationBackups(for: golden.key).isEmpty, "opening never writes a backup")
        guard case let .viewable(document) = V1.opener(rig).olderShowForViewing(golden.bytes, url: url) else {
            Issue.record("a valid schema 2 file is viewable read-only")
            return
        }
        #expect(document.payload == (try ShowSchemaMigration.decodeSchema2(golden.bytes).payload))
        #expect(try Data(contentsOf: url) == golden.bytes)
    }

    @Test(arguments: goldens)
    func migratesThroughTheUnchangedC3OrderWithABackupOfTheOriginalBytes(_ golden: Golden) throws {
        let hooks = ShowSchemaMigrationTests.RecordingHooks()
        let rig = Rig(hooks: hooks)
        let url = rig.url()
        try golden.bytes.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)

        #expect(hooks.log.withLock { $0 } == PublicationBoundary.migration + PublicationBoundary.show.dropLast())
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
        #expect(receipt.backup == Self.backupURL(rig, golden))
        #expect(receipt.publication.revision == golden.revision + 1)
        #expect(receipt.publication.priorCheckpoint == nil)

        #expect(RevisionFingerprint(of: try Data(contentsOf: url)).schemaVersion == SchemaVersion.show)
        guard case let .editable(document, fingerprint) = V1.opener(rig).open(url, key: golden.key) else {
            Issue.record("migrated show is not editable")
            return
        }
        #expect(fingerprint == receipt.publication.fingerprint)
        #expect(document.revision == golden.revision + 1)
        #expect(document.payload == (try ShowSchemaMigration.decodeSchema2(golden.bytes).payload))

        // Idempotent: the current show is never migrated again and the backup is untouched.
        #expect(throws: PublicationError.self) { try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key) }
        #expect(V1.paths(try rig.recovery.migrationBackups(for: golden.key)) == V1.paths([receipt.backup]))
    }

    @Test(arguments: ShowSchemaMigrationTests.goldens)
    func aSchema1ShowMigratesStraightToCurrentSchema(_ golden: Golden) throws {
        let hooks = ShowSchemaMigrationTests.RecordingHooks()
        let rig = Rig(hooks: hooks)
        let url = rig.url()
        try golden.bytes.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        #expect(hooks.log.withLock { $0 } == PublicationBoundary.migration + PublicationBoundary.show.dropLast(), "one publication, no intermediate schema 2 revision")
        #expect(receipt.publication.revision == golden.revision + 1)
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
        #expect(receipt.backup.lastPathComponent.hasPrefix("schema1-"))
        let published = try Data(contentsOf: url)
        #expect(RevisionFingerprint(of: published).schemaVersion == SchemaVersion.show)
        let document = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(published)
        #expect(document.payload == (try ShowSchemaMigration.decodeSchema1(golden.bytes).payload))
    }

    @Test func aMigrationThatBreaksItsSchema2ExpectationsPublishesNothing() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let real = try #require(ShowSchemaMigration.steps.first { $0.fromSchema == 2 })
        let tampered = MigrationStep<ShowDocumentModel>(fromSchema: 2, migrate: { data in
            var (model, revision) = try real.migrate(data)
            model.show.title += " (edited)"
            return (model, revision)
        }, expectations: real.expectations)
        #expect(throws: PublicationError.self) { try DocumentMigrator(publisher: rig.publisher, steps: [tampered]).migrate(url, key: golden.key) }
        #expect(try Data(contentsOf: url) == golden.bytes)
        #expect(try rig.recovery.migrationBackups(for: golden.key).map { try Data(contentsOf: $0) } == [golden.bytes])
    }

    @Test func migrationRefusesADifferentShowBeforeAnyBackupOrWrite() throws {
        let golden = Self.goldens[0]
        let hooks = ShowSchemaMigrationTests.RecordingHooks()
        let rig = Rig(hooks: hooks)
        let url = rig.url()
        try golden.bytes.write(to: url)
        let other = DocumentKey.show(ShowSchemaMigrationTests.otherShow)
        #expect(throws: PublicationError.invalidCandidate(.identityMismatch(expected: other.rawValue, found: golden.key.rawValue))) {
            try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: other)
        }
        #expect(try Data(contentsOf: url) == golden.bytes)
        #expect(try ShowSchemaMigrationTests.tree(rig.dir.sub("Recovery")).isEmpty)
        #expect(hooks.log.withLock { $0 }.isEmpty)
    }

    /// C5 fault matrix on the 2 → 3 step: every boundary leaves the schema 2 original or the migrated revision.
    @Test(arguments: PublicationBoundary.migration + PublicationBoundary.show.dropLast())
    func everyFaultLeavesTheOriginalOrTheMigratedRevision(_ boundary: PublicationBoundary) throws {
        let golden = Self.goldens[2]
        try ShowSchemaMigrationTests.faultMatrix(boundary, golden: golden, fromSchema: 2,
                                                 expected: try ShowSchemaMigration.decodeSchema2(golden.bytes).payload)
    }

    // MARK: - The #175 (schema 2) build refuses schema 3 as unknown-newer

    @Test func aSchema2BuildRefusesASchema3ShowAsUnknownNewer() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        _ = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        let migrated = try Data(contentsOf: url)

        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show, supported: 2)) { try Self.schema2Reader.decode(migrated) }
        guard case .refusedNewerFormat(found: SchemaVersion.show, supported: 2, _) = DocumentOpener(coder: Self.schema2Reader, recovery: rig.recovery).open(url) else {
            Issue.record("a schema 2 build must refuse schema 3 as unknown-newer, never as damaged")
            return
        }
        // A schema 3 show *with maps* is refused the same way (the schema check precedes the payload).
        let fixture = AlignmentPersistenceFixture()
        let withMaps = try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(
            fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: try fixture.map())], acceptedRevision: 1)), revision: 1)
        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show, supported: 2)) { try Self.schema2Reader.decode(withMaps) }

        let record = try rig.recovery.writeEditCheckpoint(snapshot: migrated, base: nil, schemaVersion: SchemaVersion.show, for: golden.key,
                                                          at: Date(timeIntervalSince1970: 1_790_000_000))
        let offer = EditCheckpointOffer.assess([StoredEditCheckpoint(url: url, record: .success(record))], documentID: golden.key.rawValue,
                                               onDisk: nil, coder: Self.schema2Reader, belongsToDocument: { _ in true })
        #expect(offer.usable.isEmpty)
        #expect(offer.problems == [.newerFormat(url, found: SchemaVersion.show, supported: 2)])
    }

    // MARK: - Recovery records written before the format change

    @Test func schema2RecoveryCheckpointsStayOfferableUpgradedInMemory() throws {
        let golden = Self.goldens[1]
        let rig = Rig()
        let url = rig.url()
        try rig.recovery.retainCheckpoint(golden.bytes, for: golden.key)
        try Data("not a show".utf8).write(to: url)
        guard case let .damaged(_, candidates) = V1.opener(rig).open(url, key: golden.key) else {
            Issue.record("expected damaged with candidates")
            return
        }
        #expect(candidates.map(\.document.payload) == [try ShowSchemaMigration.decodeSchema2(golden.bytes).payload])
        #expect(candidates.first?.document.revision == golden.revision)
        #expect(try rig.recovery.bytes(of: try #require(candidates.first).checkpoint) == golden.bytes, "the checkpoint is not rewritten")
    }

    @Test func aDamagedSchema2FileStillOffersItsRecoveredCopyWhenOpenedForViewing() throws {
        let golden = Self.goldens[0]
        let rig = Rig()
        let url = rig.url()
        let damaged = try ShowSchemaMigrationTests.checksumDamaged(golden)
        try damaged.write(to: url)
        try rig.recovery.retainCheckpoint(golden.bytes, for: golden.key)
        try rig.recovery.recordLocation(url, for: golden.key)
        let opener = V1.opener(rig)
        guard case .needsMigration(2, _) = opener.outcome(for: damaged, url: url) else {
            Issue.record("a schema 2 file is classified by schema before its checksum")
            return
        }
        guard case let .damaged(error, candidates) = opener.olderShowForViewing(damaged, url: url) else {
            Issue.record("a checksum-damaged schema 2 file must not be viewable")
            return
        }
        #expect(error == .checksumMismatch)
        #expect(candidates.map(\.document.payload) == [try ShowSchemaMigration.decodeSchema2(golden.bytes).payload])
        #expect(try Data(contentsOf: url) == damaged)
    }
}
