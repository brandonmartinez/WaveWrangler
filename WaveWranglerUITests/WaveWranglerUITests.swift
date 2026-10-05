import XCTest

/// Core keyboard tasks for the library window, show workspace, menus and settings (Design acceptance
/// T01–T06, T14, T22–T25 subsets, K02–K06, K13, K21, K23, K24) plus accessibility audits on each surface.
///
/// These tests launch the app (GUI). Run them only with GUI permission under the coordinator's GUI lock:
/// `scripts/test.sh --ui`. Fixtures are synthetic: an in-memory library (`-WWUITestLibraryFixture`) and a
/// generated show in the app container's temporary directory (`-WWUITestOpenShow`). No user files.
@MainActor
final class WaveWranglerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestResetPreferences", "YES"] + arguments
        app.launch()
        app.activate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func menuItem(_ title: String) -> XCUIElement {
        app.menuBars.menuItems[title].firstMatch
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Audit types available on macOS (acceptance §4.2). Issues on system-drawn controls that we can't
    /// change are waived with a rationale; everything else fails the test.
    private func audit(_ surface: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var findings: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]) { issue in
            let description = "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(240) ?? "no element")"
            if let rationale = Self.waiver(for: issue) {
                print("AUDIT WAIVED \(description) — \(rationale)")
                return true
            }
            findings.append(description)
            return true
        }
        for finding in findings {
            XCTFail("AUDIT \(finding)", file: file, line: line)
        }
        print("AUDIT \(surface): \(findings.isEmpty ? "no unwaived issues" : "\(findings.count) unwaived issue(s)")")
    }

    private static func waiver(for issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else { return nil }
        // Window chrome (traffic lights, toolbar overflow, split-view dividers) is drawn by AppKit.
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem].contains(element.elementType) {
            return "system window chrome"
        }
        return nil
    }

    // MARK: - Library window (T04, T05, T22; K05, K06, K21, K25)

    func testLibraryWindowAtScaleWithUnavailableEntries() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        let sidebar = element("ww.library.sidebar")
        waitFor(sidebar)
        XCTAssertEqual(app.windows.firstMatch.title, "Library")

        let shows = element("ww.library.sidebar.shows")
        waitFor(shows)
        XCTAssertEqual(value(shows), "100 shows")
        let unavailable = element("ww.library.sidebar.unavailable")
        XCTAssertEqual(value(unavailable), "3 items need attention")
        XCTAssertEqual(value(element("ww.library.sidebar.recent")), "10 items")

        // Keyboard: arrow from Shows → Recent → Unavailable; the entry list follows the selection.
        sidebar.typeKey(.downArrow, modifierFlags: [])
        sidebar.typeKey(.downArrow, modifierFlags: [])
        let entries = element("ww.library.entries")
        waitFor(entries)
        let unavailableTable = app.tables["ww.library.entries"]
        XCTAssertTrue(unavailableTable.waitForExistence(timeout: 5))
        XCTAssertEqual(unavailableTable.tableRows.count, 3, "Unavailable is a filter showing exactly the 3 unavailable entries")
        for status in ["Can't find show file", "Needs permission", "Needs newer WaveWrangler"] {
            XCTAssertTrue(unavailableTable.staticTexts[status].exists || unavailableTable.descendants(matching: .any)
                .matching(NSPredicate(format: "value == %@", status)).firstMatch.exists, "Status text \(status)")
        }
        try audit("Library window (F-LIB100, Unavailable)")
    }

    func testCollectionsCreateAddReorderDeleteWithKeyboardAndMenus() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        waitFor(element("ww.library.sidebar"))
        let before = app.outlines["ww.library.sidebar"].outlineRows.count

        // K05: File › Library › New Collection… → type → Return.
        menuItem("New Collection…").click()
        let nameField = element("ww.dialog.name")
        waitFor(nameField)
        nameField.typeText("Season Two\r")
        let created = app.outlines["ww.library.sidebar"].outlineRows.containing(NSPredicate(format: "label == %@", "Season Two, collection")).firstMatch
        waitFor(created)
        XCTAssertEqual(app.outlines["ww.library.sidebar"].outlineRows.count, before + 1)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(menuItem("Undo New Collection").exists, "Named undo")
        app.typeKey(.escape, modifierFlags: [])

        // New collection is selected and empty; Move Up (⌥⌘↑) moves it above the last fixture collection.
        XCTAssertEqual(value(created), "0 items")
        created.typeKey(.upArrow, modifierFlags: [.command, .option])
        let rows = app.outlines["ww.library.sidebar"].outlineRows.allElementsBoundByIndex.map(\.label)
        let moved = rows.firstIndex(of: "Season Two, collection")
        let last = rows.firstIndex(of: "Synthetic Collection 5, collection")
        XCTAssertNotNil(moved)
        XCTAssertNotNil(last)
        if let moved, let last { XCTAssertLessThan(moved, last, "Move Collection Up reorders without drag") }

        // Add a show via File › Library › Add to Collection ▸ (non-drag path).
        element("ww.library.sidebar.shows").click()
        let table = app.tables["ww.library.entries"]
        waitFor(table)
        table.tableRows.firstMatch.click()
        menuItem("Add to Collection").hover()
        let target = app.menuBars.menuItems["Season Two"].firstMatch
        waitFor(target)
        target.click()
        XCTAssertEqual(value(created), "1 item")

        // ⌫ on the collection → confirm → collection removed, shows kept.
        created.click()
        created.typeKey(.delete, modifierFlags: [])
        let sheet = app.sheets.firstMatch
        waitFor(sheet)
        XCTAssertTrue(sheet.staticTexts["Delete the collection “Season Two”?"].exists)
        sheet.buttons["Delete"].click()
        XCTAssertFalse(created.waitForExistence(timeout: 2))
        XCTAssertEqual(value(element("ww.library.sidebar.shows")), "100 shows", "Deleting a collection never deletes shows")
    }

    // MARK: - Show window (T01–T03, T06, T24; K02, K03, K24)

    func testShowWindowEpisodesMetadataDestinationsAndHonestSaveStatus() throws {
        launch(["-WWUITestLibraryFixture", "empty", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "0"])
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        waitFor(window, timeout: 15)
        XCTAssertTrue(window.title.hasPrefix("Synthetic Show"))
        let episodes = element("ww.show.sidebar.episodes")
        waitFor(episodes)
        XCTAssertEqual(value(episodes), "0 episodes")
        waitFor(element("ww.show.empty.newEpisode"))

        // Honest status: the fallback never claims "Saved".
        let status = element("ww.show.saveStatus")
        waitFor(status)
        XCTAssertFalse(value(status).hasPrefix("Saved"), "Save status must not say Saved without coherent publication: \(value(status))")

        // K02: ⇧⌘N → inline rename → type → Return.
        window.typeKey("n", modifierFlags: [.command, .shift])
        let rename = element("ww.show.sidebar.rename")
        waitFor(rename)
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Pilot\r")
        XCTAssertEqual(value(episodes), "1 episode")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "1 Pilot")).firstMatch)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(menuItem("Undo Rename Episode").exists, "Named undo for rename")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.title.contains("Edited") || value(status).hasPrefix("Edited") || value(status).hasPrefix("Not saved"),
                      "Edits are shown as unsaved: title \(window.title), status \(value(status))")

        // K03: ⌘I focuses Title; invalid Number shows inline text error.
        window.typeKey("i", modifierFlags: .command)
        let title = element("ww.inspector.episode.title")
        waitFor(title)
        let number = element("ww.inspector.episode.number")
        number.click()
        number.typeKey("a", modifierFlags: .command)
        number.typeText("abc")
        waitFor(app.staticTexts["Enter a whole number"])
        number.typeKey("a", modifierFlags: .command)
        number.typeText("12\t")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "12 Pilot")).firstMatch)

        // K24: ⌘2 shows the blocked Alignment panel; Go to Setup returns.
        window.typeKey("2", modifierFlags: .command)
        let blocked = element("ww.show.blocked.alignment")
        waitFor(blocked)
        XCTAssertTrue(app.staticTexts["Alignment isn't available yet"].exists)
        XCTAssertEqual(value(element("ww.show.destination.alignment")), "Not available in this version")
        try audit("Show window (blocked Alignment)")
        element("ww.show.blocked.goToSetup").click()
        waitFor(element("ww.setup.sources"))
        waitFor(element("ww.setup.speakers"))
        try audit("Show window (Setup)")

        // T24: second window on the same show shares the document.
        menuItem("New Window for “Synthetic Show”").click()
        let windows = app.windows.matching(identifier: "ww.show.window")
        XCTAssertTrue(windows.element(boundBy: 1).waitForExistence(timeout: 5))
    }

    // MARK: - Settings (T14, T19 wording, A-07, K13, K14, K23, T25 default)

    func testSettingsDefaultsTogglesAndTextSize() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        waitFor(element("ww.library.sidebar"))
        app.typeKey(",", modifierFlags: .command)
        let autosave = element("ww.settings.autosave")
        waitFor(autosave)
        XCTAssertEqual(value(autosave), "1", "Autosave ON by default")
        XCTAssertEqual(value(element("ww.settings.libraryLocation")), "In WaveWrangler")
        XCTAssertTrue(app.staticTexts["WaveWrangler saves your changes as you work. You can also choose File › Save at any time."].exists)
        try audit("Settings › General")
        autosave.click()
        XCTAssertEqual(value(autosave), "0")
        waitFor(app.staticTexts["Changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing a show with unsaved changes."])
        autosave.click()

        app.toolbars.buttons["Sources"].click()
        let downloads = element("ww.settings.downloadSources")
        waitFor(downloads)
        XCTAssertEqual(value(downloads), "1", "Source downloads ON by default")
        try audit("Settings › Sources")

        // K23: ⌘+ up to 200%, ⌘0 resets.
        app.windows["Sources"].typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["General"].click()
        let textSize = element("ww.settings.textSize")
        waitFor(textSize)
        XCTAssertEqual(value(textSize), "200%")
        app.typeKey("w", modifierFlags: .command)
        try audit("Library window at 200% text")
        app.typeKey("0", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        waitFor(element("ww.settings.textSize"))
        XCTAssertEqual(value(element("ww.settings.textSize")), "100%")
    }
}
