import AppKit
import XCTest

/// #138 regression guard: the SELECTED, emphasized sidebar rows (Library "Shows"; show window episode row) draw
/// their text in opaque white on the accent fill (`EmphasizedSelectionForeground`). For each appearance the test
/// gives the sidebar keyboard focus (click on the selected row), checks the row really sits on an emphasized
/// (accent-blue) selection, then measures the row's own screenshot: ≥ `AcceptanceAudit.minimumGlyphPixels` glyph
/// pixels with p75 ≥ 4.5:1. Before the fix, system Increase Contrast measured 2.33:1 (#94B6F8 on #0A6CF0).
///
/// Appearances: `WW_SELECTION_APPEARANCES` (comma-separated), default aqua, darkAqua, highContrastAqua and
/// highContrastDarkAqua (AppKit appearance overrides). `system` passes no override, so the system appearance and
/// the system Increase Contrast setting apply (Mac mini slot for #139). Results: `[evidence-json] selection-contrast`.
@MainActor
final class SelectionContrastUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    func testSelectedSidebarRowsHaveLegibleTextOnTheAccent() throws {
        let appearances = Acceptance.environment["WW_SELECTION_APPEARANCES"].map { $0.split(separator: ",").map(String.init) }
            ?? ["aqua", "darkAqua", "highContrastAqua", "highContrastDarkAqua"]
        var results: [[String: Any]] = []
        for appearance in appearances {
            let overrides = appearance == "system" ? [] : ["-WWUITestAppearance", appearance]
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

            launch(["-WWUITestLibraryFixture", "lib100"] + overrides)
            let shows = app.descendants(matching: .any)["ww.library.sidebar.shows"]
            XCTAssertTrue(shows.waitForExistence(timeout: 15), "\(appearance): Library sidebar")
            results.append(measureSelected(shows, surface: "Library sidebar 'Shows'", appearance: appearance, increaseContrast: increaseContrast))
            // Focus leaves the sidebar: the selection becomes unemphasized (grey); its text must stay legible
            // (guards against white text drawn on a grey selection).
            app.typeKey("\t", modifierFlags: [])
            Thread.sleep(forTimeInterval: 1)
            results.append(measureUnemphasized(shows, surface: "Library sidebar 'Shows' (focus in the entry list)", appearance: appearance,
                                               increaseContrast: increaseContrast))
            app.terminate()

            launch(["-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "2"] + overrides)
            let window = app.windows.matching(identifier: "ww.show.window").firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15), "\(appearance): show window")
            let episode = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.show.sidebar.episode.'")).firstMatch
            XCTAssertTrue(episode.waitForExistence(timeout: 10), "\(appearance): episode row")
            results.append(measureSelected(episode, surface: "Show sidebar episode row", appearance: appearance, increaseContrast: increaseContrast))
            app.terminate()
        }
        Acceptance.writeEvidence("selection-contrast", ["revision": Acceptance.revision(), "results": results], test: self)
    }

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES"] + arguments
        app.launch()
        app.activate()
    }

    /// Clicks the row (selects it and gives the sidebar keyboard focus, so the selection is emphasized), then measures it.
    private func measureSelected(_ row: XCUIElement, surface: String, appearance: String, increaseContrast: Bool) -> [String: Any] {
        row.click()
        Thread.sleep(forTimeInterval: 1)
        let shot = row.screenshot()
        let name = "selection-\(appearance)-\(surface.filter { $0.isLetter || $0.isNumber }).png"
        Acceptance.attach(self, png: shot.pngRepresentation, name: name)
        let m = ContrastMeter.measure(shot.image) ?? [:]
        let background = m["background"] as? String ?? ""
        let count = m["glyphPixels"] as? Int ?? 0, p75 = m["glyphP75"] as? Double ?? 0
        let label = "\(appearance) (system Increase Contrast \(increaseContrast)) \(surface)"
        XCTAssertTrue(Acceptance.isAccentBlue(background), "\(label): row is on an emphasized accent selection (background \(background))")
        XCTAssertGreaterThanOrEqual(count, AcceptanceAudit.minimumGlyphPixels, "\(label): glyph pixels \(count)")
        XCTAssertGreaterThanOrEqual(p75, 4.5, "\(label): text p75 \(p75) (\(m["text"] ?? "") on \(background))")
        Acceptance.record(self, "#138 \(label): \(count) px, p75 \(p75), \(m["text"] ?? "") on \(background)")
        return ["appearance": appearance, "systemIncreaseContrast": increaseContrast, "surface": surface, "crop": name,
                "frame": "\(row.frame)"].merging(m) { $1 }
    }

    /// Measures a selected row whose list no longer has keyboard focus: text ≥ 4.5:1 on whatever selection is drawn.
    private func measureUnemphasized(_ row: XCUIElement, surface: String, appearance: String, increaseContrast: Bool) -> [String: Any] {
        let shot = row.screenshot()
        let name = "selection-\(appearance)-\(surface.filter { $0.isLetter || $0.isNumber }).png"
        Acceptance.attach(self, png: shot.pngRepresentation, name: name)
        let m = ContrastMeter.measure(shot.image) ?? [:]
        let count = m["glyphPixels"] as? Int ?? 0, p75 = m["glyphP75"] as? Double ?? 0
        let label = "\(appearance) (system Increase Contrast \(increaseContrast)) \(surface)"
        XCTAssertGreaterThanOrEqual(count, AcceptanceAudit.minimumGlyphPixels, "\(label): glyph pixels \(count)")
        XCTAssertGreaterThanOrEqual(p75, 4.5, "\(label): text p75 \(p75) (\(m["text"] ?? "") on \(m["background"] ?? ""))")
        Acceptance.record(self, "#139 \(label): \(count) px, p75 \(p75), \(m["text"] ?? "") on \(m["background"] ?? "")")
        return ["appearance": appearance, "systemIncreaseContrast": increaseContrast, "surface": surface, "crop": name,
                "frame": "\(row.frame)"].merging(m) { $1 }
    }

}
