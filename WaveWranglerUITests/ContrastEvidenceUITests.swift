import AppKit
import CoreImage
import XCTest

/// Evidence for #59 (C04/C07) and C06: measures text/background contrast ratios from screenshots of the
/// elements the `.contrast` audit flags, in light, dark and both Increase Contrast appearances, and saves
/// saturation-0 screenshots for colour-independence review. Synthetic F-LIB100 library only.
///
/// The appearance comes from `-WWUITestAppearance` (AppKit's own high-contrast appearances: an override,
/// not the system setting). The system-setting run is the same test with Increase Contrast turned on in
/// System Settings (grant D) and `WW_CONTRAST_LABEL` naming it.
@MainActor
final class ContrastEvidenceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    func testLibraryTextContrastAcrossAppearances() throws {
        let label = Acceptance.environment["WW_CONTRAST_LABEL"] ?? "override"
        var results: [[String: Any]] = []
        for appearance in ["aqua", "darkAqua", "highContrastAqua", "highContrastDarkAqua"] {
            app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                                   "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100", "-WWUITestAppearance", appearance]
            app.launch()
            app.activate()
            let entries = app.outlines["ww.library.entries"]
            XCTAssertTrue(entries.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            // Move keyboard focus away from the sidebar's selected row so "Recent" is an ordinary unselected row.
            var measured: [[String: Any]] = []
            let names = entries.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.'"))
            let targets: [(String, XCUIElement)] = [
                ("sidebar unselected row 'Recent'", app.descendants(matching: .any)["ww.library.sidebar.recent"]),
                ("sidebar unselected row 'Unavailable'", app.descendants(matching: .any)["ww.library.sidebar.unavailable"]),
                ("entry table name text (row 1)", names.element(boundBy: 0)),
                ("entry table name text (row 2)", names.element(boundBy: 1)),
                ("entry table name text (row 5)", names.element(boundBy: 4)),
                ("entry table column header 'Name'", entries.descendants(matching: .any).matching(NSPredicate(format: "label == 'Name' AND elementType != 48")).firstMatch),
            ]
            for (name, element) in targets where element.exists {
                let screenshot = element.screenshot()
                let file = "contrast-\(label)-\(appearance)-\(name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "'", with: "")).png"
                Acceptance.attach(self, png: screenshot.pngRepresentation, name: file)
                var entry: [String: Any] = ["element": name, "identifier": element.identifier, "frame": "\(element.frame)", "screenshot": file]
                if let ratio = ContrastMeter.measure(screenshot.image) {
                    entry.merge(ratio) { $1 }
                }
                measured.append(entry)
            }
            // Audit without any contrast waiver: which elements does the audit flag in this appearance?
            var flagged: [String] = []
            try app.performAccessibilityAudit(for: [.contrast]) { issue in
                flagged.append("\(issue.element?.identifier ?? "") \(issue.element?.label ?? "") \(issue.element.map { "\($0.frame)" } ?? "")")
                return true
            }
            let window = app.windows.firstMatch.screenshot()
            let full = "contrast-\(label)-\(appearance)-library-window.png"
            Acceptance.attach(self, png: window.pngRepresentation, name: full)
            if let gray = ContrastMeter.desaturated(window.image) {
                Acceptance.attach(self, png: gray, name: "saturation0-\(label)-\(appearance)-library-window.png")
            }
            results.append(["appearance": appearance, "measurements": measured, "auditContrastFlags": flagged, "windowScreenshot": full])
            Acceptance.record(self, "#59 \(label) \(appearance): \(measured.map { "\($0["element"] ?? ""): \($0["ratio"] ?? "n/a")" }) audit flags \(flagged.count)")
            app.terminate()
        }
        Acceptance.writeEvidence("contrast-\(label)", ["revision": Acceptance.revision(), "label": label, "results": results], test: self)
    }

    /// C03: in-app Text Size 200% (⌘+ to the maximum) screenshots of the Library, the show window's Setup with
    /// the F-STATES fixture and the episode inspector, for clipping review.
    func testTextSize200Screenshots() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "3"]
        app.launchEnvironment["WW_SETUP_ENGINE"] = "fixture-states"
        app.launch()
        app.activate()
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        window.typeKey("1", modifierFlags: .command)
        app.typeKey("i", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.5)
        Acceptance.attach(self, png: app.windows.firstMatch.screenshot().pngRepresentation, name: "text200-import-review.png")
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        Acceptance.attach(self, png: window.screenshot().pngRepresentation, name: "text200-setup.png")
        window.typeKey("i", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        Acceptance.attach(self, png: window.screenshot().pngRepresentation, name: "text200-episode-inspector.png")
        app.typeKey("l", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.5)
        Acceptance.attach(self, png: app.windows.firstMatch.screenshot().pngRepresentation, name: "text200-library.png")
        _ = try AcceptanceAudit.run(app, surface: "200% text (Library)", test: self)
    }

    /// C03 quick check: the Library window with its message bar at in-app 200% text (light), screenshot only.
    func testLibraryMessageBarAt200() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100", "-WWUITestAppearance", "aqua"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.outlines["ww.library.entries"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        capture("library-messagebar-100")
        let first = app.outlines["ww.library.entries"].staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.'")).element(boundBy: 0)
        let ratio = first.exists ? ContrastMeter.measure(first.screenshot().image)?["ratio"] ?? "n/a" : "missing"
        let header = app.outlines["ww.library.entries"].frame
        Acceptance.record(self, "C03 library 100%: first row ratio \(ratio), entries frame \(header), first row \(first.exists ? "\(first.frame)" : "missing")")
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        Thread.sleep(forTimeInterval: 1.5)
        capture("library-messagebar-200")
        let shows = app.descendants(matching: .any)["ww.library.sidebar.shows"]
        let window = app.windows.firstMatch
        Acceptance.record(self, "C03 library 200%: window \(window.frame), Shows row \(shows.exists ? "\(shows.frame)" : "missing"), new-collection element \(app.descendants(matching: .any)["ww.library.sidebar.newCollection"].elementType.rawValue) button \(app.buttons["ww.library.sidebar.newCollection"].exists)")
    }

    /// A11Y-003 with in-app overrides only (OS-level Increase Contrast / Reduce Motion / larger text are
    /// user-only items): light and dark appearance, `-WWForceReduceMotion YES`, in-app text size 200%.
    /// Library (with its message bar, #59) and Setup with the F-STATES fixture; audits plus normal and
    /// saturation-0 screenshots of each surface.
    func testVisualOverridesLightDarkReduceMotion200() throws {
        for appearance in ["aqua", "darkAqua"] {
            app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                                   "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100", "-WWUITestAppearance", appearance,
                                   "-WWForceReduceMotion", "YES"]
            app.launch()
            app.activate()
            XCTAssertTrue(app.outlines["ww.library.entries"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            capture("visual-\(appearance)-library-100")
            let first = app.outlines["ww.library.entries"].staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.'")).element(boundBy: 0)
            if first.exists, let ratio = ContrastMeter.measure(first.screenshot().image) {
                Acceptance.record(self, "#59 after fix \(appearance): first entry row ratio \(ratio["ratio"] ?? "?") (\(ratio["text"] ?? "") on \(ratio["background"] ?? ""))")
            }
            let unwaived = try AcceptanceAudit.run(app, surface: "Library \(appearance) 100% reduce motion", test: self)
            Acceptance.record(self, "A11Y-003 Library \(appearance) 100%: \(unwaived.isEmpty ? "no unwaived audit issues" : "\(unwaived)")")
            for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
            Thread.sleep(forTimeInterval: 1)
            capture("visual-\(appearance)-library-200")
            let unwaived200 = try AcceptanceAudit.run(app, surface: "Library \(appearance) 200%", test: self)
            Acceptance.record(self, "A11Y-003 Library \(appearance) 200%: \(unwaived200.isEmpty ? "no unwaived audit issues" : "\(unwaived200)")")
            app.terminate()

            app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                                   "-WWUITestCenterWindows", "YES", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "2",
                                   "-WWUITestAppearance", appearance, "-WWForceReduceMotion", "YES"]
            app.launchEnvironment["WW_SETUP_ENGINE"] = "fixture-states"
            app.launch()
            app.activate()
            let window = app.windows.matching(identifier: "ww.show.window").firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
            window.typeKey("1", modifierFlags: .command)
            app.typeKey("i", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 1.5)
            capture("visual-\(appearance)-import-review-200")
            app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 2)
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuItems["Zoom"].click()
            Thread.sleep(forTimeInterval: 1)
            capture("visual-\(appearance)-setup-200-zoomed")
            let unwaivedSetup = try AcceptanceAudit.run(app, surface: "Setup \(appearance) 200% reduce motion", test: self)
            Acceptance.record(self, "A11Y-003 Setup \(appearance) 200%: \(unwaivedSetup.isEmpty ? "no unwaived audit issues" : "\(unwaivedSetup)")")
            app.terminate()
        }
    }

    /// Accent decision (AccentColor #0064E1, design spec states-and-recovery §1 "Accent"): measures every
    /// accent-tinted control in light and dark. Text on an accent fill (selected rows, the default button,
    /// the selected toolbar destination) must reach glyph p75 ≥ 4.5:1; an accent fill that alone shows state
    /// (switch on, checkbox checked) must reach ≥ 3:1 against its surroundings (WCAG 1.4.11). Values recorded
    /// as `[evidence-json] accent-controls-<appearance>` with a crop per control.
    func testAccentTintedControls() throws {
        for appearance in ["aqua", "darkAqua"] {
            var rows: [[String: Any]] = []
            func textOnAccent(_ name: String, _ element: XCUIElement) {
                guard element.exists else { rows.append(["control": name, "result": "not found"]); return }
                let shot = element.screenshot()
                Acceptance.attach(self, png: shot.pngRepresentation, name: "accent-\(appearance)-\(slug(name)).png")
                let m = ContrastMeter.measure(shot.image) ?? [:]
                let p75 = m["glyphP75"] as? Double ?? 0
                rows.append(["control": name, "kind": "text on accent", "frame": "\(element.frame)", "threshold": 4.5].merging(m) { $1 })
                XCTAssertGreaterThanOrEqual(p75, 4.5, "\(appearance) \(name): text on accent glyph p75 \(p75) (\(m["text"] ?? "") on \(m["background"] ?? ""))")
            }
            func fill(_ name: String, _ element: XCUIElement, assert: Bool) {
                guard element.exists else { rows.append(["control": name, "result": "not found"]); return }
                let window = app.windows.firstMatch
                var m = ContrastMeter.accentFill(window.screenshot().image, windowFrame: window.frame, element: element.frame) ?? [:]
                if let crop = m.removeValue(forKey: "crop") as? Data { Acceptance.attach(self, png: crop, name: "accent-\(appearance)-\(slug(name)).png") }
                let ratio = m["fillContrast"] as? Double ?? 0
                rows.append(["control": name, "kind": "accent fill vs surroundings", "frame": "\(element.frame)", "value": "\(element.value ?? "")",
                             "threshold": assert ? 3.0 : "recorded only"].merging(m) { $1 })
                if assert { XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(appearance) \(name): accent fill \(m["fill"] ?? "none") vs \(m["background"] ?? "") = \(ratio)") }
            }

            app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                                   "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100", "-WWUITestAppearance", appearance]
            app.launch()
            app.activate()
            let entries = app.outlines["ww.library.entries"]
            XCTAssertTrue(entries.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            textOnAccent("Library sidebar selected row 'Shows'", app.descendants(matching: .any)["ww.library.sidebar.shows"])
            let first = entries.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.'")).element(boundBy: 0)
            if first.exists { first.click(); Thread.sleep(forTimeInterval: 1) }
            textOnAccent("Library selected entry row (focused outline)", first)
            let open = app.descendants(matching: .any)["ww.library.detail.open"]
            textOnAccent("Default button 'Open Show' label", open)
            fill("Default button 'Open Show' bezel", open, assert: false)
            app.typeKey(",", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1.5)
            let autosave = app.descendants(matching: .any)["ww.settings.autosave"]
            fill("Settings switch 'Autosave' (on)", autosave, assert: isOn(autosave) && autosave.isEnabled)
            let sourcesTab = app.toolbars.buttons["Sources"]
            if sourcesTab.exists { sourcesTab.click(); Thread.sleep(forTimeInterval: 1) }
            let download = app.descendants(matching: .any)["ww.settings.downloadSources"]
            fill("Settings switch 'Download sources'", download, assert: isOn(download))
            app.terminate()

            app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                                   "-WWUITestCenterWindows", "YES", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "2",
                                   "-WWUITestAppearance", appearance]
            app.launchEnvironment["WW_SETUP_ENGINE"] = "fixture-states"
            app.launch()
            app.activate()
            let window = app.windows.matching(identifier: "ww.show.window").firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            window.typeKey("1", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            let episode = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.show.sidebar.episode.'")).firstMatch
            textOnAccent("Show sidebar selected episode row", episode)
            textOnAccent("Toolbar selected destination 'Setup' (accent 25% fill)", app.descendants(matching: .any)["ww.show.destination.setup"])
            app.typeKey("i", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 1.5)
            let include = app.descendants(matching: .any)["ww.import.row.0.include"]
            fill("Import review checkbox 'Include' (checked)", include, assert: isOn(include))
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()

            Acceptance.writeEvidence("accent-controls-\(appearance)", ["revision": Acceptance.revision(), "appearance": appearance,
                                                                       "accent": "AccentColor #0064E1 (system accent: Multicolor)", "controls": rows], test: self)
            Acceptance.record(self, "Accent \(appearance): \(rows.map { "\($0["control"] ?? ""): \($0["glyphP75"] ?? $0["fillContrast"] ?? $0["result"] ?? "n/a")" })")
        }
    }

    private func isOn(_ element: XCUIElement) -> Bool {
        element.exists && ("\(element.value ?? "")" == "1" || (element.value as? Bool) == true)
    }

    private func slug(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func capture(_ name: String) {
        let shot = app.windows.firstMatch.screenshot()
        Acceptance.attach(self, png: shot.pngRepresentation, name: "\(name).png")
        if let gray = ContrastMeter.desaturated(shot.image) { Acceptance.attach(self, png: gray, name: "saturation0-\(name).png") }
    }

    /// C06 saturation-0 captures of the show window (Setup and a blocked destination).
    func testSaturationZeroShowWindow() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "3"]
        app.launchEnvironment["WW_SETUP_ENGINE"] = "fixture-states"
        app.launch()
        app.activate()
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        window.typeKey("1", modifierFlags: .command)
        app.typeKey("i", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.5)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        // Episode inspector labels (flagged for contrast in a Setup audit): measure from pixels.
        let inspector = app.descendants(matching: .any).matching(identifier: "ww.inspector").firstMatch
        var labels: [[String: Any]] = []
        for text in ["Episode", "Title", "Number", "Recording date", "Notes"] {
            let label = inspector.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).firstMatch
            guard label.exists else { continue }
            let shot = label.screenshot()
            Acceptance.attach(self, png: shot.pngRepresentation, name: "inspector-label-\(text).png")
            labels.append(["label": text, "frame": "\(label.frame)"].merging(ContrastMeter.measure(shot.image) ?? [:]) { $1 })
        }
        Acceptance.record(self, "Episode inspector labels: \(labels.map { "\($0["label"] ?? ""): \($0["ratio"] ?? "n/a") \($0["text"] ?? "") on \($0["background"] ?? "")" })")
        Acceptance.writeEvidence("contrast-episode-inspector-labels", ["revision": Acceptance.revision(), "labels": labels], test: self)
        _ = try AcceptanceAudit.run(app, surface: "Setup with episode inspector", test: self)
        for (key, name) in [("1", "setup"), ("2", "alignment-blocked")] {
            window.typeKey(key, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            let shot = window.screenshot()
            Acceptance.attach(self, png: shot.pngRepresentation, name: "show-\(name).png")
            if let gray = ContrastMeter.desaturated(shot.image) {
                Acceptance.attach(self, png: gray, name: "saturation0-show-\(name).png")
            }
        }
    }
}

