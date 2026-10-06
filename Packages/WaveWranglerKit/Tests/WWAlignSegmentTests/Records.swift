import Foundation
import WWAlignSegment

/// One scored case as committed under docs/m2/evidence/ww-017/ (JSON lines, plan order, sorted keys). The freeze
/// record's reported calibration, floor and edge-silence totals are recomputed from these files alone
/// (SegmentFreezeTests), so the report never rests on a log excerpt.
struct SegmentCaseRecord: Codable, Equatable, Sendable {
    struct PlantRecord: Codable, Equatable, Sendable {
        let kind: String
        let frame: Int
        let insertedFrames: Int?
        let stepMilliseconds: Double
        let deltaPPM: Double
        let status: String
        let detectionKind: String?
        let positionErrorSeconds: Double?
    }

    let label: String
    let stratum: String
    let index: Int
    let seed: String
    let negative: Bool
    let rate: Int
    let lengthSeconds: Double
    let mute: [Int]?
    let plants: [PlantRecord]
    let detections: Int
    let spuriousDetections: Int
    let mappedRegions: Int
    let bridgingRegions: Int
    let silentBridges: Int
    let falseSplit: Bool
    let supportedFraction: Double
    let residualP95Milliseconds: Double
    let residualMaxMilliseconds: Double
    let residualGateFailures: [String]
    let monotonicFailures: [String]
    let inverseFailures: [String]
    let retentionFailures: [String]
    let hardFailures: [String]
    let detectionSummary: [String]
    let unsupportedSummary: [String]

    init(label: String, score s: CaseScore) {
        self.label = label
        stratum = s.kase.stratum.rawValue
        index = s.kase.index
        seed = SegmentFreezeTests.hex(s.kase.seed)
        negative = s.kase.stratum.isNegative
        rate = s.kase.truth.rate
        lengthSeconds = s.kase.lengthSeconds
        mute = s.kase.mute.map { [$0.lowerBound, $0.upperBound] }
        plants = s.plants.map {
            PlantRecord(kind: $0.plant.kind.rawValue, frame: $0.plant.frame, insertedFrames: $0.plant.inserted?.count,
                        stepMilliseconds: $0.plant.stepSeconds * 1000, deltaPPM: $0.plant.deltaPPM, status: $0.status.rawValue,
                        detectionKind: $0.detection?.kind.rawValue, positionErrorSeconds: $0.positionErrorSeconds)
        }
        detections = s.detections
        spuriousDetections = s.spuriousDetections
        mappedRegions = s.mappedRegions
        bridgingRegions = s.bridgingRegions
        silentBridges = s.silentBridges
        falseSplit = s.falseSplit
        supportedFraction = s.supportedFraction
        residualP95Milliseconds = s.residualP95Milliseconds
        residualMaxMilliseconds = s.residualMaxMilliseconds
        residualGateFailures = s.residualGateFailures
        monotonicFailures = s.monotonicFailures
        inverseFailures = s.inverseFailures
        retentionFailures = s.retentionFailures
        hardFailures = s.hardFailures
        detectionSummary = s.detectionSummary
        unsupportedSummary = s.unsupportedSummary
    }

    static func label(_ kase: SegmentCase) -> String { "\(kase.stratum.rawValue)#\(kase.index)" }

    /// Edge-silence cases share their calibration case's stratum and index; the label says which side is muted.
    static func edgeSilenceLabel(_ kase: SegmentCase) -> String {
        let side = (kase.mute?.lowerBound ?? 0) >= (kase.plants.first?.frame ?? 0) ? "after" : "before"
        return "\(label(kase)) muted \(side)"
    }

