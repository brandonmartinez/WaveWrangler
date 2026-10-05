import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Builds a publisher/opener pair rooted in a temp directory.
struct Rig {
    let dir: TempDirectory
    let docs: URL
    let recovery: RecoveryStore
    let publisher: DocumentPublisher<JSONEnvelopeCoder<ShowDocumentModel>>
    let opener: DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>

    init(label: String = "rig", ops: any FileOperations = LocalFileOperations(), hooks: any PublicationHooks = NoPublicationHooks(),
         dir: TempDirectory? = nil) {
        self.dir = dir ?? TempDirectory(label)
        docs = self.dir.sub("Documents")
        recovery = RecoveryStore(root: self.dir.sub("Recovery"), ops: ops)
        publisher = DocumentPublisher(coder: .show, ops: ops, coordination: NSFileCoordination(), recovery: recovery, hooks: hooks)
        opener = DocumentOpener(coder: .show, ops: ops, coordination: NSFileCoordination(), recovery: recovery, migratableSchemas: [0])
    }

    func url(_ name: String = "Synthetic.wwshow") -> URL { docs.appending(path: name) }

    /// Creates r1 and r2 so that a coherent prior checkpoint exists. Returns (r2 payload, r2 fingerprint).
    func seedTwoRevisions(_ model: ShowDocumentModel, at url: URL) throws -> (ShowDocumentModel, RevisionFingerprint) {
        let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        let second = try model.renamingShow(to: model.show.title + " r2")
        let receipt = try publisher.publish(second, revision: 2, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: first.fingerprint))
        return (second, receipt.fingerprint)
    }
}

@Suite("Publication protocol")
struct PublicationTests {
    @Test func publishesVerifiesAndRetainsPrior() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 1)
        let url = rig.url()
        let first = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        #expect(first.priorCheckpoint == nil)
        #expect(first.revision == 1 && !first.followUpIncomplete)

        let edited = try model.renamingShow(to: "Edited")
        let second = try rig.publisher.publish(edited, revision: 2, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: first.fingerprint))
        #expect(second.priorCheckpoint?.fingerprint == first.fingerprint)
        guard case let .editable(document, fingerprint) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(document.payload == edited && document.revision == 2 && fingerprint == second.fingerprint)
        let checkpoints = try rig.recovery.validatedCheckpoints(for: .show(model.show.id), coder: JSONEnvelopeCoder<ShowDocumentModel>.show)
        #expect(checkpoints.map(\.document.payload) == [model])
    }

    @Test func retainsAtMostConfiguredCheckpointsNewestFirst() throws {
        let rig = Rig()
        var model = Fixtures.show(seed: 2)
        let url = rig.url()
        var base = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation).fingerprint
        for revision in 2...7 {
            model = try model.renamingShow(to: "Rev \(revision)")
            base = try rig.publisher.publish(model, revision: revision, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base)).fingerprint
        }
        let revisions = try rig.recovery.checkpoints(for: .show(model.show.id)).map(\.fingerprint.revision)
        #expect(revisions == [6, 5, 4])
    }

    @Test func detectsExternalChangeAsConflictAndPreservesBoth() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 3)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        // Another writer publishes over our base.
        let theirs = try current.renamingShow(to: "Theirs")
        let theirsReceipt = try rig.publisher.publish(theirs, revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        let mine = try current.renamingShow(to: "Mine")
        #expect {
            try rig.publisher.publish(mine, revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        } throws: { error in
            guard case let .conflict(conflict) = error as? PublicationError else { return false }
            guard conflict.onDisk == theirsReceipt.fingerprint, let preserved = conflict.preservedCandidate,
                  let bytes = try? Data(contentsOf: preserved), let decoded = try? JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes)
            else { return false }
            return decoded.payload == mine
        }
        // Disk still holds theirs, untouched.
        guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(document.payload == theirs)
    }

    @Test func missingDocumentIsConflictNotSilentRecreate() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 4)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        try FileManager.default.moveItem(at: url, to: rig.url("Moved.wwshow"))
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(current, revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newLocationNeverOverwrites() throws {
        let rig = Rig()
        let url = rig.url()
        try Data("someone else's file".utf8).write(to: url)
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(Fixtures.show(seed: 5), revision: 1, key: .show(ShowID()), to: url, target: .newLocation)
        }
        #expect(try Data(contentsOf: url) == Data("someone else's file".utf8))
    }

    @Test(arguments: [(ENOSPC, WriteFailureKind.diskFull), (EACCES, .permissionDenied), (ETIMEDOUT, .unavailable)])
    func writeFailuresKeepPriorAndClassify(_ code: Int32, _ kind: WriteFailureKind) throws {
        let dir = TempDirectory("fail")
        let clean = Rig(dir: dir)
        let model = Fixtures.show(seed: 6)
        let url = clean.url()
        let (current, base) = try clean.seedTwoRevisions(model, at: url)
        let before = try Data(contentsOf: url)
        for boundary in [PublicationBoundary.baseChecked, .stagedFlushed] {
            let faults = FaultState(.failWrite(after: boundary, errno: code))
            let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
            #expect {
                try faulty.publisher.publish(try current.renamingShow(to: "X"), revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
            } throws: { error in
                guard case let .failed(_, actual, _) = error as? PublicationError else { return false }
                return actual == kind
            }
            #expect(faults.fired)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func cancellationBeforePublishChangesNothing() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 7)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let before = try Data(contentsOf: url)
        #expect(throws: PublicationError.cancelled) {
            try rig.publisher.publish(try current.renamingShow(to: "C"), revision: 3, key: .show(model.show.id), to: url,
                                      target: .inPlace(expectedBase: base), isCancelled: { true })
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func staleReadBackIsAcknowledgementUncertainNotSuccess() throws {
        let dir = TempDirectory("stale")
        let clean = Rig(dir: dir)
        let model = Fixtures.show(seed: 8)
        let url = clean.url()
        let (current, base) = try clean.seedTwoRevisions(model, at: url)
        let faults = FaultState(.staleReadBack)
        let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
        #expect {
            try faulty.publisher.publish(try current.renamingShow(to: "N"), revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        } throws: { error in
            if case .acknowledgementUncertain = error as? PublicationError { return true }
            return false
        }
    }

    @Test func refusesNonIncreasingRevisionAndInvalidPayloadBeforeWriting() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 9)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let before = try Data(contentsOf: url)
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(current, revision: 2, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        }
        var invalid = current
        invalid.episodes.append(invalid.episodes[0])
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(invalid, revision: 3, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: base))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func sessionSaveAsAndDuplicateKeepOriginalIntact() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 10)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let original = try Data(contentsOf: url)
        let session = CanonicalDocumentSession(key: .show(model.show.id), url: url, payload: current, base: base, revision: 2, publisher: rig.publisher)
        try await session.edit { try $0.renamingShow(to: "Copy") }
        let copyURL = rig.url("Copy.wwshow")
        guard case .success = await session.saveAs(copyURL) else { Issue.record("save as failed"); return }
        #expect(try Data(contentsOf: url) == original)
        #expect(await session.url == copyURL)
        #expect(await !session.isDirty)
        // Save As onto an existing file without consent is refused.
        let other = CanonicalDocumentSession(key: .show(model.show.id), url: url, payload: current, base: base, revision: 2, publisher: rig.publisher)
        guard case .failure(.conflict) = await other.saveAs(copyURL) else { Issue.record("expected refusal"); return }
    }
}

