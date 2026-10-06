import Foundation
import Testing
import WWAlignEstimate
import WWAlignSegment
import WWCore
import WWTimeMap

/// The CPU-heavy suites (calibration and floor sweep) run in scripts/test.sh's serialized segment pass, alone in
/// their process: in the parallel `swift test` pass their synchronous signal processing would occupy the
/// cooperative pool for minutes on a small CI runner and starve other suites' liveness waits.
enum SegmentHeavyGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_SEGMENT_TESTS"] == "1"
    static let reason: Comment = "serialized segment pass (WW_SEGMENT_TESTS=1, scripts/test.sh)"
}

enum SegmentRunner {
    static func run(_ kase: SegmentCase) throws -> CaseScore {
        let request = try kase.request()
        let report = try DiscontinuitySegmenter.segment(request)
        return try Scoring.score(kase, request: request, report: report)
    }

    /// Default cap on cases in flight: a heavy pass must stay near four cores on a shared machine. It never
    /// derives from the processor count.
    static let defaultMaximumConcurrency = 4

    /// `WW_SEGMENT_MAX_CONCURRENCY` may only lower the cap (1...4); anything else falls back to the default.
    static func maximumConcurrency(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment["WW_SEGMENT_MAX_CONCURRENCY"], let value = Int(raw), (1...defaultMaximumConcurrency).contains(value) else {
            return defaultMaximumConcurrency
        }
        return value
    }

    /// Runs cases with at most `maximumConcurrency()` in flight and returns scores in plan order.
    static func runAll(_ cases: [SegmentCase], maximumConcurrency limit: Int = maximumConcurrency()) async throws -> [CaseScore] {
        try await bounded(cases, maximumConcurrency: limit) { try run($0) }
    }

