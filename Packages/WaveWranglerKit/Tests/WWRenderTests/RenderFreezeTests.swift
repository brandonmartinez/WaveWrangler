import CryptoKit
import Foundation
import Testing
@testable import WWRender

/// m2-freeze-render-3 consistency (docs/m2/fixtures/m2-freeze-render-3.json). These checks render nothing and
/// always run: they fail if the gates, recipe, versions, split counts or pinned trees drift from the committed
/// freeze. A deliberate change is a new dated freeze revision, never a silent edit.
@Suite("Render freeze (m2-freeze-render-3)")
struct RenderFreezeTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let freezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-render.json")
    static let revisionTwoFreezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-render-2.json")
    static let activeFreezeURL = repository.appendingPathComponent("docs/m2/fixtures/m2-freeze-render-3.json")

    static func freeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: freezeURL)) as? [String: Any])
    }

    static func revisionTwoFreeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: revisionTwoFreezeURL)) as? [String: Any])
    }

    static func activeFreeze() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: activeFreezeURL)) as? [String: Any])
    }

    @Test func frozenDefinitionMatchesTheFreezeRecord() throws {
        let json = try Self.freeze()
        #expect(json["freezeID"] as? String == "m2-freeze-render")
        #expect(json["fixtureID"] as? String == RenderFixture.fixtureID)

        let gates = try #require(json["gateValues"] as? [String: Double])
        #expect(gates == [
            "landmarkFrames": RenderGates.landmarkFrames,
            "passbandDB": RenderGates.passbandDB,
            "passbandFraction": RenderGates.passbandFraction,
            "aliasDBc": RenderGates.aliasDBc,
            "skewFrames": RenderGates.skewFrames,
            "inactiveDBFS": RenderGates.inactiveDBFS,
            "phaseToleranceDegrees": RenderGates.phaseToleranceDegrees,
            "familyPeakBytes": Double(RenderGates.familyPeakBytes),
            "maximumInversionsSwaps": 0,
        ])

        let renderer = try #require(json["renderer"] as? [String: Any])
        #expect(renderer["RenderVersions.renderer"] as? Int == RenderVersions.renderer)
        #expect(renderer["RenderVersions.outputAssetFormat"] as? Int == RenderVersions.outputAssetFormat)
        #expect(renderer["RenderRecipe.currentVersion"] as? Int == RenderRecipe.currentVersion)
        let frozenRecipe = try #require(renderer["recipeEncoding"] as? NSDictionary)
        let actualRecipe = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderRecipe.m2Candidate)) as? NSDictionary)
        #expect(frozenRecipe == actualRecipe)

        let splits = try #require(json["splits"] as? [String: [String: Any]])
        #expect(splits["calibration"]?["cases"] as? Int == RenderFixture.calibrationCases)
        #expect(splits["holdout"]?["cases"] as? Int == RenderFixture.holdoutCases)
        #expect(RenderFixture.holdoutCases >= RenderFixture.calibrationCases)
    }

    @Test func revisionTwoChangesOnlySchedulingAndHoldoutSeeds() throws {
        let original = try Self.freeze()
        let active = try Self.revisionTwoFreeze()
        #expect(active["freezeID"] as? String == "m2-freeze-render-2")
        #expect(active["supersedesForExecution"] as? String == "m2-freeze-render")
        #expect(active["fixtureID"] as? String == RenderFixture.fixtureID)
        #expect(active["gateValues"] as? NSDictionary == original["gateValues"] as? NSDictionary)
        #expect(active["renderer"] as? NSDictionary == original["renderer"] as? NSDictionary)
        let originalSplits = try #require(original["splits"] as? [String: [String: Any]])
        let activeSplits = try #require(active["splits"] as? [String: [String: Any]])
        for split in ["calibration", "holdout"] {
            #expect(activeSplits[split]?["cases"] as? Int == originalSplits[split]?["cases"] as? Int)
            #expect(activeSplits[split]?["plusMultiSpan"] as? Int == originalSplits[split]?["plusMultiSpan"] as? Int)
        }
        #expect(activeSplits["holdout"]?["run"] as? Bool == false)
        #expect(active["maximumConcurrentCases"] as? Int == RenderFixture.maximumConcurrentCases)
        #expect(active["holdoutSplit"] as? String == "holdout-2")
        #expect(RenderFixture.maximumConcurrentCases <= 2)

        let oldSeeds = Set((0..<RenderFixture.holdoutCases).map { RenderFixture.seed(split: "holdout", index: $0) })
        let calibrationSeeds = Set((0..<RenderFixture.calibrationCases).map { RenderFixture.seed(split: "calibration", index: $0) })
        let newSeeds = Set((0..<RenderFixture.holdoutCases).map { RenderFixture.seed(split: "holdout-2", index: $0) })
        #expect(newSeeds.count == RenderFixture.holdoutCases)
        #expect(newSeeds.isDisjoint(with: oldSeeds))
        #expect(newSeeds.isDisjoint(with: calibrationSeeds))
    }

    @Test func revisionThreePreservesTheRecipeAndPinsTheCPUProtocol() throws {
        let previous = try Self.revisionTwoFreeze()
        let active = try Self.activeFreeze()
        #expect(active["freezeID"] as? String == "m2-freeze-render-3")
        #expect(active["supersedesForExecution"] as? String == "m2-freeze-render-2")
        #expect(active["fixtureID"] as? String == RenderFixture.fixtureID)
        for key in ["generator", "renderer", "gateValues"] {
            #expect(active[key] as? NSDictionary == previous[key] as? NSDictionary)
        }
        for key in ["truth", "measurement"] {
            #expect(active[key] as? String == previous[key] as? String)
        }
        #expect(active["maximumConcurrentCases"] as? Int == RenderFixture.maximumConcurrentCases)
        #expect(active["holdoutSplit"] as? String == "holdout-3")
        #expect(RenderFixture.holdoutSplit == "holdout-3")
        let previousSplits = try #require(previous["splits"] as? [String: [String: Any]])
        let splits = try #require(active["splits"] as? [String: [String: Any]])
        for split in ["calibration", "holdout"] {
            #expect(splits[split]?["cases"] as? Int == previousSplits[split]?["cases"] as? Int)
            #expect(splits[split]?["plusMultiSpan"] as? Int == previousSplits[split]?["plusMultiSpan"] as? Int)
        }
        #expect(splits["holdout"]?["run"] as? Bool == false)
        #expect(splits["holdout"]?["seedSplit"] as? String == RenderFixture.holdoutSplit)

        let telemetry = try #require(active["cpuTelemetry"] as? [String: Any])
        #expect(telemetry["runner"] as? String == "scripts/render-holdout-3.sh")
        #expect(telemetry["sampleIntervalSeconds"] as? Double == 0.25)
        #expect(telemetry["maximumSampleGapSeconds"] as? Double == 1)
        #expect(telemetry["perPIDCPUPercentLimit"] as? Double == 400)
        #expect(telemetry["maximumOneMinuteLoad"] as? Double == 24)
        #expect(telemetry["swiftJobs"] as? Int == 4)
        #expect(telemetry["maximumConcurrentCases"] as? Int == RenderFixture.maximumConcurrentCases)
        let script = try Data(contentsOf: Self.repository.appendingPathComponent("scripts/render-holdout-3.sh"))
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        #expect(telemetry["runnerSHA256"] as? String == digest)

        let splitsToCheck = ["calibration": RenderFixture.calibrationCases, "holdout": RenderFixture.holdoutCases,
                             "holdout-2": RenderFixture.holdoutCases, "holdout-3": RenderFixture.holdoutCases]
        var allSeeds: Set<UInt64> = []
        for (split, count) in splitsToCheck {
            let identities = Set((0..<count).map { RenderFixture.seed(split: split, index: $0) })
            #expect(identities.count == count)
            #expect(identities.isDisjoint(with: allSeeds))
            allSeeds.formUnion(identities)
        }
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

    /// Prior freeze pins remain historical; only revision 3 pins the current working test tree.
    @Test func rendererAndHarnessTreesMatchTheFreezeRecord() throws {
        let original = try #require(try Self.freeze()["pinnedTrees"] as? [String: String])
        let revisionTwo = try #require(try Self.revisionTwoFreeze()["pinnedTrees"] as? [String: String])
        let trees = try #require(try Self.activeFreeze()["pinnedTrees"] as? [String: String])
        #expect(Set(trees.keys) == ["Sources/WWRender", "Tests/WWRenderTests"])
        #expect(trees["Sources/WWRender"] == original["Sources/WWRender"])
        #expect(revisionTwo["Sources/WWRender"] == original["Sources/WWRender"])
        #expect(revisionTwo["Tests/WWRenderTests"] == "073754414e1ee52c638d48e64a2e4a262c2ba30e")
        #expect(trees["Tests/WWRenderTests"] != revisionTwo["Tests/WWRenderTests"])
        let package = Self.repository.appendingPathComponent("Packages/WaveWranglerKit")
        for (path, frozen) in trees {
            let actual = try Self.gitTreeID(package.appendingPathComponent(path))
            #expect(actual == frozen, "\(path) is \(actual) but m2-freeze-render-3 pins \(frozen): a frozen tree changed; record a new freeze revision before any holdout")
        }
    }

    /// The M2 fixture registry lists this freeze, its record and its fixture with the frozen counts.
    @Test func fixtureRegistryListsTheFreeze() throws {
        let url = Self.freezeURL.deletingLastPathComponent().appendingPathComponent("m2-fixture-registry.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let freezes = try #require(json["freezes"] as? [[String: Any]])
        let entry = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-render" })
        #expect(entry["record"] as? String == "docs/m2/fixtures/m2-freeze-render.json")
        #expect(entry["fixtures"] as? [String] == [RenderFixture.fixtureID])
        let counts = try #require(entry["counts"] as? [String: Int])
        #expect(counts["calibrationCases"] == RenderFixture.calibrationCases)
        #expect(counts["holdoutCases"] == RenderFixture.holdoutCases)
        let fixtures = try #require(entry["fixtureEntries"] as? [[String: Any]])
        #expect(fixtures.count == 1)
        let split = try #require(fixtures.first?["split"] as? [String: Any])
        #expect(fixtures.first?["id"] as? String == RenderFixture.fixtureID)
        #expect(split["calibration"] as? Int == RenderFixture.calibrationCases)
        #expect(split["holdout"] as? Int == RenderFixture.holdoutCases)

        let active = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-render-2" })
        #expect(active["record"] as? String == "docs/m2/fixtures/m2-freeze-render-2.json")
        #expect(active["fixtures"] as? [String] == [RenderFixture.fixtureID])
        #expect(active["counts"] as? [String: Int] == counts)

        let current = try #require(freezes.first { $0["freezeID"] as? String == "m2-freeze-render-3" })
        #expect(current["record"] as? String == "docs/m2/fixtures/m2-freeze-render-3.json")
        #expect(current["fixtures"] as? [String] == [RenderFixture.fixtureID])
        #expect(current["counts"] as? [String: Int] == counts)
    }
}
