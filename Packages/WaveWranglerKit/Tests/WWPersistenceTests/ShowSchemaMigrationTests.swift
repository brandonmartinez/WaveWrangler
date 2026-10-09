import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

/// Show schema 1 → current (WW-009 C5, issue #63): explicit stated-channel references, migrated from golden
/// schema 1 files through the unchanged C3 publication order, straight to the current schema (3 since WW-020; the
/// 2 → 3 step is covered by `ShowSchema2MigrationTests`). Synthetic fixtures only; deterministic (no wall clock).
@Suite("Show schema 1 → current migration (C5, #63)")
struct ShowSchemaMigrationTests {
    // MARK: - Fixture identifiers (see ShowSchema1Fixtures)

    static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    static let ana = SpeakerID(uuid(20)), ben = SpeakerID(uuid(21)), cy = SpeakerID(uuid(22))
    static let s1 = SourceID(uuid(30)), s2 = SourceID(uuid(31)), s3 = SourceID(uuid(32))
    static let ep1 = EpisodeID(uuid(10)), ep2 = EpisodeID(uuid(11))

    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: Data
        let showID: ShowID
        let revision: Int
        var testDescription: String { name }
        var key: DocumentKey { .show(showID) }
    }

    static let goldens = [
        Golden(name: "placeholderOnly", bytes: ShowSchema1Fixtures.placeholderOnly, showID: ShowID(uuid(1)), revision: 7),
        Golden(name: "statedChannels", bytes: ShowSchema1Fixtures.statedChannels, showID: ShowID(uuid(2)), revision: 4),
        Golden(name: "mixed", bytes: ShowSchema1Fixtures.mixed, showID: ShowID(uuid(3)), revision: 12),
    ]

    static func ref(_ source: SourceID, _ channel: Knowledge<Int>) -> ChannelReference {
        ChannelReference(sourceID: source, channel: channel)
    }

    static func assignment(_ model: ShowDocumentModel, _ episode: EpisodeID, _ speaker: SpeakerID) throws -> SpeakerAssignment {
        try #require(model.episode(episode)?.assignment(for: speaker))
    }

    static func allReferences(_ model: ShowDocumentModel) -> [ChannelReference] {
        model.episodes.flatMap(\.speakerAssignments).flatMap { [$0.primary].compactMap { $0 } + $0.backups }
    }

    /// A show opener as the app builds it (schema 1 migratable, schema 1 recovery records upgraded read-only).
    static func opener(_ rig: Rig, ops: any FileOperations = LocalFileOperations()) -> DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>> {
        .show(ops: ops, recovery: rig.recovery)
    }

    /// Recovery listings and constructed URLs differ only in form (e.g. /var vs /private/var); compare paths.
    static func paths(_ urls: [URL]) -> Set<String> { Set(urls.map { $0.resolvingSymlinksInPath().path }) }

    static func backupURL(_ rig: Rig, _ golden: Golden) -> URL {
        rig.dir.sub("Recovery").appending(path: "migration-backups/\(golden.key.rawValue)/schema1-\(RevisionFingerprint(of: golden.bytes).shortDigest).wwbackup")
    }

    @Test func formatUpdateRefusesByteIdenticalReplacementOfTheOpenedItem() throws {
        let golden = Self.goldens[0]
        let rig = Rig()
        let url = rig.url()
        let moved = rig.url("Moved-original.wwshow")
        try golden.bytes.write(to: url)
        let openedItem = try #require(FileItemIdentity.observe(at: url))
        let migrator = DocumentMigrator.show(publisher: rig.publisher)
        try FileManager.default.moveItem(at: url, to: moved)
        try golden.bytes.write(to: url)
        let replacement = try Data(contentsOf: url)
        #expect(FileItemIdentity.observe(at: url) != openedItem)
        #expect(throws: PublicationError.self) {
            _ = try migrator.migrate(url, key: golden.key, originatingItem: openedItem)
        }
        #expect(try Data(contentsOf: moved) == golden.bytes)
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test func migrationReceiptRejectsByteIdenticalReplacementBeforeAdoption() throws {
        let golden = Self.goldens[0]
        let rig = Rig()
        let url = rig.url()
        let moved = rig.url("Migrated-original.wwshow")
        try golden.bytes.write(to: url)
        let openedItem = try #require(FileItemIdentity.observe(at: url))
        let receipt = try DocumentMigrator.show(publisher: rig.publisher)
            .migrate(url, key: golden.key, originatingItem: openedItem)
        let published = try Data(contentsOf: url)
        let verifiedItem = try #require(receipt.publication.itemIdentity)
        #expect(FileItemIdentity.observe(at: url) == verifiedItem)
        try FileManager.default.moveItem(at: url, to: moved)
        try published.write(to: url)
        #expect(try Data(contentsOf: url) == published)
        #expect(FileItemIdentity.observe(at: url) != verifiedItem,
                "matching publication bytes alone cannot authorize adoption of a new physical item")
        #expect(try Data(contentsOf: moved) == published)
    }

    // MARK: - Golden schema 1 files and the upgrade rule

    @Test(arguments: goldens)
    func goldenFilesAreSchema1AndRefusedByTheCurrentReader(_ golden: Golden) throws {
        #expect(RevisionFingerprint(of: golden.bytes).schemaVersion == 1)
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 1, minimum: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(golden.bytes)
        }
        let decoded = try ShowSchemaMigration.decodeSchema1(golden.bytes)
        #expect(decoded.revision == golden.revision)
        #expect(decoded.payload.schemaVersion == SchemaVersion.show)
        #expect(decoded.payload.show.id == golden.showID)
        #expect(decoded.payload.validationIssues().isEmpty)
        #expect(ShowSchemaMigration.expectationFailures(original: golden.bytes, migrated: decoded.payload).isEmpty)
    }

    @Test func withoutStatedChannelsTheIndexZeroPlaceholderBecomesUnknown() throws {
        let model = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.placeholderOnly).payload
        #expect(try Self.assignment(model, Self.ep1, Self.ana).primary == Self.ref(Self.s1, .unknown))
        #expect(try Self.assignment(model, Self.ep1, Self.ben).backups == [Self.ref(Self.s2, .unknown)])
        #expect(!Self.allReferences(model).contains { $0.channel == .known(0) }, "no placeholder survives as channel 0")
        #expect(model.episodes.flatMap(\.sources).allSatisfy { $0.placement.channelLabels.isEmpty }, "nothing is stated by migration")
    }

    @Test func userStatedChannelsAreKeptIncludingAStatedChannelZero() throws {
        let model = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.statedChannels).payload
        #expect(try Self.assignment(model, Self.ep1, Self.ana).primary == Self.ref(Self.s1, .known(1)))
        #expect(try Self.assignment(model, Self.ep1, Self.ben).primary == Self.ref(Self.s2, .known(0)), "stated channel 0 stays known")
        #expect(model.episode(Self.ep1)?.statedChannel(of: Self.s1) == 1)
        #expect(model.episode(Self.ep1)?.statedChannel(of: Self.s2) == 0)
    }

    @Test func mixedFileFollowsTheRuleAndChangesNothingElse() throws {
        let v1 = try JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV1>(format: ShowSchemaMigration.schema1Format) { _, _ in [] }
            .decode(ShowSchema1Fixtures.mixed).payload
        let model = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.mixed).payload
        let ana = try Self.assignment(model, Self.ep1, Self.ana)
        #expect(ana.primary == Self.ref(Self.s1, .known(2)), "stated index 2")
        #expect(ana.backups == [Self.ref(Self.s2, .unknown)], "unstated index 0 placeholder")
        let ben = try Self.assignment(model, Self.ep1, Self.ben)
        #expect(ben.primary == Self.ref(Self.s2, .unknown))
        #expect(ben.backups == [Self.ref(Self.s3, .known(3))], "an explicit nonzero index is kept as written")
        let cy = try Self.assignment(model, Self.ep1, Self.cy)
        #expect(cy.primary == nil && cy.backups.isEmpty)
        #expect(model.episode(Self.ep2)?.speakerAssignments.map(\.speakerID) == [Self.cy])

        // Everything except channel references is carried over unchanged.
        #expect(model.show == v1.show && model.speakers == v1.speakers && model.history == v1.history)
        #expect(model.episodes.map(\.id) == v1.episodes.map(\.id))
        #expect(model.episodes.map(\.sources) == v1.episodes.map(\.sources))
        #expect(model.episodes.map(\.recorderGroups) == v1.episodes.map(\.recorderGroups))
        #expect(model.episodes.map(\.title) == v1.episodes.map(\.title))
        #expect(model.episodes.map { $0.speakerAssignments.map(\.primaryConfirmation) } == v1.episodes.map { $0.speakerAssignments.map(\.primaryConfirmation) })
        #expect(model.episodes.map { $0.speakerAssignments.map(\.backups.count) } == v1.episodes.map { $0.speakerAssignments.map(\.backups.count) })
    }

    @Test func expectationsAreIndependentAndCatchATamperedMigration() throws {
        let original = ShowSchema1Fixtures.mixed
        let honest = try ShowSchemaMigration.decodeSchema1(original).payload
        #expect(ShowSchemaMigration.expectationFailures(original: original, migrated: honest).isEmpty)

        var placeholderAsZero = honest
        placeholderAsZero.episodes[0].speakerAssignments[1].primary = Self.ref(Self.s2, .known(0))
        #expect(!ShowSchemaMigration.expectationFailures(original: original, migrated: placeholderAsZero).isEmpty)

        var droppedStated = honest
        droppedStated.episodes[0].speakerAssignments[0].primary = Self.ref(Self.s1, .unknown)
        #expect(!ShowSchemaMigration.expectationFailures(original: original, migrated: droppedStated).isEmpty)

        var renamed = honest
        renamed.show.title += " (edited)"
        #expect(!ShowSchemaMigration.expectationFailures(original: original, migrated: renamed).isEmpty)

        var droppedBackup = honest
        droppedBackup.episodes[0].speakerAssignments[1].backups = []
        #expect(!ShowSchemaMigration.expectationFailures(original: original, migrated: droppedBackup).isEmpty)

        let unrelated = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.placeholderOnly).payload
        #expect(!ShowSchemaMigration.expectationFailures(original: original, migrated: unrelated).isEmpty)
        #expect(!ShowSchemaMigration.expectationFailures(original: Data("{}".utf8), migrated: honest).isEmpty)
    }

    // MARK: - Opening and migrating

    @Test(arguments: goldens)
    func opensAsNeedsMigrationNeverDamagedAndNeverWrites(_ golden: Golden) throws {
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        guard case let .needsMigration(schema, fingerprint) = Self.opener(rig).open(url, key: golden.key) else {
            Issue.record("expected needsMigration")
            return
        }
        #expect(schema == 1 && fingerprint.byteDigest == RevisionFingerprint(of: golden.bytes).byteDigest)
        #expect(try Data(contentsOf: url) == golden.bytes)
        #expect(try rig.recovery.migrationBackups(for: golden.key).isEmpty, "opening never writes a backup")
    }

    final class RecordingHooks: PublicationHooks {
        let log = Mutex<[PublicationBoundary]>([])
        func reached(_ boundary: PublicationBoundary) throws { log.withLock { $0.append(boundary) } }
    }

    @Test(arguments: goldens)
    func migratesThroughTheUnchangedC3OrderWithABackupOfTheOriginalBytes(_ golden: Golden) throws {
        let hooks = RecordingHooks()
        let rig = Rig(hooks: hooks)
        let url = rig.url()
        try golden.bytes.write(to: url)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)

        #expect(hooks.log.withLock { $0 } == PublicationBoundary.migration + PublicationBoundary.show.dropLast(),
                "M1–M3 then the ordinary P1–P6 publication (no library follow-up)")
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
        #expect(receipt.backup == Self.backupURL(rig, golden))
        #expect(Self.paths(try rig.recovery.migrationBackups(for: golden.key)) == Self.paths([receipt.backup]))
        #expect(receipt.originalFingerprint.byteDigest == RevisionFingerprint(of: golden.bytes).byteDigest)
        #expect(receipt.publication.revision == golden.revision + 1)
        #expect(receipt.publication.priorCheckpoint == nil, "the backup, not a checkpoint, holds the schema 1 original")

        let published = try Data(contentsOf: url)
        #expect(RevisionFingerprint(of: published).schemaVersion == SchemaVersion.show)
        guard case let .editable(document, fingerprint) = Self.opener(rig).open(url, key: golden.key) else {
            Issue.record("migrated show is not editable")
            return
        }
        #expect(fingerprint == receipt.publication.fingerprint)
        #expect(document.revision == golden.revision + 1)
        #expect(document.payload == (try ShowSchemaMigration.decodeSchema1(golden.bytes).payload))
        #expect(ShowSchemaMigration.expectationFailures(original: golden.bytes, migrated: document.payload).isEmpty)
    }

    @Test func migratedDocumentRoundTripsAndEncodesUnknownWithoutAnIndex() throws {
        let model = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.mixed).payload
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let bytes = try coder.encode(model, revision: 13)
        let decoded = try coder.decode(bytes)
        #expect(decoded.payload == model && decoded.revision == 13)
        #expect(try coder.encode(decoded.payload, revision: 13, publicationID: decoded.publication.publicationID)
            == coder.encode(model, revision: 13, publicationID: decoded.publication.publicationID))

        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        let episodes = try #require(payload["episodes"] as? [[String: Any]])
        let ben = try #require((episodes[0]["speakerAssignments"] as? [[String: Any]])?.first { $0["speakerID"] as? String == Self.ben.description })
        let primary = try #require(ben["primary"] as? [String: Any])
        let channel = try #require(primary["channel"] as? [String: Any])
        #expect(channel.count == 1 && channel["state"] as? String == "unknown", "unknown carries no index at all: \(channel)")
        let backups = try #require(ben["backups"] as? [[String: Any]])
        #expect((backups.first?["channel"] as? [String: Any])?["value"] as? Int == 3)
    }

    @Test func migrationIsIdempotentAndAnAlreadyCurrentShowIsNeverRewritten() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let migrator = DocumentMigrator.show(publisher: rig.publisher)
        #expect(throws: PublicationError.cancelled) { try migrator.migrate(url, key: golden.key, isCancelled: { true }) }
        #expect(try Data(contentsOf: url) == golden.bytes, "cancel leaves the schema 1 file")
        let receipt = try migrator.migrate(url, key: golden.key)
        let migrated = try Data(contentsOf: url)
        #expect(Self.paths(try rig.recovery.migrationBackups(for: golden.key)) == Self.paths([receipt.backup]), "retry reuses the identical backup")

        #expect(throws: PublicationError.self) { try migrator.migrate(url, key: golden.key) }
        #expect(try Data(contentsOf: url) == migrated, "a current show is not migrated again")
        #expect(Self.paths(try rig.recovery.migrationBackups(for: golden.key)) == Self.paths([receipt.backup]))
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
    }

    // MARK: - Backup never clobbered

    @Test func anExistingIdenticalBackupIsReusedUnchanged() throws {
        let golden = Self.goldens[0]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let existing = try rig.recovery.preserveMigrationBackup(golden.bytes, schemaVersion: 1, for: golden.key)
        let before = try FileManager.default.attributesOfItem(atPath: existing.path)[.systemFileNumber] as? Int
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        #expect(receipt.backup == existing)
        #expect(try FileManager.default.attributesOfItem(atPath: existing.path)[.systemFileNumber] as? Int == before, "not rewritten")
        #expect(Self.paths(try rig.recovery.migrationBackups(for: golden.key)) == Self.paths([existing]))
    }

    @Test func otherBytesAtTheBackupNameAreSetAsideNeverOverwritten() throws {
        let golden = Self.goldens[1]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let name = Self.backupURL(rig, golden)
        try FileManager.default.createDirectory(at: name.deletingLastPathComponent(), withIntermediateDirectories: true)
        let leftover = Data("an earlier, different backup at the same name".utf8)
        try leftover.write(to: name)

        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
        let folder = try FileManager.default.contentsOfDirectory(at: name.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let keptAside = folder.filter { $0.lastPathComponent.hasPrefix(name.lastPathComponent + ".damaged-") }
        #expect(keptAside.count == 1)
        #expect(try keptAside.map { try Data(contentsOf: $0) } == [leftover], "the earlier bytes survive")
    }

    @Test func anEarlierBackupOfAnotherOriginalIsLeftAlone() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        // A backup of a different schema 1 original under the same key (e.g. a copy migrated earlier).
        let earlier = try rig.recovery.preserveMigrationBackup(ShowSchema1Fixtures.placeholderOnly, schemaVersion: 1, for: golden.key)
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        #expect(Self.paths(try rig.recovery.migrationBackups(for: golden.key)) == Self.paths([earlier, receipt.backup]))
        #expect(try Data(contentsOf: earlier) == ShowSchema1Fixtures.placeholderOnly)
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
    }

    /// Writes the original's bytes with one byte flipped (a backup that doesn't read back as the original).
    struct CorruptingBackupWrites: FileOperations {
        let base = LocalFileOperations()
        let original: Data
        func read(_ url: URL) throws -> Data { try base.read(url) }
        func exists(_ url: URL) -> Bool { base.exists(url) }
        func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
        func writeNew(_ data: Data, to url: URL) throws {
            var bytes = data
            if data == original { bytes[bytes.startIndex] ^= 0x01 }
            try base.writeNew(bytes, to: url)
        }
        func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
        func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
        func remove(_ url: URL) throws { try base.remove(url) }
        func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
        func makeStagingDirectory(appropriateFor destination: URL) throws -> URL { try base.makeStagingDirectory(appropriateFor: destination) }
    }

    @Test func aBackupThatDoesNotReadBackStopsTheMigrationAndAHonestRetrySucceeds() throws {
        let golden = Self.goldens[2]
        let dir = TempDirectory("backup-verify")
        let corrupt = Rig(ops: CorruptingBackupWrites(original: golden.bytes), dir: dir)
        let url = corrupt.url()
        try golden.bytes.write(to: url)
        do {
            _ = try DocumentMigrator.show(publisher: corrupt.publisher).migrate(url, key: golden.key)
            Issue.record("migration continued without a verified backup")
        } catch let PublicationError.failed(stage, _, detail) {
            #expect(stage == .migrationOriginalRead)
            #expect(detail.contains("backup"))
        }
        #expect(try Data(contentsOf: url) == golden.bytes, "the schema 1 file is untouched")
        guard case .needsMigration(1, _) = Self.opener(corrupt).open(url, key: golden.key) else {
            Issue.record("expected needsMigration after the failed attempt")
            return
        }

        let clean = Rig(dir: dir)
        let receipt = try DocumentMigrator.show(publisher: clean.publisher).migrate(url, key: golden.key)
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
        #expect(RevisionFingerprint(of: try Data(contentsOf: url)).schemaVersion == SchemaVersion.show)
    }

    // MARK: - Identity: a different show's schema 1 file is never adopted or migrated (#175 review)

    /// Every file under `folder` with its bytes (empty when the folder doesn't exist).
    static func tree(_ folder: URL) throws -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var files: [String: Data] = [:]
        for case let file as URL in walker where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[file.resolvingSymlinksInPath().path] = try Data(contentsOf: file)
        }
        return files
    }

    static let otherShow = ShowID(uuid(99))

    @Test func aDifferentShowsSchema1FileIsRefusedByIdentityOnOpen() throws {
        let rig = Rig()
        let url = rig.url()
        let golden = Self.goldens[0]
        try golden.bytes.write(to: url)
        guard case let .damaged(.identityMismatch(expected, found), _) = Self.opener(rig).open(url, key: .show(Self.otherShow)) else {
            Issue.record("a different show's schema 1 file must be refused by identity")
            return
        }
        #expect(expected == DocumentKey.show(Self.otherShow).rawValue && found == golden.key.rawValue)
        guard case .needsMigration = Self.opener(rig).open(url, key: golden.key) else {
            Issue.record("the expected show still needs migration")
            return
        }
        #expect(try Data(contentsOf: url) == golden.bytes)
    }

    @Test func aDifferentShowsSchema1FileNeedsARelinkWhenReopenedFromItsRecordedLocation() async throws {
        let rig = Rig()
        let url = rig.url()
        try Self.goldens[0].bytes.write(to: url)
        let locations = ShowLocationStore(root: rig.dir.sub("ShowLocations"))
        try locations.record(Self.otherShow, at: url)
        let (outcome, result) = try await locations.withReopenedShow(Self.otherShow, opener: Self.opener(rig)) { _, _, _ in
            Issue.record("must not open a different show")
            return true
        }
        guard case .relinkRequired = outcome else {
            Issue.record("expected relinkRequired, got \(outcome)")
            return
        }
        #expect(result == nil)
    }

    @Test func openVerifiedRefusesADifferentShowsSchema1File() async throws {
        let rig = Rig()
        let url = rig.url()
        try Self.goldens[0].bytes.write(to: url)
        let locations = LibraryShowLocations(root: rig.dir.sub("Device"))
        try locations.record(Self.otherShow, at: url)
        await #expect(throws: ShowOpenError.differentShow(folderDisplayName: url.deletingLastPathComponent().lastPathComponent)) {
            _ = try await locations.openVerified(Self.otherShow, opener: Self.opener(rig)) { _ in Issue.record("must not adopt a different show") }
        }
    }

    @Test(arguments: goldens)
    func migrationRefusesADifferentShowBeforeAnyBackupOrWrite(_ golden: Golden) throws {
        let hooks = RecordingHooks()
        let rig = Rig(hooks: hooks)
        let url = rig.url()
        try golden.bytes.write(to: url)
        let recoveryBefore = try Self.tree(rig.dir.sub("Recovery"))
        let other = DocumentKey.show(Self.otherShow)
        #expect(throws: PublicationError.invalidCandidate(.identityMismatch(expected: other.rawValue, found: golden.key.rawValue))) {
            try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: other)
        }
        #expect(try Data(contentsOf: url) == golden.bytes, "the file is byte-for-byte unchanged")
        #expect(try Self.tree(rig.dir.sub("Recovery")) == recoveryBefore, "no backup (or any other recovery file) was written")
        #expect(try rig.recovery.migrationBackups(for: other).isEmpty && rig.recovery.migrationBackups(for: golden.key).isEmpty)
        #expect(hooks.log.withLock { $0 }.isEmpty, "refused before M1")
        // The expected show still migrates normally.
        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
    }

    // MARK: - Failure: honest error, schema 1 file and backup intact

    @Test func aDamagedSchema1FileFailsHonestlyAndStaysUnchanged() throws {
        let golden = Self.goldens[0]
        var object = try #require(try JSONSerialization.jsonObject(with: golden.bytes) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        var show = try #require(payload["show"] as? [String: Any])
        show["title"] = "Edited outside WaveWrangler"
        payload["show"] = show
        object["payload"] = payload
        let damaged = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)

        let rig = Rig()
        let url = rig.url()
        try damaged.write(to: url)
        #expect(throws: PublicationError.invalidCandidate(.checksumMismatch)) {
            try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        }
        #expect(try Data(contentsOf: url) == damaged)
        let backups = try rig.recovery.migrationBackups(for: golden.key)
        #expect(try backups.map { try Data(contentsOf: $0) } == [damaged], "the original bytes are preserved even when they can't be migrated")
    }

    static func checksumDamaged(_ golden: Golden) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: golden.bytes) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        var show = try #require(payload["show"] as? [String: Any])
        show["title"] = "Edited outside WaveWrangler"
        payload["show"] = show
        object["payload"] = payload
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// #175 review: the schema check reports `.needsMigration` before the checksum is verified, so the window's
    /// read-only view must still refuse a damaged older file as damaged and keep M1's recovered-copy offer.
    @Test(arguments: goldens)
    func aDamagedSchema1FileStillOffersItsRecoveredCopyWhenOpenedForViewing(_ golden: Golden) throws {
        let rig = Rig()
        let url = rig.url()
        let damaged = try Self.checksumDamaged(golden)
        try damaged.write(to: url)
        try rig.recovery.retainCheckpoint(golden.bytes, for: golden.key)
        try rig.recovery.recordLocation(url, for: golden.key)
        let opener = Self.opener(rig)
        guard case .needsMigration(1, _) = opener.outcome(for: damaged, url: url) else {
            Issue.record("a schema 1 file is classified by schema before its checksum")
            return
        }
        // As the document window asks: by location only (no key yet).
        guard case let .damaged(error, candidates) = opener.olderShowForViewing(damaged, url: url) else {
            Issue.record("a checksum-damaged schema 1 file must not be viewable")
            return
        }
        #expect(error == .checksumMismatch)
        #expect(candidates.map(\.document.payload) == [try ShowSchemaMigration.decodeUpgradingOlder(golden.bytes).payload])
        #expect(candidates.first?.document.revision == golden.revision)
        #expect(try Data(contentsOf: url) == damaged, "the damaged file is left untouched")
        #expect(try rig.recovery.migrationBackups(for: golden.key).isEmpty, "viewing never writes a backup")
        // A whole older file is viewable, upgraded in memory, and nothing is written.
        try golden.bytes.write(to: url)
        guard case let .viewable(document) = opener.olderShowForViewing(golden.bytes, url: url) else {
            Issue.record("a valid schema 1 file is viewable")
            return
        }
        #expect(document.payload == (try ShowSchemaMigration.decodeUpgradingOlder(golden.bytes).payload))
        #expect(try Data(contentsOf: url) == golden.bytes)
    }

    @Test func aMigrationThatBreaksItsExpectationsPublishesNothing() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let real = try #require(ShowSchemaMigration.steps.first)
        let placeholderAsZero = MigrationStep<ShowDocumentModel>(fromSchema: 1, migrate: { data in
            var (model, revision) = try real.migrate(data)
            model.episodes[0].speakerAssignments[1].primary = ChannelReference(sourceID: Self.s2, channel: .known(0))
            return (model, revision)
        }, expectations: real.expectations)
        do {
            _ = try DocumentMigrator(publisher: rig.publisher, steps: [placeholderAsZero]).migrate(url, key: golden.key)
            Issue.record("a migration that turned the placeholder into channel 0 was published")
        } catch let PublicationError.failed(stage, _, detail) {
            #expect(stage == .migrationBackupPreserved)
            #expect(detail.contains("stated-channel"))
        }
        #expect(try Data(contentsOf: url) == golden.bytes)
        #expect(try rig.recovery.migrationBackups(for: golden.key).map { try Data(contentsOf: $0) } == [golden.bytes])
    }

    enum Outcome: Equatable { case old, new, recoveredOld, mixed, zeroValid }

    /// Every fault at every migration (M1–M3) and publication (P1–P6) boundary: afterwards the show opens as
    /// the intact schema 1 file (and an honest retry migrates it with exactly one backup), or as the migrated
    /// revision, or — after a torn publish — as damaged with the original bytes in the backup. Never mixed,
    /// never zero valid copies.
    @Test(arguments: PublicationBoundary.migration + PublicationBoundary.show.dropLast())
    func everyFaultLeavesTheOriginalOrTheMigratedRevision(_ boundary: PublicationBoundary) throws {
        let golden = Self.goldens[2]
        try Self.faultMatrix(boundary, golden: golden, fromSchema: 1, expected: try ShowSchemaMigration.decodeSchema1(golden.bytes).payload)
    }

    /// The C5 fault matrix for one migration step (`fromSchema` → current) at one boundary.
    static func faultMatrix(_ boundary: PublicationBoundary, golden: Golden, fromSchema: Int, expected: ShowDocumentModel) throws {
        var variants = FaultInjectionHarnessTests.variants(for: boundary)
        if boundary == .candidateValidated {
            variants = [{ _ in .crash(at: boundary) }] // a migration retains no prior checkpoint: no write follows P1
        }
        if [.migrationOriginalRead, .baseChecked].contains(boundary) {
            variants.append { _ in .failWrite(after: boundary, errno: ENOSPC) } // boundaries followed by a write
        }
        var outcomes: [Outcome] = []
        var fired = 0
        for (index, variant) in variants.enumerated() {
            for fraction in [0.1, 0.35, 0.65, 0.9] {
                let dir = TempDirectory("show-migration-\(fromSchema)-\(boundary.rawValue)-\(index)")
                let url = Rig(dir: dir).url()
                try golden.bytes.write(to: url)
                let faults = FaultState(variant(fraction))
                let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
                do {
                    _ = try DocumentMigrator.show(publisher: faulty.publisher).migrate(url, key: golden.key)
                } catch is SimulatedCrash {
                } catch is PublicationError {
                }
                if faults.fired { fired += 1 }

                let after = Rig(dir: dir)
                after.recovery.removeStagingLeftovers()
                let backups = try after.recovery.migrationBackups(for: golden.key)
                #expect(try backups.allSatisfy { try Data(contentsOf: $0) == golden.bytes }, "every backup holds the original bytes")
                switch Self.opener(after).open(url, key: golden.key) {
                case let .needsMigration(schema, _) where try schema == fromSchema && Data(contentsOf: url) == golden.bytes:
                    outcomes.append(.old)
                    let receipt = try DocumentMigrator.show(publisher: after.publisher).migrate(url, key: golden.key)
                    #expect(Self.paths(try after.recovery.migrationBackups(for: golden.key)) == Self.paths([receipt.backup]), "retry keeps exactly one backup")
                    #expect(try Data(contentsOf: receipt.backup) == golden.bytes)
                case let .editable(document, _):
                    outcomes.append(document.payload == expected && document.revision == golden.revision + 1 ? .new : .mixed)
                case .damaged:
                    outcomes.append(backups.isEmpty ? .zeroValid : .recoveredOld)
                default:
                    outcomes.append(.mixed)
                }
                Self.cleanStaging(faults)
            }
        }
        Evidence.record("show schema \(fromSchema)→\(SchemaVersion.show) migration boundary=\(boundary.rawValue) runs=\(outcomes.count) fired=\(fired) old=\(outcomes.count { $0 == .old }) new=\(outcomes.count { $0 == .new }) recoveredOld=\(outcomes.count { $0 == .recoveredOld }) [simulated/local]")
        #expect(fired == outcomes.count, "every injected fault fired")
        #expect(!outcomes.contains(.mixed) && !outcomes.contains(.zeroValid), "\(outcomes)")
    }

    static func cleanStaging(_ faults: FaultState) {
        FaultInjectionHarnessTests.cleanStaging(faults)
    }

    // MARK: - Unknown-newer refusal

    /// The M1 (schema 1) build's show reader: current and minimum readable schema 1.
    static let olderReader = JSONEnvelopeCoder<ShowSchemaMigration.ShowDocumentModelV1>(format: ShowSchemaMigration.schema1Format) { _, _ in [] }

    @Test func anOlderBuildRefusesTheMigratedShowAsUnknownNewer() throws {
        let rig = Rig()
        let url = rig.url()
        let golden = Self.goldens[2]
        try golden.bytes.write(to: url)
        _ = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        let migrated = try Data(contentsOf: url)

        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show, supported: 1)) { try Self.olderReader.decode(migrated) }
        let olderOpener = DocumentOpener(coder: Self.olderReader, recovery: nil)
        guard case .refusedNewerFormat(found: SchemaVersion.show, supported: 1, _) = olderOpener.open(url) else {
            Issue.record("an older build must refuse the migrated show as unknown-newer")
            return
        }
        // The older build still reads its own format (the simulation is faithful, not a blanket refusal).
        #expect(try Self.olderReader.decode(golden.bytes).revision == golden.revision)

        // An older build's edit-checkpoint offer reports a current-schema record as newer, never applies it.
        let record = try rig.recovery.writeEditCheckpoint(snapshot: migrated, base: nil, schemaVersion: SchemaVersion.show, for: golden.key,
                                                          at: Date(timeIntervalSince1970: 1_790_000_000))
        let offer = EditCheckpointOffer.assess([StoredEditCheckpoint(url: url, record: .success(record))], documentID: golden.key.rawValue,
                                               onDisk: nil, coder: Self.olderReader, belongsToDocument: { _ in true })
        #expect(offer.usable.isEmpty)
        #expect(offer.problems == [.newerFormat(url, found: SchemaVersion.show, supported: 1)])
    }

    @Test func thisBuildRefusesAFutureSchemaAsUnknownNewer() throws {
        let model = try ShowSchemaMigration.decodeSchema1(ShowSchema1Fixtures.mixed).payload
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEnvelopeCoder<ShowDocumentModel>.show.encode(model, revision: 13)) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.show + 1
        let future = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show + 1, supported: SchemaVersion.show)) {
            try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(future)
        }
        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show + 1, supported: SchemaVersion.show)) {
            try ShowSchemaMigration.decodeUpgradingOlder(future)
        }
        let rig = Rig()
        let url = rig.url()
        try future.write(to: url)
        guard case .refusedNewerFormat(found: SchemaVersion.show + 1, supported: SchemaVersion.show, _) = Self.opener(rig).open(url) else {
            Issue.record("expected unknown-newer refusal")
            return
        }
        #expect(throws: PublicationError.self) { try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: .show(model.show.id)) }
        #expect(try Data(contentsOf: url) == future, "never migrated or downsaved")
    }

    // MARK: - Recovery records written before the format change

    @Test func schema1RecoveryCheckpointsStayOfferableUpgradedInMemory() throws {
        let golden = Self.goldens[2]
        let rig = Rig()
        let url = rig.url()
        try rig.recovery.retainCheckpoint(golden.bytes, for: golden.key)
        try Data("not a show".utf8).write(to: url)
        guard case let .damaged(_, candidates) = Self.opener(rig).open(url, key: golden.key) else {
            Issue.record("expected damaged with candidates")
            return
        }
        #expect(candidates.map(\.document.payload) == [try ShowSchemaMigration.decodeSchema1(golden.bytes).payload])
        let candidate = try #require(candidates.first)
        #expect(candidate.document.revision == golden.revision)
        #expect(try rig.recovery.bytes(of: candidate.checkpoint) == golden.bytes, "the checkpoint itself is not rewritten")
    }

    @Test func schema1EditCheckpointsStayOfferableUpgradedInMemoryButNeverOverTheMigratedFile() throws {
        let golden = Self.goldens[1]
        let rig = Rig()
        let url = rig.url()
        try golden.bytes.write(to: url)
        let record = try rig.recovery.writeEditCheckpoint(snapshot: golden.bytes, base: RevisionFingerprint(of: golden.bytes), schemaVersion: 1,
                                                          for: golden.key, at: Date(timeIntervalSince1970: 1_790_000_000))
        let stored = [StoredEditCheckpoint(url: rig.url("edit.wwedit"), record: .success(record))]
        let belongs: @Sendable (ShowDocumentModel) -> Bool = { $0.show.id == golden.showID }

        let before = EditCheckpointOffer.assess(stored, documentID: golden.key.rawValue, onDisk: RevisionFingerprint(of: golden.bytes),
                                                coder: .show, decodeOlder: ShowSchemaMigration.decodeUpgradingOlder, belongsToDocument: belongs)
        #expect(before.problems.isEmpty)
        #expect(before.usable.map(\.payload) == [try ShowSchemaMigration.decodeSchema1(golden.bytes).payload])

        let receipt = try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: golden.key)
        let after = EditCheckpointOffer.assess(stored, documentID: golden.key.rawValue, onDisk: receipt.publication.fingerprint,
                                               coder: .show, decodeOlder: ShowSchemaMigration.decodeUpgradingOlder, belongsToDocument: belongs)
        #expect(after.usable.map(\.relation) == [.basedOnOtherRevision], "a pre-migration record never restores over the migrated file")

        let withoutUpgrade = EditCheckpointOffer.assess(stored, documentID: golden.key.rawValue, onDisk: nil, coder: .show, belongsToDocument: belongs)
        #expect(withoutUpgrade.usable.isEmpty && withoutUpgrade.problems.count == 1, "without the upgrade it is reported, never dropped silently")
    }
}
