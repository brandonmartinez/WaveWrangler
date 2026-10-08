import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// C2b recovery presentation (#84): records are set aside as an offer on open, assessed against the publication
/// on disk, and only removed by an explicit resolution. Damaged and unknown-newer records are reported and kept.
@Suite("C2b edit-checkpoint offer")
struct EditCheckpointOfferTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    func assess(_ rig: Rig, _ key: DocumentKey, _ model: ShowDocumentModel, onDisk: RevisionFingerprint?) -> EditCheckpointOffer<ShowDocumentModel> {
        let showID = model.show.id
        return EditCheckpointOffer.assess(rig.recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue, onDisk: onDisk,
                                          coder: coder, belongsToDocument: { $0.show.id == showID })
    }

    @Test func offerSurvivesLaterSavesAndCheckpointsUntilResolved() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 840)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let key = DocumentKey.show(model.show.id)
        let unsaved = try current.renamingShow(to: "Unsaved before the crash")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(unsaved, revision: 3), base: base, schemaVersion: 1, for: key)

        // Open: set aside as an offer.
        try rig.recovery.setAsideEditCheckpoints(for: key)
        #expect(rig.recovery.editCheckpoints(for: key).isEmpty)
        let offer = assess(rig, key, model, onDisk: base)
        let candidate = try #require(offer.candidate)
        #expect(candidate.relation == .basedOnCurrent)
        #expect(candidate.payload == unsaved)
        #expect(offer.problems.isEmpty && offer.usable.count == 1)
        // Restoring is an in-memory edit; nothing on disk changed.
        guard case let .editable(onDisk, _) = rig.opener.open(url) else { Issue.record("not editable"); return }
        #expect(onDisk.payload == current)

        // The new session's own checkpoints, their pruning and "discard after a verified save" leave the offer alone.
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: "New session"), revision: 3), base: base, schemaVersion: 1, for: key)
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: "New session 2"), revision: 3), base: base, schemaVersion: 1, for: key)
        try rig.recovery.discardEditCheckpoints(for: key)
        #expect(rig.recovery.offeredEditCheckpoints(for: key).count == 1)

        // After another version is published, the same record is "based on an older revision" (never restored over it).
        let r3 = try rig.publisher.publish(current.renamingShow(to: "Saved elsewhere"), revision: 3, key: key, to: url, target: .inPlace(expectedBase: base))
        #expect(offer.reassessed(against: r3.fingerprint).candidate?.relation == .basedOnOtherRevision)
        #expect(assess(rig, key, model, onDisk: r3.fingerprint).candidate?.relation == .basedOnOtherRevision)

        // Explicit resolution removes exactly the offered record.
        try rig.recovery.discardOfferedEditCheckpoints([candidate.url], for: key)
        #expect(rig.recovery.offeredEditCheckpoints(for: key).isEmpty)
        #expect(assess(rig, key, model, onDisk: r3.fingerprint).isEmpty)
    }

    @Test func damagedWrongDocumentAndNewerRecordsAreReportedKeptAndNeverApplied() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 841)
        let (current, base) = try rig.seedTwoRevisions(model, at: rig.url())
        let key = DocumentKey.show(model.show.id)
        let valid = try current.renamingShow(to: "Valid unsaved")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(valid, revision: 3), base: base, schemaVersion: 1, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)

        // Record written by a newer WaveWrangler (record schema), and a snapshot in a newer envelope schema.
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: "Newer record"), revision: 3), base: base, schemaVersion: 99, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let newerSnapshot = try Self.patch(coder.encode(current.renamingShow(to: "Newer snapshot"), revision: 3)) { $0["schemaVersion"] = 42 }
        try rig.recovery.writeEditCheckpoint(snapshot: newerSnapshot, base: base, schemaVersion: 1, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        // Another show's snapshot under this show's key, and a snapshot whose payload no longer matches its checksum.
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(Fixtures.show(seed: 842), revision: 1), base: base, schemaVersion: 1, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let tampered = try Self.patch(coder.encode(current.renamingShow(to: "Tampered"), revision: 3)) { envelope in
            var payload = envelope["payload"] as! [String: Any]
            var show = payload["show"] as! [String: Any]
            show["title"] = "Changed after checksum"
            payload["show"] = show
            envelope["payload"] = payload
        }
        try rig.recovery.writeEditCheckpoint(snapshot: tampered, base: base, schemaVersion: 1, for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        // An unreadable/damaged record file.
        let offeredFolder = try #require(rig.recovery.offeredEditCheckpoints(for: key).first?.url.deletingLastPathComponent())
        try Data("{broken".utf8).write(to: offeredFolder.appending(path: "0000000000000-damaged.wwedit"))

        let offer = assess(rig, key, model, onDisk: base)
        #expect(offer.candidate?.payload == valid, "only the valid record is ever offered")
        #expect(offer.problems.count == 5)
        let newer = offer.problems.filter { if case .newerFormat = $0 { true } else { false } }
        #expect(newer.count == 2)
        #expect(offer.problems.contains { if case .newerFormat(_, 42, _) = $0 { true } else { false } })
        #expect(offer.problems.contains { if case .newerFormat(_, 99, _) = $0 { true } else { false } })

        // Discarding the offer removes the valid record only; every problem record is kept.
        try rig.recovery.discardOfferedEditCheckpoints([try #require(offer.candidate).url], for: key)
        let after = assess(rig, key, model, onDisk: base)
        #expect(after.candidate == nil && after.problems.count == 5)
        for problem in after.problems { #expect(FileManager.default.fileExists(atPath: problem.url.path)) }
    }

    @Test func newestFirstAndActionsResolveOnlyTheShownRecord() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 843)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let key = DocumentKey.show(model.show.id)
        let older = try current.renamingShow(to: "Unsaved on r2")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(older, revision: 3), base: base, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 1_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let r3 = try rig.publisher.publish(current.renamingShow(to: "r3"), revision: 3, key: key, to: url, target: .inPlace(expectedBase: base))
        let newer = try current.renamingShow(to: "Unsaved on r3")
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(newer, revision: 4), base: r3.fingerprint, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 2_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)

        let offer = assess(rig, key, model, onDisk: r3.fingerprint)
        let candidate = try #require(offer.candidate)
        #expect(candidate.payload == newer && candidate.relation == .basedOnCurrent)
        // After the newest is restored (or discarded), the older record is still offered, honestly labelled.
        let next = offer.excluding([candidate.url])
        #expect(next.candidate?.payload == older && next.candidate?.relation == .basedOnOtherRevision)
    }

    /// Two crashed sessions on the same base leave two records with different edits. Every action applies to the
    /// shown record only; the other is offered next and is never deleted along with it.
    @Test func twoSessionsOnTheSameBaseAreOfferedOneAfterAnother() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 845)
        let (current, base) = try rig.seedTwoRevisions(model, at: rig.url())
        let key = DocumentKey.show(model.show.id)
        let sessionA = try current.renamingShow(to: "Session A edits")
        let sessionB = try current.renamingShow(to: "Session B edits")
        // Session A: checkpoint, crash, reopen (set aside). Session B: the same.
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(sessionA, revision: 3), base: base, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 1_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(sessionB, revision: 3), base: base, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 2_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)

        let offer = assess(rig, key, model, onDisk: base)
        #expect(offer.usable.map(\.payload) == [sessionB, sessionA])
        #expect(offer.usable.allSatisfy { $0.relation == .basedOnCurrent })
        let shown = try #require(offer.candidate)
        // Restore (or Open as Separate Copy) of B: A is still offered.
        #expect(offer.excluding([shown.url]).candidate?.payload == sessionA)
        // Discard of B deletes B only.
        try rig.recovery.discardOfferedEditCheckpoints([shown.url], for: key)
        let after = assess(rig, key, model, onDisk: base)
        #expect(after.usable.map(\.payload) == [sessionA])
    }

    /// Re-review probe: restore B, then A (another session, same base) must not be restorable over B; otherwise
    /// a save holding only A's edits would resolve (delete) both and lose B.
    @Test func secondSessionIsCopyOnlyWhileARestoreIsInEffect() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 846)
        let (current, base) = try rig.seedTwoRevisions(model, at: rig.url())
        let key = DocumentKey.show(model.show.id)
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: "A"), revision: 3), base: base, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 1_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current.renamingShow(to: "B"), revision: 3), base: base, schemaVersion: 1, for: key,
                                             at: Date(timeIntervalSince1970: 2_000))
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let offer = assess(rig, key, model, onDisk: base)
        let b = try #require(offer.candidate)
        #expect(b.payload.show.title == "B" && offer.candidateMode(restoreInEffect: false) == .restore)
        // B restored: A (same base) is offered, but copy-only.
        let afterB = offer.excluding([b.url])
        let a = try #require(afterB.candidate)
        #expect(a.payload.show.title == "A" && a.relation == .basedOnCurrent)
        #expect(afterB.candidateMode(restoreInEffect: true) == .copyOnlyWhileAnotherRestoreIsInEffect)
        // Saving resolves B only; A stays on disk and is offered again (restorable once B's restore is saved).
        var restores = RestoredEditCheckpoints.State<ShowDocumentModel>()
        restores.mark(b.url, snapshot: b.payload, generation: restores.currentGeneration)
        let start = restores.startingSave()
        let resolved = restores.resolved(started: start, published: b.payload, current: b.payload)
        #expect(resolved == [b.url])
        // Even if two were ever marked restored, a save would delete neither.
        restores.mark(a.url, snapshot: a.payload, generation: restores.currentGeneration)
        #expect(restores.resolved(started: restores.startingSave(), published: b.payload, current: b.payload).isEmpty)
        try rig.recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        #expect(assess(rig, key, model, onDisk: base).usable.map(\.payload.show.title) == ["A"])
    }

    /// A verified save resolves a restored record only if it contains the restore (#84 review).
    @Test func restoredRecordsResolveOnlyWhenThePublicationContainsTheRestore() throws {
        let a = URL(fileURLWithPath: "/offered/a.wwedit"), b = URL(fileURLWithPath: "/offered/b.wwedit")
        let base = Fixtures.show(seed: 847)
        let restored = try base.renamingShow(to: "Restored")
        let unrelated = try base.renamingShow(to: "Unrelated")
        var state = RestoredEditCheckpoints.State<ShowDocumentModel>()
        let generation = state.currentGeneration
        state.mark(a, snapshot: restored, generation: generation)
        let start = state.startingSave()
        // Restored before the save started, still restored, nothing changed during the save: resolved.
        #expect(state.resolved(started: start, published: restored, current: restored) == [a])
        #expect(state.resolved(started: start, published: unrelated, current: unrelated).isEmpty)
        // The restore was undone during or before completion: kept.
        state.unmark(a, generation: generation)
        #expect(state.resolved(started: start, published: restored, current: restored).isEmpty)
        // The publication was captured before the restore and finished after it: kept.
        let beforeRestore = state.startingSave()
        state.mark(a, snapshot: restored, generation: generation)
        #expect(state.resolved(started: beforeRestore, published: restored, current: restored).isEmpty)
        // Edits (or an undo) happened during the save, so the published candidate isn't the current model: kept.
        #expect(state.resolved(started: start, published: restored, current: unrelated).isEmpty)
        // Only the record restored at both ends (at most one restore is ever in effect).
        state.unmark(a, generation: generation)
        state.mark(b, snapshot: restored, generation: generation)
        #expect(state.resolved(started: state.startingSave(), published: restored, current: restored) == [b])
        #expect(state.resolved(started: start, published: restored, current: restored).isEmpty)
        // Repeated restore after a disk read has a new epoch; stale undo/redo cannot re-mark the prior restore.
        state.supersede()
        state.mark(a, snapshot: restored, generation: generation)
        #expect(state.isEmpty)
        state.mark(b, snapshot: restored, generation: state.currentGeneration)
        #expect(state.resolved(started: start, published: restored, current: restored).isEmpty)
    }

    @Test func revertThenUnrelatedSaveRetainsDeletionCheckpointForReopen() throws {
        let rig = Rig()
        let base = Fixtures.show(seed: 848)
        let url = rig.url()
        let (current, fingerprint) = try rig.seedTwoRevisions(base, at: url)
        let key = DocumentKey.show(current.show.id)
        let restored = try current.renamingShow(to: "Recovered")
        try rig.recovery.writeEditCheckpoint(
            snapshot: coder.encode(restored, revision: 3), base: fingerprint,
            schemaVersion: SchemaVersion.show, for: key
        )
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let candidate = try #require(assess(rig, key, current, onDisk: fingerprint).candidate)
        var state = RestoredEditCheckpoints.State<ShowDocumentModel>()
        state.mark(candidate.url, snapshot: candidate.payload, generation: state.currentGeneration)
        #expect(state.urls == [candidate.url])

        // Revert reads the saved model; even a save captured before it may not resolve this record.
        let beforeRevert = state.startingSave()
        guard case let .editable(reloaded, _) = rig.opener.open(url) else {
            Issue.record("revert did not read the saved document"); return
        }
        #expect(reloaded.payload == current)
        state.supersede()
        #expect(state.resolved(started: beforeRevert, published: restored, current: restored).isEmpty)
        let unrelated = try reloaded.payload.renamingShow(to: "Unrelated save")
        let afterRevert = state.startingSave()
        let saved = try rig.publisher.publish(unrelated, revision: 3, key: key, to: url, target: .inPlace(expectedBase: fingerprint))
        #expect(state.resolved(started: afterRevert, published: unrelated, current: unrelated).isEmpty)
        #expect(rig.recovery.offeredEditCheckpoints(for: key).count == 1)
        guard case let .editable(reopened, _) = rig.opener.open(url) else {
            Issue.record("saved show did not reopen"); return
        }
        #expect(reopened.payload == unrelated)
        #expect(assess(rig, key, current, onDisk: saved.fingerprint).candidate?.url == candidate.url)
        #expect(assess(rig, key, current, onDisk: saved.fingerprint).candidate?.relation == .basedOnOtherRevision)
    }

    @Test func cancelledOrRefusedSaveRetainsRestoredOfferUntilExactPublication() throws {
        let rig = Rig()
        let base = Fixtures.show(seed: 849)
        let url = rig.url()
        let (current, fingerprint) = try rig.seedTwoRevisions(base, at: url)
        let key = DocumentKey.show(current.show.id)
        let restored = try current.renamingShow(to: "Recovered")
        try rig.recovery.writeEditCheckpoint(
            snapshot: coder.encode(restored, revision: 3), base: fingerprint,
            schemaVersion: SchemaVersion.show, for: key
        )
        try rig.recovery.setAsideEditCheckpoints(for: key)
        let candidate = try #require(assess(rig, key, current, onDisk: fingerprint).candidate)
        var state = RestoredEditCheckpoints.State<ShowDocumentModel>()
        state.mark(candidate.url, snapshot: restored, generation: state.currentGeneration)
        let started = state.startingSave()
        #expect(throws: PublicationError.cancelled) {
            try rig.publisher.publish(restored, revision: 3, key: key, to: url,
                                      target: .inPlace(expectedBase: fingerprint), isCancelled: { true })
        }
        #expect(throws: PublicationError.self) {
            try rig.publisher.publish(restored, revision: 3, key: key, to: url,
                                      target: .inPlace(expectedBase: RevisionFingerprint(of: Data())))
        }
        // Neither error has a verified receipt: no resolution is permitted.
        #expect(state.urls == [candidate.url])
        #expect(rig.recovery.offeredEditCheckpoints(for: key).count == 1)
        guard case let .editable(unchanged, _) = rig.opener.open(url) else {
            Issue.record("a failed save changed the document"); return
        }
        #expect(unchanged.payload == current)

        let published = try rig.publisher.publish(
            restored, revision: 3, key: key, to: url, target: .inPlace(expectedBase: fingerprint)
        )
        let resolved = state.resolved(started: started, published: restored, current: restored)
        #expect(resolved == [candidate.url])
        try rig.recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        state.unmark(candidate.url, generation: state.currentGeneration)
        #expect(state.isEmpty && rig.recovery.offeredEditCheckpoints(for: key).isEmpty)
        guard case let .editable(reopened, _) = rig.opener.open(url) else {
            Issue.record("restored show did not reopen"); return
        }
        #expect(reopened.payload == restored && reopened.publication == published.publication)
    }

    @Test func discardNeverDeletesOutsideTheOfferedRecords() throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 844)
        let url = rig.url()
        let (current, base) = try rig.seedTwoRevisions(model, at: url)
        let key = DocumentKey.show(model.show.id)
        try rig.recovery.writeEditCheckpoint(snapshot: coder.encode(current, revision: 3), base: base, schemaVersion: 1, for: key)
        let live = rig.recovery.root.appending(path: "edit-checkpoints/\(key.rawValue)")
        let liveFile = try #require(try FileManager.default.contentsOfDirectory(at: live, includingPropertiesForKeys: nil).first)
        try rig.recovery.discardOfferedEditCheckpoints([url, liveFile], for: key)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: liveFile.path))
        // Nothing to set aside is a no-op; setting aside twice never overwrites.
        try rig.recovery.setAsideEditCheckpoints(for: key)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        #expect(rig.recovery.offeredEditCheckpoints(for: key).count == 1)
    }

    static func patch(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
