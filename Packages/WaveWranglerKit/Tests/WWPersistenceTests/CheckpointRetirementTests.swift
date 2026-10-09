import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Explicit recovery retirement")
struct CheckpointRetirementTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    @Test func saveAsAndDontSaveLeaveOriginCheckpointAndBytes() async throws {
        let rig = Rig()
        let initial = Fixtures.show(seed: 2701)
        let origin = rig.url("Origin.wwshow")
        let (current, base) = try rig.seedTwoRevisions(initial, at: origin)
        let key = DocumentKey.show(current.show.id)
        let originBytes = try Data(contentsOf: origin)
        let restored = try current.renamingShow(to: "Restored")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(restored, revision: 3), base: base,
                                             schemaVersion: coder.format.currentSchemaVersion, for: key)
        let snapshot = try #require(rig.recovery.latestEditCheckpoint(for: key))
        let session = CanonicalDocumentSession(key: key, url: origin, payload: current, base: base, revision: 2,
                                               publisher: rig.publisher, gate: AutosaveGate(AutosavePreference(enabled: false)))
        try await session.edit { _ in restored }
        let destination = rig.url("Destination.wwshow")
        guard case .success = await session.saveAs(destination) else { Issue.record("Save As failed"); return }
        #expect(try Data(contentsOf: origin) == originBytes)
        #expect(try coder.decode(Data(contentsOf: destination)).payload == restored)
        await session.discardUnsavedChanges()
        #expect(rig.recovery.latestEditCheckpoint(for: key) == snapshot)
    }

    @Test func restoredThenRevertedThenUnrelatedSaveKeepsEveryRecord() async throws {
        let rig = Rig()
        let initial = Fixtures.show(seed: 2702)
        let origin = rig.url()
        let (current, base) = try rig.seedTwoRevisions(initial, at: origin)
        let key = DocumentKey.show(current.show.id)
        let restored = try current.renamingShow(to: "Restored")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(restored, revision: 3), base: base,
                                             schemaVersion: coder.format.currentSchemaVersion, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let offered = try #require(rig.recovery.offeredEditCheckpoints(for: key).first)
        let offeredBytes = try Data(contentsOf: offered.url)
        let session = CanonicalDocumentSession(key: key, url: origin, payload: current, base: base, revision: 2, publisher: rig.publisher)
        try await session.edit { _ in restored }
        try await session.edit { _ in current }
        try await session.edit { try $0.renamingShow(to: "Unrelated") }
        guard case .success = await session.save() else { Issue.record("Save failed"); return }
        #expect(try Data(contentsOf: offered.url) == offeredBytes)
        #expect(rig.recovery.offeredEditCheckpoints(for: key).count == 1)
    }

    @Test func movedOriginAndIdenticalReplacementCannotBecomeAnInPlaceSave() async throws {
        let rig = Rig()
        let initial = Fixtures.show(seed: 2703)
        let origin = rig.url()
        let (current, base) = try rig.seedTwoRevisions(initial, at: origin)
        let moved = rig.url("Moved.wwshow")
        let originalBytes = try Data(contentsOf: origin)
        let session = CanonicalDocumentSession(key: .show(current.show.id), url: origin, payload: current, base: base,
                                               revision: 2, publisher: rig.publisher)
        try FileManager.default.moveItem(at: origin, to: moved)
        try originalBytes.write(to: origin)
        let candidate = try current.renamingShow(to: "Must refuse")
        try await session.edit { _ in candidate }
        guard case .failure = await session.save() else { Issue.record("replaced original was overwritten"); return }
        guard case .failure(.originConflict) = await session.saveAs(origin, replacingExisting: true) else {
            Issue.record("Save As to the originating path bypassed its identity check"); return
        }
        #expect(try Data(contentsOf: moved) == originalBytes)
        #expect(try Data(contentsOf: origin) == originalBytes)
    }

    @Test func unknownOriginIdentityRefusesSaveAndSubsequentVerifiedSavesRefreshIdentity() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2704)
        let url = rig.url()
        let key = DocumentKey.show(model.show.id)
        let receipt = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let unknown = CanonicalDocumentSession(key: key, url: rig.url("Missing.wwshow"), payload: model,
                                               base: receipt.fingerprint, revision: 1, publisher: rig.publisher)
        try await unknown.edit { try $0.renamingShow(to: "Keep dirty") }
        guard case .failure(.originConflict) = await unknown.save() else { Issue.record("missing identity accepted"); return }
        #expect(await unknown.isDirty)
        let session = CanonicalDocumentSession(key: key, url: url, payload: model, base: receipt.fingerprint, revision: 1,
                                               publisher: rig.publisher)
        for index in 2...3 {
            try await session.edit { try $0.renamingShow(to: "Edit \(index)") }
            guard case .success = await session.save() else { Issue.record("legitimate next save refused"); return }
        }
        #expect(try coder.decode(Data(contentsOf: url)).payload.show.title == "Edit 3")
    }

    @Test func selectedOfferedAndPriorDiscardRemoveOnlyBoundRecord() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2705)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let key = DocumentKey.show(model.show.id)
        for (index, name) in ["First", "Rival"].enumerated() {
            try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: name), revision: 3), base: base,
                                                 schemaVersion: coder.format.currentSchemaVersion, for: key,
                                                 at: Date(timeIntervalSince1970: Double(1_000 + index)))
            try rig.recovery.setAsideEditCheckpoints(for: key)
        }
        let records = rig.recovery.offeredEditCheckpoints(for: key)
        let first = try #require(records.first)
        let rival = try #require(records.last)
        let rivalBytes = try Data(contentsOf: rival.url)
        let prior = try #require(rig.recovery.checkpoints(for: key).first)
        let priorBytes = try Data(contentsOf: prior.url)
        let selected = try rig.recovery.selectRecord(.offeredEditCheckpoint, at: first.url, for: key)
        // The displayed choice changed while a confirmation was open; the selected first record still wins.
        try rig.recovery.discardSelectedRecord(selected)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(try Data(contentsOf: rival.url) == rivalBytes)
        #expect(try Data(contentsOf: prior.url) == priorBytes)
        #expect(throws: CocoaError.self) { try rig.recovery.discardSelectedRecord(selected) }

        let chosenPrior = try rig.recovery.selectRecord(.priorCheckpoint, at: prior.url, for: key)
        try rig.recovery.discardSelectedRecord(chosenPrior)
        #expect(!FileManager.default.fileExists(atPath: prior.url.path))
        #expect(try Data(contentsOf: rival.url) == rivalBytes)
    }

    @Test func staleReplacementAndFailedRemoveLeaveAllOtherRecordsUntouched() throws {
        let directory = TempDirectory("discard-fault")
        let rig = Rig(dir: directory)
        let model = Fixtures.show(seed: 2706)
        let key = DocumentKey.show(model.show.id)
        let snapshot = try coder.encode(model, revision: 2)
        try rig.recovery.writeEditCheckpoint(snapshot: snapshot, base: nil, schemaVersion: coder.format.currentSchemaVersion, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let url = try #require(rig.recovery.offeredEditCheckpoints(for: key).first?.url)
        let selection = try rig.recovery.selectRecord(.offeredEditCheckpoint, at: url, for: key)
        let original = try Data(contentsOf: url)
        try original.write(to: url, options: .atomic)
        #expect(throws: CocoaError.self) { try rig.recovery.discardSelectedRecord(selection) }
        #expect(try Data(contentsOf: url) == original)
        let failedStore = RecoveryStore(root: rig.recovery.root, ops: FaultingFileOperations(removeFails: true))
        let failedSelection = try failedStore.selectRecord(.offeredEditCheckpoint, at: url, for: key)
        #expect(throws: POSIXError.self) { try failedStore.discardSelectedRecord(failedSelection) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func damagedPriorRequiresExplicitSelectionAndLeavesHealthyRival() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2708)
        let key = DocumentKey.show(model.show.id)
        let healthy = try rig.recovery.retainCheckpoint(coder.encode(model, revision: 1), for: key)
        let directory = healthy.url.deletingLastPathComponent()
        let damaged = directory.appending(path: "0000000000-damaged.wwcheckpoint")
        try Data("damaged".utf8).write(to: damaged)
        let healthyBytes = try Data(contentsOf: healthy.url)
        #expect(try rig.recovery.checkedCheckpoints(for: key).count == 2)
        #expect(throws: PersistenceError.self) {
            try rig.recovery.selectRecord(.priorCheckpoint, at: damaged, for: key)
        }
        let chosen = try rig.recovery.selectRecord(.priorCheckpoint, at: damaged, for: key, allowingDamagedRecord: true)
        try rig.recovery.discardSelectedRecord(chosen)
        #expect(!FileManager.default.fileExists(atPath: damaged.path))
        #expect(try Data(contentsOf: healthy.url) == healthyBytes)
    }

    @Test func verifiedCurrentReplacementRetainsItsValidatedPredecessor() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2707)
        let key = DocumentKey.show(model.show.id)
        let first = try coder.encode(model, revision: 1)
        let second = try coder.encode(model.renamingShow(to: "Second"), revision: 2)
        try rig.recovery.recordVerifiedCurrent(first, for: key)
        try rig.recovery.recordVerifiedCurrent(second, for: key)
        #expect(try rig.recovery.checkpoints(for: key).map { try rig.recovery.bytes(of: $0) } == [first])
        #expect(try rig.recovery.bytes(of: #require(rig.recovery.verifiedCurrent(for: key))) == second)
    }

    @Test func externalSafeWriteErrorAfterCommitNeverReportsSuccessOrRollback() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2709)
        let key = DocumentKey.show(model.show.id)
        let encoded = try coder.encodeDocument(model, revision: 1, publicationID: UUID())
        let destination = rig.url()
        var reportedUncertain = false
        do {
            _ = try rig.publisher.publish(
                encoded: encoded, key: key, to: destination, target: .newLocation,
                retainPrior: false, isCancelled: { false },
                step: .external { url, data in
                    try data.write(to: url, options: .atomic)
                    throw POSIXError(.EIO)
                },
                followUp: .none
            )
            Issue.record("An external safe-write error was reported as success")
        } catch {
            if case .acknowledgementUncertain = error as? PublicationError {
                reportedUncertain = true
            } else {
                Issue.record("Expected acknowledgement uncertainty, got \(error)")
            }
        }
        #expect(reportedUncertain)
        #expect(try Data(contentsOf: destination) == encoded.data)
    }

    @Test func unreadableOriginCannotSkipRequiredPriorRetention() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2710)
        let key = DocumentKey.show(model.show.id)
        let origin = rig.url()
        let initial = try rig.publisher.publish(model, revision: 1, key: key, to: origin, target: .newLocation)
        let oldBytes = try Data(contentsOf: origin)
        let publisher = DocumentPublisher(coder: coder, ops: FaultingFileOperations(readFailureURL: origin),
                                          coordination: NSFileCoordination(), recovery: rig.recovery)
        var refused = false
        do {
            _ = try publisher.publish(model.renamingShow(to: "Blocked"), revision: 2, key: key, to: origin,
                                      target: .inPlace(expectedBase: initial.fingerprint))
        } catch {
            if case .failed(stage: .candidateValidated, _, _) = error as? PublicationError {
                refused = true
            } else {
                Issue.record("Expected a pre-write retention failure, got \(error)")
            }
        }
        #expect(refused)
        #expect(try Data(contentsOf: origin) == oldBytes)
    }
}

private struct FaultingFileOperations: FileOperations {
    private let base = LocalFileOperations()
    var readFailureURL: URL?
    var removeFails = false
    func read(_ url: URL) throws -> Data {
        if url.standardizedFileURL == readFailureURL?.standardizedFileURL { throw POSIXError(.EIO) }
        return try base.read(url)
    }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
    func remove(_ url: URL) throws {
        if removeFails { throw POSIXError(.EACCES) }
        try base.remove(url)
    }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL { try base.makeStagingDirectory(appropriateFor: destination) }
}
