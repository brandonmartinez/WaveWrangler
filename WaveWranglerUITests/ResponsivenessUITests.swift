import XCTest

/// WW-007 responsiveness on the native app (M1-SCALE-001 native variant, grant A): launch to library ready,
/// opening shows from the 100-show / 1,000-reference synthetic library (`-WWUITestLibraryFixture
/// lib100files`), and the defined interactions (library sidebar selection, collection edit, episode switch,
/// metadata edit). Timings come from the app's own instrumentation (`Responsiveness`, event timestamp →
/// end of the committing run-loop pass), extracted from the unified log; harness wall-clock times are
/// recorded alongside as upper bounds (they include XCUITest's event synthesis and AX polling).
///
/// Samples per stratum: `TEST_RUNNER_WW_SCALE_SAMPLES` (default 5 = calibration; 100 = frozen holdout:
/// 100 first-open + 100 warm + 4 × 100 interactions). Claimed host only; not the macOS 26 / 16 GB reference.
@MainActor
final class ResponsivenessUITests: XCTestCase {
    private var app: XCUIApplication!
    private let samples = Acceptance.count("WW_SCALE_SAMPLES", default: 5)

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", fixture,
        ] + Acceptance.timingArguments
        app.launch()
        app.activate()
    }

    private var entries: XCUIElement { app.outlines["ww.library.entries"] }
    private var showWindows: XCUIElementQuery { app.windows.matching(identifier: "ww.show.window") }

    private func waitForLibrary() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == 'Shows (100)'"), object: entries)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 30), .completed, "library ready")
    }

    /// Focuses the entry table by click, type-selects `row` (0-based), then presses Return.
    /// Full Keyboard Access is a host setting, so Tab cannot reliably move from the sidebar to the outline.
    /// Returns the harness wall-clock time from Return to the show window existing, or nil if the row
    /// is one of the three unavailable fixture entries (it doesn't open).
    private func openRow(_ row: Int) -> Double? {
        let title = String(format: "Synthetic Show %03d", row + 1)
        entries.click()
        entries.typeText(title)
        let selected = entries.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", title, title)
        ).firstMatch
        guard selected.waitForExistence(timeout: 5) else { return nil }
        return pressReturnAndWaitForShow()
    }

    /// Opens `row`, or the next rows if it is unavailable (it then doesn't open).
    private func openFirstAvailable(from row: Int) -> Double? {
        if let ms = openRow(row) { return ms }
        for _ in 0..<5 {
            app.typeKey(.downArrow, modifierFlags: [])
            if let ms = pressReturnAndWaitForShow() { return ms }
        }
        return nil
    }

    private func pressReturnAndWaitForShow() -> Double? {
        let before = showWindows.count
        let start = Date()
        app.typeKey(.return, modifierFlags: [])
        let opened = Acceptance.waitFor(timeout: 10) { self.showWindows.count > before }
        return opened ? Date().timeIntervalSince(start) * 1000 : nil
    }

    // MARK: - Launch and first open (cold process)

    /// Each sample is a fresh app process: launch → library ready → open one show (the first show opened in
    /// the process). Rows rotate through the 97 available shows (rows 4–100; rows 1–3 are the unavailable
    /// fixture entries). A warm-up launch first generates the fixture files (excluded from the phase).
    func testColdLaunchAndFirstOpen() throws {
        launch("lib100files")
        waitForLibrary()
        app.terminate()
        var harness: [Double] = []
        Acceptance.phase("cold-first-open") {
            for index in 0..<samples {
                launch("lib100files")
                waitForLibrary()
                guard let ms = openFirstAvailable(from: 3 + index % 97) else {
                    XCTFail("cold sample \(index) did not open a show")
                    break
                }
                harness.append(ms)
                app.terminate()
            }
        }
        Acceptance.writeEvidence("scale001-native-first-open-harness", [
            "revision": Acceptance.revision(), "harnessReturnToWindowMs": harness, "summary": Acceptance.summary(harness),
        ], test: self)
        XCTAssertEqual(harness.count, samples, "first-open samples")
    }

    // MARK: - Warm open (same process)

    /// One process: open a show, then close it (⌘W) and reopen it from the library with Return, `samples`
    /// times. The first open (openIndex 1) is excluded; every reopen is warm.
    func testWarmReopen() throws {
        launch("lib100files")
        waitForLibrary()
        XCTAssertNotNil(openFirstAvailable(from: 3), "opened an available show")
        var harness: [Double] = []
        Acceptance.phase("warm-reopen") {
            for index in 0..<samples {
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(Acceptance.waitFor(timeout: 5) { self.showWindows.count == 0 }, "closed (\(index))")
                guard let ms = pressReturnAndWaitForShow() else {
                    XCTFail("warm reopen \(index) did not open a show window")
                    break
                }
                harness.append(ms)
            }
        }
        Acceptance.writeEvidence("scale001-native-warm-open-harness", [
            "revision": Acceptance.revision(), "harnessReturnToWindowMs": harness, "summary": Acceptance.summary(harness),
        ], test: self)
        XCTAssertEqual(harness.count, samples, "warm samples")
    }

    // MARK: - Interactions

    /// Library sidebar selection, collection reorder (an undoable library edit), episode switch and
    /// episode-title edit: `samples` each, keyboard only. Each kind is its own phase.
    func testInteractions() throws {
        launch("lib100files")
        waitForLibrary()

        // Sidebar: Shows, Recent, Unavailable, Synthetic Collection 1…5 (8 rows); walk down and up.
        var position = 0
        Acceptance.phase("interaction-library-sidebar") {
            for index in 0..<samples {
                let down = (index / 7) % 2 == 0
                app.typeKey(down ? .downArrow : .upArrow, modifierFlags: [])
                position += down ? 1 : -1
            }
        }
        // Collection edit: select Synthetic Collection 3 (row 5) and move it down/up (⌥⌘↓ / ⌥⌘↑).
        let target = 5 - position
        for _ in 0..<abs(target) { app.typeKey(target > 0 ? .downArrow : .upArrow, modifierFlags: []) }
        let collection = app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Synthetic Collection 3, collection'")).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        Acceptance.phase("interaction-collection-edit") {
            for index in 0..<samples {
                app.typeKey(index % 2 == 0 ? .downArrow : .upArrow, modifierFlags: [.command, .option])
            }
        }

        // Back to Shows (top), open an available show.
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        XCTAssertNotNil(openFirstAvailable(from: 3), "opened an available show")
        let window = showWindows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let episodes = app.descendants(matching: .any).matching(identifier: "ww.show.sidebar.episodes").firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)

        // Episode switch: the episode list has focus when the window opens; walk 5 episodes down and up.
        Acceptance.phase("interaction-episode-switch") {
            for index in 0..<samples {
                app.typeKey((index / 4) % 2 == 0 ? .downArrow : .upArrow, modifierFlags: [])
            }
        }

        // Metadata edit: ⌘I focuses Title; each typed character (then each deletion) is a live, undoable edit.
        window.typeKey("i", modifierFlags: .command)
        let title = app.descendants(matching: .any).matching(identifier: "ww.inspector.episode.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: .command)
        let half = samples / 2
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        Acceptance.phase("interaction-metadata-edit") {
            for index in 0..<half { app.typeKey(String(letters[index % letters.count]), modifierFlags: []) }
            for _ in 0..<(samples - half) { app.typeKey(.delete, modifierFlags: []) }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Main-thread file activity (Instruments File Activity, attached from outside)

    /// Prints `[trace] attach-now`, waits for an external `xctrace record --template 'File Activity' --attach
    /// WaveWrangler` (started by the harness script; the sandboxed runner can't run xctrace), then performs a
    /// show open, episode switches, edits, sidebar selections and a close inside the `file-activity` phase.
    func testMainThreadFileActivityTrace() throws {
        launch("lib100files")
        waitForLibrary()
        print("[trace] attach-now \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 10)
        Acceptance.phase("file-activity") {
            for index in 0..<20 { app.typeKey((index / 7) % 2 == 0 ? .downArrow : .upArrow, modifierFlags: []) }
            for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
            XCTAssertNotNil(openFirstAvailable(from: 3), "opened an available show")
            for index in 0..<16 { app.typeKey((index / 4) % 2 == 0 ? .downArrow : .upArrow, modifierFlags: []) }
            app.typeKey("i", modifierFlags: .command)
            for letter in ["a", "b", "c", "d", "e"] { app.typeKey(letter, modifierFlags: []) }
            for _ in 0..<5 { app.typeKey(.delete, modifierFlags: []) }
            app.typeKey("w", modifierFlags: .command)
        }
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: - XCTest launch metric (corroboration)

    /// XCTApplicationLaunchMetric (launch until responsive) on the F-LIB100 in-memory fixture.
    func testLaunchMetric() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = min(samples, 10)
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestLibraryFixture", "lib100"]
            app.launch()
        }
    }
}
