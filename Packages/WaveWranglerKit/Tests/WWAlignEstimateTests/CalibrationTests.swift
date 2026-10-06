import Foundation
import Testing
import WWAlignEstimate
import WWTimeMap

/// WW-016 CALIBRATION (not a holdout): every stratum is scored against independent clock truth. The printed
/// table is the source of docs/m2/evidence/ww-016-estimator-calibration.md.
@Suite("Estimator calibration")
struct CalibrationTests {
    struct StratumSummary {
        var cases = 0
        var epochs = 0
        var proposals = 0
        var abstentions: [AbstentionReason: Int] = [:]
        var residuals: [Double] = []
        var proposalsFailingClockGates = 0
        var worstPerProposal: [Double] = []
    }

    static func runAll(_ cases: [CalibrationCase] = CalibrationPlan.cases()) async throws -> [ScoredEpoch] {
        try await withThrowingTaskGroup(of: [ScoredEpoch].self) { group in
            for c in cases { group.addTask { try CalibrationRunner.run(c) } }
            var all: [ScoredEpoch] = []
            for try await scored in group { all += scored }
            return all.sorted { ($0.stratum.rawValue, $0.caseIndex) < ($1.stratum.rawValue, $1.caseIndex) }
        }
    }

    static func summarise(_ scored: [ScoredEpoch]) -> [Stratum: StratumSummary] {
        var summaries: [Stratum: StratumSummary] = [:]
        var casesSeen: Set<String> = []
        for s in scored {
            var summary = summaries[s.stratum, default: StratumSummary()]
            if casesSeen.insert("\(s.stratum.rawValue)#\(s.caseIndex)").inserted { summary.cases += 1 }
            summary.epochs += 1
            switch s.estimate.outcome {
            case .acousticConsistentProposal:
                summary.proposals += 1
                summary.residuals += s.clockResidualsMs
                let p95 = Percentile.nearestRank(s.clockResidualsMs, 0.95) ?? .infinity
                let worst = s.clockResidualsMs.max() ?? .infinity
                summary.worstPerProposal.append(worst)
                if p95 > ProvisionalClockGates.maximumResidualP95Milliseconds || worst > ProvisionalClockGates.maximumResidualMaxMilliseconds {
                    summary.proposalsFailingClockGates += 1
                }
            case .abstained(let a):
                summary.abstentions[a.reason, default: 0] += 1
            }
            summaries[s.stratum] = summary
        }
        return summaries
    }

    static func table(_ summaries: [Stratum: StratumSummary]) -> String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "-" }
        var lines = ["stratum | cases | epochs | proposals | abstentions | clock residual p95 ms | clock residual max ms | proposals failing clock gates"]
        for stratum in Stratum.allCases {
            guard let s = summaries[stratum] else { continue }
            let abstentions = s.abstentions.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ",")
            lines.append("\(stratum.rawValue) | \(s.cases) | \(s.epochs) | \(s.proposals) | \(abstentions.isEmpty ? "-" : abstentions) | \(ms(Percentile.nearestRank(s.residuals, 0.95))) | \(ms(s.residuals.max())) | \(s.proposalsFailingClockGates)")
        }
        return lines.joined(separator: "\n")
    }

    /// One per-epoch result line (shared with the holdout report).
    static func line(_ s: ScoredEpoch) -> String {
        let w = s.estimate
        let outcome: String
        switch w.outcome {
        case .acousticConsistentProposal(let p): outcome = String(format: "proposal ppm=%.3f clockMax=%.4fms acousticP95=%.4fms", p.ppm, s.clockResidualsMs.max() ?? -1, p.acousticResidualP95Milliseconds)
        case .abstained(let a): outcome = "abstained \(a.reason.rawValue): \(a.detail)"
        }
        return "\(s.stratum.rawValue)#\(s.caseIndex) truth ppm=\(String(format: "%.3f", s.truth.ppm)) eligible=\(w.coverage.eligibleCount)/\(w.coverage.windowCount) span=\(String(format: "%.3f", w.coverage.eligibleSpanFraction)) peak=\(String(format: "%.3f", w.scores.medianPeakScore)) flags=\(w.flags.map(\.rawValue).sorted()) cycle=\(w.cycle) -> \(outcome)"
    }

    @Test func calibrationAgainstClockTruth() async throws {
        let scored = try await Self.runAll()
        let summaries = Self.summarise(scored)
        print("WW-016 calibration (master seed 0x\(String(CalibrationPlan.calibrationMasterSeed, radix: 16)), estimator \(AcousticEstimator.identifier))\n" + Self.table(summaries))
        for s in scored { print("  " + Self.line(s)) }

        #expect(Set(summaries.keys) == Set(Stratum.allCases))
        // The frozen gate definition (shared with the holdout): zero false accepts, every positive proposal meets
        // the window gates, pooled positive clock-truth residuals meet the clock gates.
        let gate = GateEvaluation(scored)
        print(gate.summary)
        #expect(gate.passed, "\(gate.failures)")
        #expect(gate.falseAccepts.isEmpty)
        #expect(scored.allSatisfy { $0.estimate.epochClockMap.provenanceKind != .clockApproved })
        // Calibration-only expectations (not gates): every acoustic-delay proposal is outside the clock gates --
        // which is exactly why none may ever be promoted.
        #expect(gate.positiveProposals == gate.positiveEpochs)
        #expect(gate.acousticDelayWithinClockGates.isEmpty)
        #expect(gate.acousticDelayProposals > 0)
        // Restarts are flagged and never bridged; cycles are measured in three-group scenes.
        for s in scored where s.stratum == .positiveRestart { #expect(s.estimate.flags.contains(.restartedEpoch)) }
        for s in scored where s.stratum == .positiveThreeGroup { #expect(s.estimate.cycle != .unavailable) }
        for s in scored where s.stratum == .cycleConflict {
            if case .abstained(let a) = s.estimate.outcome { #expect(a.reason == .cycleInconsistent) }
        }
        for s in scored where s.stratum == .disconnected {
            if case .abstained(let a) = s.estimate.outcome { #expect(a.reason == .disconnected) }
        }
    }
}

extension EpochClockMap {
    var provenanceKind: MapProvenance.Kind? {
        if case .mapped(_, let provenance) = mapping { return provenance.kind }
        return nil
    }
}
