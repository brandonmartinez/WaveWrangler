import CryptoKit
import Foundation
import Testing
import WWTestSupport

@Suite("Source maintenance baselines")
struct SourceTreeBaselineTests {
    @Test func maintenanceDoesNotAuthorizeHistoricalQualification() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trees = try SourceTreeBaseline.currentTrees(for: fixture.freeze)
        #expect(trees == ["Sources/Example": fixture.currentTree])
        #expect(throws: SourceTreeBaseline.Failure.changedHistoricalTree("Sources/Example")) {
            try SourceTreeBaseline.requireHistoricalTrees(for: fixture.freeze)
        }
    }

    @Test func changingTheHistoricalRecordIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var data = try Data(contentsOf: fixture.freeze)
        data.append(Data("\n".utf8))
        try data.write(to: fixture.freeze)
        #expect(throws: SourceTreeBaseline.Failure.changedHistoricalRecord("historical")) {
            try SourceTreeBaseline.currentTrees(for: fixture.freeze)
        }
    }

    @Test func maintenanceCannotDropAnOriginallyPinnedTree() throws {
        let fixture = try Fixture(dropTree: true)
        defer { fixture.remove() }
        #expect(throws: SourceTreeBaseline.Failure.changedTreePaths("historical")) {
            try SourceTreeBaseline.currentTrees(for: fixture.freeze)
        }
    }

    private struct Fixture {
        let root: URL
        let freeze: URL
        let currentTree: String

        init(dropTree: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "ww-baseline-\(UUID())")
            freeze = root.appending(path: "docs/m2/fixtures/historical.json")
            let source = root.appending(path: "Packages/WaveWranglerKit/Sources/Example")
            let baseline = root.appending(path: "docs/engineering/source-tree-baselines.json")
            for directory in [freeze.deletingLastPathComponent(), source, baseline.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let file = source.appending(path: "Example.swift")
            try Data("original\n".utf8).write(to: file)
            let originalTree = try SourceTreeBaseline.gitTreeID(source)
            let record = try JSONSerialization.data(withJSONObject: [
                "freezeID": "historical", "pinnedTrees": ["Sources/Example": originalTree],
            ])
            try record.write(to: freeze)
            try Data("maintained\n".utf8).write(to: file)
            currentTree = try SourceTreeBaseline.gitTreeID(source)
            let manifest: [String: Any] = [
                "version": 1,
                "records": ["historical": [
                    "historicalRecordSHA256": SHA256.hash(data: record)
                        .map { String(format: "%02x", $0) }.joined(),
                    "currentTrees": dropTree ? [:] : ["Sources/Example": currentTree],
                ]],
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: baseline)
        }

        func remove() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove baseline test fixture: \(error)")
            }
        }
    }
}
