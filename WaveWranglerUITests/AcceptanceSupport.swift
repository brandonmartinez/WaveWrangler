import Foundation
import XCTest

/// Shared helpers for the integrated M1 acceptance UI tests (WW-007): in-app timing extraction, nearest-rank
/// statistics and evidence output. Synthetic fixtures only.
///
/// Environment (set with the `TEST_RUNNER_` prefix when invoking `scripts/test.sh --ui`):
/// - `WW_EVIDENCE_DIR`: folder for raw JSON evidence (default: the runner's temporary directory).
/// - `WW_SCALE_SAMPLES`: samples per SCALE-001 stratum (default 5 = calibration; 100 = frozen holdout).
/// - `WW_HOLDOUT_SCENARIOS`: GUI scenarios for DUR-026 / REF-020 (default 2 = calibration; 20 = holdout).
enum Acceptance {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func count(_ key: String, default value: Int) -> Int {
        environment[key].flatMap(Int.init) ?? value
    }

    static var evidenceDirectory: URL {
        let url = environment["WW_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "WaveWranglerEvidence", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `object` as pretty JSON into the evidence folder and returns its URL.
    @discardableResult
    static func writeEvidence(_ name: String, _ object: Any) -> URL {
        let url = evidenceDirectory.appending(path: name)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        return url
    }

    // MARK: - Statistics (registry: nearest-rank ceil(0.95 n))

    static func p95(_ values: [Double]) -> Double? { percentile(values, 0.95) }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    static func summary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        return [
            "n": values.count,
            "p50": percentile(values, 0.5) ?? 0,
            "p95": p95(values) ?? 0,
            "max": values.max() ?? 0,
            "min": values.min() ?? 0,
        ]
    }

    // MARK: - In-app timings (`-WWUITestTimingLog YES`, see WaveWrangler/Support/Responsiveness.swift)

    struct Timing {
        var name: String
        var eventMs: Double
        var handlerMs: Double
        var thread: String
        var detail: [String: String]
        var date: String
    }

    static let timingArguments = ["-WWUITestTimingLog", "YES"]

    /// Reads the app's `WWTIMING` lines logged since `start` from the unified log.
    static func appTimings(since start: Date) -> [Timing] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--style", "ndjson", "--info",
            "--start", formatter.string(from: start.addingTimeInterval(-1)),
            "--predicate", "subsystem == \"com.brandonmartinez.wavewrangler\" AND category == \"Responsiveness\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var timings: [Timing] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["eventMessage"] as? String, message.hasPrefix("WWTIMING ") else { continue }
            var fields: [String: String] = [:]
            for part in message.dropFirst("WWTIMING ".count).split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard let name = fields.removeValue(forKey: "name"),
                  let event = fields.removeValue(forKey: "eventMs").flatMap(Double.init),
                  let handler = fields.removeValue(forKey: "handlerMs").flatMap(Double.init) else { continue }
            let thread = fields.removeValue(forKey: "thread") ?? "?"
            timings.append(Timing(name: name, eventMs: event, handlerMs: handler, thread: thread, detail: fields,
                                  date: object["timestamp"] as? String ?? ""))
        }
        return timings
    }

    static func json(_ timings: [Timing]) -> [[String: Any]] {
        timings.map { ["name": $0.name, "eventMs": $0.eventMs, "handlerMs": $0.handlerMs, "thread": $0.thread, "detail": $0.detail, "date": $0.date] }
    }

    /// Commit and tree IDs of the tested checkout (the runner is not sandboxed; `WW_SOURCE_ROOT` or the
    /// source file's location find the repository).
    static func revision(file: String = #filePath) -> [String: String] {
        let root = environment["WW_SOURCE_ROOT"] ?? URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().path
        func git(_ args: [String]) -> (String, Int32) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return ("", -1) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        }
        return [
            "commit": git(["rev-parse", "HEAD"]).0,
            "tree": git(["rev-parse", "HEAD^{tree}"]).0,
            "worktree": git(["status", "--porcelain", "--untracked-files=no"]).0.isEmpty ? "clean" : "dirty",
            "containsFreeze2fcf4d7": git(["merge-base", "--is-ancestor", "2fcf4d7", "HEAD"]).1 == 0 ? "yes" : "no",
        ]
    }

    static func record(_ test: XCTestCase, _ line: String) {
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        test.add(attachment)
        print("[evidence] \(line)")
    }

    static func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