    /// Maps `work` over `items` with at most `limit` calls in flight, results in input order.
    static func bounded<Item: Sendable, Result: Sendable>(
        _ items: [Item], maximumConcurrency limit: Int, _ work: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var pending = items.enumerated().makeIterator()
            var done: [(Int, Result)] = []
            for _ in 0..<max(1, limit) {
                guard let (offset, item) = pending.next() else { break }
                group.addTask { (offset, try await work(item)) }
            }
            while let result = try await group.next() {
                done.append(result)
                if let (offset, item) = pending.next() { group.addTask { (offset, try await work(item)) } }
            }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func line(_ s: CaseScore) -> String {
        let plants = s.plants.map { p -> String in
            let error = p.positionErrorSeconds.map { String(format: " err %.3fs", $0) } ?? ""
            let kind = p.detection.map { " \($0.kind.rawValue)" } ?? ""
            return "\(p.plant.kind.rawValue)[\(String(format: "%.1f ms, %.0f ppm", p.plant.stepSeconds * 1000, p.plant.deltaPPM))]=\(p.status.rawValue)\(kind)\(error)"
        }.joined(separator: "; ")
        let head = String(format: "%@#%d rate %d L %.1fs: detections %d mapped %d coverage %.2f p95 %.3f max %.3f ms bridges %d ",
                          s.kase.stratum.rawValue, s.kase.index, s.kase.truth.rate, s.kase.lengthSeconds, s.detections, s.mappedRegions,
                          s.supportedFraction, s.residualP95Milliseconds, s.residualMaxMilliseconds, s.bridgingRegions)
        let detail = " | det " + (s.detectionSummary.isEmpty ? "-" : s.detectionSummary.joined(separator: ", "))
            + " | unsupported " + (s.unsupportedSummary.isEmpty ? "-" : s.unsupportedSummary.joined(separator: ", "))
        return head + plants + detail + (s.hardFailures.isEmpty ? "" : " FAIL: " + s.hardFailures.joined(separator: ", "))
    }

    /// Aggregate table by stratum, printed for the evidence note.
    static func table(_ scores: [CaseScore]) -> String {
        var rows = ["stratum | cases | plants flagged/unsupported/bridged | false splits | spurious detections | coverage (mean) | worst p95 / max ms"]
        for stratum in SegmentStratum.allCases {
            let mine = scores.filter { $0.kase.stratum == stratum }
            guard !mine.isEmpty else { continue }
            let plants = mine.flatMap(\.plants)
            let flagged = plants.filter { $0.status == .flagged }.count
            let unsupported = plants.filter { $0.status == .unsupported }.count
            let bridged = plants.filter { $0.status == .bridged }.count
            let falseSplits = stratum.isNegative ? "\(mine.filter(\.falseSplit).count)/\(mine.count)" : "n/a"
            let spurious = mine.map(\.spuriousDetections).reduce(0, +)
            let coverage = mine.map(\.supportedFraction).reduce(0, +) / Double(mine.count)
            rows.append(String(format: "%@ | %d | %d/%d/%d | %@ | %d | %.2f | %.3f / %.3f", stratum.rawValue, mine.count, flagged, unsupported, bridged,
                               falseSplits, spurious, coverage, mine.map(\.residualP95Milliseconds).max()!, mine.map(\.residualMaxMilliseconds).max()!))
        }
        return rows.joined(separator: "\n")
    }

    /// The WW-017 gates, applied identically to calibration and (later) holdout scores.
    static func gateFailures(_ scores: [CaseScore], maximumFalseSplitRate: Double) -> [String] {
        var failures: [String] = []
        for s in scores where !s.hardFailures.isEmpty {
            failures.append("\(s.kase.stratum.rawValue)#\(s.kase.index): \(s.hardFailures.joined(separator: ", "))")
        }
        for s in scores where s.silentBridges > 0 {
            failures.append("\(s.kase.stratum.rawValue)#\(s.kase.index): silent smooth bridging")
        }
        let negatives = scores.filter { $0.kase.stratum.isNegative }
        if !negatives.isEmpty {
            let rate = Double(negatives.filter(\.falseSplit).count) / Double(negatives.count)
            if rate > maximumFalseSplitRate { failures.append(String(format: "false-split rate %.3f > %.3f", rate, maximumFalseSplitRate)) }
        }
        return failures
    }
}

@Suite("Segment calibration", .enabled(if: SegmentHeavyGate.enabled, SegmentHeavyGate.reason))
struct CalibrationTests {
    @Test func calibrationAgainstPlantedTruth() async throws {
        let scores = try await SegmentRunner.runAll(SegmentPlan.cases())
        for score in scores { print("WW-017 calibration " + SegmentRunner.line(score)) }
        try SegmentCaseRecord.write(scores.map { SegmentCaseRecord(label: SegmentCaseRecord.label($0.kase), score: $0) }, split: "calibration-2")
        print("WW-017 calibration table\n" + SegmentRunner.table(scores))
        let failures = SegmentRunner.gateFailures(scores, maximumFalseSplitRate: SegmentPlan.maximumFalseSplitRate)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        // Every planted discontinuity is flagged or unsupported (never bridged).
        #expect(scores.flatMap(\.plants).allSatisfy { $0.status != .bridged })
        var planted = 0
        for (stratum, count) in SegmentPlan.counts where !stratum.isNegative { planted += stratum == .compound ? 2 * count : count }
        #expect(scores.flatMap(\.plants).count == planted)
    }
}

@Suite("Segment floor sweep", .enabled(if: SegmentHeavyGate.enabled, SegmentHeavyGate.reason))
struct FloorSweepTests {
    /// Reported, not gated: how small a step or rate change the defaults resolve. Sub-tolerance changes are
    /// below the floor; the hard invariants (retention, monotonic, inverse) must still hold for every case.
    @Test func detectionFloor() async throws {
        let cases = SegmentPlan.floorCases()
        let scores = try await SegmentRunner.runAll(cases.map(\.1))
        try SegmentCaseRecord.write(zip(cases, scores).map { SegmentCaseRecord(label: $0.0.label, score: $0.1) }, split: "floor-2")
        for ((label, _), score) in zip(cases, scores) {
            print("WW-017 floor \(label): " + SegmentRunner.line(score))
            #expect(score.retentionFailures.isEmpty && score.monotonicFailures.isEmpty && score.inverseFailures.isEmpty, "\(label)")
        }
    }
}

/// The heavy passes share a developer Mac: the harness keeps at most four cases in flight (an override may only
/// lower that), and the bound actually holds. Cheap; runs in the parallel pass.
@Suite("Segment harness compute budget")
struct SegmentBudgetTests {
    @Test func defaultConcurrencyIsAtMostFour() {
        #expect(SegmentRunner.defaultMaximumConcurrency <= 4)
        #expect(SegmentRunner.maximumConcurrency([:]) == SegmentRunner.defaultMaximumConcurrency)
        #expect(SegmentRunner.maximumConcurrency(["WW_SEGMENT_MAX_CONCURRENCY": "2"]) == 2)
        #expect(SegmentRunner.maximumConcurrency(["WW_SEGMENT_MAX_CONCURRENCY": "4"]) == 4)
        for bad in ["0", "-3", "5", "16", "17", "many", ""] {
            #expect(SegmentRunner.maximumConcurrency(["WW_SEGMENT_MAX_CONCURRENCY": bad]) == SegmentRunner.defaultMaximumConcurrency)
        }
    }

    final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
        func leave() { lock.withLock { current -= 1 } }
    }

    /// Each item yields repeatedly while counted in flight (never sleeping or blocking a thread), so an unbounded
    /// runner would start every item and exceed the limit.
    @Test(arguments: [1, 2, 3])
    func boundedRunnerNeverExceedsTheLimit(limit: Int) async throws {
        let meter = InFlight()
        let results = try await SegmentRunner.bounded(Array(0..<24), maximumConcurrency: limit) { item -> Int in
            meter.enter()
            defer { meter.leave() }
            for _ in 0..<50 { await Task.yield() }
            return item * 2
        }
        #expect(results == (0..<24).map { $0 * 2 })
        #expect(meter.peak <= limit)
        #expect(meter.peak >= 1)
    }
}
