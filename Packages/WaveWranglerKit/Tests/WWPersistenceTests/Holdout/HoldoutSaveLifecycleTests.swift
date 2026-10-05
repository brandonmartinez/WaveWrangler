import Darwin
import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

private typealias ShowSession = CanonicalDocumentSession<JSONEnvelopeCoder<ShowDocumentModel>>

/// A show document in a temp dir with a prior checkpoint (revisions 1 and 2 published).
private struct ShowCase {
    let rig: Rig
    let url: URL
    let key: DocumentKey
    let r1: ShowDocumentModel
    let r2: ShowDocumentModel
    let base: RevisionFingerprint

    init(_ rng: inout SeededGenerator, label: String, ops: any FileOperations = LocalFileOperations(), hooks: any PublicationHooks = NoPublicationHooks()) throws {
        let dir = TempDirectory(label)
        let clean = Rig(dir: dir)
        rig = (ops is LocalFileOperations && hooks is NoPublicationHooks) ? clean : Rig(ops: ops, hooks: hooks, dir: dir)
        url = clean.url()
        r1 = HoldoutGen.show(&rng)
        key = .show(r1.show.id)
        let first = try clean.publisher.publish(r1, revision: 1, key: key, to: url, target: .newLocation)
        r2 = try r1.renamingShow(to: r1.show.title + " r2")
        base = try clean.publisher.publish(r2, revision: 2, key: key, to: url, target: .inPlace(expectedBase: first.fingerprint)).fingerprint
    }

    func session(gate: AutosaveGate? = nil, publisher: DocumentPublisher<JSONEnvelopeCoder<ShowDocumentModel>>? = nil) -> ShowSession {
        ShowSession(key: key, url: url, payload: r2, base: base, revision: 2, publisher: publisher ?? rig.publisher, gate: gate)
    }

    var bytes: Data { (try? Data(contentsOf: url)) ?? Data() }
}

/// Applies `states` as successive edits to `session`; returns the final expected model.
@discardableResult
private func applyEdits(_ session: ShowSession, _ states: [ShowDocumentModel]) async -> ShowDocumentModel? {
    for state in states { await session.edit { _ in state } }
    return states.last
}

@Suite("M1 durability holdout — save lifecycle", .serialized, .enabled(if: Holdout.enabled, "WW_HOLDOUT=1"))
struct HoldoutSaveLifecycleTests {
    // MARK: DUR-001 explicit Save (new and existing document)

