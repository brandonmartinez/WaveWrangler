import CryptoKit
import Foundation
import Testing
import WWAlignEstimate
import WWTimeMap

/// m2-freeze-estimator-2: revised test harness (docs/m2/fixtures/m2-freeze-estimator-2.json), same frozen estimator.
///
/// The consistency tests (definition, pinned trees, registry, seed disjointness) always run: they render and
/// estimate nothing, and fail if the code drifts from the committed freeze. `frozenHoldout` renders and estimates
/// the holdout and is DISABLED unless `WW_ESTIMATOR_HOLDOUT=1`; it runs once per frozen revision, on a clean
/// commit containing the freeze, in its own PR -- never in CI, `scripts/test.sh` or a calibration run.
@Suite("Estimator freeze (m2-freeze-estimator-2)")
struct HoldoutTests {
    static let freezeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/m2/fixtures/m2-freeze-estimator-2.json")

    static var holdoutEnabled: Bool { ProcessInfo.processInfo.environment["WW_ESTIMATOR_HOLDOUT"] == "1" }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }
    static func countsMap(_ counts: [(Stratum, Int)]) -> [String: Int] { Dictionary(uniqueKeysWithValues: counts.map { ($0.0.rawValue, $0.1) }) }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.freezeURL)) as? [String: Any])
        #expect(json["freezeID"] as? String == "m2-freeze-estimator-2")
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
        #expect(holdout["masterSeed"] as? String == Self.hex(CalibrationPlan.revision2HoldoutMasterSeed))
        #expect(calibration["masterSeed"] as? String == Self.hex(CalibrationPlan.calibrationMasterSeed))
        #expect(holdout["counts"] as? [String: Int] == Self.countsMap(CalibrationPlan.revision2HoldoutCounts))
        #expect(calibration["counts"] as? [String: Int] == Self.countsMap(CalibrationPlan.counts))
        #expect(Set(CalibrationPlan.revision2HoldoutCounts.map(\.0)) == Set(Stratum.allCases))
        // Counts never fall below the calibration counts.
        for (stratum, n) in CalibrationPlan.counts { #expect((Self.countsMap(CalibrationPlan.revision2HoldoutCounts)[stratum.rawValue] ?? 0) >= n) }
    }

    /// Git tree ID of a flat directory of regular files (git's object format: SHA-1 over "tree <n>\0" and
    /// sorted "100644 <name>\0<20-byte blob ID>" entries). Matches `git rev-parse HEAD:<dir>` for a clean
    /// checkout; any untracked or edited file changes it.
    static func gitTreeID(_ directory: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var body = Data()
        for name in names {
            let content = try Data(contentsOf: directory.appendingPathComponent(name))
            var blob = Data("blob \(content.count)\0".utf8)
            blob.append(content)
            body.append(Data("100644 \(name)\0".utf8))
            body.append(contentsOf: Insecure.SHA1.hash(data: blob))
        }
        var tree = Data("tree \(body.count)\0".utf8)
        tree.append(body)
        return Insecure.SHA1.hash(data: tree).map { String(format: "%02x", $0) }.joined()
    }

    /// The estimator source and this test tree (generator, plan, gate, harness) are pinned by the freeze. A
    /// change after the freeze is a new freeze revision (and a fresh holdout), never a silent edit.
    @Test func estimatorAndHarnessTreesMatchTheFreezeRecord() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.freezeURL)) as? [String: Any])
        let trees = try #require(json["pinnedTrees"] as? [String: String])
        let package = Self.freezeURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packages/WaveWranglerKit")
        #expect(trees.count == 2)
        for (path, frozen) in trees {
            let actual = try Self.gitTreeID(package.appendingPathComponent(path))
            #expect(actual == frozen, "\(path) is \(actual) but m2-freeze-estimator-2 pins \(frozen): a frozen tree changed; record a new freeze revision before any holdout")
        }
    }

    /// The M2 fixture registry lists every stratum once, with the frozen split counts.
    @Test func fixtureRegistryMatchesThePlan() throws {
        let url = Self.freezeURL.deletingLastPathComponent().appendingPathComponent("m2-fixture-registry.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fixtures = try #require(json["fixtures"] as? [[String: Any]])
        let calibration = Self.countsMap(CalibrationPlan.counts)
        let holdout = Self.countsMap(CalibrationPlan.holdoutCounts)
        #expect(fixtures.compactMap { $0["stratum"] as? String }.sorted() == Stratum.allCases.map(\.rawValue).sorted())
        for fixture in fixtures {
            let stratum = try #require(fixture["stratum"] as? String)
            let split = try #require(fixture["split"] as? [String: Any])
            #expect(split["calibration"] as? Int == calibration[stratum], "\(stratum)")
            #expect(split["holdout"] as? Int == holdout[stratum], "\(stratum)")
        }
        let freezes = try #require(json["freezes"] as? [[String: Any]])
        #expect(freezes.contains { $0["freezeID"] as? String == "m2-freeze-estimator" })
    }

    @Test func holdoutIsDisjointFromCalibration() {
        let calibration = Set(CalibrationPlan.seeds(master: CalibrationPlan.calibrationMasterSeed, counts: CalibrationPlan.counts))
        let holdout = CalibrationPlan.seeds(master: CalibrationPlan.holdoutMasterSeed, counts: CalibrationPlan.holdoutCounts)
        #expect(Set(holdout).count == holdout.count)
        #expect(calibration.isDisjoint(with: holdout))

        let revision2Holdout = CalibrationPlan.seeds(master: CalibrationPlan.revision2HoldoutMasterSeed, counts: CalibrationPlan.revision2HoldoutCounts)
        #expect(Set(revision2Holdout).count == revision2Holdout.count)
        #expect(calibration.isDisjoint(with: revision2Holdout))
        #expect(Set(holdout).isDisjoint(with: revision2Holdout))
    }

    @Test(.enabled(if: HoldoutTests.holdoutEnabled, "m2-freeze-estimator-2 holdout: run once with WW_ESTIMATOR_HOLDOUT=1"))
    func frozenHoldout() async throws {
        let scored = try await CalibrationTests.runAll(CalibrationPlan.cases(master: CalibrationPlan.revision2HoldoutMasterSeed, counts: CalibrationPlan.revision2HoldoutCounts))
        let summaries = CalibrationTests.summarise(scored)
        print("WW-016 FROZEN HOLDOUT m2-freeze-estimator-2 (master seed \(Self.hex(CalibrationPlan.revision2HoldoutMasterSeed)), estimator \(AcousticEstimator.identifier))\n" + CalibrationTests.table(summaries))
        for s in scored { print("  " + CalibrationTests.line(s)) }
        let gate = GateEvaluation(scored)
        print(gate.summary)
        #expect(Set(summaries.keys) == Set(Stratum.allCases))
        for (stratum, n) in CalibrationPlan.revision2HoldoutCounts { #expect(summaries[stratum]?.cases == n) }
        #expect(gate.passed, "\(gate.failures)")
    }
}
