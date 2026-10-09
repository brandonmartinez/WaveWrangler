import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Explicit recovery retirement")
struct CheckpointRetirementTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    @Test func saveAsRetainsBothOriginAndDestinationRecoveryLookups() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2711)
        let key = DocumentKey.show(model.show.id)
        let origin = rig.url("Origin.wwshow")
        let destination = rig.url("Destination.wwshow")
        let original = try coder.encode(model, revision: 1)
        let prior = try rig.recovery.retainCheckpoint(original, for: key)
        try rig.recovery.recordLocation(origin, for: key)
        try rig.recovery.recordLocation(destination, for: key)
        #expect(rig.recovery.keys(forLocation: origin).contains(key))
        #expect(rig.recovery.keys(forLocation: destination).contains(key))
        #expect(try rig.recovery.bytes(of: prior) == original)
        let reopened = RecoveryStore(root: rig.recovery.root)
        #expect(reopened.keys(forLocation: origin).contains(key))
        #expect(reopened.keys(forLocation: destination).contains(key))
    }

    @Test func legacyOriginHintSurvivesANewDestinationHint() throws {
        let rig = Rig()
        let key = DocumentKey.show(Fixtures.show(seed: 2712).show.id)
        let origin = rig.url("Legacy.wwshow")
        let destination = rig.url("New.wwshow")
        let legacy = rig.recovery.root.appending(path: "locations/\(key.rawValue).json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["path": origin.standardizedFileURL.path]).write(to: legacy)
        let bytes = try Data(contentsOf: legacy)
        try rig.recovery.recordLocation(destination, for: key)
        #expect(try Data(contentsOf: legacy) == bytes)
        #expect(rig.recovery.keys(forLocation: origin) == [key])
        #expect(rig.recovery.keys(forLocation: destination) == [key])
    }

    @Test func unrelatedLocationFilesDoNotHideRetainedUnsavedCopies() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2715)
        let key = DocumentKey.show(model.show.id)
        let location = rig.url("Damaged.wwshow")
        let snapshot = try coder.encode(model.renamingShow(to: "Unsaved"), revision: 2)
        try rig.recovery.writeEditCheckpoint(snapshot: snapshot, base: nil,
                                             schemaVersion: coder.format.currentSchemaVersion, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        try rig.recovery.recordLocation(location, for: key)
        let locations = rig.recovery.root.appending(path: "locations")
        try Data("Finder metadata".utf8).write(to: locations.appending(path: ".DS_Store"))
        try Data("unrelated".utf8).write(to: locations.appending(path: "unrelated.txt"))

        #expect(try rig.recovery.checkedKeys(forLocation: location) == [key])
        let offered = try #require(try rig.recovery.checkedOfferedEditCheckpoints(for: key).first)
        let selected = try rig.recovery.selectRecord(.offeredEditCheckpoint, at: offered.url, for: key)
        let retained = try EditCheckpointRecord.decode(rig.recovery.readSelectedRecord(selected))
        #expect(retained.snapshot == snapshot)
    }

    @Test func failedLocationHintAfterPublicationReportsUncertaintyNotSuccess() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2714)
        let destination = rig.url("Hint Failure.wwshow")
        let recovery = RecoveryStore(root: rig.recovery.root, ops: FaultingFileOperations(writeNewFails: true))
        let publisher = DocumentPublisher(coder: coder, recovery: recovery)
        var uncertain = false
        do {
            _ = try publisher.publish(model, revision: 1, key: .show(model.show.id),
                                      to: destination, target: .newLocation, retainPrior: false)
            Issue.record("a missing recovery-location hint was reported as a verified save")
        } catch {
            if case .acknowledgementUncertain = error as? PublicationError { uncertain = true }
            else { Issue.record("expected uncertainty, got \(error)") }
        }
        #expect(uncertain)
        #expect(try coder.decode(Data(contentsOf: destination)).payload == model)
    }

    @Test func damagedC2bSnapshotCannotBeDecodedAndItsSelectedRawBytesRemain() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2713)
        let key = DocumentKey.show(model.show.id)
        var snapshot = try coder.encode(model, revision: 2)
        let index = try #require(snapshot.firstIndex(of: UInt8(ascii: "S")))
        snapshot[index] = UInt8(ascii: "T")
        try rig.recovery.writeEditCheckpoint(snapshot: snapshot, base: nil,
                                             schemaVersion: coder.format.currentSchemaVersion, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let stored = try #require(try rig.recovery.checkedOfferedEditCheckpoints(for: key).first)
        let offer = EditCheckpointOffer.assess([stored], documentID: key.rawValue, onDisk: nil,
                                                coder: coder, belongsToDocument: { $0.show.id == model.show.id })
        #expect(offer.usable.isEmpty && offer.problems == [.damaged(stored.url)])
        let selected = try rig.recovery.selectRecord(.offeredEditCheckpoint, at: stored.url, for: key)
        let raw = try rig.recovery.readSelectedRecord(selected)
        #expect(try EditCheckpointRecord.decode(raw).snapshot == snapshot)
        #expect(throws: PersistenceError.self) { try coder.decode(snapshot) }
        #expect(try rig.recovery.readSelectedRecord(selected) == raw)
    }

    @Test func olderPriorAndDamagedPriorRemainDistinctUnderSelection() throws {
        let rig = Rig()
        let golden = ShowSchema1Fixtures.placeholderOnly
        let model = try ShowSchemaMigration.decodeUpgradingOlder(golden).payload
        let key = DocumentKey.show(model.show.id)
        let prior = try rig.recovery.retainCheckpoint(golden, for: key)
        let older = try rig.recovery.selectRecord(.priorCheckpoint, at: prior.url, for: key,
                                                  allowingDamagedRecord: true)
        #expect(try ShowSchemaMigration.decodeUpgradingOlder(rig.recovery.readSelectedRecord(older)).payload == model)
        let broken = prior.url.deletingLastPathComponent().appending(path: "broken.wwcheckpoint")
        try Data("damaged".utf8).write(to: broken)
        let brokenSelection = try rig.recovery.selectRecord(.priorCheckpoint, at: broken, for: key,
                                                           allowingDamagedRecord: true)
        #expect(throws: PersistenceError.self) {
            try ShowSchemaMigration.decodeUpgradingOlder(rig.recovery.readSelectedRecord(brokenSelection))
        }
        #expect(try rig.recovery.readSelectedRecord(older) == golden)
        #expect(try rig.recovery.readSelectedRecord(brokenSelection) == Data("damaged".utf8))
    }

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
        #expect(rig.recovery.keys(forLocation: origin).contains(key))
        #expect(rig.recovery.keys(forLocation: destination).contains(key))
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

    @Test func changedOriginPreservesExplicitSaveWithoutAnyEditCheckpoint() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2716)
        let url = rig.url()
        let initial = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id),
                                                to: url, target: .newLocation)
        let session = CanonicalDocumentSession(key: .show(model.show.id), url: url, payload: model,
                                               base: initial.fingerprint, revision: 1, publisher: rig.publisher,
                                               gate: AutosaveGate(AutosavePreference(enabled: false)))
        let competing = try model.renamingShow(to: "Another writer")
        _ = try rig.publisher.publish(competing, revision: 2, key: session.key, to: url,
                                      target: .inPlace(expectedBase: initial.fingerprint))
        let competingBytes = try Data(contentsOf: url)
        let mine = try model.renamingShow(to: "My explicit Save")
        try await session.edit { _ in mine }
        #expect(rig.recovery.latestEditCheckpoint(for: session.key) == nil)

        guard case let .failure(.conflict(conflict)) = await session.save() else {
            Issue.record("The changed-origin Save must preserve the competing candidate as a conflict")
            return
        }
        let candidate = try #require(conflict.preservedCandidate)
        #expect(try coder.decode(Data(contentsOf: candidate)).payload == mine)
        #expect(try Data(contentsOf: url) == competingBytes)
        #expect(await session.isDirty)
        #expect(await session.status.state == .conflict(onDiskRevision: 2, missing: false))
    }

    @Test func failedExplicitSaveOfCleanSessionBecomesDirty() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2719)
        let key = DocumentKey.show(model.show.id)
        let url = rig.url()
        let first = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let session = CanonicalDocumentSession(key: key, url: url, payload: model,
                                               base: first.fingerprint, revision: 1, publisher: rig.publisher)
        #expect(await !session.isDirty)
        let other = try model.renamingShow(to: "Competing")
        _ = try rig.publisher.publish(other, revision: 2, key: key, to: url,
                                      target: .inPlace(expectedBase: first.fingerprint))

        guard case .failure(.conflict) = await session.save() else {
            Issue.record("The changed file must refuse an explicit Save")
            return
        }
        #expect(await session.isDirty)
    }

    @Test func failedSaveAsOfCleanSessionKeepsOriginalAndBecomesDirty() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2720)
        let key = DocumentKey.show(model.show.id)
        let origin = rig.url()
        let first = try rig.publisher.publish(model, revision: 1, key: key, to: origin, target: .newLocation)
        let originalBytes = try Data(contentsOf: origin)
        let publisher = DocumentPublisher(coder: coder, ops: FaultingFileOperations(writeNewFails: true),
                                          recovery: rig.recovery)
        let session = CanonicalDocumentSession(key: key, url: origin, payload: model,
                                               base: first.fingerprint, revision: 1, publisher: publisher)
        let destination = rig.url("Failed copy.wwshow")
        #expect(await !session.isDirty)

        guard case .failure(.failed) = await session.saveAs(destination) else {
            Issue.record("A failed Save As must report the write failure")
            return
        }
        #expect(await session.isDirty)
        guard case .saveFailed(_, .diskFull, _) = await session.status.state else {
            Issue.record("A failed Save As must show its write failure rather than the old clean status")
            return
        }
        #expect(await session.url == origin)
        #expect(try Data(contentsOf: origin) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func failedConflictPreservationIsReportedAsFailureNotAPreservedConflict() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 2717)
        let key = DocumentKey.show(model.show.id)
        let url = rig.url()
        let original = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        let competing = try model.renamingShow(to: "Competing")
        _ = try rig.publisher.publish(competing, revision: 2, key: key, to: url,
                                      target: .inPlace(expectedBase: original.fingerprint))
        let competingBytes = try Data(contentsOf: url)
        let failedRecovery = RecoveryStore(root: rig.recovery.root, ops: FaultingFileOperations(writeNewFails: true))
        let publisher = DocumentPublisher(coder: coder, recovery: failedRecovery)
        do {
            _ = try publisher.publish(model.renamingShow(to: "Mine"), revision: 2, key: key, to: url,
                                      target: .inPlace(expectedBase: original.fingerprint))
            Issue.record("A conflict with no recoverable candidate was reported as saved")
        } catch {
            guard case .failed(stage: .priorRetained, _, _) = error as? PublicationError else {
                Issue.record("The missing conflict backup was hidden: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: url) == competingBytes)
    }

    @Test func conflictCandidateMustReadBackBeforeReportingPreserved() throws {
        let rig = Rig()
        let key = DocumentKey.show(Fixtures.show(seed: 2718).show.id)
        let bytes = Data("unsaved candidate".utf8)
        let digest = RevisionFingerprint(of: bytes).shortDigest
        let url = rig.recovery.root.appending(path: "conflicts/\(key.rawValue)/\(digest).wwconflict")
        let store = RecoveryStore(root: rig.recovery.root, ops: FaultingFileOperations(readFailureURL: url))

        #expect(throws: POSIXError.self) {
            try store.preserveConflictCandidate(bytes, for: key)
        }
        #expect(try Data(contentsOf: url) == bytes)
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
        guard case let .failure(.conflict(conflict)) = await unknown.save(), conflict.onDisk == nil,
              let preserved = conflict.preservedCandidate,
              try coder.decode(Data(contentsOf: preserved)).payload.show.title == "Keep dirty" else {
            Issue.record("missing origin was not refused with a preserved candidate")
            return
        }
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
        #expect(throws: CocoaError.self) { _ = try rig.recovery.readSelectedRecord(selection) }
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
    var writeNewFails = false
    func read(_ url: URL) throws -> Data {
        if url.standardizedFileURL == readFailureURL?.standardizedFileURL { throw POSIXError(.EIO) }
        return try base.read(url)
    }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws {
        if writeNewFails { throw POSIXError(.ENOSPC) }
        try base.writeNew(data, to: url)
    }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
    func remove(_ url: URL) throws {
        if removeFails { throw POSIXError(.EACCES) }
        try base.remove(url)
    }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL { try base.makeStagingDirectory(appropriateFor: destination) }
}