    @Test func dur001ExplicitSave() async {
        let result = await runFamily("M1-DUR-001", calibration: 10, holdout: 100) { _, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = Rig(label: "dur001")
            let model = HoldoutGen.show(&rng)
            let key = DocumentKey.show(model.show.id)
            let url = rig.url("Show-\(model.show.id).wwshow")
            // First Save to a new temp URL.
            let session = ShowSession(key: key, url: url, payload: model, base: nil, revision: 0, publisher: rig.publisher)
            guard case let .success(first) = await session.save() else { throw CaseFailure(description: "first save failed") }
            try check(first.revision == 1, "first revision \(first.revision)")
            // Library acknowledges the verified publication.
            let library = LibraryRig("dur001-lib")
            let store = library.store()
            _ = await store.load()
            _ = await store.acknowledgeShowPublication(model.show.id, title: model.show.title, publication: first.publication)
            let libraryRevisionBefore = decodeLibrary(library.containerFile)?.revision ?? -1
            // Edits, then explicit Save.
            let states = HoldoutGen.edits(1...20, on: model, &rng)
            let expected = await applyEdits(session, states)!
            try check(await session.status.state.isVerifiedOnDisk == false, "status claimed saved before the save")
            guard case let .success(second) = await session.save() else { throw CaseFailure(description: "explicit save failed") }
            let onDisk = try #require(decodeShow(url))
            try check(onDisk.payload == expected, "payload differs from the independently built expected value")
            try check(onDisk.revision == first.revision + 1 && onDisk.publication == second.publication, "revision/publication")
            let state = await session.status.state
            guard case .saved(second.revision, _) = state else { throw CaseFailure(description: "status \(state)") }
            let priors = try rig.recovery.validatedCheckpoints(for: key, coder: JSONEnvelopeCoder<ShowDocumentModel>.show)
            try check(priors.first?.document.payload == model && priors.first?.document.revision == 1, "prior revision not retained")
            _ = await store.acknowledgeShowPublication(model.show.id, title: expected.show.title, publication: second.publication)
            let libraryAfter = try #require(decodeLibrary(library.containerFile))
            try check(libraryAfter.revision == libraryRevisionBefore + 1, "library advanced \(libraryAfter.revision - libraryRevisionBefore) times")
            try check(libraryAfter.payload.entries.first { $0.showID == model.show.id }?.lastKnownPublication == second.publication, "library ack")
            return CaseResult("saved")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-003 autosave OFF

    @Test func dur003AutosaveOff() async {
        let result = await runFamily("M1-DUR-003", calibration: 10, holdout: 100, concurrency: 25) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur003")
            let gate = AutosaveGate(AutosavePreference(enabled: false, delaySeconds: [1.0, 2, 5][index % 3]))
            let session = show.session(gate: gate)
            let ran = Mutex(0)
            let scheduler = QuiescenceScheduler(gate: gate, queue: DispatchQueue(label: "dur003.\(index)")) { _ in ran.withLock { $0 += 1 } }
            let before = show.bytes
            await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))
            try check(scheduler.noteEdit() == false, "OFF scheduled work")
            // Queued automatic requests delivered while OFF complete as non-success.
            for _ in 0..<HoldoutGen.int(1...5, &rng) {
                guard case .failure(.cancelled) = await session.save(automatic: true) else { throw CaseFailure(description: "automatic save was not refused") }
            }
            try check(await session.writeEditCheckpoint() == false, "OFF wrote an edit checkpoint")
            try await Task.sleep(for: .milliseconds(1_300))   // bounded observation window
            try check(ran.withLock { $0 } == 0, "scheduled work ran")
            try check(show.bytes == before, "canonical bytes changed")
            try check(show.rig.recovery.editCheckpoints(for: show.key).isEmpty, "edit-checkpoint record exists")
            try check(await session.isDirty, "dirty cleared")
            try check(await session.status.state == .autosaveSkipped, "status \(await session.status.state)")
            return CaseResult("notPublished")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-004 toggle interleavings

    @Test func dur004ToggleInterleavings() async {
        let result = await runFamily("M1-DUR-004", calibration: 10, holdout: 100, concurrency: 50) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur004")
            let schedule = index % 2 == 0 ? "onToOff" : "offToOn"
            let gate = AutosaveGate(AutosavePreference(enabled: schedule == "onToOff", delaySeconds: 1))
            let session = show.session(gate: gate)
            let fired = LockedBox<ContinuousClock.Instant?>(nil)
            let published = LockedBox<ContinuousClock.Instant?>(nil)
            let scheduler = QuiescenceScheduler(gate: gate, queue: DispatchQueue(label: "dur004.\(index)")) { work in
                guard work == .publish else { return }
                fired.withLock { $0 = .now }
                Task {
                    if case .success = await session.save(automatic: true) { published.withLock { $0 = .now } }
                }
            }
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            if schedule == "onToOff" {
                scheduler.noteEdit()
                // Toggle OFF before, around or after the 1 s quiescent publication fires.
                try await Task.sleep(for: .milliseconds(HoldoutGen.int(0...1_400, &rng)))
                gate.preference.enabled = false
                let off = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(1_800))
                let onDisk = try #require(decodeShow(show.url), "mixed or unreadable revision")
                if let firedAt = fired.withLock({ $0 }), published.withLock({ $0 }) != nil {
                    // The gate is read when the timer fires; the timestamp is taken just after.
                    try check(firedAt <= off + .milliseconds(50), "automatic work started after OFF took effect")
                    try check(onDisk.payload == expected && onDisk.revision == 3, "published revision")
                    guard case .saved(3, _) = await session.status.state else { throw CaseFailure(description: "status \(await session.status.state)") }
                    try check(await !session.isDirty, "dirty after publication")
                    return CaseResult("publishedBeforeOff")
                }
                try check(onDisk.payload == show.r2 && onDisk.revision == 2, "published after OFF")
                try check(await session.isDirty, "dirty state lost")
                // Fired but refused at the automatic-save entry (OFF arrived in between) is also a skip.
                return CaseResult(fired.withLock { $0 } == nil ? "skippedAfterOff" : "skippedAtEntry")
            } else {
                try check(scheduler.noteEdit() == false, "OFF scheduled")
                try await Task.sleep(for: .milliseconds(HoldoutGen.int(0...600, &rng)))
                let on = ContinuousClock.now
                gate.preference.enabled = true
                scheduler.reschedulePending()
                let deadline = on + .seconds(2)
                while ContinuousClock.now < deadline + .seconds(1) {
                    if let doc = decodeShow(show.url), doc.payload == expected { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let onDisk = try #require(decodeShow(show.url))
                try check(onDisk.payload == expected, "pending edits not published")
                let latency = Stats.seconds((published.withLock { $0 } ?? .now) - on)
                try check(latency <= 2.0, "OFF→ON checkpoint after \(latency) s")
                return CaseResult("publishedAfterOn", seconds: latency)
            }
        }
        expectAllPassed(result)
    }

    // MARK: DUR-005 explicit Save while OFF

    @Test func dur005SaveWhileOff() async {
        let result = await runFamily("M1-DUR-005", calibration: 10, holdout: 100) { _, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur005")
            let gate = AutosaveGate(AutosavePreference(enabled: false))
            let session = show.session(gate: gate)
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            try check(await session.isDirty, "not dirty after edits")
            guard case let .success(receipt) = await session.save() else { throw CaseFailure(description: "explicit save failed") }
            let onDisk = try #require(decodeShow(show.url))
            try check(onDisk.payload == expected && onDisk.revision == 3 && onDisk.publication == receipt.publication, "published value")
            try check(await !session.isDirty, "still dirty")
            try check(gate.isEnabled == false, "OFF setting changed")
            return CaseResult("saved")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-007 conflict with another writer

    @Test func dur007ExternalWriterConflict() async {
        let result = await runFamily("M1-DUR-007", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur007")
            let session = show.session()
            let mine = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            // The other writer: a different valid revision, or a different document entirely.
            let variant = index % 2 == 0 ? "otherRevision" : "otherDocument"
            if variant == "otherRevision" {
                let theirs = try show.r2.renamingShow(to: "Theirs \(index)")
                _ = try Rig(dir: show.rig.dir).publisher.publish(theirs, revision: 3, key: show.key, to: show.url, target: .inPlace(expectedBase: show.base))
            } else {
                let other = HoldoutGen.show(&rng)
                try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(other, revision: 7).write(to: show.url, options: .atomic)
            }
            let theirBytes = show.bytes
            guard case let .failure(.conflict(conflict)) = await session.save() else { throw CaseFailure(description: "no conflict") }
            try check(show.bytes == theirBytes, "their revision overwritten")
            let preserved = try #require(conflict.preservedCandidate)
            try check(decodeShow(preserved)?.payload == mine, "my candidate not preserved")
            let (dirty, payload) = (await session.isDirty, await session.payload)
            try check(dirty && payload == mine, "my edits lost")
            guard case .conflict = await session.status.state else { throw CaseFailure(description: "status") }
            // Non-destructive choice: keep mine as a new document; theirs stays.
            guard case .success = await session.duplicate(to: show.rig.url("Mine-\(index).wwshow")) else { throw CaseFailure(description: "keep-mine copy failed") }
            try check(show.bytes == theirBytes, "copy touched their file")
            return CaseResult(variant)
        }
        expectAllPassed(result)
    }

    // MARK: DUR-010 offline / unavailable destination

    @Test func dur010UnavailableDestination() async {
        let result = await runFamily("M1-DUR-010", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur010")
            let session = show.session()
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            let original = show.bytes
            let folder = show.url.deletingLastPathComponent()
            let away = folder.deletingLastPathComponent().appending(path: "Away-\(index)", directoryHint: .isDirectory)
            let variant = ["folderOffline", "folderReadOnly", "filePermissionDenied", "pathUnresolvable"][index % 4]
            var restore: () throws -> Void = {}
            switch variant {
            case "folderOffline":
                try FileManager.default.moveItem(at: folder, to: away)
                restore = { try FileManager.default.moveItem(at: away, to: folder) }
            case "folderReadOnly":
                chmod(folder.path, 0o555)
                restore = { chmod(folder.path, 0o755) }
            case "filePermissionDenied":
                chmod(show.url.path, 0o000)
                restore = { chmod(show.url.path, 0o644) }
            default:
                try FileManager.default.moveItem(at: folder, to: away)
                try Data("not a folder".utf8).write(to: folder)
                restore = {
                    try FileManager.default.removeItem(at: folder)
                    try FileManager.default.moveItem(at: away, to: folder)
                }
            }
            let failure = await session.save()
            try restore()
            let reason: String
            switch failure {
            case let .failure(.failed(_, kind, _)): reason = kind.rawValue
            case let .failure(.conflict(conflict)) where conflict.onDisk == nil: reason = "missing"
            default: throw CaseFailure(description: "\(variant): \(failure)")
            }
            let expectedReason = ["folderOffline": "missing", "folderReadOnly": "permissionDenied",
                                  "filePermissionDenied": "permissionDenied", "pathUnresolvable": "missing"][variant]
            try check(reason == expectedReason, "\(variant) reason \(reason)")
            try check(show.bytes == original, "prior revision changed")
            try check(await session.isDirty, "dirty cleared on failure")
            try check(!(await session.status.state.isVerifiedOnDisk), "status claims saved")
            // Retry offered: succeeds once the destination is back.
            guard case .success = await session.save() else { throw CaseFailure(description: "retry failed") }
            try check(decodeShow(show.url)?.payload == expected, "retry value")
            return CaseResult("\(variant):\(reason)")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-011 cancel during save stages

    @Test func dur011CancelAtStages() async {
        let result = await runFamily("M1-DUR-011", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let show = try ShowCase(&rng, label: "dur011")
            let session = show.session()
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            let original = show.bytes
            let stage = ["beforePublish", "afterPublish"][index % 2]
            let operation = ["save", "saveAs"][(index / 2) % 2]
            let calls = Mutex(0)
            // The publisher consults cancellation right before publishing (call 1) and after it (call 2).
            let isCancelled: () -> Bool = {
                let call = calls.withLock { $0 += 1; return $0 }
                return stage == "beforePublish" ? true : call >= 2
            }
            let copy = show.rig.url("SaveAs-\(index).wwshow")
            let outcome = operation == "save" ? await session.save(isCancelled: isCancelled) : await session.saveAs(copy, isCancelled: isCancelled)
            if stage == "beforePublish" {
                guard case .failure(.cancelled) = outcome else { throw CaseFailure(description: "\(outcome)") }
                try check(show.bytes == original, "disk changed")
                try check(!FileManager.default.fileExists(atPath: copy.path), "Save As destination created")
                try check(await session.isDirty, "dirty cleared")
                return CaseResult("\(operation):cancelledBeforePublish")
            }
            guard case let .success(receipt) = outcome, receipt.followUpIncomplete else { throw CaseFailure(description: "\(outcome)") }
            let target = operation == "save" ? show.url : copy
            try check(decodeShow(target)?.payload == expected && decodeShow(target)?.publication == receipt.publication, "published revision")
            if operation == "save" {
                guard case let .savedFollowUpIncomplete(revision, _) = await session.status.state, revision == receipt.revision
                else { throw CaseFailure(description: "status \(await session.status.state)") }
            } else {
                try check(show.bytes == original, "original changed by Save As")
            }
            return CaseResult("\(operation):savedFollowUpIncomplete")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-012 retry after failure

    @Test func dur012Retry() async {
        let result = await runFamily("M1-DUR-012", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let boundary: PublicationBoundary = [.candidateValidated, .baseChecked, .stagedFlushed][index % 3]
            let code = [EIO, ENOSPC, ETIMEDOUT][(index / 3) % 3]
            let faults = FaultState(.failOnce(after: boundary, errno: code))
            let show = try ShowCase(&rng, label: "dur012", ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            let session = show.session()
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            guard case .failure(.failed) = await session.save() else { throw CaseFailure(description: "transient failure not reported") }
            try check(faults.fired, "fault did not fire")
            guard case .saveFailed = await session.status.state else { throw CaseFailure(description: "status after failure") }
            for _ in 0..<HoldoutGen.int(1...3, &rng) {
                let attempt = await session.save()
                if case .success = attempt { break }
                throw CaseFailure(description: "retry failed: \(attempt)")
            }
            let onDisk = try #require(decodeShow(show.url))
            try check(onDisk.payload == expected && onDisk.revision == 3, "retry published revision \(onDisk.revision)")
            let revisions = try show.rig.recovery.checkpoints(for: show.key).compactMap(\.fingerprint.revision)
            try check(revisions == [2, 1], "checkpoint revisions \(revisions)")
            guard case .saved(3, _) = await session.status.state else { throw CaseFailure(description: "final status") }
            return CaseResult("\(boundary.rawValue):retried")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-013 disk full (injected ENOSPC)

    @Test func dur013DiskFullInjected() async {
        let result = await runFamily("M1-DUR-013", calibration: 10, holdout: 100,
                                     notes: ["Injected ENOSPC only; the real-volume variant M1-DUR-013-real-volume is consent-blocked and not run."]) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let stage = ["stageWrite", "priorRetention", "editCheckpoint", "publication"][index % 4]
            let fault: Fault = switch stage {
            case "stageWrite": .failWrite(after: .baseChecked, errno: ENOSPC)
            case "priorRetention": .failWrite(after: .candidateValidated, errno: ENOSPC)
            case "publication": .failWrite(after: .stagedFlushed, errno: ENOSPC)
            default: .failAllWrites(errno: ENOSPC)
            }
            let faults = FaultState(fault)
            let show = try ShowCase(&rng, label: "dur013", ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            let session = show.session(gate: AutosaveGate(AutosavePreference(enabled: true)))
            await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))
            let original = show.bytes
            if stage == "editCheckpoint" {
                try check(await session.writeEditCheckpoint() == false, "edit checkpoint reported written")
                try check(show.rig.recovery.editCheckpoints(for: show.key).isEmpty, "partial edit-checkpoint record")
            } else {
                guard case let .failure(.failed(_, kind, _)) = await session.save() else { throw CaseFailure(description: "save did not fail") }
                try check(kind == .diskFull, "kind \(kind)")
                guard case .saveFailed(_, .diskFull, _) = await session.status.state else { throw CaseFailure(description: "status") }
            }
            try check(faults.fired, "fault did not fire")
            try check(show.bytes == original, "prior revision changed")
            try check(await session.isDirty, "dirty cleared")
            // Partial stage files are cleaned or ignored: the document and recovery records stay readable.
            show.rig.recovery.removeStagingLeftovers()
            try check(decodeShow(show.url)?.revision == 2, "current unreadable")
            let priors = try show.rig.recovery.validatedCheckpoints(for: show.key, coder: JSONEnvelopeCoder<ShowDocumentModel>.show)
            try check(priors.contains { $0.document.revision == 1 && $0.document.payload == show.r1 }, "prior checkpoint")
            return CaseResult(stage)
        }
        expectAllPassed(result)
    }

    // MARK: DUR-014 Save As

    @Test func dur014SaveAs() async {
        let result = await runFamily("M1-DUR-014", calibration: 10, holdout: 100,
                                     notes: ["Save As keeps the logical ShowID and changes the location (Duplicate assigns a new ShowID); recorded explicitly per case."]) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = ["success", "failure", "cancel"][index % 3]
            // Save As retains no prior, so failures are injected at the stage write and at the publication.
            let boundary: PublicationBoundary = [.baseChecked, .stagedFlushed][(index / 3) % 2]
            let faults = FaultState(variant == "failure" ? .failWrite(after: boundary, errno: EIO) : nil)
            let show = try ShowCase(&rng, label: "dur014", ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            let session = show.session()
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            let original = show.bytes
            let destination = show.rig.dir.sub("Elsewhere").appending(path: "Saved As \(index).wwshow")
            let library = LibraryRig("dur014-lib")
            let store = library.store()
            _ = await store.load()
            let outcome = await session.saveAs(destination, isCancelled: { variant == "cancel" })
            if case let .success(receipt) = outcome {
                _ = await store.acknowledgeShowPublication(expected.show.id, title: expected.show.title, publication: receipt.publication)
            }
            try check(show.bytes == original, "original changed")
            let entries = await store.library?.entries ?? []
            switch variant {
            case "success":
                guard case .success = outcome else { throw CaseFailure(description: "\(outcome)") }
                try check(decodeShow(destination)?.payload == expected, "Save As value")
                let (url, dirty) = (await session.url, await session.isDirty)
                try check(url == destination && !dirty, "session location")
                try check(decodeShow(destination)?.payload.show.id == show.r2.show.id, "ShowID semantics")
                try check(entries.map(\.showID) == [expected.show.id], "library entry")
                return CaseResult("success:sameShowIDNewLocation")
            default:
                if case .success = outcome { throw CaseFailure(description: "\(variant) succeeded") }
                try check(!FileManager.default.fileExists(atPath: destination.path) || decodeShow(destination) == nil, "orphan destination")
                let (url, payload, dirty) = (await session.url, await session.payload, await session.isDirty)
                try check(url == show.url && payload == expected && dirty, "edits/location lost")
                try check(entries.isEmpty, "orphan library entry")
                return CaseResult(variant == "cancel" ? "cancel" : "failure:\(boundary.rawValue)")
            }
        }
        expectAllPassed(result)
    }

    // MARK: DUR-015 acknowledgement-uncertain publication and reconcile

    @Test func dur015AcknowledgementUncertain() async {
        let result = await runFamily("M1-DUR-015", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = ["staleReadBack", "readBackError", "libraryAckFailure"][index % 3]
            let fault: Fault? = switch variant {
            case "staleReadBack": .staleReadBack
            case "readBackError": .failReadBack(errno: EIO)
            default: nil
            }
            let faults = FaultState(fault)
            let show = try ShowCase(&rng, label: "dur015", ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            // Library with aliases, collections, order and an unavailable entry, acknowledging revision 2.
            let others = HoldoutGen.shows(2...5, &rng)
            var libraryModel = HoldoutGen.library([show.r2] + others, &rng)
            libraryModel = LibraryReconciler.acknowledging(show.r2.show.id, title: show.r2.show.title, publication: try #require(show.base.publication), in: libraryModel)
            let libraryRig = LibraryRig("dur015-lib")
            let store = libraryRig.store()
            _ = await store.load()
            _ = try await store.update { var model = libraryModel; model.libraryID = $0.libraryID; return model }
            let libraryBefore = try #require(await store.library)
            let session = show.session()
            let expected = await applyEdits(session, HoldoutGen.edits(1...20, on: show.r2, &rng))!
            let followUp = PublicationFollowUp(acknowledgeLibrary: { _ in throw CaseFailure(description: "library acknowledgement interrupted") })
            let outcome = await session.save(followUp: variant == "libraryAckFailure" ? followUp : .none)
            let state = await session.status.state
            switch variant {
            case "libraryAckFailure":
                guard case let .success(receipt) = outcome, receipt.followUpIncomplete,
                      case .savedFollowUpIncomplete = state else { throw CaseFailure(description: "\(outcome) \(state)") }
            default:
                guard case .failure(.acknowledgementUncertain) = outcome, case .acknowledgementUncertain = state
                else { throw CaseFailure(description: "\(outcome) \(state)") }
                try check(state.title == "Save may have completed — reopen to verify", "status text \(state.title)")
            }
            try check(faults.fired || variant == "libraryAckFailure", "fault did not fire")
            try check(await store.library == libraryBefore, "library advanced on an unverified/unacknowledged save")
            // Explicit reopen/reconcile adopts the coherent on-disk revision.
            guard case let .editable(document, _) = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: show.rig.recovery).open(show.url, key: show.key)
            else { throw CaseFailure(description: "reopen") }
            try check(document.payload == expected, "on-disk revision is not the saved value")
            _ = await store.reconcile([show.r2.show.id: .available(title: document.payload.show.title, publication: document.publication)])
            let reconciled = try #require(await store.library)
            let entry = try #require(reconciled.entries.first { $0.showID == show.r2.show.id })
            try check(entry.lastKnownPublication == document.publication, "reconciled publication")
            try check(reconciled.collections == libraryBefore.collections && reconciled.recentShowIDs == libraryBefore.recentShowIDs, "collections/order/recents")
            try check(zip(reconciled.entries, libraryBefore.entries).allSatisfy { $0.alias == $1.alias && ($0.showID == show.r2.show.id || $0.unavailable == $1.unavailable) },
                      "aliases/unavailable entries")
            return CaseResult(variant)
        }
        expectAllPassed(result)
    }
}
