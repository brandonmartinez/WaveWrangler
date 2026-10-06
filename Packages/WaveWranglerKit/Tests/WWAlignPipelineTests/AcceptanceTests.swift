import Foundation
import Testing
import WWCore
@testable import WWDerived
@testable import WWTimeMap
@testable import WWAlignPipeline

/// Every way a person can decide an epoch produces a versioned EpisodeAlignment revision whose provenance is
/// `.timelineReference` or `.manual(...)`; an undecided epoch at most carries the estimator's own
/// `.acousticConsistentProposal`. This layer can neither create nor carry a clock approval.
@Suite("Accept/apply: versioned map revisions; ClockApproval cannot be faked from this layer")
struct AcceptanceTests {
    static let truthRate = try! ExactRational(10_001, 10_000)
    static let truthOffset = try! ExactRational(5, 4)

    static func provenances(_ map: AlignedTimelineMap) -> [RecordingEpochID: MapProvenance.Kind] {
        var result: [RecordingEpochID: MapProvenance.Kind] = [:]
        for group in map.groups {
            for epoch in group.epochs {
                if case let .mapped(_, provenance) = epoch.mapping { result[epoch.epoch] = provenance.kind }
            }
        }
        return result
    }

    static func segment(_ map: AlignedTimelineMap, _ epoch: RecordingEpochID) -> AffineClockSegment? {
        for group in map.groups {
            for entry in group.epochs where entry.epoch == epoch {
                if case let .mapped(segments, _) = entry.mapping { return segments.first }
            }
        }
        return nil
    }

