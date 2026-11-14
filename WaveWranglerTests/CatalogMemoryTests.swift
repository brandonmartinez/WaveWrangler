import Foundation
import Testing

@Suite("Generated catalog persistence memory (opt-in)", .serialized)
struct CatalogMemoryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_CATALOG_MEMORY_TESTS"] == "1"
                  || ProcessInfo.processInfo.environment["WW_LAZY_CATALOG_MEMORY_TESTS"] == "1"),
          arguments: [1, 8, 32])
    func freshProcessCodecAndPublisherMeasurements(episodes: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        let probe = try #require(environment["WW_PROBE"])
        let lazy = environment["WW_LAZY_CATALOG_MEMORY_TESTS"] == "1"
        let root = URL(fileURLWithPath: try #require(environment["WW_CATALOG_MEMORY_ROOT"]), isDirectory: true)
        try await Task.detached {
            let available = try #require(root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
            try #require(available >= 2 * 1_024 * 1_024 * 1_024, "Keep room for generated fixtures and exact recovery.")
            let run = root.appendingPathComponent("catalog-\(episodes)-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
            let output = run.appendingPathComponent("measurements.jsonl")
            try Data().write(to: output, options: .withoutOverwriting)
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }

            func invoke(_ arguments: [String]) throws {
                let context: [String: Any] = ["episodes": episodes, "arguments": arguments]
                try log.write(contentsOf: JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
                try log.write(contentsOf: Data([10]))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: probe)
                process.arguments = arguments
                process.standardOutput = log
                process.standardError = FileHandle.standardError
                try process.run()
                process.waitUntilExit()
                try #require(process.terminationReason == .exit && process.terminationStatus == 0,
                    "Probe failed; preserve \(output.path)")
                print("Catalog memory \(episodes) episodes: \(arguments.first ?? "") completed")
            }

            let package = run.appendingPathComponent("package.wwshow").path
            let flat = run.appendingPathComponent("flat.wwshow").path
            let indexed = run.appendingPathComponent("indexed.wwshow").path
            try invoke(["catalog-generate", "--file", package, "--flat-copy", flat,
                        "--episodes", "\(episodes)", "--words", "8000"] + (lazy ? ["--indexed-copy", indexed] : []))
            for repetition in 1...3 {
                if lazy {
                    try invoke(["catalog-memory", "--file", indexed, "--storage", "indexed"])
                    try invoke(["catalog-memory", "--file", indexed, "--storage", "indexed", "--episode", "1",
                                "--save", "1", "--recovery", run.appendingPathComponent("indexed-recovery").path])
                }
                for storage in repetition == 2 ? ["flat", "package"] : ["package", "flat"] {
                    let fixture = storage == "package" ? package : flat
                    if !lazy { try invoke(["catalog-memory", "--file", fixture, "--storage", storage]) }
                    try invoke(["catalog-memory", "--file", fixture, "--storage", storage,
                                "--save", "1", "--recovery", run.appendingPathComponent("\(storage)-recovery").path])
                }
            }
            try log.synchronize()
            let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
            let measured = try lines.compactMap { line -> [String: Any]? in
                let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                return record["result"] as? String == "measured" ? record : nil
            }
            #expect(measured.count == 12)
            for record in measured {
                #expect(record["episodes"] as? Int == episodes)
                if record["storage"] as? String == "indexed" {
                    let loaded = record["residentEpisodes"] as? Int ?? -1
                    #expect(record["currentWordsLoaded"] as? Int == loaded * 8_000)
                    #expect(record["historicalWordsLoaded"] as? Int == loaded * 8_000)
                    if loaded == 1 { #expect(record["unvisitedStoredComponentsPreserved"] as? Bool == true) }
                } else {
                    #expect(record["currentWords"] as? Int == episodes * 8_000)
                    #expect(record["historicalWords"] as? Int == episodes * 8_000)
                }
                #expect((record["openSeconds"] as? Double ?? 0) > 0)
            }
        }.value
    }
}
