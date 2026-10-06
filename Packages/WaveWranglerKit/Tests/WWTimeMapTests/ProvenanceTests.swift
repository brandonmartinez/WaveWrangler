import Foundation
import Testing
import WWCore
@testable import WWTimeMap

@Suite("Provenance")
struct ProvenanceTests {
    private func measurements(windows: Int = 5, overlap: Double = 0.8, eligible: Double = 0.6, p95: Double = 5, max: Double = 10) throws -> ClockGateMeasurements {
        try ClockGateMeasurements(windowCount: windows, overlapSpanFraction: overlap, eligibleWindowFraction: eligible, residualP95Milliseconds: p95, residualMaxMilliseconds: max)
    }

    private let reference = try! IndependentClockReference(description: "synthetic certified clock anchors")

    @Test func clockApprovalPassesExactlyAtTheProvisionalGates() throws {
        let approval = try ClockApproval(evaluator: "test-evaluator/1", reference: reference, measurements: try measurements())
        #expect(MapProvenance.clockApproved(approval).kind.isClockApproved)
        #expect(try measurements().failedProvisionalGates.isEmpty)
    }

    @Test func eachFailingGateIsNamedAndRefused() throws {
        let cases: [(ClockGateMeasurements, [String])] = [
            (try measurements(windows: 4), ["windowCount"]),
            (try measurements(overlap: 0.7999), ["overlapSpanFraction"]),
            (try measurements(eligible: 0.5999), ["eligibleWindowFraction"]),
            (try measurements(p95: 5.0001, max: 10), ["residualP95Milliseconds"]),
            (try measurements(max: 10.0001), ["residualMaxMilliseconds"]),
            (try measurements(windows: 0, overlap: 0, eligible: 0, p95: 50, max: 100), ["windowCount", "overlapSpanFraction", "eligibleWindowFraction", "residualP95Milliseconds", "residualMaxMilliseconds"]),
        ]
        for (m, failed) in cases {
            #expect(m.failedProvisionalGates == failed)
            #expect(throws: TimeMapError.clockApprovalGateNotMet(failed)) { try ClockApproval(evaluator: "e", reference: reference, measurements: m) }
        }
        #expect(throws: TimeMapError.emptyDescription("ClockApproval.evaluator")) { try ClockApproval(evaluator: "  ", reference: reference, measurements: try measurements()) }
        #expect(throws: TimeMapError.emptyDescription("IndependentClockReference")) { try IndependentClockReference(description: "\n") }
    }

    @Test func measurementsMustBeWellFormed() {
        #expect(throws: TimeMapError.invalidMeasurement("windowCount")) { try measurements(windows: -1) }
        #expect(throws: TimeMapError.invalidMeasurement("overlapSpanFraction")) { try measurements(overlap: 1.01) }
        #expect(throws: TimeMapError.invalidMeasurement("overlapSpanFraction")) { try measurements(overlap: .nan) }
        #expect(throws: TimeMapError.invalidMeasurement("eligibleWindowFraction")) { try measurements(eligible: -0.1) }
        #expect(throws: TimeMapError.invalidMeasurement("residualP95Milliseconds")) { try measurements(p95: .infinity, max: .infinity) }
        #expect(throws: TimeMapError.invalidMeasurement("residualMaxMilliseconds")) { try measurements(p95: 4, max: 3) }
        #expect(throws: TimeMapError.invalidMeasurement("evidenceScore")) { try AcousticConsistencyProposal(estimator: "x", evidenceScore: .nan) }
    }

    /// Acoustic delay must never pass as clock correction: even perfect measurements leave a proposal a
    /// proposal, and a person accepting it makes it manual, not clock-approved.
    @Test func onlyClockApprovalIsClockApproved() throws {
        let perfect = try measurements(windows: 100, overlap: 1, eligible: 1, p95: 0, max: 0)
        let proposal = try AcousticConsistencyProposal(estimator: "synthetic", evidenceScore: 1e9, measurements: perfect, seed: CaptureMetadataSeed(kind: .embeddedTimestamp, suggestedOffset: q(12)))
        #expect(!MapProvenance.acousticConsistentProposal(proposal).kind.isClockApproved)
        #expect(!MapProvenance.manual(ManualCorrection(basis: .acceptedAcousticProposal)).kind.isClockApproved)
        #expect(!MapProvenance.externalEvidence(try ExternalClockEvidence(kind: .sharedTimecodeGenerator, description: "LTC")).kind.isClockApproved)
        #expect(!MapProvenance.timelineReference.kind.isClockApproved)
        #expect(MapProvenance.Kind.allCases.filter(\.isClockApproved) == [.clockApproved])
        #expect(MapProvenance.Kind.allCases.count == 5)
        #expect(UnsupportedReason.allCases.contains(.acousticOnly))
    }

