import CryptoKit
import Foundation
import Testing
import WWCore
@testable import WWTimeMap

// M2-TIMEMAP-001: WW-015 time-map truth cases (m2-freeze-timemap, docs/m2/fixtures/m2-freeze-timemap.json).
//
// Recipe: 7 strata, stratum = case index mod 7. Each case seeds `SplitMix64` from the frozen fixture seed
// and draws `SyntheticTimeMapGenerator.timeline` until the timeline satisfies its stratum (rejection
// sampling; the same generator stream then drives `RoundTripPropertyTests.probe`). Truth is the oracle
// evaluated from the generating parameters (`t = a*(n/F + e) + b`, `n = F*((t - b)/a - e)`), independent of
// the compiled pieces under test. Nothing touches files, recordings or clocks.
//
// Gates are `TimeMapGates`, frozen as m2-freeze-timemap. The holdout split runs only with
// WW_M2_TIMEMAP_HOLDOUT=1 and has NOT been run.

/// The frozen time-map gates (m2-freeze-timemap; TimeMapFreezeTests fails on drift).
enum TimeMapGates {
    /// "round trip ≤0.5 source frame": |nearest returned frame − exact inverse|, source frames.
    static let roundTripSourceFrames = 0.5
    /// Failure counts per category; all zero.
    static let maximumRoundTripFailures = 0
    static let maximumGapNonInvertibilityFailures = 0
    static let maximumStateAgreementFailures = 0
    static let maximumOracleFailures = 0
    /// Reported (not gated) percentile of the quantisation error.
    static let reportedPercentile = 95.0
}

enum TimeMapFixture {
    static let fixtureID = "M2-TIMEMAP-001"
    static let calibrationCases = 700
    static let holdoutCases = 2100
    static let holdoutEnabled = ProcessInfo.processInfo.environment["WW_M2_TIMEMAP_HOLDOUT"] == "1"
    /// The calibration split is a serialized pass of scripts/test.sh, not the parallel package run.
    static let calibrationEnabled = ProcessInfo.processInfo.environment["WW_TIMEMAP_CALIBRATION"] == "1"
    static let recordsDirectory = ProcessInfo.processInfo.environment["WW_TIMEMAP_RECORDS_DIR"]
    /// Compute budget: a split measures at most this many cases at once (never the core count).
    /// `WW_M2_FREEZE_MAX_CONCURRENCY` may lower it; values outside 1...4 are clamped. Records are sorted by
    /// caseIndex, so the limit never changes a record.
    static let defaultMaxConcurrency = 4
    static let maxConcurrency = concurrencyLimit(from: ProcessInfo.processInfo.environment["WW_M2_FREEZE_MAX_CONCURRENCY"])

    static func concurrencyLimit(from value: String?) -> Int {
        guard let value, let requested = Int(value) else { return defaultMaxConcurrency }
        return min(max(requested, 1), defaultMaxConcurrency)
    }
    /// A stratum not met within this many draws is recorded as an oracle failure (never silently skipped).
    static let maximumDraws = 10_000

