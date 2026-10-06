import Foundation
import Testing
import WWAlignEstimate
import WWTimeMap

/// m2-freeze-estimator: the frozen definition (docs/m2/fixtures/m2-freeze-estimator.json) and its holdout harness.
///
/// `frozenDefinitionMatchesTheFreezeRecord` and `holdoutIsDisjointFromCalibration` always run: they render and
/// estimate nothing, and fail if the code drifts from the committed freeze. `frozenHoldout` renders and estimates
/// the holdout and is DISABLED unless `WW_ESTIMATOR_HOLDOUT=1`; it runs once per frozen revision, on a clean
/// commit containing the freeze, in its own PR -- never in CI, `scripts/test.sh` or a calibration run.
@Suite("Estimator freeze (m2-freeze-estimator)")
struct HoldoutTests {
    static let freezeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/m2/fixtures/m2-freeze-estimator.json")

    static var holdoutEnabled: Bool { ProcessInfo.processInfo.environment["WW_ESTIMATOR_HOLDOUT"] == "1" }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }
    static func countsMap(_ counts: [(Stratum, Int)]) -> [String: Int] { Dictionary(uniqueKeysWithValues: counts.map { ($0.0.rawValue, $0.1) }) }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.freezeURL)) as? [String: Any])
        #expect(json["freezeID"] as? String == "m2-freeze-estimator")
        let estimator = try #require(json["estimator"] as? [String: Any])
        #expect(estimator["identifier"] as? String == AcousticEstimator.identifier)
        let p = EstimatorParameters()
        let frozen = try #require(estimator["parameters"] as? [String: Double])
        let actual: [String: Double] = [
            "proxyRate": p.proxyRate, "proxyCutoffFraction": p.proxyCutoffFraction, "windowSeconds": p.windowSeconds,
            "windowCount": Double(p.windowCount), "minimumPeakScore": p.minimumPeakScore, "ambiguityRatio": p.ambiguityRatio,
            "periodicityThreshold": p.periodicityThreshold, "lobeExclusionMilliseconds": p.lobeExclusionMilliseconds,
            "silenceRMS": p.silenceRMS, "consistencyToleranceMilliseconds": p.consistencyToleranceMilliseconds,
            "maximumAbsolutePPM": p.maximumAbsolutePPM, "cycleToleranceMilliseconds": p.cycleToleranceMilliseconds,
        ]
        #expect(frozen == actual)
        let gate = try #require(json["gate"] as? [String: Any])
        let numbers = try #require(gate["values"] as? [String: Double])
        #expect(numbers == [
            "maximumResidualP95Milliseconds": ProvisionalClockGates.maximumResidualP95Milliseconds,
            "maximumResidualMaxMilliseconds": ProvisionalClockGates.maximumResidualMaxMilliseconds,
            "minimumWindows": Double(ProvisionalClockGates.minimumWindows),
            "minimumOverlapSpanFraction": ProvisionalClockGates.minimumOverlapSpanFraction,
            "minimumEligibleWindowFraction": ProvisionalClockGates.minimumEligibleWindowFraction,
            "maximumFalseAccepts": 0,
        ])
        let split = try #require(json["split"] as? [String: Any])
        let holdout = try #require(split["holdout"] as? [String: Any])
        let calibration = try #require(split["calibration"] as? [String: Any])
        #expect(holdout["masterSeed"] as? String == Self.hex(CalibrationPlan.holdoutMasterSeed))
        #expect(calibration["masterSeed"] as? String == Self.hex(CalibrationPlan.calibrationMasterSeed))
        #expect(holdout["counts"] as? [String: Int] == Self.countsMap(CalibrationPlan.holdoutCounts))
        #expect(calibration["counts"] as? [String: Int] == Self.countsMap(CalibrationPlan.counts))
        #expect(Set(CalibrationPlan.holdoutCounts.map(\.0)) == Set(Stratum.allCases))
        // Counts never fall below the calibration counts.
        for (stratum, n) in CalibrationPlan.counts { #expect((Self.countsMap(CalibrationPlan.holdoutCounts)[stratum.rawValue] ?? 0) >= n) }
    }

    @Test func holdoutIsDisjointFromCalibration() {
        let calibration = Set(CalibrationPlan.seeds(master: CalibrationPlan.calibrationMasterSeed, counts: CalibrationPlan.counts))
        let holdout = CalibrationPlan.seeds(master: CalibrationPlan.holdoutMasterSeed, counts: CalibrationPlan.holdoutCounts)
        #expect(Set(holdout).count == holdout.count)
        #expect(calibration.isDisjoint(with: holdout))
    }

    @Test(.enabled(if: HoldoutTests.holdoutEnabled, "frozen holdout: run once per frozen revision with WW_ESTIMATOR_HOLDOUT=1"))
    func frozenHoldout() async throws {
        let scored = try await CalibrationTests.runAll(CalibrationPlan.cases(master: CalibrationPlan.holdoutMasterSeed, counts: CalibrationPlan.holdoutCounts))
        let summaries = CalibrationTests.summarise(scored)
        print("WW-016 FROZEN HOLDOUT m2-freeze-estimator (master seed \(Self.hex(CalibrationPlan.holdoutMasterSeed)), estimator \(AcousticEstimator.identifier))\n" + CalibrationTests.table(summaries))
        for s in scored { print("  " + CalibrationTests.line(s)) }
        let gate = GateEvaluation(scored)
        print(gate.summary)
        #expect(Set(summaries.keys) == Set(Stratum.allCases))
        for (stratum, n) in CalibrationPlan.holdoutCounts { #expect(summaries[stratum]?.cases == n) }
        #expect(gate.passed, "\(gate.failures)")
    }
}
