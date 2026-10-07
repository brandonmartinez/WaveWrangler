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

    /// Accent variants and the system blue used for emphasized list selection are strongly blue.
    static func isAccentBlue(_ hex: String) -> Bool {
        guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return false }
        let r = value >> 16 & 0xFF, g = value >> 8 & 0xFF, b = value & 0xFF
        return b - r >= 120 && b - g >= 60
    }

    static func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
    }
}

/// Accessibility audit policy for the acceptance suites (accessibility-acceptance §4.2): the macOS audit
/// types and the lane suites' structural waivers (system chrome, non-interactive SwiftUI containers, pop-up
/// AXShowMenu, system overlays, AppKit alert icons). For `.contrast`, every finding is screenshotted (crop
/// attached) and measured, and it is waived only as:
/// - **measured artefact**: a surface in `measuredArtefact` (each measured from pixels and cited there) **and**
///   the screenshot taken now shows legible text: ≥ `minimumGlyphPixels` (40) glyph pixels (≥ 1.5:1 against the background) whose
///   75th-percentile ratio is ≥ 4.5:1. A blurred, clipped or low-contrast instance stays unwaived;
/// - **offscreen**: not hittable and no glyph pixels (scrolled out of view: nothing is drawn);
/// - **behind a modal sheet**: content dimmed by AppKit, measured and listed.
/// Every waiver — structural or contrast — is recorded with its element, rationale and (for contrast) the
/// glyph statistics and crop name in an `audit-<surface>` evidence record. No blanket waivers.
extension XCUIApplication {
    /// Launch the app once, opening `document`, with the configured `launchArguments`/`launchEnvironment`.
    ///
    /// Don't call `launch()` and then `open(_:)`: on macOS 27 that pair starts **two** app processes (the second
    /// for the URL), and XCTest can stay bound to the first, which has no document window (and no Library window
    /// when `-WWUITestHooks` suppresses it). Diagnosed on the Mac mini from launchd/runningboard and unified logs
    /// (REF-020, pids 92503/92506): the URL instance opened the document in 0.45 s, while the test waited on the
    /// windowless one, and the orphan's window then "interrupted" later tests. `open(_:)` applies the launch
    /// arguments (the URL instance used the isolated `WaveWrangler-UITests` storage).
    @MainActor
    func launchOnce(opening document: URL) {
        open(document)
        activate()
    }

    /// Opens a menu path, waiting for every item before using it. Intermediate items are hovered so their
    /// submenus have time to populate; only the terminal item is clicked.
    @MainActor
    func chooseMenu(_ path: [String], timeout: TimeInterval = 3) -> Bool {
        guard let rootTitle = path.first else { return false }
        let root = menuBars.menuBarItems[rootTitle]
        guard root.waitForExistence(timeout: timeout) else { return false }
        root.click()

        var parent = root
        for (index, title) in path.dropFirst().enumerated() {
            let item = parent.menuItems[title].firstMatch
            guard item.waitForExistence(timeout: timeout) else { return false }
            if index == path.count - 2 {
                item.click()
            } else {
                item.hover()
            }
            parent = item
        }
        return true
    }
}

/// Visible-part contrast for a `.contrast` audit finding on an element that is **partly** clipped by its
/// window's edge (#59 option (a), coordinator decision 2026-10-05). The audit samples the whole frame,
/// including pixels never drawn outside the window; this measures only the visible intersection, from the
/// window's own screenshot. A finding is waived only when that visible part has >= `AcceptanceAudit.minimumGlyphPixels` glyph pixels with
/// p75 >= 4.5:1; otherwise it stays unwaived. Cells wholly outside every window are not handled here (see
/// `OffscreenAuditWaiver`, whose budget is unchanged). Returns nil when the element isn't partly clipped.
@MainActor
enum PartialClipContrast {
    struct Result { let waived: Bool; let record: [String: Any]; let crop: Data? }