    static func seed(split: String, index: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m2-fixture|v1|\(fixtureID)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

enum TimeMapStratum: Int, CaseIterable, Sendable {
    case general, multiSegment, gap, unsupported, extremeRateRatio, edgeNominalRate, longOccurrence

    var name: String {
        switch self {
        case .general: "general"
        case .multiSegment: "multi-segment"
        case .gap: "gap"
        case .unsupported: "unsupported"
        case .extremeRateRatio: "extreme-rate-ratio"
        case .edgeNominalRate: "edge-nominal-rate"
        case .longOccurrence: "long-occurrence"
        }
    }

    static let edgeRates: Set<Int64> = [1, 7, 44099, 1 << 20]

    func accepts(_ timeline: SyntheticTimeline) -> Bool {
        let groups = timeline.groups
        switch self {
        case .general:
            return true
        case .multiSegment:
            return groups.contains { $0.epochs.contains { if case let .mapped(segments, _) = $0.mapping { segments.count >= 2 } else { false } } }
        case .gap:
            return groups.contains { $0.occurrences.contains { occ in zip(occ.spans, occ.spans.dropFirst()).contains { $0.end < $1.start } } }
        case .unsupported:
            return groups.contains { group in
                group.occurrences.contains { occ in occ.spans.contains { if case .unsupported = group.epoch($0.epoch).mapping { true } else { false } } }
            }
        case .extremeRateRatio:
            let limit = q(1, 10) // |a − 1| ≥ 100,000 ppm
            return groups.contains { $0.epochs.contains {
                guard case let .mapped(segments, _) = $0.mapping else { return false }
                return segments.contains { s in
                    let offset = try! s.a.subtracting(.one)
                    return (offset < .zero ? offset.negated() : offset) >= limit
                }
            } }
        case .edgeNominalRate:
            return groups.contains { $0.occurrences.contains { Self.edgeRates.contains($0.rate) } }
        case .longOccurrence:
            return groups.contains { $0.occurrences.contains { $0.occurrence.frameCount >= 1 << 32 } }
        }
    }
}

struct TimeMapCaseRecord: Codable, Sendable {
    var split: String
    var caseIndex: Int
    var seed: String
    var stratum: String
    var draws: Int
    var groups = 0
    var occurrences = 0
    var spans = 0
    var maxFrameCount: Int64 = 0
    var frameRoundTrips = 0
    var forwardGap = 0
    var forwardUnsupported = 0
    var forwardOutside = 0
    var inverseSource = 0
    var inverseGap = 0
    var inverseUnsupported = 0
    var inverseOutside = 0
    /// |returned frame − exact inverse| per inverse that returned a source, source frames, in probe order.
    /// Recorded raw so the pooled nearest-rank p95 and max can be recomputed from the records file alone.
    var quantisation: [Double] = []
    var quantisationCount = 0
    var quantisationMax: Double?
    var quantisationP95: Double?
    var failureCounts: [String: Int] = [:]
    var failures: [String] = []

    enum CodingKeys: String, CodingKey {
        case split, caseIndex, seed, stratum, draws, groups, occurrences, spans, maxFrameCount, frameRoundTrips
        case forwardGap, forwardUnsupported, forwardOutside, inverseSource, inverseGap, inverseUnsupported, inverseOutside
        case quantisation, quantisationCount, quantisationMax, quantisationP95, failureCounts, failures
    }
}

struct TimeMapGateOutcome: CustomStringConvertible {
    var gate: String
    var worst: Double
    var limit: Double
    var passed: Bool
    var detail: [String]
    var description: String { "\(gate): worst \(worst) limit \(limit) \(passed ? "PASS" : "FAIL") \(detail.prefix(8))" }
}

enum TimeMapGateEvaluation {
    /// Evaluates every frozen gate. A gate without evidence fails (never passes vacuously).
    static func evaluate(_ records: [TimeMapCaseRecord]) -> [TimeMapGateOutcome] {
        func failures(_ category: RoundTripPropertyTests.FailureCategory) -> (Int, [String]) {
            let bad = records.filter { ($0.failureCounts[category.rawValue] ?? 0) > 0 }
            return (records.reduce(0) { $0 + ($1.failureCounts[category.rawValue] ?? 0) }, bad.flatMap { r in r.failures.filter { $0.hasPrefix("[\(category.rawValue)]") }.map { "\(r.split)#\(r.caseIndex): \($0)" } })
        }
        let quantisation = records.flatMap(\.quantisation)
        let maxQ = quantisation.contains { $0.isNaN } ? Double.nan : (quantisation.max() ?? .nan)
        let (roundTrip, roundTripDetail) = failures(.roundTrip)
        let roundTripEvidence = !quantisation.isEmpty && records.reduce(0) { $0 + $1.frameRoundTrips } > 0
        let (gap, gapDetail) = failures(.gapNonInvertibility)
        let gapEvidence = records.reduce(0) { $0 + $1.forwardGap } > 0 && records.reduce(0) { $0 + $1.inverseGap } > 0
        let (state, stateDetail) = failures(.stateAgreement)
        let stateEvidence = gapEvidence && records.reduce(0) { $0 + $1.forwardUnsupported } > 0 && records.reduce(0) { $0 + $1.inverseUnsupported } > 0
        let (oracle, oracleDetail) = failures(.oracle)
        let present = Set(records.map(\.stratum))
        let missing = TimeMapStratum.allCases.map(\.name).filter { !present.contains($0) }
        func counted(_ gate: String, _ count: Int, _ limit: Int, _ evidence: Bool, _ detail: [String]) -> TimeMapGateOutcome {
            TimeMapGateOutcome(gate: gate, worst: evidence ? Double(count) : .nan, limit: Double(limit), passed: evidence && count <= limit, detail: evidence ? detail : ["no evidence"])
        }
        return [
            TimeMapGateOutcome(
                gate: "round-trip", worst: roundTripEvidence ? maxQ : .nan, limit: TimeMapGates.roundTripSourceFrames,
                passed: roundTripEvidence && maxQ <= TimeMapGates.roundTripSourceFrames && roundTrip <= TimeMapGates.maximumRoundTripFailures,
                detail: ["failures \(roundTrip)", "p\(Int(TimeMapGates.reportedPercentile)) \(nearestRank(quantisation, TimeMapGates.reportedPercentile))"] + roundTripDetail
            ),
            counted("gap-non-invertibility", gap, TimeMapGates.maximumGapNonInvertibilityFailures, gapEvidence, gapDetail),
            counted("unsupported-gap-agreement", state, TimeMapGates.maximumStateAgreementFailures, stateEvidence, stateDetail),
            counted("oracle-agreement", oracle, TimeMapGates.maximumOracleFailures, !records.isEmpty, oracleDetail),
            TimeMapGateOutcome(gate: "strata-coverage", worst: Double(missing.count), limit: 0, passed: !records.isEmpty && missing.isEmpty, detail: missing),
        ]
    }
}

func measureTimeMapCase(split: String, index: Int) -> TimeMapCaseRecord {
    let seed = TimeMapFixture.seed(split: split, index: index)
    let stratum = TimeMapStratum(rawValue: index % TimeMapStratum.allCases.count)!
    var rng = SplitMix64(seed: seed)
    var record = TimeMapCaseRecord(split: split, caseIndex: index, seed: String(format: "0x%016llX", seed), stratum: stratum.name, draws: 0)
    var stats = RoundTripPropertyTests.Stats()
    var truth: SyntheticTimeline?
    while record.draws < TimeMapFixture.maximumDraws {
        record.draws += 1
        let candidate = SyntheticTimeMapGenerator.timeline(&rng)
        if stratum.accepts(candidate) {
            truth = candidate
            break
        }
    }
    if let truth {
        switch Result(catching: { () throws(TimeMapError) in try truth.build() }) {
        case let .failure(error):
            stats.fail(.oracle, "generated timeline refused: \(error)")
        case let .success(map):
            for group in truth.groups {
                record.groups += 1
                for occ in group.occurrences {
                    record.occurrences += 1
                    record.spans += occ.spans.count
                    record.maxFrameCount = max(record.maxFrameCount, occ.occurrence.frameCount)
                    RoundTripPropertyTests.probe(map, group, occ, &rng, &stats)
                }
            }
        }
    } else {
        stats.fail(.oracle, "stratum \(stratum.name) not met in \(TimeMapFixture.maximumDraws) draws")
    }
    record.frameRoundTrips = stats.frameRoundTrips
    record.forwardGap = stats.forwardGap
    record.forwardUnsupported = stats.forwardUnsupported
    record.forwardOutside = stats.forwardOutside
    record.inverseSource = stats.inverseSource
    record.inverseGap = stats.inverseGap
    record.inverseUnsupported = stats.inverseUnsupported
    record.inverseOutside = stats.inverseOutside
    record.quantisation = stats.quantisation
    record.quantisationCount = stats.quantisation.count
    record.quantisationMax = stats.quantisation.max()
    record.quantisationP95 = stats.quantisation.isEmpty ? nil : nearestRank(stats.quantisation, 95)
    record.failureCounts = Dictionary(uniqueKeysWithValues: stats.failureCounts.map { ($0.key.rawValue, $0.value) })
    record.failures = stats.failures
    return record
}

func runTimeMapSplit(_ split: String, cases: Int) async throws -> [TimeMapCaseRecord] {
    let records = await withTaskGroup(of: TimeMapCaseRecord.self) { group in
        var next = 0
        func addNext() {
            guard next < cases else { return }
            let index = next
            next += 1
            group.addTask { measureTimeMapCase(split: split, index: index) }
        }
        for _ in 0 ..< TimeMapFixture.maxConcurrency { addNext() }
        var results: [TimeMapCaseRecord] = []
        while let result = await group.next() {
            results.append(result)
            addNext()
        }
        return results
    }.sorted { $0.caseIndex < $1.caseIndex }
    let quantisation = records.flatMap(\.quantisation)
    print("""
    M2-TIMEMAP-001 \(split): cases=\(records.count) draws=\(records.reduce(0) { $0 + $1.draws }) occurrences=\(records.reduce(0) { $0 + $1.occurrences }) \
    spans=\(records.reduce(0) { $0 + $1.spans }) maxFrameCount=\(records.map(\.maxFrameCount).max() ?? 0) \
    frameRoundTrips=\(records.reduce(0) { $0 + $1.frameRoundTrips }) forwardGap=\(records.reduce(0) { $0 + $1.forwardGap }) \
    forwardUnsupported=\(records.reduce(0) { $0 + $1.forwardUnsupported }) inverseSource=\(records.reduce(0) { $0 + $1.inverseSource }) \
    inverseGap=\(records.reduce(0) { $0 + $1.inverseGap }) inverseUnsupported=\(records.reduce(0) { $0 + $1.inverseUnsupported }) \
    quantisation N=\(quantisation.count) max=\(quantisation.max() ?? .nan) p95(nearest-rank)=\(nearestRank(quantisation, 95))
    """)
    if let directory = TimeMapFixture.recordsDirectory {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: "\(directory)/ww-015-\(split).jsonl", atomically: true, encoding: .utf8)
    }
    return records
}

@Suite("Time-map calibration (M2-TIMEMAP-001)")
struct TimeMapCalibrationTests {
    @Test(.enabled(if: TimeMapFixture.calibrationEnabled, "serialized calibration pass (WW_TIMEMAP_CALIBRATION=1)"))
    func calibrationSplitMeetsEveryGate() async throws {
        let records = try await runTimeMapSplit("calibration", cases: TimeMapFixture.calibrationCases)
        #expect(records.count == TimeMapFixture.calibrationCases)
        for outcome in TimeMapGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Frozen holdout: runs once, only with WW_M2_TIMEMAP_HOLDOUT=1, after m2-freeze-timemap.
    @Test(.enabled(if: TimeMapFixture.holdoutEnabled))
    func holdoutSplitMeetsEveryFrozenGate() async throws {
        let records = try await runTimeMapSplit("holdout", cases: TimeMapFixture.holdoutCases)
        #expect(records.count == TimeMapFixture.holdoutCases)
        for outcome in TimeMapGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Each gate check trips on one record just past its limit and on missing evidence.
    @Test func gateChecksTripOnFailures() {
        func record(_ stratum: TimeMapStratum, _ edit: (inout TimeMapCaseRecord) -> Void = { _ in }) -> TimeMapCaseRecord {
            var r = TimeMapCaseRecord(split: "t", caseIndex: stratum.rawValue, seed: "0", stratum: stratum.name, draws: 1)
            r.frameRoundTrips = 1
            r.forwardGap = 1
            r.inverseGap = 1
            r.forwardUnsupported = 1
            r.inverseUnsupported = 1
            r.inverseSource = 2
            r.quantisation = [0, 0.5]
            edit(&r)
            return r
        }
        let good = TimeMapStratum.allCases.map { record($0) }
        #expect(TimeMapGateEvaluation.evaluate(good).allSatisfy { $0.passed })
        let breaks: [(String, TimeMapCaseRecord)] = [
            ("round-trip", record(.general) { $0.quantisation = [0.5000001] }),
            ("round-trip", record(.general) { $0.quantisation = [.nan] }),
            ("round-trip", record(.longOccurrence) { $0.failureCounts = ["round-trip": 1] }),
            ("gap-non-invertibility", record(.gap) { $0.failureCounts = ["gap-non-invertibility": 1] }),
            ("unsupported-gap-agreement", record(.unsupported) { $0.failureCounts = ["unsupported-gap-agreement": 1] }),
            ("oracle-agreement", record(.multiSegment) { $0.failureCounts = ["oracle-agreement": 1] }),
        ]
        for (gate, bad) in breaks {
            let outcomes = TimeMapGateEvaluation.evaluate(good + [bad])
            #expect(outcomes.filter { !$0.passed }.map(\.gate) == [gate], "\(gate): \(outcomes)")
        }
        // Missing evidence fails: no records, no strata, no inverse sources, no gaps, no unsupported probes.
        #expect(TimeMapGateEvaluation.evaluate([]).allSatisfy { !$0.passed })
        #expect(TimeMapGateEvaluation.evaluate(good.filter { $0.stratum != "gap" }).filter { !$0.passed }.map(\.gate) == ["strata-coverage"])
        let noInverse = good.map { r in var r = r; r.quantisation = []; return r }
        #expect(TimeMapGateEvaluation.evaluate(noInverse).filter { !$0.passed }.map(\.gate) == ["round-trip"])
        let noGap = good.map { r in var r = r; r.inverseGap = 0; return r }
        #expect(TimeMapGateEvaluation.evaluate(noGap).filter { !$0.passed }.map(\.gate) == ["gap-non-invertibility", "unsupported-gap-agreement"])
        let noUnsupported = good.map { r in var r = r; r.forwardUnsupported = 0; return r }
        #expect(TimeMapGateEvaluation.evaluate(noUnsupported).filter { !$0.passed }.map(\.gate) == ["unsupported-gap-agreement"])
    }

    /// The harness's failure categories reach the gates: a broken map shows up in the right category.
    @Test func probeFailuresAreCategorised() {
        #expect(RoundTripPropertyTests.forwardCategory(.gap, .outsideCoverage) == .gapNonInvertibility)
        #expect(RoundTripPropertyTests.forwardCategory(.unsupported, .outsideCoverage) == .stateAgreement)
        #expect(RoundTripPropertyTests.forwardCategory(.outside, .outsideCoverage) == .oracle)
        #expect(RoundTripPropertyTests.inverseCategory(.gap, .outsideCoverage) == .gapNonInvertibility)
        #expect(RoundTripPropertyTests.inverseCategory(.unsupported([]), .outsideCoverage) == .stateAgreement)
        #expect(RoundTripPropertyTests.inverseCategory(.outside, .outsideCoverage) == .oracle)
        var stats = RoundTripPropertyTests.Stats()
        for _ in 0 ..< 30 { stats.fail(.roundTrip, "x") }
        #expect(stats.failureCounts[.roundTrip] == 30 && stats.failures.count == 25)
    }

    /// Seeds are derived, stable, split-separated and disjoint from the WW-015 suites' own seeds; every
    /// stratum is reachable from its first calibration seed.
    @Test func seedsAreStableAndSplitSeparated() {
        #expect(TimeMapFixture.seed(split: "calibration", index: 0) == TimeMapFixture.seed(split: "calibration", index: 0))
        let calibration = Set((0 ..< TimeMapFixture.calibrationCases).map { TimeMapFixture.seed(split: "calibration", index: $0) })
        let holdout = Set((0 ..< TimeMapFixture.holdoutCases).map { TimeMapFixture.seed(split: "holdout", index: $0) })
        #expect(calibration.count == TimeMapFixture.calibrationCases && holdout.count == TimeMapFixture.holdoutCases)
        #expect(calibration.isDisjoint(with: holdout))
        let existing: Set<UInt64> = [RoundTripPropertyTests.seed, HostileDenominatorInverseTests.seed]
        #expect(calibration.isDisjoint(with: existing) && holdout.isDisjoint(with: existing))
        #expect(TimeMapFixture.calibrationCases % TimeMapStratum.allCases.count == 0 && TimeMapFixture.holdoutCases % TimeMapStratum.allCases.count == 0)
    }
}

/// m2-freeze-timemap consistency (docs/m2/fixtures/m2-freeze-timemap.json). These checks map nothing and
/// always run: they fail if the gates, split counts or pinned trees drift from the committed freeze. A
/// deliberate change is a new dated freeze revision, never a silent edit.
@Suite("Time-map freeze (m2-freeze-timemap)")
struct TimeMapFreezeTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let freezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-timemap.json")

    static func freeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: freezeURL)) as? [String: Any])
    }

    @Test func splitConcurrencyIsCappedAtFour() {
        #expect(TimeMapFixture.defaultMaxConcurrency <= 4)
        #expect((1 ... 4).contains(TimeMapFixture.maxConcurrency))
        #expect(TimeMapFixture.concurrencyLimit(from: nil) == TimeMapFixture.defaultMaxConcurrency)
        #expect(TimeMapFixture.concurrencyLimit(from: "not a number") == TimeMapFixture.defaultMaxConcurrency)
        #expect(TimeMapFixture.concurrencyLimit(from: "2") == 2)
        #expect(TimeMapFixture.concurrencyLimit(from: "0") == 1)
        #expect(TimeMapFixture.concurrencyLimit(from: "\(ProcessInfo.processInfo.activeProcessorCount * 4)") <= 4)
    }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try Self.freeze()
        #expect(json["freezeID"] as? String == "m2-freeze-timemap")
        #expect(json["fixtureID"] as? String == TimeMapFixture.fixtureID)

        let gates = try #require(json["gateValues"] as? [String: Double])
        #expect(gates == [
            "roundTripSourceFrames": TimeMapGates.roundTripSourceFrames,
            "maximumRoundTripFailures": Double(TimeMapGates.maximumRoundTripFailures),
            "maximumGapNonInvertibilityFailures": Double(TimeMapGates.maximumGapNonInvertibilityFailures),
            "maximumStateAgreementFailures": Double(TimeMapGates.maximumStateAgreementFailures),
            "maximumOracleFailures": Double(TimeMapGates.maximumOracleFailures),
            "reportedPercentile": TimeMapGates.reportedPercentile,
        ])

        let recipe = try #require(json["recipe"] as? [String: Any])
        #expect(recipe["strata"] as? [String] == TimeMapStratum.allCases.map(\.name))
        #expect(recipe["maximumDraws"] as? Int == TimeMapFixture.maximumDraws)
        #expect(recipe["generatorRates"] as? [Int64] == SyntheticTimeMapGenerator.rates)
        #expect(recipe["generatorPPMMilli"] as? [Int64] == SyntheticTimeMapGenerator.ppmMilli)

        let splits = try #require(json["splits"] as? [String: [String: Any]])
        #expect(splits["calibration"]?["cases"] as? Int == TimeMapFixture.calibrationCases)
        #expect(splits["holdout"]?["cases"] as? Int == TimeMapFixture.holdoutCases)
        #expect(splits["holdout"]?["run"] as? Bool == false)
        #expect(TimeMapFixture.holdoutCases >= TimeMapFixture.calibrationCases)
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

    /// The time-map source and this test tree (generator, oracle, gates, harness) are pinned by the freeze.
    @Test func timeMapAndHarnessTreesMatchTheFreezeRecord() throws {
        let trees = try #require(try Self.freeze()["pinnedTrees"] as? [String: String])
        #expect(Set(trees.keys) == ["Sources/WWTimeMap", "Tests/WWTimeMapTests"])
        let package = Self.repository.appendingPathComponent("Packages/WaveWranglerKit")
        for (path, frozen) in trees {
            let actual = try Self.gitTreeID(package.appendingPathComponent(path))
            #expect(actual == frozen, "\(path) is \(actual) but m2-freeze-timemap pins \(frozen): a frozen tree changed; record a new freeze revision before any holdout")
        }
    }

    /// The M2 fixture registry lists this freeze, its record and its fixture with the frozen counts.
    @Test func fixtureRegistryListsTheFreeze() throws {
        let url = Self.freezeURL.deletingLastPathComponent().appendingPathComponent("m2-fixture-registry.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let freezes = try #require(json["freezes"] as? [[String: Any]])
        let entry = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-timemap" })
        #expect(entry["record"] as? String == "docs/m2/fixtures/m2-freeze-timemap.json")
        #expect(entry["fixtures"] as? [String] == [TimeMapFixture.fixtureID])
        let counts = try #require(entry["counts"] as? [String: Int])
        #expect(counts["calibrationCases"] == TimeMapFixture.calibrationCases)
        #expect(counts["holdoutCases"] == TimeMapFixture.holdoutCases)
        let fixtures = try #require(entry["fixtureEntries"] as? [[String: Any]])
        #expect(fixtures.count == 1)
        let split = try #require(fixtures.first?["split"] as? [String: Any])
        #expect(fixtures.first?["id"] as? String == TimeMapFixture.fixtureID)
        #expect(split["calibration"] as? Int == TimeMapFixture.calibrationCases)
        #expect(split["holdout"] as? Int == TimeMapFixture.holdoutCases)
    }

    /// The committed calibration records are the ones the freeze hashed, and they alone reproduce the reported
    /// pooled quantisation count, max and nearest-rank p95.
    @Test func committedCalibrationRecordsReproduceTheReportedQuantisation() throws {
        let summary = try #require(try Self.freeze()["calibrationSummary"] as? [String: Any])
        let file = try #require(summary["recordsFile"] as? String)
        let data = try Data(contentsOf: Self.repository.appendingPathComponent(file))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == summary["recordsSHA256"] as? String)
        let decoder = JSONDecoder()
        let records = try data.split(separator: UInt8(ascii: "\n")).map { try decoder.decode(TimeMapCaseRecord.self, from: Data($0)) }
        #expect(records.count == TimeMapFixture.calibrationCases)
        #expect(records.map(\.caseIndex) == Array(0 ..< TimeMapFixture.calibrationCases))
        for record in records {
            #expect(record.quantisation.count == record.quantisationCount, "case \(record.caseIndex)")
            #expect(record.quantisation.count == record.inverseSource, "case \(record.caseIndex)")
            #expect(record.quantisation.max() == record.quantisationMax, "case \(record.caseIndex)")
        }
        let pooled = records.flatMap(\.quantisation)
        let reported = try #require(summary["quantisation"] as? [String: Any])
        #expect(reported["count"] as? Int == pooled.count)
        #expect(reported["max"] as? Double == pooled.max())
        #expect(reported["p95NearestRank"] as? Double == nearestRank(pooled, TimeMapGates.reportedPercentile))
    }
}
