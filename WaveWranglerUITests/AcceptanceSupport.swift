import Foundation
import XCTest

/// Shared helpers for the integrated M1 acceptance UI tests (WW-007): in-app timing extraction, nearest-rank
/// statistics and evidence output. Synthetic fixtures only.
///
/// Environment (set with the `TEST_RUNNER_` prefix when invoking `scripts/test.sh --ui`):
/// - `WW_SCALE_SAMPLES`: samples per SCALE-001 stratum (default 5 = calibration; 100 = frozen holdout).
/// - `WW_HOLDOUT_SCENARIOS`: GUI scenarios for DUR-026 / REF-020 (default 2 = calibration; 20 = holdout).
enum Acceptance {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func count(_ key: String, default value: Int) -> Int {
        environment[key].flatMap(Int.init) ?? value
    }

    /// Emits `object` as one `[evidence-json] <name> <json>` line (and an attachment). The sandboxed runner
    /// can't write outside its container, so evidence is collected from the test log.
    static func writeEvidence(_ name: String, _ object: Any, test: XCTestCase? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        print("[evidence-json] \(name) \(String(decoding: data, as: UTF8.self))")
        if let test {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
    }

    /// Keeps a PNG as an attachment in the result bundle (export with `xcresulttool export attachments`).
    static func attach(_ test: XCTestCase, png: Data, name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
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

    // MARK: - Phases (in-app timings are extracted outside the sandboxed runner)

    static let timingArguments = ["-WWUITestTimingLog", "YES"]

    /// Marks a measurement phase in the test log. The UI-test runner is sandboxed and can't read the unified
    /// log, so `docs/m1/evidence/ww-007/collect_timings.py` assigns the app's `WWTIMING` lines to phases by time.
    static func phase(_ name: String, _ body: () throws -> Void) rethrows {
        print("[phase] begin \(name) \(Date().timeIntervalSince1970)")
        defer { print("[phase] end \(name) \(Date().timeIntervalSince1970)") }
        try body()
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