@Suite("Opening, refusal and recovery")
struct OpenRecoveryTests {
    @Test func unknownNewerIsRefusedAndNeverWritten() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 20)
        let url = rig.url()
        _ = try rig.seedTwoRevisions(model, at: url)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.show + 1
        object["payload"] = ["fromTheFuture": true]
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: url)
        guard case let .refusedNewerFormat(found, supported, fingerprint) = rig.opener.open(url) else { Issue.record("not refused"); return }
        #expect(found == SchemaVersion.show + 1 && supported == SchemaVersion.show)
        // Any save attempt against it (from a stale base or as new) is refused without writing.
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(model, revision: 9, key: .show(model.show.id), to: url, target: .newLocation)
        }
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(model, revision: 9, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: RevisionFingerprint(of: Data())))
        }
        #expect(RevisionFingerprint(of: try Data(contentsOf: url)) == fingerprint)
        let session = CanonicalDocumentSession(key: .show(model.show.id), url: url, payload: model, base: fingerprint, revision: 1,
                                               publisher: rig.publisher, readOnlyReason: "newer format")
        let edited = await session.edit { $0 }
        #expect(edited == false)
        guard case .failure(.readOnly) = await session.save() else { Issue.record("save not refused"); return }
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test func damagedCurrentOffersWholeCheckpointsReadOnlyAndKeepsSuspectFile() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 21)
        let url = rig.url()
        let (current, _) = try rig.seedTwoRevisions(model, at: url)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0x5A
        try bytes.write(to: url)
        // Without the key, the location hint finds the records.
        guard case let .damaged(_, candidates) = rig.opener.open(url) else { Issue.record("not damaged"); return }
        #expect(candidates.first?.document.payload == model)
        #expect(candidates.first?.document.revision == 1)
        let recovered = CanonicalDocumentSession.recovered(try #require(candidates.first), originalURL: url, publisher: rig.publisher)
        let edited = await recovered.edit { $0 }
        #expect(edited == false)
        guard case .failure(.readOnly) = await recovered.save() else { Issue.record("recovered save allowed"); return }
        let copy = rig.url("Recovered.wwshow")
        guard case .success = await recovered.duplicate(to: copy) else { Issue.record("copy failed"); return }
        #expect(try Data(contentsOf: url) == bytes)
        guard case let .editable(document, _) = rig.opener.open(copy) else { Issue.record("copy unreadable"); return }
        #expect(document.payload == model)
        _ = current
    }

    @Test func checkpointsSurviveDocumentMove() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 22)
        let url = rig.url()
        _ = try rig.seedTwoRevisions(model, at: url)
        let moved = rig.dir.sub("Elsewhere").appending(path: "Renamed.wwshow")
        try FileManager.default.moveItem(at: url, to: moved)
        try Data("garbage".utf8).write(to: moved, options: .atomic)
        guard case let .damaged(_, candidates) = rig.opener.open(moved, key: .show(model.show.id)) else { Issue.record("not damaged"); return }
        #expect(candidates.first?.document.payload == model)
    }

    @Test func unreadableReportsKindAndCandidates() {
        let rig = Rig()
        guard case let .unreadable(kind, _, candidates) = rig.opener.open(rig.url("Missing.wwshow")) else { Issue.record("expected unreadable"); return }
        #expect(kind == .unavailable && candidates.isEmpty)
    }
}

