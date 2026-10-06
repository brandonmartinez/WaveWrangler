import Foundation
import WWAlignEstimate
import WWTimeMap

/// The m2-freeze-estimator gate, evaluated in exactly one place so calibration and the frozen holdout apply
/// the same definition (docs/m2/fixtures/m2-freeze-estimator.json, "gate"). All residuals are against
/// independent clock truth on a 1 s grid over the declared overlap; never against the fitted map.
///
/// Provisional gates (verbatim): held-out residual p95 ≤5 ms / max ≤10 ms; ≥5 windows spanning ≥80% of
/// declared overlap and ≥60% eligible windows; zero false accepts on the finite negative set.
struct GateEvaluation {
    /// Every epoch whose map carries `clockApproved` (any stratum). Structurally impossible; still counted.
    var clockApprovedEpochs: [String] = []
    /// Proposals on strata that must abstain (discontinuity, unrelated, silent, periodic, disconnected,
    /// cycleConflict).
    var proposalsWhereAbstentionRequired: [String] = []
    /// Acoustic-delay epochs whose proposal is not labelled `acousticConsistentProposal`.
    var acousticDelayMislabelled: [String] = []
    /// Acoustic-delay proposals that would pass the clock gates against clock truth. Reported, not a false
    /// accept (they are never promoted); a non-empty list means the negative no longer discriminates.
    var acousticDelayWithinClockGates: [String] = []
    var acousticDelayProposals = 0
    var acousticDelayEpochs = 0

    var positiveEpochs = 0
    var positiveProposals = 0
    /// Positive epochs that miss a window gate (count, overlap span or eligible fraction). The window gate
    /// applies to every held-out positive EPOCH, so a positive that abstains fails it.
    var positiveWindowGateFailures: [String] = []
    var positiveResidualsMs: [Double] = []

    /// False accepts on the finite negative set (gate: zero).
    var falseAccepts: [String] { clockApprovedEpochs + proposalsWhereAbstentionRequired + acousticDelayMislabelled }
    var positiveResidualP95Ms: Double? { Percentile.nearestRank(positiveResidualsMs, 0.95) }
    var positiveResidualMaxMs: Double? { positiveResidualsMs.max() }

    /// Gate failures, in plain words. Empty means the gate passed. With no positive proposal the residual
    /// gate is undefined, which FAILS (abstaining on everything is not evidence).
    var failures: [String] {
        var out: [String] = []
        if !falseAccepts.isEmpty { out.append("false accepts: \(falseAccepts.count) (\(falseAccepts.joined(separator: ", ")))") }
        if !positiveWindowGateFailures.isEmpty { out.append("positive epochs missing a window gate: \(positiveWindowGateFailures.joined(separator: ", "))") }
        if positiveProposals == 0 {
            out.append("no positive proposal: residual gate undefined")
        } else {
            let p95 = positiveResidualP95Ms ?? .infinity, worst = positiveResidualMaxMs ?? .infinity
            if p95 > ProvisionalClockGates.maximumResidualP95Milliseconds { out.append("pooled positive residual p95 \(p95) ms > \(ProvisionalClockGates.maximumResidualP95Milliseconds) ms") }
            if worst > ProvisionalClockGates.maximumResidualMaxMilliseconds { out.append("pooled positive residual max \(worst) ms > \(ProvisionalClockGates.maximumResidualMaxMilliseconds) ms") }
        }
        return out
    }

    var passed: Bool { failures.isEmpty }

    /// What the gate reads from one scored epoch.
    struct Input {
        let label: String
        let stratum: Stratum
        let proposed: Bool
        let provenanceKind: MapProvenance.Kind?
        let eligibleCount: Int
        let eligibleSpanFraction: Double
        let eligibleWindowFraction: Double
        let clockResidualsMs: [Double]
    }

    init(_ scored: [ScoredEpoch]) {
        self.init(inputs: scored.map { s in
            let proposed: Bool
            if case .acousticConsistentProposal = s.estimate.outcome { proposed = true } else { proposed = false }
            let c = s.estimate.coverage
            return Input(label: "\(s.stratum.rawValue)#\(s.caseIndex)", stratum: s.stratum, proposed: proposed,
                         provenanceKind: s.estimate.epochClockMap.provenanceKind, eligibleCount: c.eligibleCount,
                         eligibleSpanFraction: c.eligibleSpanFraction, eligibleWindowFraction: c.eligibleWindowFraction,
                         clockResidualsMs: s.clockResidualsMs)
        })
    }

    init(inputs: [Input]) {
        for s in inputs {
            let label = s.label
            if s.provenanceKind == .clockApproved { clockApprovedEpochs.append(label) }
            switch s.stratum.expectation {
            case .noProposal:
                if s.proposed { proposalsWhereAbstentionRequired.append(label) }
            case .acousticOnly:
                acousticDelayEpochs += 1
                guard s.proposed else { continue }
                acousticDelayProposals += 1
                if s.provenanceKind != .acousticConsistentProposal { acousticDelayMislabelled.append(label) }
                if Self.withinClockGates(s.clockResidualsMs) { acousticDelayWithinClockGates.append(label) }
            case .clockTruthWithinGates:
                positiveEpochs += 1
                guard s.proposed else { positiveWindowGateFailures.append(label + " (abstained)"); continue }
                positiveProposals += 1
                if s.eligibleCount < ProvisionalClockGates.minimumWindows
                    || s.eligibleSpanFraction < ProvisionalClockGates.minimumOverlapSpanFraction
                    || s.eligibleWindowFraction < ProvisionalClockGates.minimumEligibleWindowFraction {
                    positiveWindowGateFailures.append(label)
                }
                positiveResidualsMs += s.clockResidualsMs
            }
        }
    }

    static func withinClockGates(_ residualsMs: [Double]) -> Bool {
        guard let p95 = Percentile.nearestRank(residualsMs, 0.95), let worst = residualsMs.max() else { return false }
        return p95 <= ProvisionalClockGates.maximumResidualP95Milliseconds && worst <= ProvisionalClockGates.maximumResidualMaxMilliseconds
    }

    var summary: String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "-" }
        return """
        gate: \(passed ? "PASS" : "FAIL")\(failures.isEmpty ? "" : " -- " + failures.joined(separator: "; "))
        positives: \(positiveProposals)/\(positiveEpochs) epochs proposed (an abstaining positive fails the window gate); pooled clock residual p95 \(ms(positiveResidualP95Ms)) ms, max \(ms(positiveResidualMaxMs)) ms over \(positiveResidualsMs.count) grid points
        false accepts: \(falseAccepts.count) (clockApproved \(clockApprovedEpochs.count), proposals where abstention required \(proposalsWhereAbstentionRequired.count), acoustic-delay mislabelled \(acousticDelayMislabelled.count))
        acoustic-delay negatives: \(acousticDelayProposals)/\(acousticDelayEpochs) emitted as acousticConsistentProposal only; \(acousticDelayWithinClockGates.count) within clock gates if promoted (never promoted)
        """
    }
}