    /// Capture metadata can only seed a proposal: no clock-approval, manual or external type can hold it,
    /// and external evidence has no file/capture-metadata kind.
    @Test func captureMetadataIsNeverClockProof() throws {
        func holdsSeed(_ value: Any) -> Bool {
            func walk(_ value: Any, depth: Int) -> Bool {
                if value is CaptureMetadataSeed || value is CaptureMetadataSeed.Kind { return true }
                guard depth < 6 else { return false }
                return Mirror(reflecting: value).children.contains { walk($0.value, depth: depth + 1) }
            }
            return walk(value, depth: 0)
        }
        let approval = try ClockApproval(evaluator: "e", reference: reference, measurements: try measurements())
        let external = try ExternalClockEvidence(kind: .userSuppliedSyncLog, description: "log")
        #expect(!holdsSeed(approval))
        #expect(!holdsSeed(external))
        #expect(!holdsSeed(ManualCorrection(basis: .anchors)))
        #expect(!holdsSeed(reference))
        #expect(holdsSeed(try AcousticConsistencyProposal(estimator: "x", seed: CaptureMetadataSeed(kind: .fileCreationDate))))
        let externalKinds = Set(ExternalClockEvidence.Kind.allCases.map(\.rawValue))
        let metadataKinds = Set(CaptureMetadataSeed.Kind.allCases.map(\.rawValue))
        #expect(externalKinds.isDisjoint(with: metadataKinds))
        #expect(!externalKinds.contains { $0.localizedCaseInsensitiveContains("file") || $0.localizedCaseInsensitiveContains("date") })
    }

    /// Query results carry the provenance kind of the epoch that produced them.
    @Test func resultsReportProvenance() throws {
        let fx = Fixture()
        let approval = MapProvenance.clockApproved(try ClockApproval(evaluator: "e", reference: reference, measurements: try measurements()))
        let proposal = MapProvenance.acousticConsistentProposal(try AcousticConsistencyProposal(estimator: "x"))
        let a = RecordingEpochID(), b = RecordingEpochID()
        let occurrence = fx.occurrence(frames: 96000)
        let group = try fx.otherGroup(
            epochs: [mapped(a, [seg(q(0), q(1), .one, .zero)], approval), mapped(b, [seg(q(0), q(1), .one, q(1))], proposal)],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, a), span(48000, 96000, b, e: q(-1))])]
        )
        #expect(try group.alignedTime(ofFrame: 0, in: occurrence.id).regionState == .mapped(.clockApproved))
        #expect(try group.alignedTime(ofFrame: 48000, in: occurrence.id).regionState == .mapped(.acousticConsistentProposal))
        #expect(try group.sourceFrame(at: q(1, 2), in: occurrence.id).regionState == .mapped(.clockApproved))
        #expect(try group.sourceFrame(at: q(3, 2), in: occurrence.id).regionState == .mapped(.acousticConsistentProposal))
        let referenceMap = try fx.timeline([group])
        #expect(try referenceMap.alignedTime(ofFrame: 0, in: fx.refOccurrence).regionState == .mapped(.timelineReference))
    }

    /// Scores are never called probabilities in the public vocabulary.
    @Test func noProbabilityVocabulary() throws {
        let banned = ["probability", "likelihood", "confidence", "percent"]
        var names: [String] = []
        names += MapProvenance.Kind.allCases.map(\.rawValue)
        names += UnsupportedReason.allCases.map(\.rawValue)
        names += ManualCorrection.Basis.allCases.map(\.rawValue)
        names += ExternalClockEvidence.Kind.allCases.map(\.rawValue)
        names += AcousticConsistencyProposal.CodingKeys.allCases.map(\.stringValue)
        names += ClockGateMeasurements.CodingKeys.allCases.map(\.stringValue)
        names += Mirror(reflecting: try AcousticConsistencyProposal(estimator: "x", evidenceScore: 1)).children.compactMap(\.label)
        for name in names {
            #expect(!banned.contains { name.localizedCaseInsensitiveContains($0) }, "\(name)")
        }
    }
}
