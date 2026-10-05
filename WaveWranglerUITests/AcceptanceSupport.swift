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
        let commit = git(["rev-parse", "HEAD"]).0
        // The UI-test runner is sandboxed and usually can't run git; the harness records the revision instead.
        guard !commit.isEmpty else { return ["note": "not readable in the sandboxed runner; recorded by the harness"] }
        return [
            "commit": commit,
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

/// Accessibility audit policy for the acceptance suites (accessibility-acceptance §4.2): the macOS audit
/// types and the lane suites' structural waivers (system chrome, non-interactive SwiftUI containers, pop-up
/// AXShowMenu, system overlays, AppKit alert icons). For `.contrast`, a finding is waived only when **both**:
/// 1. the element is one of the surfaces whose audit-artefact status was measured and evidenced in #59
///    (`measuredArtefact`), and
/// 2. its screenshot, measured now, shows real text with A1 contrast: at least 100 glyph pixels (pixels
///    ≥ 1.5:1 against the background) whose 75th-percentile ratio is ≥ 4.5:1. A blurred or clipped label has
///    only a handful of glyph pixels (the #59 blur measured 4), so a single bright pixel can't pass.
/// Findings on window content behind a modal sheet (dimmed by AppKit) are waived but measured and listed.
/// Every waiver — structural or contrast — is recorded with its element and rationale (and, for contrast,
/// the glyph statistics) in an `audit-<surface>` evidence record.
enum AcceptanceAudit {
    static let types: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]

    /// Episode inspector field labels measured at 15.7–15.9:1 (#59 "first row under the toolbar").
    static let inspectorLabels: Set<String> = ["Episode", "Title", "Number", "Recording date", "Notes"]

    /// Surfaces measured as audit artefacts in #59: Library sidebar unselected rows (18.1 / 15.7:1) and the
    /// Episode inspector's labels inside `ww.inspector` (15.7–15.9:1).
    @MainActor
    static func measuredArtefact(_ element: XCUIElement, inspectorFrame: CGRect?) -> String? {
        if ["ww.library.sidebar.recent", "ww.library.sidebar.unavailable"].contains(element.identifier) {
            return "Library sidebar unselected row (#59: measured 18.1:1 light / 15.7:1 dark)"
        }
        let text = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        if element.elementType == .staticText, inspectorLabels.contains(text), let inspectorFrame,
           inspectorFrame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
            return "Episode inspector label (#59: measured 15.7–15.9:1)"
        }
        return nil
    }

    /// Glyph-statistic test for an element screenshot (see type comment).
    static func passesGlyphContrast(_ measured: [String: Any]?) -> Bool {
        guard let measured, let count = measured["glyphPixels"] as? Int, let p75 = measured["glyphP75"] as? Double else { return false }
        return count >= 100 && p75 >= 4.5
    }

    @MainActor
    static func run(_ app: XCUIApplication, surface: String, test: XCTestCase) throws -> [String] {
        var unwaived: [String] = []
        var waived: [[String: Any]] = []
        let sheetFrame: CGRect? = app.sheets.firstMatch.exists ? app.sheets.firstMatch.frame : nil
        let inspector = app.descendants(matching: .any).matching(identifier: "ww.inspector").firstMatch
        let inspectorFrame: CGRect? = inspector.exists ? inspector.frame : nil
        var contrast: [(XCUIElement, String)] = []
        func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
            "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(200) ?? "no element")"
        }
        func handle(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            let description = describe(issue)
            if let rationale = structuralWaiver(for: issue) {
                waived.append(["finding": description, "rationale": rationale, "kind": "structural"])
                print("AUDIT WAIVED \(description) — \(rationale)")
            } else if issue.auditType == .contrast, let element = issue.element {
                contrast.append((element, description))
            } else {
                unwaived.append(description)
            }
            return true
        }
        // Audits of large trees can time out (XCTest error -56); run contrast separately and retry once.
        func audit(_ kinds: XCUIAccessibilityAuditType) throws {
            do {
                try app.performAccessibilityAudit(for: kinds, handle)
            } catch let error as NSError where error.code == -56 {
                print("AUDIT \(surface): timed out once for \(kinds); retrying")
                try app.performAccessibilityAudit(for: kinds, handle)
            }
        }
        try audit(types.subtracting(.contrast))
        try audit(.contrast)
        for (element, description) in contrast {
            let measured = element.exists ? ContrastMeter.measure(element.screenshot().image) : nil
            let stats = measured.map { m in ["glyphPixels": m["glyphPixels"] ?? 0, "glyphP75": m["glyphP75"] ?? 0, "max": m["ratio"] ?? 0] } ?? [:]
            if let sheetFrame, element.exists, !sheetFrame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                waived.append(["finding": description, "kind": "behind-modal-sheet", "measured": stats,
                               "rationale": "window content dimmed behind a modal sheet; that surface is audited without the sheet"])
                print("AUDIT WAIVED \(description) — dimmed behind a modal sheet; measured \(stats)")
                continue
            }
            if let artefact = measuredArtefact(element, inspectorFrame: inspectorFrame), passesGlyphContrast(measured) {
                waived.append(["finding": description, "kind": "measured-artefact", "measured": stats, "rationale": artefact])
                print("AUDIT WAIVED \(description) — \(artefact); measured now \(stats)")
            } else {
                unwaived.append("\(description) — measured \(stats)")
            }
        }
        Acceptance.writeEvidence("audit-\(surface.replacingOccurrences(of: " ", with: "_"))", [
            "surface": surface, "unwaived": unwaived, "waived": waived,
        ], test: test)
        print("AUDIT \(surface): \(unwaived.isEmpty ? "no unwaived issues" : "\(unwaived.count) unwaived issue(s)"); \(waived.count) waived (recorded)")
        return unwaived
    }

    static func structuralWaiver(for issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else { return nil }
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) { return "system window chrome" }
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled { return "non-interactive layout container" }
        if issue.auditType == .action, element.elementType == .popUpButton { return "system pop-up button exposes AXShowMenu" }
        if element.elementType == .popUpButton, element.label == "emoji & symbols" { return "system input item, not app UI" }
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists { return "system Siri overlay, not app UI" }
        if element.elementType == .image, element.label.hasSuffix("alert"), element.identifier.hasPrefix("_NS:") {
            return "AppKit NSAlert icon (decorative; the alert's text carries the message)"
        }
        return nil
    }
}