    @Test("Every decision yields only timelineReference or manual provenance, versioned and derived from the prior revision")
    func provenanceIsOnlyReferenceOrManual() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "provenance")
        let (referenceEpoch, targetEpoch) = (fixture.epochs[0], fixture.epochs[1])
        let report = try await fixture.analyse(preferredReference: "ref")
        let decisions: [(EpochMapDecision, ManualCorrection.Basis?)] = [
            (.acceptProposal(note: "ok"), .acceptedAcousticProposal),
            (.numeric(ppm: 100, offsetMilliseconds: 1250), .numericEntry),
            (.anchors([AlignmentAnchor(sourceSeconds: 1, alignedSeconds: 2.2501), AlignmentAnchor(sourceSeconds: 21, alignedSeconds: 22.2521)]), .anchors),
            (.unmapped, nil),
        ]
        for (index, (decision, basis)) in decisions.enumerated() {
            let accepted = try await fixture.acceptAndActivate(report, [targetEpoch: decision])
            let revision = index + 1
            #expect(accepted.revision == MapRevisionReference(episode: fixture.episodeID, revision: revision))
            let alignment = try #require(fixture.model.episode(fixture.episodeID)?.alignment)
            #expect(alignment.acceptedRevision == revision)
            #expect(alignment.acceptedMap?.derivedFrom == (revision == 1 ? nil : revision - 1))
            #expect(alignment.acceptedMap?.inputs.recipe == AlignmentAssetKinds.acceptanceRecipe)
            #expect(try fixture.model.timeMap(revision: revision, in: fixture.episodeID) == accepted.map, "persisted map round-trips")
            #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == revision)

            let kinds = Self.provenances(accepted.map)
            #expect(kinds[referenceEpoch] == .timelineReference)
            for kind in kinds.values { #expect(kind == .timelineReference || kind == .manual || kind == .acousticConsistentProposal, "provenance \(kind)") }
            #expect(!kinds.values.contains { $0.isClockApproved })
            let status = await fixture.states(report)[targetEpoch]?.status
            if let basis {
                #expect(kinds[targetEpoch] == .manual)
                #expect(status == .manual(basis, revision: revision))
            } else {
                #expect(kinds[targetEpoch] == nil)
                #expect(status == .unsupported(.notAttempted, .acceptedMap(revision: revision)))
            }
        }
    }

    @Test("Undecided epoch carries its current proposal unaccepted (U3); an explicit reject returns it to U8 and stays rejected")
    func undecidedCarriesProposalAndRejectSticks() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "reject")
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let proposal = try #require(await fixture.states(report)[targetEpoch]?.status.proposal)

        let undecided = try await fixture.acceptAndActivate(report, [:])
        #expect(Self.provenances(undecided.map)[targetEpoch] == .acousticConsistentProposal)
        let carried = try #require(Self.segment(undecided.map, targetEpoch))
        #expect(carried.rateRatio == proposal.segment.rateRatio)
        #expect(carried.alignedOffset == proposal.segment.alignedOffset)
        #expect(carried.groupClockStart == .zero)
        let u3 = try #require(await fixture.states(report)[targetEpoch])
        #expect(u3.status == .proposedInAcceptedMap(revision: 1))
        #expect(u3.remedies == [.acceptAsManual, .reject, .editNumerically, .placeAnchors, .audition])

        _ = try await fixture.acceptAndActivate(report, [targetEpoch: .unmapped])
        let rejected = try #require(await fixture.states(report)[targetEpoch])
        #expect(rejected.status == .unsupported(.notAttempted, .acceptedMap(revision: 2)), "the still-current proposal must not mask the rejection")
        #expect(rejected.remedies == [.acceptAsManual, .editNumerically, .placeAnchors])

        // Accepting nothing again carries the rejection forward rather than resurrecting the proposal.
        let carriedReject = try await fixture.acceptAndActivate(report, [:])
        #expect(Self.provenances(carriedReject.map)[targetEpoch] == nil)
        #expect(await fixture.states(report)[targetEpoch]?.status == .unsupported(.notAttempted, .acceptedMap(revision: 3)))

        // And it can still be accepted from the rejected state.
        _ = try await fixture.acceptAndActivate(report, [targetEpoch: .acceptProposal(note: "changed my mind")])
        #expect(await fixture.states(report)[targetEpoch]?.status == .manual(.acceptedAcousticProposal, revision: 4))
    }

    @Test("Anchors placed on the truth and the numeric truth produce the identical exact segment")
    func anchorsFromTruthAreExact() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "anchors")
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let truth: (Double) -> Double = { TwoRecorder.rate * $0 + TwoRecorder.offset }
        let anchors = [0.5, 7.25, 13, 23.5].map { AlignmentAnchor(sourceSeconds: $0, alignedSeconds: truth($0)) }
        let fitted = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .anchors(anchors)])
        let numeric = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .numeric(ppm: 100, offsetMilliseconds: 1250)])
        let segment = try #require(Self.segment(fitted.map, targetEpoch))
        #expect(segment.rateRatio == Self.truthRate)
        #expect(segment.alignedOffset == Self.truthOffset)
        #expect(Self.segment(numeric.map, targetEpoch) == segment)
        #expect(segment.groupClockStart == .zero)
        #expect(segment.groupClockEnd == (try ExactRational(24 * 48_000, 48_000)))
    }

    enum Expected: Sendable {
        case invalidNumeric, insufficientAnchors, invalidAnchors

        func matches(_ error: AlignmentAcceptanceError, _ epoch: RecordingEpochID) -> Bool {
            switch (self, error) {
            case let (.invalidNumeric, .invalidNumericEntry(e, _)): e == epoch
            case let (.insufficientAnchors, .insufficientAnchors(e)): e == epoch
            case let (.invalidAnchors, .invalidAnchors(e, _)): e == epoch
            default: false
            }
        }
    }

    static let invalidDecisions: [(String, EpochMapDecision, Expected)] = [
        ("NaN ppm", .numeric(ppm: .nan, offsetMilliseconds: 0), .invalidNumeric),
        ("infinite offset", .numeric(ppm: 0, offsetMilliseconds: .infinity), .invalidNumeric),
        ("ppm beyond ±1e6", .numeric(ppm: 2e6, offsetMilliseconds: 0), .invalidNumeric),
        ("zero rate", .numeric(ppm: -1e6, offsetMilliseconds: 0), .invalidNumeric),
        ("rate outside the envelope", .numeric(ppm: -600_000, offsetMilliseconds: 0), .invalidNumeric),
        ("no anchors", .anchors([]), .insufficientAnchors),
        ("one anchor", .anchors([AlignmentAnchor(sourceSeconds: 1, alignedSeconds: 2)]), .insufficientAnchors),
        ("NaN anchor", .anchors([AlignmentAnchor(sourceSeconds: 1, alignedSeconds: .nan), AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 3)]), .invalidAnchors),
        ("negative source time", .anchors([AlignmentAnchor(sourceSeconds: -1, alignedSeconds: 0), AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 3)]), .invalidAnchors),
        ("duplicate source time", .anchors([AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 3), AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 4)]), .invalidAnchors),
        ("time runs backwards", .anchors([AlignmentAnchor(sourceSeconds: 1, alignedSeconds: 5), AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 4)]), .invalidAnchors),
    ]

    @Test("Invalid numeric entries and anchors are refused with typed errors and record nothing")
    func invalidDecisionsAreRefused() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "invalid")
        let (referenceEpoch, targetEpoch) = (fixture.epochs[0], fixture.epochs[1])
        let report = try await fixture.analyse(preferredReference: "ref")
        for (name, decision, expected) in Self.invalidDecisions {
            do {
                _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: decision])
                Issue.record("\(name) was accepted")
            } catch {
                #expect(expected.matches(error, targetEpoch), "\(name): \(error)")
            }
        }
        await #expect(throws: AlignmentAcceptanceError.decisionForReferenceEpoch(referenceEpoch)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [referenceEpoch: .numeric(ppm: 0, offsetMilliseconds: 0)])
        }
        let stranger = RecordingEpochID()
        await #expect(throws: AlignmentAcceptanceError.unknownEpoch(stranger)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [stranger: .unmapped])
        }
        let otherEpisode = EpisodeID()
        await #expect(throws: AlignmentAcceptanceError.episodeNotFound(otherEpisode)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: otherEpisode, report: report, decisions: [:])
        }
        #expect(fixture.model.episode(fixture.episodeID)?.alignment == nil, "nothing was recorded")
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
    }

    @Test("A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision")
    func clockApprovedPriorIsRefused() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "clock")
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")

        // A map written by something else (a future evaluator, or a tampered document) claiming approval.
        let numeric = try await fixture.acceptAndActivate(report, [targetEpoch: .numeric(ppm: 100, offsetMilliseconds: 1250)])
        let segments = [try #require(Self.segment(numeric.map, targetEpoch))]
        let approval = try ClockApproval(
            evaluator: "future/1", reference: try IndependentClockReference(description: "anchors"),
            measurements: try ClockGateMeasurements(windowCount: 5, overlapSpanFraction: 0.8, eligibleWindowFraction: 0.6, residualP95Milliseconds: 5, residualMaxMilliseconds: 10),
            epoch: targetEpoch, segments: segments
        )
        let groups = try numeric.map.groups.map { group in
            try GroupTimeMap(
                group: group.group, reference: numeric.map.reference,
                epochs: group.epochs.map { $0.epoch == targetEpoch ? EpochClockMap(epoch: targetEpoch, mapping: .mapped(segments: segments, provenance: .clockApproved(approval))) : $0 },
                placements: group.placements
            )
        }
        let approved = try AlignedTimelineMap(reference: numeric.map.reference, groups: groups)
        let inputs = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.acceptedMap?.inputs)
        let (recorded, revision) = try fixture.model.recordingMap(approved, in: fixture.episodeID, inputs: inputs.sources, recipe: inputs.recipe, derivedFrom: 1)
        fixture.model = try recorded.acceptingMap(revision: revision.revision, in: fixture.episodeID)
        await fixture.coordinator.acceptMap(revision)

        let state = try #require(await fixture.states(report)[targetEpoch])
        #expect(state.status == .clockApprovalRefused(revision: 2))
        #expect(state.remedies == [.editNumerically, .placeAnchors])
        // Accepting without deciding that epoch would carry the approval: refused.
        await #expect(throws: AlignmentAcceptanceError.priorMapHasClockApproval(targetEpoch)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [:])
        }
        // An explicit decision replaces it with manual provenance.
        let replaced = try await fixture.acceptAndActivate(report, [targetEpoch: .acceptProposal()])
        #expect(replaced.revision.revision == 3)
        #expect(Self.provenances(replaced.map)[targetEpoch] == .manual)
        #expect(await fixture.states(report)[targetEpoch]?.status == .manual(.acceptedAcousticProposal, revision: 3))
    }

    @Test("activate refuses a revision its document does not accept; nothing runs after shutdown")
    func activationAndShutdownRefusals() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4), label: "refusals")
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let accepted = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .numeric(ppm: 0, offsetMilliseconds: 0)])
        let unsaved = AcceptedAlignment(model: fixture.model, revision: accepted.revision, map: accepted.map)
        await #expect(throws: AlignmentAcceptanceError.history(.mapNotFound(revision: 1))) { try await fixture.pipeline.activate(unsaved) }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
        fixture.model = accepted.model
        await #expect(throws: AlignedAssetRefusal.acceptedMapNotActive(document: 1, coordinator: nil)) { _ = try await fixture.render() }

        await fixture.coordinator.shutdown()
        let opens = fixture.content.total.opens
        await #expect(throws: AlignmentAcceptanceError.coordinatorShutDown) { try await fixture.pipeline.activate(accepted) }
        await #expect(throws: AlignmentAcceptanceError.coordinatorShutDown) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [:])
        }
        await #expect(throws: AlignedAssetRefusal.coordinatorShutDown) { _ = try await fixture.render() }
        let after = try await fixture.analyse(preferredReference: "ref")
        #expect(after.records.isEmpty)
        #expect(after.probes.values.allSatisfy { $0.outcome == .cancelled })
        #expect(fixture.content.total.opens == opens, "no content is opened after shutdown")
    }

    @Test("No pipeline source constructs a clock approval or names the clockApproved provenance constructor")
    func pipelineCannotConstructApproval() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWAlignPipeline", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 10)
        let forbidden = [#"(?<![A-Za-z_])ClockApproval\s*\("#, #"\.clockApproved\s*\("#, #"MapProvenance\s*\("#, #"ClockGateMeasurements\s*\("#]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(file.lastPathComponent) matches \(pattern)")
            }
        }
    }
}