    /// Sorted-key JSON lines, one per case, in the given (plan) order.
    static func jsonLines(_ records: [SegmentCaseRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    static func decode(_ data: Data) throws -> [SegmentCaseRecord] {
        let decoder = JSONDecoder()
        return try data.split(separator: UInt8(ascii: "\n")).map { try decoder.decode(SegmentCaseRecord.self, from: Data($0)) }
    }

    /// When WW_SEGMENT_RECORDS_DIR names a directory, a heavy run writes `<split>.jsonl` there (calibration,
    /// floor, edge-silence). Never set by CI; used to produce the committed evidence files.
    static func write(_ records: [SegmentCaseRecord], split: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let directory = environment["WW_SEGMENT_RECORDS_DIR"], !directory.isEmpty else { return }
        try jsonLines(records).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(split).jsonl"), options: .atomic)
    }
}

/// Totals recomputed from committed records; the freeze record reports exactly these.
struct SegmentRecordTotals: Equatable {
    var cases = 0
    var negatives = 0
    var falseSplits = 0
    var plants = 0
    var plantsFlagged = 0
    var plantsFlaggedWithExpectedKind = 0
    var plantsUnsupported = 0
    var plantsBridged = 0
    var bridgingRegions = 0
    var silentBridges = 0
    var spuriousDetectionsOnPositives = 0
    var casesWithHardFailures = 0
    var invariantFailures = 0
    var worstResidualP95Milliseconds = 0.0
    var worstResidualMaxMilliseconds = 0.0

    /// offsetStep for steps, drops, insertions and restarts; slopeChange for a rate change.
    static func expectedKind(_ plantKind: String) -> String {
        plantKind == PlantKind.rateChange.rawValue ? DiscontinuityKind.slopeChange.rawValue : DiscontinuityKind.offsetStep.rawValue
    }

    init(_ records: [SegmentCaseRecord]) {
        for r in records {
            cases += 1
            if r.negative {
                negatives += 1
                if r.falseSplit { falseSplits += 1 }
            } else {
                spuriousDetectionsOnPositives += r.spuriousDetections
            }
            for p in r.plants {
                plants += 1
                switch p.status {
                case PlantScore.Status.flagged.rawValue:
                    plantsFlagged += 1
                    if p.detectionKind == Self.expectedKind(p.kind) { plantsFlaggedWithExpectedKind += 1 }
                case PlantScore.Status.unsupported.rawValue: plantsUnsupported += 1
                default: plantsBridged += 1
                }
            }
            bridgingRegions += r.bridgingRegions
            silentBridges += r.silentBridges
            if !r.hardFailures.isEmpty { casesWithHardFailures += 1 }
            invariantFailures += r.monotonicFailures.count + r.inverseFailures.count + r.retentionFailures.count
            worstResidualP95Milliseconds = max(worstResidualP95Milliseconds, r.residualP95Milliseconds)
            worstResidualMaxMilliseconds = max(worstResidualMaxMilliseconds, r.residualMaxMilliseconds)
        }
    }

    var falseSplitRate: Double { negatives == 0 ? 0 : Double(falseSplits) / Double(negatives) }

    /// The keys and values the freeze record's calibrationSummary reports for this split.
    var dictionary: [String: Double] {
        [
            "cases": Double(cases), "negatives": Double(negatives), "falseSplits": Double(falseSplits), "falseSplitRate": falseSplitRate,
            "plants": Double(plants), "plantsFlagged": Double(plantsFlagged),
            "plantsFlaggedWithExpectedKind": Double(plantsFlaggedWithExpectedKind), "plantsUnsupported": Double(plantsUnsupported),
            "plantsBridged": Double(plantsBridged), "bridgingRegions": Double(bridgingRegions), "silentBridges": Double(silentBridges),
            "spuriousDetectionsOnPositives": Double(spuriousDetectionsOnPositives), "casesWithHardFailures": Double(casesWithHardFailures),
            "invariantFailures": Double(invariantFailures),
            "worstResidualP95Milliseconds": worstResidualP95Milliseconds, "worstResidualMaxMilliseconds": worstResidualMaxMilliseconds,
        ]
    }
}
