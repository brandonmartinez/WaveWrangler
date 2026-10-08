import Foundation
import Testing

/// The Setup UI-test fixture engine (`WW_SETUP_ENGINE=fixture-states`) must never be reachable in Release
/// builds: every line that reads the variable or builds fixture data sits inside `#if DEBUG`.
@Suite("Setup fixture guard")
struct SetupFixtureGuardTests {
    static let sourcesFolder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "WaveWrangler/Sources")

    @Test func fixtureEnvironmentIsOnlyReadInDebugBuilds() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourcesFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var readers = 0
        for file in files {
            var depth: [Bool] = []
            for (number, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") { depth.append(trimmed == "#if DEBUG") }
                else if trimmed.hasPrefix("#else") { if depth.popLast() != nil { depth.append(false) } }
                else if trimmed.hasPrefix("#endif") { _ = depth.popLast() }
                let readsVariable = line.contains("environment[\"WW_SETUP_ENGINE\"]")
                let buildsFixture = line.contains("func makeStatesEngine(")
                guard readsVariable || buildsFixture else { continue }
                readers += 1
                #expect(depth.last == true, "\(file.lastPathComponent):\(number + 1) must be inside #if DEBUG")
            }
        }
        #expect(readers >= 2, "guard found the fixture switch and builder")
    }

    @Test func downloadSourcesTestHookDoesNotWriteTheAppPreference() throws {
        let source = try String(contentsOf: Self.sourcesFolder.appending(path: "SetupFixtures.swift"), encoding: .utf8)
        #expect(source.contains("static var downloadsAutomatically: Bool"))
        #expect(source.contains(#"UserDefaults.standard.string(forKey: "WWUITestDownloadSources") != "OFF""#))
        #expect(!source.contains("AppSettingsDownloadPreference.shared.downloadsAutomatically = false"))
    }
}
