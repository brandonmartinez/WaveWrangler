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
            let targets: [(String, XCUIElement)] = [
                ("sidebar unselected row 'Recent'", app.descendants(matching: .any)["ww.library.sidebar.recent"]),
                ("sidebar unselected row 'Unavailable'", app.descendants(matching: .any)["ww.library.sidebar.unavailable"]),
                ("entry table name cell (row 1)", entries.outlineRows.element(boundBy: 0).cells.element(boundBy: 0)),
                ("entry table episodes cell (row 1)", entries.outlineRows.element(boundBy: 0).cells.element(boundBy: 1)),
                ("entry table last-opened cell (row 2)", entries.outlineRows.element(boundBy: 1).cells.element(boundBy: 3)),
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

/// WCAG 2 contrast ratio from rendered pixels: background = the most common colour; text = the pixel with
/// the highest contrast against it (the fully covered core of a glyph stem at 2× scale).
enum ContrastMeter {
    static func measure(_ image: NSImage) -> [String: Any]? {
        guard let pixels = rgba(image) else { return nil }
        var histogram: [UInt32: Int] = [:]
        for pixel in pixels { histogram[pixel.key, default: 0] += 1 }
        guard let background = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = Pixel(key: background)
        let bgLum = bg.luminance
        var best = (ratio: 1.0, pixel: bg)
        for pixel in pixels {
            let ratio = contrast(pixel.luminance, bgLum)
            if ratio > best.ratio { best = (ratio, pixel) }
        }
        return [
            "ratio": (best.ratio * 100).rounded() / 100,
            "background": bg.hex, "text": best.pixel.hex,
            "meetsAA4.5": best.ratio >= 4.5, "pixels": pixels.count,
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
