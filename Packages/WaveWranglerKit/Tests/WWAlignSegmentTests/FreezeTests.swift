import CryptoKit
import Foundation
import Testing
import WWAlignEstimate
import WWAlignSegment
import WWTimeMap

/// m2-freeze-discontinuity consistency (docs/m2/fixtures/m2-freeze-discontinuity.json). These checks segment
/// nothing and always run: they fail if the segmenter parameters, identifiers, seeds, counts, gates, registry
/// entry or pinned trees drift from the committed freeze. A deliberate change is a new dated freeze revision,
/// never a silent edit.
@Suite("Segment freeze (m2-freeze-discontinuity)")
struct SegmentFreezeTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let freezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-discontinuity.json")

    static func freeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: freezeURL)) as? [String: Any])
    }

    static func hex(_ value: UInt64) -> String { String(format: "0x%016llX", value) }

    static func countsMap(_ counts: [(SegmentStratum, Int)]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.0.rawValue, $0.1) })
    }

    static func plants(_ counts: [(SegmentStratum, Int)]) -> Int {
        counts.reduce(0) { total, entry in
            entry.0.isNegative ? total : total + (entry.0 == .compound ? 2 : 1) * entry.1
        }
    }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try Self.freeze()
        #expect(json["freezeID"] as? String == "m2-freeze-discontinuity")

        let segmenter = try #require(json["segmenter"] as? [String: Any])
        #expect(segmenter["identifier"] as? String == DiscontinuitySegmenter.identifier)
        #expect(segmenter["customIdentifier"] as? String == DiscontinuitySegmenter.customIdentifier)
        #expect(segmenter["estimatorIdentifier"] as? String == AcousticEstimator.identifier)
        let parameters = try #require(segmenter["parameters"] as? [String: Double])
        let defaults = SegmenterParameters()
        #expect(parameters == [
            "tileSeconds": defaults.tileSeconds,
            "slicePaddingSeconds": defaults.slicePaddingSeconds,
            "splitToleranceMilliseconds": defaults.splitToleranceMilliseconds,
            "stepToleranceFactor": defaults.stepToleranceFactor,
            "minimumSegmentWindows": Double(defaults.minimumSegmentWindows),
            "minimumSupportedSeconds": defaults.minimumSupportedSeconds,
            "proposalAgreementMilliseconds": defaults.proposalAgreementMilliseconds,
        ])

        let gate = try #require(json["gate"] as? [String: Any])
        let values = try #require(gate["values"] as? [String: Double])
        #expect(values == [
            "residualP95Milliseconds": ProvisionalClockGates.maximumResidualP95Milliseconds,
            "residualMaxMilliseconds": ProvisionalClockGates.maximumResidualMaxMilliseconds,
            "plantsBridgedMaximum": 0,
            "silentBridgesMaximum": 0,
            "maximumFalseSplitRate": SegmentPlan.maximumFalseSplitRate,
        ])

        let split = try #require(json["split"] as? [String: Any])
        let calibration = try #require(split["calibration"] as? [String: Any])
        #expect(calibration["masterSeed"] as? String == Self.hex(SegmentPlan.calibrationMasterSeed))
        #expect(calibration["counts"] as? [String: Int] == Self.countsMap(SegmentPlan.counts))
        #expect(calibration["totalCases"] as? Int == SegmentPlan.counts.reduce(0) { $0 + $1.1 })
        #expect(calibration["totalPlants"] as? Int == Self.plants(SegmentPlan.counts))
        let holdout = try #require(split["holdout"] as? [String: Any])
        #expect(holdout["masterSeed"] as? String == Self.hex(SegmentPlan.holdoutMasterSeed))
        #expect(holdout["counts"] as? [String: Int] == Self.countsMap(SegmentPlan.holdoutCounts))
        #expect(holdout["totalCases"] as? Int == SegmentPlan.holdoutCounts.reduce(0) { $0 + $1.1 })
        #expect(holdout["totalPlants"] as? Int == Self.plants(SegmentPlan.holdoutCounts))
        let floor = try #require(split["floorSweep"] as? [String: Any])
        #expect(floor["masterSeed"] as? String == Self.hex(SegmentPlan.floorMasterSeed))
        #expect(floor["totalCases"] as? Int == SegmentPlan.floorCases().count)
        // Every stratum is in both splits, and the holdout is never smaller than calibration.
        let calibrationCounts = Self.countsMap(SegmentPlan.counts)
        for (stratum, count) in SegmentPlan.holdoutCounts {
            #expect(count >= calibrationCounts[stratum.rawValue] ?? .max, "\(stratum)")
        }
        #expect(Set(SegmentPlan.counts.map(\.0)) == Set(SegmentStratum.allCases))
        #expect(Set(SegmentPlan.holdoutCounts.map(\.0)) == Set(SegmentStratum.allCases))
    }

    /// Git tree ID of a flat directory of regular files: SHA-1 over "tree <n>\0" and the sorted
    /// "100644 <name>\0<20-byte blob ID>" entries. Equals `git rev-parse HEAD:<dir>` for a clean checkout;
    /// any edited or untracked file changes it.
    static func gitTreeID(_ directory: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
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

    /// The segmenter source and this test tree (generator, truth, scoring, gates, harness) are pinned.
    @Test func segmenterAndHarnessTreesMatchTheFreezeRecord() throws {
        let trees = try #require(try Self.freeze()["pinnedTrees"] as? [String: String])
        #expect(Set(trees.keys) == ["Sources/WWAlignSegment", "Tests/WWAlignSegmentTests"])
        let package = Self.repository.appendingPathComponent("Packages/WaveWranglerKit")
        for (path, frozen) in trees {
            let actual = try Self.gitTreeID(package.appendingPathComponent(path))
            #expect(actual == frozen, "\(path) is \(actual) but m2-freeze-discontinuity pins \(frozen): a frozen tree changed; record a new freeze revision before any holdout")
        }
    }

    /// The M2 fixture registry lists this freeze, its record, and one fixture per stratum with the frozen split.
    @Test func fixtureRegistryListsTheFreeze() throws {
        let url = Self.freezeURL.deletingLastPathComponent().appendingPathComponent("m2-fixture-registry.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let freezes = try #require(json["freezes"] as? [[String: Any]])
        let entry = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-discontinuity" })
        #expect(entry["record"] as? String == "docs/m2/fixtures/m2-freeze-discontinuity.json")
        let counts = try #require(entry["counts"] as? [String: Int])
        #expect(counts["fixtures"] == SegmentStratum.allCases.count)
        #expect(counts["calibrationCases"] == SegmentPlan.counts.reduce(0) { $0 + $1.1 })
        #expect(counts["calibrationPlants"] == Self.plants(SegmentPlan.counts))
        #expect(counts["holdoutCases"] == SegmentPlan.holdoutCounts.reduce(0) { $0 + $1.1 })
        #expect(counts["holdoutPlants"] == Self.plants(SegmentPlan.holdoutCounts))
        let fixtures = try #require(entry["fixtureEntries"] as? [[String: Any]])
        #expect(entry["fixtures"] as? [String] == fixtures.compactMap { $0["id"] as? String })
        #expect(fixtures.compactMap { $0["stratum"] as? String }.sorted() == SegmentStratum.allCases.map(\.rawValue).sorted())
        let calibration = Self.countsMap(SegmentPlan.counts)
        let holdout = Self.countsMap(SegmentPlan.holdoutCounts)
        for fixture in fixtures {
            let stratum = try #require(fixture["stratum"] as? String)
            let split = try #require(fixture["split"] as? [String: Any])
            #expect(split["calibration"] as? Int == calibration[stratum], "\(stratum)")
            #expect(split["holdout"] as? Int == holdout[stratum], "\(stratum)")
        }
    }

    /// The committed per-case records are the ones the freeze hashed, they cover exactly the planned cases with
    /// their planted truth, and they alone reproduce every reported total and the calibration gate verdict.
    @Test func committedRecordsReproduceTheReportedCalibration() throws {
        let summary = try #require(try Self.freeze()["calibrationSummary"] as? [String: Any])

        // Calibration: plan order, identities and planted truth; totals; the WW-017 gates recomputed.
        let (calibration, calibrationTotals) = try Self.committedRecords(summary)
        let plan = SegmentPlan.cases()
        #expect(calibration.map(\.label) == plan.map(SegmentCaseRecord.label))
        try Self.expectTruth(calibration, plan)
        let c = SegmentRecordTotals(calibration)
        #expect(c.dictionary == calibrationTotals)
        #expect(c.cases == SegmentPlan.counts.reduce(0) { $0 + $1.1 })
        #expect(c.plants == Self.plants(SegmentPlan.counts))
        #expect(c.plantsFlagged + c.plantsUnsupported == c.plants)
        #expect(c.plantsBridged == 0 && c.bridgingRegions == 0 && c.silentBridges == 0)
        #expect(c.casesWithHardFailures == 0 && c.invariantFailures == 0)
        #expect(c.negatives == SegmentPlan.counts.filter { $0.0.isNegative }.reduce(0) { $0 + $1.1 })
        #expect(c.falseSplitRate <= SegmentPlan.maximumFalseSplitRate)
        #expect(c.worstResidualP95Milliseconds <= Scoring.p95Gate && c.worstResidualMaxMilliseconds <= Scoring.maxGate)

        // Floor sweep (reported, not gated): plan order and truth; totals; the hard invariants hold.
        let (floor, floorTotals) = try Self.committedRecords(try #require(summary["floorSweepRecords"] as? [String: Any]))
        let floorPlan = SegmentPlan.floorCases()
        #expect(floor.map(\.label) == floorPlan.map(\.label))
        try Self.expectTruth(floor, floorPlan.map(\.kase))
        let f = SegmentRecordTotals(floor)
        #expect(f.dictionary == floorTotals)
        #expect(f.invariantFailures == 0)

        // Edge silence (gated with calibration): the six muted calibration cases.
        let (edge, edgeTotals) = try Self.committedRecords(try #require(summary["edgeSilenceRecords"] as? [String: Any]))
        let edgePlan = EdgeSilenceTests.cases()
        #expect(edge.map(\.label) == edgePlan.map(SegmentCaseRecord.edgeSilenceLabel))
        #expect(edge.map(\.mute) == edgePlan.map { $0.mute.map { [$0.lowerBound, $0.upperBound] } })
        try Self.expectTruth(edge, edgePlan)
        let e = SegmentRecordTotals(edge)
        #expect(e.dictionary == edgeTotals)
        #expect(e.cases == 6 && e.plantsBridged == 0 && e.silentBridges == 0 && e.casesWithHardFailures == 0)
        #expect(e.worstResidualMaxMilliseconds <= Scoring.maxGate)
    }

    /// Reads `recordsFile`, checks `recordsSHA256`, and returns the records with the reported `totals`.
    static func committedRecords(_ entry: [String: Any]) throws -> ([SegmentCaseRecord], [String: Double]) {
        let file = try #require(entry["recordsFile"] as? String)
        let data = try Data(contentsOf: repository.appendingPathComponent(file))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == entry["recordsSHA256"] as? String, "\(file)")
        let records = try SegmentCaseRecord.decode(data)
        #expect(try SegmentCaseRecord.jsonLines(records) == data, "\(file) is not canonical (sorted keys, one case per line)")
        return (records, try #require(entry["totals"] as? [String: Double]))
    }

    /// Each record carries its planned case's seed, rate, length and plants (independent truth, not the fit).
    static func expectTruth(_ records: [SegmentCaseRecord], _ plan: [SegmentCase]) throws {
        try #require(records.count == plan.count)
        for (record, kase) in zip(records, plan) {
            #expect(record.stratum == kase.stratum.rawValue && record.index == kase.index, "\(record.label)")
            #expect(record.seed == hex(kase.seed) && record.rate == kase.truth.rate && record.lengthSeconds == kase.lengthSeconds, "\(record.label)")
            #expect(record.negative == kase.stratum.isNegative, "\(record.label)")
            #expect(record.plants.map(\.kind) == kase.plants.map(\.kind.rawValue), "\(record.label)")
            #expect(record.plants.map(\.frame) == kase.plants.map(\.frame), "\(record.label)")
            #expect(record.plants.map(\.insertedFrames) == kase.plants.map { $0.inserted?.count }, "\(record.label)")
        }
    }

    /// Seeds only (nothing rendered): calibration, floor sweep and holdout never share a case.
    @Test func holdoutIsDisjointFromCalibrationAndFloor() {
        let calibration = SegmentPlan.seeds(master: SegmentPlan.calibrationMasterSeed, counts: SegmentPlan.counts)
        let holdout = SegmentPlan.seeds(master: SegmentPlan.holdoutMasterSeed, counts: SegmentPlan.holdoutCounts)
        let floor = SegmentPlan.floorCases().map(\.kase.seed)
        #expect(Set(calibration).count == calibration.count)
        #expect(Set(holdout).count == holdout.count)
        #expect(Set(floor).count == floor.count)
        #expect(Set(calibration).isDisjoint(with: holdout))
        #expect(Set(floor).isDisjoint(with: holdout))
        #expect(Set(floor).isDisjoint(with: calibration))
    }
}

/// The frozen holdout. Disabled unless WW_SEGMENT_HOLDOUT=1; run once per frozen revision in its own PR
/// (docs/m2/fixtures/m2-freeze-discontinuity.json holdoutProcedure). Never run by CI or scripts/test.sh.
@Suite("Segment holdout (m2-freeze-discontinuity)")
struct SegmentHoldoutTests {
    static let enabled = ProcessInfo.processInfo.environment["WW_SEGMENT_HOLDOUT"] == "1"

    @Test(.enabled(if: SegmentHoldoutTests.enabled, "frozen holdout: run once per frozen revision with WW_SEGMENT_HOLDOUT=1"))
    func frozenHoldout() async throws {
        let scores = try await SegmentRunner.runAll(SegmentPlan.cases(master: SegmentPlan.holdoutMasterSeed, counts: SegmentPlan.holdoutCounts))
        print("WW-017 FROZEN HOLDOUT m2-freeze-discontinuity (master seed \(SegmentFreezeTests.hex(SegmentPlan.holdoutMasterSeed)), segmenter \(DiscontinuitySegmenter.identifier), estimator \(AcousticEstimator.identifier))")
        for score in scores { print("WW-017 holdout " + SegmentRunner.line(score)) }
        try SegmentCaseRecord.write(scores.map { SegmentCaseRecord(label: SegmentCaseRecord.label($0.kase), score: $0) }, split: "holdout")
        print("WW-017 holdout table\n" + SegmentRunner.table(scores))
        let failures = SegmentRunner.gateFailures(scores, maximumFalseSplitRate: SegmentPlan.maximumFalseSplitRate)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(scores.flatMap(\.plants).allSatisfy { $0.status != .bridged })
        #expect(scores.flatMap(\.plants).count == SegmentFreezeTests.plants(SegmentPlan.holdoutCounts))
    }
}