    static func measure(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Result? {
        guard issue.auditType == .contrast, let element = issue.element, element.exists else { return nil }
        let frame = element.frame
        guard !frame.isEmpty else { return nil }
        let windows = app.windows.allElementsBoundByIndex.filter { !$0.frame.isEmpty }
        guard let window = windows.first(where: { $0.frame.intersects(frame) && !$0.frame.contains(frame) }) else { return nil }
        let visible = window.frame.intersection(frame)
        guard visible.width >= 2, visible.height >= 2,
              let cg = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / window.frame.width
        let rect = CGRect(x: (visible.minX - window.frame.minX) * scale, y: (visible.minY - window.frame.minY) * scale,
                          width: visible.width * scale, height: visible.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        let m = ContrastMeter.measure(image) ?? [:]
        let count = m["glyphPixels"] as? Int ?? 0, p75 = m["glyphP75"] as? Double ?? 0
        let waived = count >= AcceptanceAudit.minimumGlyphPixels && p75 >= 4.5
        let record: [String: Any] = ["element": "\(element.identifier) \(element.label) \((element.value as? String) ?? "")",
                                     "frame": "\(frame)", "window": "\(window.frame)", "visible": "\(visible)",
                                     "glyphPixels": count, "glyphP75": p75, "max": m["ratio"] ?? 0, "waived": waived,
                                     "rule": "partly clipped at the window edge: visible part >= \(AcceptanceAudit.minimumGlyphPixels) glyph px, p75 >= 4.5"]
        return Result(waived: waived, record: record, crop: NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
    }
}

/// Apple's contrast audit can sample the entire blue selection fill as foreground when a selected Setup status
/// wraps to two lines. This handler is intentionally limited to the imported, focused "No connection" row and
/// measures only light glyph pixels against that row's accent fill. A clipped row never qualifies.
@MainActor
enum SelectedSetupStatusContrast {
    struct Result { let waived: Bool; let record: [String: Any]; let crop: Data? }

    static func measure(_ element: XCUIElement, in app: XCUIApplication, minimumGlyphPixels: Int) -> Result? {
        let id = element.identifier
        let value = (element.value as? String) ?? element.label
        guard element.elementType == .staticText,
              id.hasPrefix("ww.setup.source."), id.hasSuffix(".status"),
              value.hasPrefix("No connection") else { return nil }

        let sources = app.outlines["ww.setup.sources"]
        let rowID = String(id.dropLast(".status".count))
        let row = app.descendants(matching: .any).matching(identifier: rowID).firstMatch
        let outlineFrame = sources.frame
        let rowFrame = row.frame
        let statusFrame = element.frame
        let fullyVisible = sources.exists && row.exists && element.exists &&
            !outlineFrame.isEmpty && !rowFrame.isEmpty && !statusFrame.isEmpty &&
            outlineFrame.contains(rowFrame) && outlineFrame.contains(statusFrame)
        let selectionPreserved = "\(sources.value ?? "")" == "9 selected"
        let focused = Acceptance.hasKeyboardFocus(sources)
        let shot = element.exists ? element.screenshot() : nil
        let measured: [String: Any]
        if fullyVisible, let shot {
            measured = ContrastMeter.measureTextOnSelection(
                shot.image,
                selectionImage: row.screenshot().image
            ) ?? [:]
        } else {
            measured = [:]
        }
        let glyphPixels = measured["glyphPixels"] as? Int ?? 0
        let glyphP75 = measured["glyphP75"] as? Double ?? 0
        let background = measured["background"] as? String ?? ""
        let accent = Acceptance.isAccentBlue(background)
        let waived = fullyVisible && selectionPreserved && focused && accent &&
            glyphPixels >= minimumGlyphPixels && glyphP75 >= 4.5
        let record: [String: Any] = [
            "element": "\(id) \(value)", "outline": "\(outlineFrame)", "row": "\(rowFrame)",
            "status": "\(statusFrame)", "fullyVisible": fullyVisible, "selection": "\(sources.value ?? "")",
            "focused": focused, "background": background, "glyphPixels": glyphPixels, "glyphP75": glyphP75,
            "max": measured["ratio"] ?? 0, "waived": waived,
            "rule": "exact selected No connection status; row and status fully visible; accent-fill glyph p75 >= 4.5",
        ]
        return Result(waived: waived, record: record, crop: shot?.pngRepresentation)
    }
}

enum AcceptanceAudit {
    /// Minimum glyph pixels (>= 1.5:1 against the background) for a measured contrast waiver, with p75 >= 4.5.
    /// Policy change 2026-10-05 (coordinator decision, disclosed in WW-007 evidence §7): 100 → 40, decided after
    /// the mini run at 550506d found a legible short word ("unknown", 65 px at p75 12.39) under 100. Separation
    /// data: blurred #59 row 4 px, clipped/offscreen cells 0 px, shortest legible word observed 65 px.
    static let minimumGlyphPixels = 40

    static let types: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]
    /// Every type but `.contrast`: for surfaces that are neither blocked nor recovery (M2 baseline).
    static let essentialTypes: XCUIAccessibilityAuditType = types.subtracting(.contrast)

    @MainActor
    static func perform(_ app: XCUIApplication, kinds: XCUIAccessibilityAuditType, surface: String, test: XCTestCase,
                        handling handler: @escaping (XCUIAccessibilityAuditIssue) -> Bool) throws {
        func isTimeout(_ error: Error) -> Bool {
            let error = error as NSError
            return error.code == -56 && error.localizedDescription.contains("Audit failed to complete in time")
        }

        do {
            try app.performAccessibilityAudit(for: kinds, handler)
        } catch {
            guard isTimeout(error) else { throw error }
            Acceptance.record(test, "INFRA ACCESSIBILITY-AUDIT TIMEOUT: \(surface) \(kinds) first attempt; retrying once")
            do {
                try app.performAccessibilityAudit(for: kinds, handler)
            } catch {
                if isTimeout(error) {
                    Acceptance.record(test, "INFRA ACCESSIBILITY-AUDIT TIMEOUT: \(surface) \(kinds) retry also timed out")
                }
                throw error
            }
        }
    }

    /// Episode inspector field labels measured at 15.7–15.9:1 (#59 "first row under the toolbar"). Only these
    /// four were measured; the "Episode" heading and the Show Info inspector's labels were not.
    static let inspectorLabels: Set<String> = ["Title", "Number", "Recording date", "Notes"]

    /// Surfaces whose `.contrast` audit findings were measured from pixels as legible system text (#59, and the
    /// Mac mini run of 479eb9e: `docs/m1/evidence/ww-007/audit-records-mini-479eb9e.jsonl`). A waiver on these
    /// surfaces still requires the glyph test to pass on the screenshot taken now, so a blurred, clipped or
    /// low-contrast instance (e.g. a selected row measured 4.02:1) stays unwaived.
    @MainActor
    static func measuredArtefact(_ element: XCUIElement, inspectorFrame: CGRect?, episodeInspectorShown: Bool,
                                 entriesFrame: CGRect?, windowFrames: [CGRect], inSheet: Bool) -> String? {
        let id = element.identifier
        let text = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        let mid = CGPoint(x: element.frame.midX, y: element.frame.midY)
        guard element.elementType == .staticText else { return nil }
        if ["ww.library.sidebar.recent", "ww.library.sidebar.unavailable"].contains(id) {
            return "Library sidebar unselected row (#59: 18.1:1 light / 15.7:1 dark)"
        }
        if id == "ww.show.sidebar.showInfo" || id.hasPrefix("ww.show.sidebar.episode.") {
            return "show sidebar row (mini 479eb9e: unselected 15.7–15.9:1)"
        }
        if episodeInspectorShown, inspectorLabels.contains(text), let inspectorFrame, inspectorFrame.contains(mid) {
            return "Episode inspector label (#59: 15.7–15.9:1)"
        }
        if let inspectorFrame, inspectorFrame.contains(mid), text == "Not set" {
            return "inspector value text (mini 479eb9e: 14.1:1)"
        }
        // Cells can extend past the outline's clip frame horizontally: match the table's left edge and vertical extent.
        if let entriesFrame, element.frame.minX >= entriesFrame.minX, element.frame.minY >= entriesFrame.minY,
           element.frame.maxY <= entriesFrame.maxY {
            return "Library entry list cell, system text (#59 after fix and mini 479eb9e: 11.0–16.3:1)"
        }
        if id.hasPrefix("ww.setup.source.") || id.hasPrefix("ww.setup.group.") {
            return "Setup Sources cell, system text (mini 479eb9e: 7.4–17.2:1)"
        }
        if id == "AX_EDITING_STATE" || windowFrames.contains(where: { $0.contains(mid) && mid.y - $0.minY < 52 }) {
            return "window title / subtitle drawn by AppKit (mini 479eb9e: 7.5–15.7:1)"
        }
        if text == "No episodes yet" {
            return "empty-state title (mini 479eb9e: 6.15:1)"
        }
        if inSheet, id.hasPrefix("_NS:") {
            return "AppKit sheet message text (mini 479eb9e: 9.75:1)"
        }
        // Setup header source count and Speakers status (non-blocked), measured legible on the Mac mini at #175
        // 2ac330a (GUI round 1, D15): "4 sources" p75 12.39:1 (147 glyph px), "Choose primary" p75 12.75:1 (248).
        if text.range(of: #"^[0-9]+ sources?$"#, options: .regularExpression) != nil {
            return "Setup source count, system headline text (mini #175 2ac330a: p75 12.39:1)"
        }
        if id.isEmpty, element.label == "Status", text != "Status" {
            return "Setup Speakers status text, system text (mini #175 2ac330a: p75 12.75:1)"
        }
        if id == "ww.show.saveStatus.popover" {
            return "save-status popover text, system text (mini #197 round 3, 0d99329: p75 9.14:1, max 9.47:1)"
        }
        return nil
    }

    /// Glyph-statistic test for an element screenshot (see type comment).
    static func passesGlyphContrast(_ measured: [String: Any]?) -> Bool {
        guard let measured, let count = measured["glyphPixels"] as? Int, let p75 = measured["glyphP75"] as? Double else { return false }
        return count >= minimumGlyphPixels && p75 >= 4.5
    }

    /// `kinds` defaults to every type. The M2 essential set (`essentialTypes`) leaves out `.contrast`, which the M2
    /// baseline enforces only on blocked or recovery surfaces (docs/m2/evidence/m2-gui-baseline.md).
    @MainActor
    static func run(_ app: XCUIApplication, surface: String, test: XCTestCase,
                    types kinds: XCUIAccessibilityAuditType = types,
                    additionalWaiver: ((XCUIAccessibilityAuditIssue) -> String?)? = nil) throws -> [String] {
        var unwaived: [String] = []
        var waived: [[String: Any]] = []
        let sheet: XCUIElement? = app.sheets.firstMatch.exists ? app.sheets.firstMatch : nil
        let sheetFrame: CGRect? = sheet?.frame
        let inspector = app.descendants(matching: .any).matching(identifier: "ww.inspector").firstMatch
        let inspectorFrame: CGRect? = inspector.exists ? inspector.frame : nil
        // The Episode inspector (not Show Info) is showing when its Title field exists.
        let episodeInspectorShown = app.descendants(matching: .any).matching(identifier: "ww.inspector.episode.title").firstMatch.exists
        let entries = app.outlines["ww.library.entries"]
        let entriesFrame: CGRect? = entries.exists ? entries.frame : nil
        let windows = app.windows.allElementsBoundByIndex
        let windowFrames = windows.map(\.frame)
        var contrast: [(XCUIElement, String)] = []
        var issueFor: [XCUIAccessibilityAuditIssue] = []
        func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
            "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(200) ?? "no element")"
        }
        func handle(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            let description = describe(issue)
            if let rationale = structuralWaiver(for: issue) {
                waived.append(["finding": description, "rationale": rationale, "kind": "structural"])
                print("AUDIT WAIVED \(description) — \(rationale)")
            } else if let rationale = additionalWaiver?(issue) {
                waived.append(["finding": description, "rationale": rationale, "kind": "test-scoped"])
                print("AUDIT WAIVED \(description) — \(rationale)")
            } else if issue.auditType == .contrast, let element = issue.element {
                contrast.append((element, description))
                issueFor.append(issue)
            } else {
                unwaived.append(description)
            }
            return true
        }
        // Audits of large trees can time out (XCTest error -56); run contrast separately and retry once.
        // Findings are retained in `unwaived`/`contrast` across both attempts, never retried away.
        func audit(_ kinds: XCUIAccessibilityAuditType) throws {
            try perform(app, kinds: kinds, surface: surface, test: test, handling: handle)
        }
        try audit(kinds.subtracting(.contrast))
        if kinds.contains(.contrast) { try audit(.contrast) }
        for (index, (element, description)) in contrast.enumerated() {
            let shot = element.exists ? element.screenshot() : nil
            let measured = shot.flatMap { ContrastMeter.measure($0.image) }
            let crop = "audit-crop-\(surface.replacingOccurrences(of: " ", with: "_"))-\(index).png"
            if let shot { Acceptance.attach(test, png: shot.pngRepresentation, name: crop) }
            var stats: [String: Any] = measured.map { m in ["glyphPixels": m["glyphPixels"] ?? 0, "glyphP75": m["glyphP75"] ?? 0, "max": m["ratio"] ?? 0] } ?? [:]
            stats["crop"] = crop
            // In the sheet by AX membership, not by geometry: window content lying under the sheet's rectangle isn't
            // the sheet's text (its screenshot shows the sheet's pixels; M1 gate cdb56bd, T23 D7). `.contrast` is
            // enforced on the sheet's own elements, the surface being audited.
            let inSheet = sheet.map { Self.isDescendant(element, of: $0) } ?? false
            // Occluded: the element belongs (by AX hierarchy) to a window behind another app window that overlaps
            // it (AX lists windows front to back). Its screenshot shows the front window's pixels, so nothing can be
            // measured here; recorded, and that window is audited while frontmost (as the C03 test does). An
            // element of the front window itself, even if partly clipped, is measured (PartialClipContrast).
            if sheetFrame == nil, let own = owningWindowIndex(of: element, in: windows), own > 0,
               windowFrames[..<own].contains(where: { $0.intersects(element.frame) }) {
                waived.append(["finding": description, "kind": "occluded-by-front-window", "measured": stats,
                               "rationale": "behind another window of the app; audited separately while frontmost"])
                print("AUDIT WAIVED \(description) — occluded by a window in front; measured (front pixels) \(stats)")
                continue
            }
            if sheetFrame != nil, element.exists, !inSheet {
                waived.append(["finding": description, "kind": "behind-modal-sheet", "measured": stats,
                               "rationale": "window content dimmed behind a modal sheet; that surface is audited without the sheet"])
                print("AUDIT WAIVED \(description) — dimmed behind a modal sheet; measured \(stats)")
                continue
            }
            // Scrolled out of view: nothing is rendered where the element is (its screenshot has no glyphs).
            if element.exists, !element.isHittable, (stats["glyphPixels"] as? Int ?? 0) < 20 {
                waived.append(["finding": description, "kind": "offscreen", "measured": stats,
                               "rationale": "element not visible (not hittable, no glyph pixels): scrolled out of view, not a colour"])
                print("AUDIT WAIVED \(description) — offscreen; measured \(stats)")
                continue
            }
            if let partial = PartialClipContrast.measure(issueFor[index], in: app) {
                if let crop = partial.crop { Acceptance.attach(test, png: crop, name: "visible-\(crop)") }
                if partial.waived {
                    waived.append(["finding": description, "kind": "partly-clipped-visible-part", "measured": partial.record])
                    print("AUDIT WAIVED \(description) — partly clipped; visible part measured \(partial.record)")
                } else {
                    unwaived.append("\(description) — partly clipped; visible part measured \(partial.record)")
                }
                continue
            }
            if let selectedStatus = SelectedSetupStatusContrast.measure(
                element,
                in: app,
                minimumGlyphPixels: minimumGlyphPixels
            ) {
                if let data = selectedStatus.crop {
                    Acceptance.attach(test, png: data, name: "selection-fill-\(crop)")
                }
                if selectedStatus.waived {
                    waived.append([
                        "finding": description, "kind": "selected-status-sampling-artefact",
                        "measured": selectedStatus.record,
                        "rationale": "Apple sampled the accent selection fill as glyphs; isolated light text passes",
                    ])
                    print("AUDIT WAIVED \(description) — selected status sampling artefact; measured \(selectedStatus.record)")
                } else {
                    unwaived.append("\(description) — selected status did not satisfy narrow artefact rule \(selectedStatus.record)")
                }
                continue
            }
            if let artefact = measuredArtefact(element, inspectorFrame: inspectorFrame, episodeInspectorShown: episodeInspectorShown,
                                               entriesFrame: entriesFrame, windowFrames: windowFrames, inSheet: inSheet),
               passesGlyphContrast(measured) {
                waived.append(["finding": description, "kind": "measured-artefact", "measured": stats, "rationale": artefact])
                print("AUDIT WAIVED \(description) — \(artefact); measured now \(stats)")
            } else {
                unwaived.append("\(description) — measured \(stats)")
            }
        }
        Acceptance.writeEvidence("audit-\(surface.replacingOccurrences(of: " ", with: "_"))", [
            "surface": surface, "unwaived": unwaived, "waived": waived, "contrastAudited": kinds.contains(.contrast),
        ], test: test)
        print("AUDIT \(surface): \(unwaived.isEmpty ? "no unwaived issues" : "\(unwaived.count) unwaived issue(s)"); \(waived.count) waived (recorded)")
        return unwaived
    }

    /// Index (front to back) of the window whose AX subtree contains `element`, matched by element type,
    /// identifier (or label and value when there is none) and frame. Geometry alone is not enough: a cell partly
    /// clipped at the front window's edge can lie wholly inside a larger window behind it.
    @MainActor
    /// Whether `element` is in `container`'s AX hierarchy (same type, identifier or label and value, and frame).
    static func isDescendant(_ element: XCUIElement, of container: XCUIElement) -> Bool {
        let frame = element.frame
        return container.descendants(matching: element.elementType).matching(sameElement(element)).allElementsBoundByIndex.contains { $0.frame == frame }
    }

    /// Matches `element` by identifier, or by label and value when it has none (a fresh predicate per query).
    static func sameElement(_ element: XCUIElement) -> NSPredicate {
        element.identifier.isEmpty
            ? NSPredicate(format: "label == %@ AND value == %@", element.label, (element.value as? String) ?? "")
            : NSPredicate(format: "identifier == %@", element.identifier)
    }

    static func owningWindowIndex(of element: XCUIElement, in windows: [XCUIElement]) -> Int? {
        let frame = element.frame
        for (index, window) in windows.enumerated() {
            let candidates = window.descendants(matching: element.elementType).matching(sameElement(element)).allElementsBoundByIndex
            if candidates.contains(where: { $0.frame == frame }) { return index }
        }
        return nil
    }

    /// Source file names in the frozen M1 golden shows (`ShowSchema1Fixtures`, F-OLDER), read from their bytes.
    static let goldenFixtureFileNames: Set<String> = {
        var names: Set<String> = []
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                if let name = object["displayNameHint"] as? String { names.insert(name) }
                object.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        for bytes in [ShowSchema1Fixtures.placeholderOnly, ShowSchema1Fixtures.statedChannels, ShowSchema1Fixtures.mixed] {
            if let object = try? JSONSerialization.jsonObject(with: bytes) { collect(object) }
        }
        return names
    }()

    static func structuralWaiver(for issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else { return nil }
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) { return "system window chrome" }
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled { return "non-interactive layout container" }
        if issue.auditType == .action, element.elementType == .popUpButton { return "system pop-up button exposes AXShowMenu" }
        // Since #112 the Setup Name cell's label is the source's file name (the visible name, IA §5) and its value
        // carries the hidden columns; the audit's heuristic calls a file name "not human-readable". Scoped to Name
        // cells of the synthetic fixtures (`synthetic-N.wav`, fixture-states `trN.wav`) and of the frozen M1 golden shows
        // (F-OLDER, #159), where the label is verifiably the file's name. This is the M2 baseline's "Setup source-name
        // cells" artefact class (docs/m2/evidence/m2-gui-baseline.md).
        if issue.auditType == .sufficientElementDescription, element.elementType == .staticText,
           element.identifier.range(of: #"^ww\.setup\.source\.[0-9A-F-]{36}$"#, options: .regularExpression) != nil,
           element.label.range(of: #"^(synthetic-[0-9]+|tr[0-9]+)\.wav$"#, options: .regularExpression) != nil
            || goldenFixtureFileNames.contains(element.label) {
            return "Setup Name cell labelled with the source's file name '\(element.label)' (the visible name; heuristic finding)"
        }
        if element.elementType == .popUpButton, element.label == "emoji & symbols" { return "system input item, not app UI" }
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists { return "system Siri overlay, not app UI" }
        if element.elementType == .image, element.label.hasSuffix("alert"), element.identifier.hasPrefix("_NS:") {
            return "AppKit NSAlert icon (decorative; the alert's text carries the message)"
        }
        return nil
    }
}
