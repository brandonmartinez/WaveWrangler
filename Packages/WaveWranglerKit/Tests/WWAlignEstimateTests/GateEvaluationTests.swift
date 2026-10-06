import Testing
import WWTimeMap

/// The frozen gate's own logic, on hand-built inputs (the calibration run cannot exercise its failure paths).
@Suite("Freeze gate evaluation")
struct GateEvaluationTests {
    typealias Input = GateEvaluation.Input

    static func positive(_ residuals: [Double] = [0.5, 1, 2], eligible: Int = 16, span: Double = 1, fraction: Double = 1, proposed: Bool = true) -> Input {
        Input(label: "p", stratum: .positive, proposed: proposed, provenanceKind: proposed ? .acousticConsistentProposal : nil,
              eligibleCount: eligible, eligibleSpanFraction: span, eligibleWindowFraction: fraction, clockResidualsMs: residuals)
    }

    static func negative(_ stratum: Stratum, proposed: Bool, kind: MapProvenance.Kind? = .acousticConsistentProposal, residuals: [Double] = [35]) -> Input {
        Input(label: stratum.rawValue, stratum: stratum, proposed: proposed, provenanceKind: proposed ? kind : nil,
              eligibleCount: 16, eligibleSpanFraction: 1, eligibleWindowFraction: 1, clockResidualsMs: proposed ? residuals : [])
    }

    @Test func cleanRunPasses() {
        let gate = GateEvaluation(inputs: [Self.positive(), Self.negative(.constantDelay, proposed: true), Self.negative(.silent, proposed: false)])
        #expect(gate.passed, "\(gate.failures)")
        #expect(gate.acousticDelayProposals == 1 && gate.acousticDelayWithinClockGates.isEmpty)
    }

    @Test func everyNonAcousticNegativeProposalIsAFalseAccept() {
        for stratum in Stratum.allCases where stratum.expectation == .noProposal {
            let gate = GateEvaluation(inputs: [Self.positive(), Self.negative(stratum, proposed: true)])
            #expect(gate.proposalsWhereAbstentionRequired == [stratum.rawValue])
            #expect(!gate.passed)
        }
    }

    @Test func clockApprovedAnywhereIsAFalseAccept() {
        let approvedPositive = Input(label: "p", stratum: .positive, proposed: true, provenanceKind: .clockApproved, eligibleCount: 16,
                                 eligibleSpanFraction: 1, eligibleWindowFraction: 1, clockResidualsMs: [0.1])
        #expect(GateEvaluation(inputs: [approvedPositive]).clockApprovedEpochs == ["p"])
        #expect(!GateEvaluation(inputs: [approvedPositive]).passed)
        let gate = GateEvaluation(inputs: [Self.positive(), Self.negative(.variableDelay, proposed: true, kind: .clockApproved)])
        #expect(gate.clockApprovedEpochs == ["variableDelay"])
        #expect(gate.acousticDelayMislabelled == ["variableDelay"])
        #expect(!gate.passed)
    }

    @Test func acousticDelayWithinClockGatesIsReportedNotAccepted() {
        let gate = GateEvaluation(inputs: [Self.positive(), Self.negative(.constantDelay, proposed: true, residuals: [0.2, 0.3])])
        #expect(gate.acousticDelayWithinClockGates == ["constantDelay"])
        #expect(gate.falseAccepts.isEmpty)
    }

    @Test func positiveWindowGates() {
        #expect(!GateEvaluation(inputs: [Self.positive(eligible: 4)]).passed)
        #expect(!GateEvaluation(inputs: [Self.positive(span: 0.79)]).passed)
        #expect(!GateEvaluation(inputs: [Self.positive(fraction: 0.59)]).passed)
        #expect(GateEvaluation(inputs: [Self.positive(eligible: 5, span: 0.8, fraction: 0.6)]).passed)
        let abstained = GateEvaluation(inputs: [Self.positive(), Self.positive(proposed: false)])
        #expect(abstained.positiveWindowGateFailures == ["p (abstained)"])
        #expect(!abstained.passed)
    }

    @Test func pooledResidualGates() {
        // Nearest-rank p95 of 20 values is the 19th.
        let p95Edge = Array(repeating: 0.1, count: 18) + [5.0, 9.9]
        #expect(GateEvaluation(inputs: [Self.positive(p95Edge)]).passed)
        let p95Over = Array(repeating: 0.1, count: 18) + [5.01, 5.01]
        #expect(!GateEvaluation(inputs: [Self.positive(p95Over)]).passed)
        #expect(!GateEvaluation(inputs: [Self.positive(Array(repeating: 0.1, count: 40) + [10.01])]).passed)
        #expect(!GateEvaluation(inputs: [Self.positive([10.0])]).passed) // p95 of a single value is that value
        #expect(GateEvaluation(inputs: [Self.positive([5.0])]).passed)
    }

    @Test func noPositiveProposalFails() {
        #expect(!GateEvaluation(inputs: []).passed)
        #expect(!GateEvaluation(inputs: [Self.negative(.silent, proposed: false)]).passed)
    }
}
