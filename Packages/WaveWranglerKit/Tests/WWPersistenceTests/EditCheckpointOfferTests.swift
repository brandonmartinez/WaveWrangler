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
        let resolved = RestoredEditCheckpoints.resolved(byPublicationStartedWith: [b.url], restoredNow: [b.url], publishedEqualsCurrent: true)
        #expect(resolved == [b.url])
        // Even if two were ever marked restored, a save would delete neither.
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [a.url, b.url], restoredNow: [a.url, b.url], publishedEqualsCurrent: true).isEmpty)
        try rig.recovery.discardOfferedEditCheckpoints(Array(resolved), for: key)
        #expect(assess(rig, key, model, onDisk: base).usable.map(\.payload.show.title) == ["A"])
    }

    /// A verified save resolves a restored record only if it contains the restore (#84 review).
    @Test func restoredRecordsResolveOnlyWhenThePublicationContainsTheRestore() {
        let a = URL(fileURLWithPath: "/offered/a.wwedit"), b = URL(fileURLWithPath: "/offered/b.wwedit")
        // Restored before the save started, still restored, nothing changed during the save: resolved.
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [a], restoredNow: [a], publishedEqualsCurrent: true) == [a])
        // The restore was undone during or before completion: kept.
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [a], restoredNow: [], publishedEqualsCurrent: true).isEmpty)
        // The publication was captured before the restore and finished after it: kept.
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [], restoredNow: [a], publishedEqualsCurrent: true).isEmpty)
        // Edits (or an undo) happened during the save, so the published candidate isn't the current model: kept.
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [a], restoredNow: [a], publishedEqualsCurrent: false).isEmpty)
        // Only the record restored at both ends (at most one restore is ever in effect).
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [b], restoredNow: [b], publishedEqualsCurrent: true) == [b])
        #expect(RestoredEditCheckpoints.resolved(byPublicationStartedWith: [a], restoredNow: [b], publishedEqualsCurrent: true).isEmpty)
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
