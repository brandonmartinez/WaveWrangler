import CryptoKit
import Foundation
import Testing
import WWCore
@testable import WWDecode

@Suite("Decode calibration (M3-DECODE-003)")
struct DecodeCalibrationTests {
    @Test(.enabled(if: DecodeFixture.calibrationEnabled, "serialized calibration pass (WW_DECODE_CALIBRATION=1)"))
    func calibrationSplitMeetsEveryGate() async throws {
        let records = try await runDecodeSplit("calibration", cases: DecodeFixture.calibrationCases)
        #expect(records.count == DecodeFixture.calibrationCases + 1)
        for outcome in DecodeGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Frozen holdout: runs once, only with WW_M3_DECODE_3_HOLDOUT=1, after m3-freeze-decode-3 merges.
    @Test(.enabled(if: DecodeFixture.holdoutEnabled))
    func holdoutSplitMeetsEveryFrozenGate() async throws {
        let records = try await runDecodeSplit("holdout", cases: DecodeFixture.holdoutCases)
        #expect(records.count == DecodeFixture.holdoutCases + 1)
        for outcome in DecodeGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Each gate check trips on one record just past its limit and on missing evidence.
    @Test func gateChecksTripOnFailures() {
        func record(_ stratum: DecodeStratum, _ edit: (inout DecodeCaseRecord) -> Void = { _ in }) -> DecodeCaseRecord {
            var r = DecodeCaseRecord(split: "t", caseIndex: stratum.rawValue, seed: "0", stratum: stratum.name, kind: stratum.isPlanted ? "planted" : "supported", spec: "", frames: 1, chunkFrames: 1, sourceUnchanged: true, published: !stratum.isPlanted)
            if stratum.isPlanted {
                r.expectedErrorMatched = true
                r.finishCalled = false
                r.appendedNotAbandoned = false
                r.readersLeftOpen = 0
                r.scopesBalanced = true
            } else {
                r.landmarkLags = [0, 1, -1]
            }
            edit(&r)
            return r
        }
        let settings = DecodeCaseRecord(split: "t", caseIndex: -1, seed: "-", stratum: "output-settings", kind: "output-settings", spec: "", frames: 0, chunkFrames: 0, sourceUnchanged: true, published: true)
        let good = DecodeStratum.allCases.map { record($0) } + [settings]
        #expect(DecodeGateEvaluation.evaluate(good).allSatisfy { $0.passed })
        let breaks: [(String, DecodeCaseRecord)] = [
            ("supported-mapping", record(.pcmInteger) { $0.mappingFailures = ["validFrames"] }),
            ("supported-mapping", record(.pcmFloat) { $0.sourceUnchanged = false }),
            ("supported-mapping", record(.losslessFLAC) { $0.published = false }),
            ("landmarks", record(.primingAACM4A) { $0.landmarkLags = [2] }),
            ("landmarks", record(.primingOpusCAF) { $0.landmarkLags = [-2] }),
            ("landmarks", record(.primingAACCAF) { $0.landmarksBelowCorrelation = 1 }),
            ("planted-explicit-error", record(.plantedUnsupported) { $0.expectedErrorMatched = false }),
            ("planted-explicit-error", record(.plantedCorrupt) { $0.expectedErrorMatched = nil }),
            ("planted-no-mutation", record(.plantedTruncated) { $0.sourceUnchanged = false }),
            ("planted-no-stale-publication", record(.plantedStale) { $0.published = true }),
            ("planted-no-stale-publication", record(.plantedStale) { $0.finishCalled = true }),
            ("planted-no-stale-publication", record(.plantedStale) { $0.appendedNotAbandoned = true }),
            ("planted-no-stale-publication", record(.plantedTruncated) { $0.readersLeftOpen = 1 }),
            ("planted-no-stale-publication", record(.plantedTruncated) { $0.scopesBalanced = false }),
            ("output-settings", { var s = settings; s.mappingFailures = ["rate 44100"]; return s }()),
        ]
        for (gate, bad) in breaks {
            let outcomes = DecodeGateEvaluation.evaluate(good + [bad])
            #expect(outcomes.filter { !$0.passed }.map(\.gate) == [gate], "\(gate): \(outcomes)")
        }
        // A missing stratum fails coverage alone; no evidence fails every gate.
        let withoutStale = DecodeGateEvaluation.evaluate(good.filter { $0.stratum != DecodeStratum.plantedStale.name })
        #expect(withoutStale.filter { !$0.passed }.map(\.gate) == ["strata-coverage"])
        #expect(DecodeGateEvaluation.evaluate([]).allSatisfy { !$0.passed })
        #expect(DecodeGateEvaluation.evaluate(good.filter { $0.kind != "supported" }).filter { !$0.passed }.map(\.gate).contains("landmarks"))
        #expect(DecodeGateEvaluation.evaluate(good.filter { $0.kind != "output-settings" }).filter { !$0.passed }.map(\.gate) == ["output-settings"])
    }

    /// Seeds are derived, stable and split-separated; the recipe is a pure function of (split, index).
    @Test func seedsAreStableAndSplitSeparated() throws {
        #expect(DecodeFixture.seed(split: "calibration", index: 0) == DecodeFixture.seed(split: "calibration", index: 0))
        let calibration = Set((0 ..< DecodeFixture.calibrationCases).map { DecodeFixture.seed(split: "calibration", index: $0) })
        let holdout = Set((0 ..< DecodeFixture.holdoutCases).map { DecodeFixture.seed(split: "holdout", index: $0) })
        #expect(calibration.count == DecodeFixture.calibrationCases && holdout.count == DecodeFixture.holdoutCases)
        #expect(calibration.isDisjoint(with: holdout))
        let revisionThree = calibration.union(holdout)
        for priorID in ["M2-DECODE-001", "M2-DECODE-002"] {
            let prior = Set(["calibration", "holdout"].flatMap { split in
                (0 ..< (split == "calibration" ? DecodeFixture.calibrationCases : DecodeFixture.holdoutCases)).map {
                    DecodeFixture.seed(fixtureID: priorID, split: split, index: $0)
                }
            })
            #expect(prior.count == DecodeFixture.calibrationCases + DecodeFixture.holdoutCases)
            #expect(revisionThree.isDisjoint(with: prior), "revision 3 must not reuse \(priorID) seeds")
        }
        for index in [0, 7, 12, 129] {
            let a = DecodeFreezeCase(split: "calibration", index: index), b = DecodeFreezeCase(split: "calibration", index: index)
            #expect(a.label == b.label && a.seed == b.seed)
        }
        #expect(DecodeFreezeCase(split: "calibration", index: 0).label != DecodeFreezeCase(split: "holdout", index: 0).label)
    }

    /// Every split covers every stratum and every planted variant, with lengths and chunks inside the recipe.
    @Test func recipeCoversEveryStratumAndPlantedVariant() {
        for (split, count) in [("calibration", DecodeFixture.calibrationCases), ("holdout", DecodeFixture.holdoutCases)] {
            let cases = (0 ..< count).map { DecodeFreezeCase(split: split, index: $0) }
            #expect(Set(cases.map(\.stratum)) == Set(DecodeStratum.allCases))
            #expect(count % DecodeStratum.allCases.count == 0)
            for c in cases {
                #expect((1 ... DecodeFixture.maximumChunkFrames).contains(c.chunkFrames))
                #expect(c.frames >= DecodeFixture.minimumFrames - 1 && c.frames <= DecodeFixture.maximumFrames)
                #expect((c.plant != nil) == c.stratum.isPlanted, "\(c.label)")
            }
            let planted = Set(cases.compactMap { $0.plant.map(Self.variantName) })
            #expect(planted == Self.allVariantNames, "\(split) missing \(Self.allVariantNames.subtracting(planted))")
            let codecs = Set(cases.filter { !$0.stratum.isPlanted }.map(\.spec.codec))
            #expect(codecs == [.aac, .opus, .appleLossless, .flac, .linearPCM])
        }
    }

    static func variantName(_ plant: DecodePlant) -> String {
        switch plant {
        case .truncate: "truncate"
        case .damagedHeader: "damaged-header"
        case .randomBytes: "random-bytes"
        case .text: "text"
        case .empty: "empty"
        case .streamingWaveSize: "streaming-wave"
        case let .outsideEnvelope(name, _): Self.unsupportedFamily(name)
        case let .changedWhileDecoding(change): "stale-\(change.rawValue)"
        }
    }

    static func unsupportedFamily(_ name: String) -> String {
        if name.hasPrefix("off-grid") { return "off-grid" }
        if name.contains("ALAC") { return "alac-channels" }
        if name.contains("-channel") { return "pcm-channels" }
        if name.hasSuffix("law WAVE") { return "companded" }
        return name
    }

    static let allVariantNames = Set<String>([
        "truncate", "damaged-header", "random-bytes", "text", "empty", "streaming-wave",
        "off-grid", "pcm-channels", "alac-channels", "companded", "IMA4 CAF", "unsigned 8-bit WAVE", "signed 8-bit AIFF", "AAC in ADTS",
    ]).union(StaleChange.allCases.map { "stale-\($0.rawValue)" })
}

/// m3-freeze-decode-3 consistency (docs/m2/fixtures/m3-freeze-decode-3.json). These checks decode nothing and
/// always run: they fail if the gates, versions, split counts or pinned trees drift from the committed
/// freeze. A deliberate change is a new dated freeze revision, never a silent edit.
@Suite("Decode freeze (m3-freeze-decode-3)")
struct DecodeFreezeTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let freezeURL = repository.appendingPathComponent("docs/m2/fixtures/m3-freeze-decode-3.json")
    static let revisionTwoFreezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-decode-2.json")
    static let revisionOneFreezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-decode.json")
    static let calibrationURL = repository.appendingPathComponent("docs/m3/evidence/ww-050/calibration-3.jsonl")

    static func freeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: freezeURL)) as? [String: Any])
    }

    @Test func revisionTwoPreservesRevisionOneDefinition() throws {
        let revisionOne = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.revisionOneFreezeURL)) as? [String: Any]
        )
        let revisionTwo = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.revisionTwoFreezeURL)) as? [String: Any]
        )
        for key in ["recipe", "truth", "measurement", "countJustification", "gate", "gateValues", "gates", "gateRule"] {
            #expect((revisionTwo[key] as? NSObject)?.isEqual(revisionOne[key]) == true, "\(key) changed from revision 1")
        }
        let oneSplits = try #require(revisionOne["splits"] as? [String: [String: Any]])
        let twoSplits = try #require(revisionTwo["splits"] as? [String: [String: Any]])
        #expect(oneSplits["calibration"]?["cases"] as? Int == twoSplits["calibration"]?["cases"] as? Int)
        #expect(oneSplits["holdout"]?["cases"] as? Int == twoSplits["holdout"]?["cases"] as? Int)
    }

    @Test func revisionThreePreservesRevisionTwoDefinition() throws {
        let revisionTwoData = try Data(contentsOf: Self.revisionTwoFreezeURL)
        let revisionTwo = try #require(JSONSerialization.jsonObject(with: revisionTwoData) as? [String: Any])
        let revisionThree = try Self.freeze()
        let historicalDigest = SHA256.hash(data: revisionTwoData).map { String(format: "%02x", $0) }.joined()
        #expect(revisionThree["revisionTwoSHA256"] as? String == historicalDigest)
        for key in ["recipe", "truth", "measurement", "countJustification", "gate", "gateValues", "gates", "gateRule"] {
            #expect((revisionThree[key] as? NSObject)?.isEqual(revisionTwo[key]) == true, "\(key) changed from revision 2")
        }
        let twoSplits = try #require(revisionTwo["splits"] as? [String: [String: Any]])
        let threeSplits = try #require(revisionThree["splits"] as? [String: [String: Any]])
        #expect(twoSplits["calibration"]?["cases"] as? Int == threeSplits["calibration"]?["cases"] as? Int)
        #expect(twoSplits["holdout"]?["cases"] as? Int == threeSplits["holdout"]?["cases"] as? Int)
    }

    @Test func splitConcurrencyIsCappedAtFour() {
        #expect(DecodeFixture.defaultMaxConcurrency <= 4)
        #expect((1 ... 4).contains(DecodeFixture.maxConcurrency))
        #expect(DecodeFixture.concurrencyLimit(from: nil) == DecodeFixture.defaultMaxConcurrency)
        #expect(DecodeFixture.concurrencyLimit(from: "not a number") == DecodeFixture.defaultMaxConcurrency)
        #expect(DecodeFixture.concurrencyLimit(from: "2") == 2)
        #expect(DecodeFixture.concurrencyLimit(from: "0") == 1)
        #expect(DecodeFixture.concurrencyLimit(from: "\(ProcessInfo.processInfo.activeProcessorCount * 4)") <= 4)
    }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try Self.freeze()
        #expect(json["freezeID"] as? String == "m3-freeze-decode-3")
        #expect(json["fixtureID"] as? String == DecodeFixture.fixtureID)
        #expect(json["supersedes"] as? String == "m2-freeze-decode-2")
        let generator = try #require(json["generator"] as? [String: Any])
        #expect((generator["seedDerivation"] as? String)?.contains(DecodeFixture.fixtureID) == true)

        let gates = try #require(json["gateValues"] as? [String: Double])
        #expect(gates == [
            "maximumSupportedMappingFailures": Double(DecodeGates.maximumSupportedMappingFailures),
            "landmarkOutputFrames": Double(DecodeGates.landmarkOutputFrames),
            "maximumPlantedWithoutExpectedError": Double(DecodeGates.maximumPlantedWithoutExpectedError),
            "maximumPlantedMutations": Double(DecodeGates.maximumPlantedMutations),
            "maximumPlantedPublications": Double(DecodeGates.maximumPlantedPublications),
            "lossyMinimumCorrelation": DecodeGates.lossyMinimumCorrelation,
            "exactMinimumCorrelation": DecodeGates.exactMinimumCorrelation,
        ])

        let versions = try #require(json["versions"] as? [String: Int])
        #expect(versions == [
            "DecodeEnvelope.version": DecodeEnvelope.version,
            "FormatInterpretation.currentVersion": FormatInterpretation.currentVersion,
            "OutputSettingsPolicy.version": OutputSettingsPolicy.version,
        ])

        let recipe = try #require(json["recipe"] as? [String: Any])
        #expect(recipe["strata"] as? [String] == DecodeStratum.allCases.map(\.name))
        #expect(recipe["minimumFrames"] as? Int == DecodeFixture.minimumFrames)
        #expect(recipe["maximumFrames"] as? Int == DecodeFixture.maximumFrames)
        #expect(recipe["maximumChunkFrames"] as? Int == DecodeFixture.maximumChunkFrames)

        let splits = try #require(json["splits"] as? [String: [String: Any]])
        #expect(splits["calibration"]?["cases"] as? Int == DecodeFixture.calibrationCases)
        #expect(splits["holdout"]?["cases"] as? Int == DecodeFixture.holdoutCases)
        #expect(splits["holdout"]?["run"] as? Bool == false)
        #expect((splits["holdout"]?["enable"] as? String)?.contains("WW_M3_DECODE_3_HOLDOUT=1") == true)
        #expect(DecodeFixture.holdoutCases >= DecodeFixture.calibrationCases)
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

    /// The decoder source and this test tree (generator, truth, gates, harness) are pinned by the freeze.
    @Test func decoderAndHarnessTreesMatchTheFreezeRecord() throws {
        let trees = try #require(try Self.freeze()["pinnedTrees"] as? [String: String])
        #expect(Set(trees.keys) == ["Sources/WWDecode", "Tests/WWDecodeTests"])
        let package = Self.repository.appendingPathComponent("Packages/WaveWranglerKit")
        for (path, frozen) in trees {
            let actual = try Self.gitTreeID(package.appendingPathComponent(path))
            #expect(actual == frozen, "\(path) is \(actual) but m3-freeze-decode-3 pins \(frozen): a frozen tree changed; record a new freeze revision before any holdout")
        }
    }

    /// The M2 fixture registry lists this freeze, its record and its fixture with the frozen counts.
    @Test func fixtureRegistryListsTheFreeze() throws {
        let url = Self.freezeURL.deletingLastPathComponent().appendingPathComponent("m2-fixture-registry.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let freezes = try #require(json["freezes"] as? [[String: Any]])
        let revisionOne = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-decode" })
        #expect(revisionOne["supersededBy"] as? String == "m2-freeze-decode-2")
        #expect((revisionOne["status"] as? String)?.contains("holdout passed once") == true)
        let revisionTwo = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-decode-2" })
        #expect(revisionTwo["record"] as? String == "docs/m2/fixtures/m2-freeze-decode-2.json")
        #expect(revisionTwo["fixtures"] as? [String] == ["M2-DECODE-002"])
        let entry = try #require(freezes.first { $0["freezeID"] as? String == "m3-freeze-decode-3" })
        #expect(entry["record"] as? String == "docs/m2/fixtures/m3-freeze-decode-3.json")
        #expect(entry["fixtures"] as? [String] == [DecodeFixture.fixtureID])
        #expect(entry["supersedes"] as? String == "m2-freeze-decode-2")
        let counts = try #require(entry["counts"] as? [String: Int])
        #expect(counts["calibrationCases"] == DecodeFixture.calibrationCases)
        #expect(counts["holdoutCases"] == DecodeFixture.holdoutCases)
        let fixtures = try #require(entry["fixtureEntries"] as? [[String: Any]])
        #expect(fixtures.count == 1)
        let split = try #require(fixtures.first?["split"] as? [String: Any])
        #expect(fixtures.first?["id"] as? String == DecodeFixture.fixtureID)
        #expect(split["calibration"] as? Int == DecodeFixture.calibrationCases)
        #expect(split["holdout"] as? Int == DecodeFixture.holdoutCases)
    }

    @Test func committedCalibrationRecordsReproduceTheReportedCalibration() throws {
        let data = try Data(contentsOf: Self.calibrationURL)
        let decoder = JSONDecoder()
        let records = try data.split(separator: 0x0A).map { try decoder.decode(DecodeCaseRecord.self, from: Data($0)) }
        #expect(records.count == DecodeFixture.calibrationCases + 1)
        #expect(records.allSatisfy { $0.split == "calibration" })
        #expect(records.map(\.caseIndex) == Array(0 ..< DecodeFixture.calibrationCases) + [-1])
        for record in records where record.caseIndex >= 0 {
            #expect(record.seed == String(
                format: "0x%016llX",
                DecodeFixture.seed(split: "calibration", index: record.caseIndex)
            ))
        }
        #expect(DecodeGateEvaluation.evaluate(records).allSatisfy { $0.passed })

        let json = try Self.freeze()
        let summary = try #require(json["calibrationSummary"] as? [String: Any])
        let metrics = try #require(summary["metrics"] as? [String: Any])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(summary["recordsSHA256"] as? String == digest)
        #expect(summary["records"] as? Int == records.count)

        let supported = records.filter { $0.kind == "supported" }
        let planted = records.filter { $0.kind == "planted" }
        let settings = records.filter { $0.kind == "output-settings" }
        let lags = supported.flatMap(\.landmarkLags)
        let lagCounts = Dictionary(grouping: lags, by: { String($0) }).mapValues(\.count)
        #expect(metrics["supportedCases"] as? Int == supported.count)
        #expect(metrics["supportedFrames"] as? Int == supported.reduce(0) { $0 + $1.frames })
        #expect(metrics["mappingFailures"] as? Int == supported.reduce(0) { $0 + $1.mappingFailures.count })
        #expect(metrics["landmarkObservations"] as? Int == lags.count)
        #expect(metrics["landmarkLagCounts"] as? [String: Int] == lagCounts)
        #expect(metrics["landmarksBelowCorrelation"] as? Int == supported.reduce(0) { $0 + $1.landmarksBelowCorrelation })
        #expect(metrics["exactCases"] as? Int == supported.count { $0.bitExact != nil })
        #expect(metrics["plantedCases"] as? Int == planted.count)
        #expect(metrics["plantedMutations"] as? Int == planted.count { !$0.sourceUnchanged })
        #expect(metrics["plantedPublications"] as? Int == planted.count {
            $0.published || $0.finishCalled != false || $0.appendedNotAbandoned != false
                || $0.readersLeftOpen != 0 || $0.scopesBalanced != true
        })
        #expect(metrics["outputSettingsFailures"] as? Int == settings.reduce(0) { $0 + $1.mappingFailures.count })
    }
}