@Suite("Migration framework (synthetic schema 0)")
struct MigrationTests {
    @Test func migratesWithBackupAndValidation() throws {
        let rig = Rig()
        let url = rig.url("Legacy.wwshow")
        let original = try SyntheticV0.bytes(seed: 30)
        try original.write(to: url)
        guard case let .needsMigration(schema, _) = rig.opener.open(url) else { Issue.record("expected migration"); return }
        #expect(schema == 0)
        let migrator = DocumentMigrator(publisher: rig.publisher, steps: [SyntheticV0.step])
        let key = DocumentKey(rawValue: "legacy-30")
        let receipt = try migrator.migrate(url, key: key)
        #expect(try Data(contentsOf: receipt.backup) == original)
        #expect(receipt.publication.revision == 5)
        guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(SyntheticV0.step.expectations(original, document.payload).isEmpty)
    }

    @Test func cancelLeavesOriginalAndRetryIsIdempotent() throws {
        let rig = Rig()
        let url = rig.url("Legacy.wwshow")
        let original = try SyntheticV0.bytes(seed: 31)
        try original.write(to: url)
        let migrator = DocumentMigrator(publisher: rig.publisher, steps: [SyntheticV0.step])
        let key = DocumentKey(rawValue: "legacy-31")
        #expect(throws: PublicationError.cancelled) { try migrator.migrate(url, key: key, isCancelled: { true }) }
        #expect(try Data(contentsOf: url) == original)
        _ = try migrator.migrate(url, key: key)
        #expect(try rig.recovery.migrationBackups(for: key).count == 1)
    }

    @Test func failedExpectationsPublishNothing() throws {
        let rig = Rig()
        let url = rig.url("Legacy.wwshow")
        let original = try SyntheticV0.bytes(seed: 32)
        try original.write(to: url)
        let lying = MigrationStep<ShowDocumentModel>(fromSchema: 0, migrate: { data in
            var (model, revision) = try SyntheticV0.step.migrate(data)
            model.episodes[0].number = 99 // invented fact
            return (model, revision)
        }, expectations: SyntheticV0.step.expectations)
        #expect(throws: PublicationError.self) { try DocumentMigrator(publisher: rig.publisher, steps: [lying]).migrate(url, key: .library) }
        #expect(try Data(contentsOf: url) == original)
    }
}

@Suite("C2b edit-checkpoint records")
struct EditCheckpointTests {
    @Test func sequenceRetentionRelationAndDamage() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 60)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let key = DocumentKey.show(model.show.id)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        for index in 1...3 {
            let snapshot = try coder.encode(try current.renamingShow(to: "Unsaved \(index)"), revision: 3)
            let record = try rig.recovery.writeEditCheckpoint(snapshot: snapshot, base: base, schemaVersion: 1, for: key)
            #expect(record.checkpointSequence == index)
        }
        let records = rig.recovery.editCheckpoints(for: key)
        #expect(records.count == 1, "older records are pruned once the newer one is verified")
        let latest = try #require(rig.recovery.latestEditCheckpoint(for: key))
        #expect(latest.unpublished && latest.recordKind == "edit-checkpoint" && latest.baseRevision == 2)
        #expect(latest.basePublicationID == base.publicationID && latest.baseChecksum == base.checksum)
        #expect(try coder.decode(latest.snapshot).payload.show.title == "Unsaved 3")
        #expect(latest.relation(to: base) == .basedOnCurrent)
        #expect(latest.relation(to: RevisionFingerprint(of: Data("other".utf8))) == .basedOnOtherRevision)
        // The canonical document was never touched.
        guard case let .editable(document, fingerprint) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(document.payload == current && fingerprint == base)

        // A damaged record is reported and retained, never applied or purged.
        let damaged = rig.recovery.root.appending(path: "edit-checkpoints/\(key.rawValue)/0000000099.wwedit")
        try Data("{broken".utf8).write(to: damaged)
        let results = rig.recovery.editCheckpoints(for: key)
        #expect(results.contains { if case .failure(.damaged) = $0 { true } else { false } })
        #expect(rig.recovery.latestEditCheckpoint(for: key)?.checkpointSequence == 3)
        #expect(FileManager.default.fileExists(atPath: damaged.path))

        try rig.recovery.discardEditCheckpoints(for: key)
        #expect(rig.recovery.editCheckpoints(for: key).isEmpty)
    }
}
