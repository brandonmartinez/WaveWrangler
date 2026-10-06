import Foundation
import Testing
import WWCore
@testable import WWTimeMap

/// #177: a clock approval is bound to the exact epoch ID and segments it approved. Editing the segments,
/// moving the approval to another epoch, or tampering with a persisted payload drops it, both in
/// `GroupTimeMap` compilation and when decoding persisted provenance.
@Suite("Clock approval binding")
struct ClockApprovalBindingTests {
    let fx = Fixture()
    let reference = try! IndependentClockReference(description: "synthetic certified clock anchors")
    let approved = [seg(q(0), q(1), q(1_000_001, 1_000_000), q(1, 10)), seg(q(1), q(2), .one, q(100_001, 1_000_000))]

    private func approval(_ epoch: RecordingEpochID, _ segments: [AffineClockSegment]) throws -> MapProvenance {
        .clockApproved(try ClockApproval(evaluator: "binding/1", reference: reference, measurements: passingMeasurements(), epoch: epoch, segments: segments))
    }

    /// Builds a group whose only non-reference epoch is `epoch` with exactly `segments` and `provenance`
    /// (no re-binding, unlike the `mapped` helper).
    private func group(_ epoch: RecordingEpochID, _ segments: [AffineClockSegment], _ provenance: MapProvenance) throws(TimeMapError) -> GroupTimeMap {
        let occurrence = fx.occurrence(frames: 48000)
        return try fx.otherGroup(
            epochs: [EpochClockMap(epoch: epoch, mapping: .mapped(segments: segments, provenance: provenance))],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, epoch)])]
        )
    }

    @Test func approvalForExactlyTheseSegmentsCompiles() throws {
        let epoch = RecordingEpochID()
        let compiled = try group(epoch, approved, approval(epoch, approved))
        #expect(compiled.epochs.first { $0.epoch == epoch }?.mapping == .mapped(segments: approved, provenance: try approval(epoch, approved)))
        guard case .clockApproved(let a) = try approval(epoch, approved) else { Issue.record("not approved"); return }
        #expect(a.epoch == epoch)
        #expect(a.segments == approved)
    }

    @Test func approvalForAnotherEpochIsRefused() throws {
        let epoch = RecordingEpochID(), other = RecordingEpochID()
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try group(epoch, approved, approval(other, approved)) }
    }

    /// Every kind of segment edit refuses the old approval, including an exact re-split that describes the
    /// same function: the binding is to the approved segments, not to a function they happen to share.
    @Test func editedSegmentsRefuseTheOldApproval() throws {
        let epoch = RecordingEpochID()
        let old = try approval(epoch, approved)
        let s0 = approved[0], s1 = approved[1]
        let oneFrame = q(1, 48000)
        let edits: [[AffineClockSegment]] = [
            // Offset nudged by one frame on both segments (still continuous).
            [seg(s0.groupClockStart, s0.groupClockEnd, s0.rateRatio, try s0.alignedOffset.adding(oneFrame)),
             seg(s1.groupClockStart, s1.groupClockEnd, s1.rateRatio, try s1.alignedOffset.adding(oneFrame))],
            // Rate changed by 1 ppb on the last segment (continuity kept at the knot).
            [s0, seg(s1.groupClockStart, s1.groupClockEnd, q(1_000_000_001, 1_000_000_000), try s1.alignedOffset.subtracting(q(1, 1_000_000_000)))],
            // Extended end.
            [s0, seg(s1.groupClockStart, q(3), s1.rateRatio, s1.alignedOffset)],
            // Dropped segment.
            [s0],
            // Same function, split differently.
            [seg(q(0), q(1, 2), s0.rateRatio, s0.alignedOffset), seg(q(1, 2), q(1), s0.rateRatio, s0.alignedOffset), s1],
        ]
        for edited in edits {
            #expect(edited != approved)
            #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try group(epoch, edited, old) }
            // Re-approval for the edited segments compiles.
            #expect(throws: Never.self) { try group(epoch, edited, approval(epoch, edited)) }
        }
    }

    @Test func nonApprovalProvenanceCarriesNoBinding() throws {
        let epoch = RecordingEpochID()
        let edited = [seg(q(0), q(2), .one, q(1, 3))]
        for provenance: MapProvenance in [manualProvenance, .acousticConsistentProposal(try AcousticConsistencyProposal(estimator: "x")), .externalEvidence(try ExternalClockEvidence(kind: .sharedWordClock, description: "house"))] {
            #expect(throws: Never.self) { try group(epoch, edited, provenance) }
        }
    }

    @Test func emptyApprovedSegmentsAreRefused() {
        let epoch = RecordingEpochID()
        #expect(throws: TimeMapError.emptyEpochMap(epoch)) {
            try ClockApproval(evaluator: "e", reference: reference, measurements: passingMeasurements(), epoch: epoch, segments: [])
        }
    }

    // MARK: Decoding

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(try JSONSerialization.jsonObject(with: try encoder.encode(value)) as? [String: Any])
    }

    private func decodeEpoch(_ object: [String: Any]) throws -> EpochClockMap {
        try JSONDecoder().decode(EpochClockMap.self, from: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    @Test func persistedApprovalRoundTripsWithItsBinding() throws {
        let epoch = RecordingEpochID()
        let map = EpochClockMap(epoch: epoch, mapping: .mapped(segments: approved, provenance: try approval(epoch, approved)))
        let object = try json(map)
        let approvalObject = try #require((object["provenance"] as? [String: Any])?["clockApproval"] as? [String: Any])
        #expect(Set(approvalObject.keys) == ["evaluator", "reference", "measurements", "epoch", "segments"])
        #expect(try decodeEpoch(object) == map)
    }

    @Test func tamperedPersistedBindingIsRefused() throws {
        let epoch = RecordingEpochID()
        let map = EpochClockMap(epoch: epoch, mapping: .mapped(segments: approved, provenance: try approval(epoch, approved)))
        let object = try json(map)
        let otherSegments = try json(EpochClockMap(epoch: epoch, mapping: .mapped(segments: [seg(q(0), q(2), .one, q(1, 3))], provenance: manualProvenance)))["segments"]!

        // Epoch segments replaced, approval kept.
        var editedSegments = object
        editedSegments["segments"] = otherSegments
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try decodeEpoch(editedSegments) }

        // Epoch ID relabelled, approval kept.
        var relabelled = object
        let newID = RecordingEpochID()
        relabelled["epoch"] = newID.rawValue.uuidString
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(newID)) { try decodeEpoch(relabelled) }

        // Approval's own binding edited.
        func editApproval(_ key: String, _ value: Any) -> [String: Any] {
            var root = object
            var provenance = root["provenance"] as! [String: Any]
            var approvalObject = provenance["clockApproval"] as! [String: Any]
            approvalObject[key] = value
            provenance["clockApproval"] = approvalObject
            root["provenance"] = provenance
            return root
        }
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try decodeEpoch(editApproval("segments", otherSegments)) }
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try decodeEpoch(editApproval("epoch", relabelled["epoch"]!)) }
        #expect(throws: TimeMapError.emptyEpochMap(epoch)) { try decodeEpoch(editApproval("segments", [Any]())) }

        // An approval without a binding (the pre-#177 shape) cannot be decoded.
        var unbound = object
        var provenance = unbound["provenance"] as! [String: Any]
        var approvalObject = provenance["clockApproval"] as! [String: Any]
        approvalObject.removeValue(forKey: "epoch")
        approvalObject.removeValue(forKey: "segments")
        provenance["clockApproval"] = approvalObject
        unbound["provenance"] = provenance
        #expect(throws: DecodingError.self) { try decodeEpoch(unbound) }
    }

    /// The whole persisted timeline refuses a tampered binding too (decoding goes through the same check
    /// and compilation re-validates).
    @Test func tamperedTimelineIsRefused() throws {
        let epoch = RecordingEpochID()
        let timeline = try fx.timeline([try group(epoch, approved, approval(epoch, approved))])
        var root = try json(timeline)
        var groups = root["groups"] as! [[String: Any]]
        var epochs = groups[1]["epochs"] as! [[String: Any]]
        epochs[0]["segments"] = try json(EpochClockMap(epoch: epoch, mapping: .mapped(segments: [seg(q(0), q(2), .one, q(1, 3))], provenance: manualProvenance)))["segments"]!
        groups[1]["epochs"] = epochs
        root["groups"] = groups
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        #expect(throws: TimeMapError.clockApprovalBindingMismatch(epoch)) { try JSONDecoder().decode(AlignedTimelineMap.self, from: data) }
        // Untampered, it round-trips.
        let clean = try JSONSerialization.data(withJSONObject: try json(timeline), options: [.sortedKeys])
        #expect(try JSONDecoder().decode(AlignedTimelineMap.self, from: clean) == timeline)
    }
}