/// WCAG 2 contrast from rendered pixels: background = the most common colour. Reports the highest-contrast
/// pixel ("ratio", an upper bound) and glyph statistics over pixels ≥ 1.5:1 against the background
/// (count, median, 75th percentile), which separate legible text from blurred or clipped text.
enum ContrastMeter {
    static func measure(_ image: NSImage) -> [String: Any]? {
        guard let pixels = rgba(image) else { return nil }
        var histogram: [UInt32: Int] = [:]
        for pixel in pixels { histogram[pixel.key, default: 0] += 1 }
        guard let background = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = Pixel(key: background)
        let bgLum = bg.luminance
        var best = (ratio: 1.0, pixel: bg)
        var glyph: [Double] = []
        for pixel in pixels {
            let ratio = contrast(pixel.luminance, bgLum)
            if ratio > best.ratio { best = (ratio, pixel) }
            if ratio >= 1.5 { glyph.append(ratio) }
        }
        glyph.sort()
        func percentile(_ p: Double) -> Double {
            glyph.isEmpty ? 0 : (glyph[min(glyph.count - 1, Int(Double(glyph.count) * p))] * 100).rounded() / 100
        }
        // "ratio" is the single highest-contrast pixel (an upper bound); the glyph statistics are what waivers
        // use: a blurred or clipped label has very few glyph pixels.
        return [
            "ratio": (best.ratio * 100).rounded() / 100,
            "background": bg.hex, "text": best.pixel.hex, "pixels": pixels.count,
            "glyphPixels": glyph.count, "glyphP50": percentile(0.5), "glyphP75": percentile(0.75),
        ]
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    struct Pixel {
        var r: UInt8, g: UInt8, b: UInt8
        init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
        init(key: UInt32) { r = UInt8(key >> 16 & 0xFF); g = UInt8(key >> 8 & 0xFF); b = UInt8(key & 0xFF) }
        var key: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
        var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
        var luminance: Double {
            func channel(_ v: UInt8) -> Double {
                let c = Double(v) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
    }

    /// Pixels converted to sRGB (alpha composited onto the captured background, which is opaque).
    static func rgba(_ image: NSImage) -> [Pixel]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: data.count, by: 4).map { Pixel(r: data[$0], g: data[$0 + 1], b: data[$0 + 2]) }
    }

    /// Non-text contrast of an accent fill: crops the window screenshot to `element` expanded by 4 pt,
    /// takes the crop perimeter's most common colour as the surroundings and the most common saturated blue as the fill.
    static func accentFill(_ image: NSImage, windowFrame: CGRect, element: CGRect) -> [String: Any]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), windowFrame.width > 0 else { return nil }
        let scale = CGFloat(cg.width) / windowFrame.width
        let rect = CGRect(x: (element.minX - windowFrame.minX - 4) * scale, y: (element.minY - windowFrame.minY - 4) * scale,
                          width: (element.width + 8) * scale, height: (element.height + 8) * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }
        let crop = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        guard let pixels = rgba(crop) else { return nil }
        // Surroundings = most common colour on the crop's 2-pixel perimeter (a small control's fill can be the
        // majority colour of the crop itself).
        let w = Int(rect.width), h = Int(rect.height)
        var edge: [UInt32: Int] = [:], blue: [UInt32: Int] = [:]
        for (i, p) in pixels.enumerated() {
            let x = i % w, y = i / w
            if x < 2 || y < 2 || x >= w - 2 || y >= h - 2 { edge[p.key, default: 0] += 1 }
            if Int(p.b) - Int(p.r) >= 80, Int(p.b) - Int(p.g) >= 40 { blue[p.key, default: 0] += 1 }
        }
        guard let bgKey = edge.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = Pixel(key: bgKey)
        var result: [String: Any] = ["background": bg.hex, "crop": NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) as Any]
        if let fillKey = blue.max(by: { $0.value < $1.value })?.key, fillKey != bgKey {
            let fill = Pixel(key: fillKey)
            result["fill"] = fill.hex
            result["fillPixels"] = blue.values.reduce(0, +)
            result["fillContrast"] = (contrast(fill.luminance, bg.luminance) * 100).rounded() / 100
        }
        return result
    }

    static func desaturated(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        let rep = NSBitmapImageRep(ciImage: output)
        return rep.representation(using: .png, properties: [:])
    }
}
