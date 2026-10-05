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

    /// Keyboard: Tab from the sidebar into the entry table, ↓ to `row` (0-based), Return opens it.
    /// Returns the harness wall-clock time from Return to the show window existing, or nil if the row
    /// is one of the three unavailable fixture entries (it doesn't open).
    private func openRow(_ row: Int) -> Double? {
        app.typeKey("\t", modifierFlags: [])
        for _ in 0...row { app.typeKey(.downArrow, modifierFlags: []) }
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

    private func gate(_ label: String, _ values: [Double], below limit: Double) -> [String: Any] {
        var summary = Acceptance.summary(values)
        summary["gateMs"] = limit
        summary["gatePassed"] = (Acceptance.p95(values) ?? .infinity) < limit
        Acceptance.record(self, "\(label): \(summary)")
        return summary
    }

    // MARK: - Launch and first open (cold process)

    /// Each sample is a fresh app process: launch → library ready → open one show (first show opened in
    /// the process). Rows rotate through the 97 available shows.
    func testColdLaunchAndFirstOpen() throws {
        let start = Date()
        var harness: [Double] = []
        var opened = 0
        var row = 0
        var attempts = 0
        while opened < samples, attempts < samples + 10 {
            attempts += 1
            launch("lib100files")
            waitForLibrary()
            if let ms = openFirstAvailable(from: row % 100) {
                harness.append(ms)
                opened += 1
            }
            row += 1
            app.terminate()
        }
        let timings = Acceptance.appTimings(since: start)
        let launches = timings.filter { $0.name == "launch.libraryReady" }.map(\.eventMs)
        let firstOpens = timings.filter { $0.name == "show.open" && $0.detail["openIndex"] == "1" }.map(\.eventMs)
        let result: [String: Any] = [
            "revision": Acceptance.revision(),
            "fixture": "F-LIB100 lib100files (100 shows, 97 file-backed, 1,000 refs, 5 collections, 3 unavailable)",
            "launchToLibraryReady": gate("cold launch → library ready (in-app, process start → commit)", launches, below: 1000),
            "firstOpenCold": gate("first open in a fresh process (in-app, Return → show window commit)", firstOpens, below: 1000),
            "firstOpenHarnessUpperBound": Acceptance.summary(harness),
            "raw": Acceptance.json(timings.filter { $0.name == "launch.libraryReady" || $0.name == "show.open" }),
        ]
        Acceptance.writeEvidence("scale001-native-first-open.json", result)
        XCTAssertGreaterThanOrEqual(firstOpens.count, samples, "first-open samples")
        XCTAssertLessThan(Acceptance.p95(firstOpens) ?? .infinity, 1000, "WW-007 provisional p95 open < 1 s")
        XCTAssertLessThan(Acceptance.p95(launches) ?? .infinity, 1000, "launch to library ready p95 < 1 s")
    }

    // MARK: - Warm open (same process)

    /// One process: open a show, close it (⌘W), reopen it from the library with Return. The first open is
    /// excluded; every later open is warm.
    func testWarmReopen() throws {
        let start = Date()
        launch("lib100files")
        waitForLibrary()
        var harness: [Double] = []
        XCTAssertNotNil(openFirstAvailable(from: 3), "opened an available show")
        XCTAssertEqual(showWindows.count, 1, "first show opened")
        for index in 0..<samples {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(Acceptance.waitFor(timeout: 5) { self.showWindows.count == 0 }, "closed (\(index))")
            guard let ms = pressReturnAndWaitForShow() else {
                XCTFail("warm reopen \(index) did not open a show window")
                break
            }
            harness.append(ms)
        }
        let timings = Acceptance.appTimings(since: start)
        let warm = timings.filter { $0.name == "show.open" && ($0.detail["openIndex"].flatMap(Int.init) ?? 0) >= 2 }.map(\.eventMs)
        let result: [String: Any] = [
            "revision": Acceptance.revision(),
            "fixture": "F-LIB100 lib100files",
            "warmOpen": gate("warm reopen (in-app, Return → show window commit)", warm, below: 1000),
            "warmOpenHarnessUpperBound": Acceptance.summary(harness),
            "raw": Acceptance.json(timings.filter { $0.name == "show.open" }),
        ]
        Acceptance.writeEvidence("scale001-native-warm-open.json", result)
        XCTAssertGreaterThanOrEqual(warm.count, samples, "warm samples")
        XCTAssertLessThan(Acceptance.p95(warm) ?? .infinity, 1000, "WW-007 provisional p95 open < 1 s")
    }

    // MARK: - Interactions

    /// Library sidebar selection, collection reorder (an undoable library edit), episode switch and
    /// episode-title edit: `samples` each, keyboard only.
    func testInteractions() throws {
        let start = Date()
        launch("lib100files")
        waitForLibrary()

        // Sidebar: Shows, Recent, Unavailable, Synthetic Collection 1…5 (8 rows); walk down and up.
        var position = 0
        for index in 0..<samples {
            let down = (index / 7) % 2 == 0
            app.typeKey(down ? .downArrow : .upArrow, modifierFlags: [])
            position += down ? 1 : -1
        }
        // Collection edit: select Synthetic Collection 3 (row 5) and move it down/up (⌥⌘↓ / ⌥⌘↑).
        let target = 5 - position
        for _ in 0..<abs(target) { app.typeKey(target > 0 ? .downArrow : .upArrow, modifierFlags: []) }
        let collection = app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Synthetic Collection 3, collection'")).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        for index in 0..<samples {
            app.typeKey(index % 2 == 0 ? .downArrow : .upArrow, modifierFlags: [.command, .option])
        }

        // Back to Shows (top), open an available show.
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        XCTAssertNotNil(openFirstAvailable(from: 3), "opened an available show")
        let window = showWindows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let episodes = app.descendants(matching: .any).matching(identifier: "ww.show.sidebar.episodes").firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))

        // Episode switch: the episode list has focus when the window opens; walk 5 episodes down and up.
        for index in 0..<samples {
            app.typeKey((index / 4) % 2 == 0 ? .downArrow : .upArrow, modifierFlags: [])
        }

        // Metadata edit: ⌘I focuses Title; each typed character (then each deletion) is a live, undoable edit.
        window.typeKey("i", modifierFlags: .command)
        let title = app.descendants(matching: .any).matching(identifier: "ww.inspector.episode.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: .command)
        let half = samples / 2
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for index in 0..<half { app.typeKey(String(letters[index % letters.count]), modifierFlags: []) }
        for _ in 0..<(samples - half) { app.typeKey(.delete, modifierFlags: []) }

        Thread.sleep(forTimeInterval: 1)
        let timings = Acceptance.appTimings(since: start)
        func values(_ name: String) -> [Double] { timings.filter { $0.name == name }.map(\.eventMs) }
        let sidebar = values("library.sidebarSelection")
        let collectionEdits = values("library.edit")
        let episodeSwitches = values("show.sidebarSelection")
        let edits = values("show.edit")
        let all = sidebar + collectionEdits + episodeSwitches + edits
        let result: [String: Any] = [
            "revision": Acceptance.revision(),
            "fixture": "F-LIB100 lib100files",
            "librarySidebarSelection": gate("library sidebar selection", sidebar, below: 100),
            "collectionEdit": gate("collection move (library edit)", collectionEdits, below: 100),
            "episodeSwitch": gate("episode switch", episodeSwitches, below: 100),
            "metadataEdit": gate("episode title edit (per keystroke)", edits, below: 100),
            "allInteractions": gate("all interactions", all, below: 100),
            "nonMainThreadReports": timings.filter { $0.thread != "main" }.count,
            "raw": Acceptance.json(timings),
        ]
        Acceptance.writeEvidence("scale001-native-interactions.json", result)
        XCTAssertGreaterThanOrEqual(sidebar.count, samples, "sidebar selection samples")
        XCTAssertGreaterThanOrEqual(collectionEdits.count, samples, "collection edit samples")
        XCTAssertGreaterThanOrEqual(episodeSwitches.count, samples, "episode switch samples")
        XCTAssertGreaterThanOrEqual(edits.count, samples, "metadata edit samples")
        XCTAssertLessThan(Acceptance.p95(all) ?? .infinity, 100, "WW-007 provisional p95 interaction < 100 ms")
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
