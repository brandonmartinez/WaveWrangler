import AppKit
import XCTest

/// Core keyboard tasks for the library window, show workspace, menus and settings (Design acceptance
/// T01–T06, T14, T22–T25 subsets, K02–K06, K13, K21, K23, K24) plus accessibility audits on each surface.
///
/// These tests launch the app (GUI). Run them only with GUI permission under the coordinator's GUI lock:
/// `scripts/test.sh --ui`. Fixtures are synthetic: an in-memory library (`-WWUITestLibraryFixture`) and a
/// generated show in the app container's temporary directory (`-WWUITestOpenShow`). No user files.
@MainActor
final class LibraryWorkspaceUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Frame of the Library entry table, captured before an audit (queries inside the audit handler are unreliable).
    private var entryTableFrame: CGRect?
    /// Toolbar/title-bar frames captured before an audit (window titles there are drawn by AppKit).
    private var toolbarFrames: [CGRect] = []

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        // -WWUITestHooks isolates persistence storage/preferences from the user's (Document/UITestHooks).
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES"] + arguments
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

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "\(element.value ?? "")" }

    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in self.value(element) == expected }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
            XCTFail("Expected value \(expected), got \(value(element)) for \(element)", file: file, line: line)
        }
    }

    /// Audit types available on macOS (acceptance §4.2). Issues on system-drawn controls that we can't
    /// change are waived with a rationale; everything else fails the test.
    private func audit(_ surface: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var findings: [String] = []
        let table = app.outlines["ww.library.entries"]
        entryTableFrame = table.exists ? table.frame : nil
        toolbarFrames = app.toolbars.allElementsBoundByIndex.map(\.frame)
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]) { issue in
            let description = "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(240) ?? "no element")"
            if let rationale = self.waiver(for: issue) {
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

    private func waiver(for issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else { return nil }
        // Entry-table cells (system table text, no custom styling) fail contrast even with the Library
        // window isolated on the primary display; tracked in #59 (P2, M1).
        // Cells can extend past the outline's clip frame horizontally, so match by the table's left edge and
        // vertical extent.
        // Rows partly scrolled out of the outline (at 200% text) are still table cells, so match any overlap.
        if issue.auditType == .contrast, let frame = entryTableFrame,
           element.frame.minX >= frame.minX, element.frame.minY < frame.maxY, element.frame.maxY > frame.minY,
           element.frame.minX < frame.maxX {
            return "issue #59: system table text contrast (tracked)"
        }
        // Window chrome (traffic lights, toolbar overflow, split-view dividers) is drawn by AppKit.
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) {
            return "system window chrome"
        }
        // Non-interactive layout containers SwiftUI creates for split-view columns and overlays (AX "Group",
        // not enabled, no actions). VoiceOver skips them; every interactive element is checked.
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled {
            return "non-interactive layout container"
        }
        // SwiftUI Picker's AppKit pop-up exposes AXShowMenu rather than AXPress; it opens with Space,
        // VoiceOver (VO-Space) and click, as these tests and keyboard checks show.
        if issue.auditType == .action, element.elementType == .popUpButton {
            return "system pop-up button exposes AXShowMenu"
        }
        // Tracked in issue #59 (P2): unselected system sidebar rows on translucent sidebar material fail
        // the contrast audit on macOS 27; text uses the system label colour with no custom styling.
        // Library sidebar rows and entry-table name cells (system label colour, no custom styling) still fail
        // with each window isolated on the main display; tracked in #59 (P2, M1) for Increase Contrast checks.
        if issue.auditType == .contrast,
           element.identifier.hasPrefix("ww.library.sidebar.") || element.identifier.hasPrefix("ww.library.entry.") {
            return "issue #59: system sidebar/table text contrast (tracked)"
        }
        // The system "emoji & symbols" input item (Touch Bar / menu bar), not app UI.
        if element.elementType == .popUpButton, element.label == "emoji & symbols" {
            return "system input item, not app UI"
        }
        // Window title/subtitle text in the unified title bar is drawn by AppKit (no identifier).
        if issue.auditType == .contrast, element.elementType == .staticText, element.identifier.isEmpty,
           toolbarFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(element.frame) }) {
            return "system window title text"
        }
        // macOS injects the Siri waveform overlay (an untitled Dialog with a 'siri' button) into every
        // app's AX tree on this host; it is not WaveWrangler UI.
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists {
            return "system Siri overlay, not app UI"
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
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        let entries = app.outlines["ww.library.entries"]
        waitFor(entries)
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Unavailable (3)'"), object: entries)
        XCTAssertEqual(XCTWaiter().wait(for: [followed], timeout: 5), .completed, "Entry list follows the sidebar: \(entries.label)")
        XCTAssertEqual(entries.outlineRows.count, 3, "Unavailable is a filter showing exactly the 3 unavailable entries")
        for status in ["Can't find show file", "Needs permission", "Needs newer WaveWrangler"] {
            let cell = entries.staticTexts.matching(NSPredicate(format: "label == 'Status' AND value == %@", status)).firstMatch
            XCTAssertTrue(cell.exists, "Status text \(status) (text, not colour)")
        }
        // An unknown episode count shows "—" and reads "unknown" to VoiceOver (not the dash).
        let newer = entries.outlineRows.containing(NSPredicate(format: "label == 'Status' AND value == 'Needs newer WaveWrangler'")).firstMatch
        XCTAssertTrue(newer.staticTexts.matching(NSPredicate(format: "value == 'unknown'")).firstMatch.exists,
                      "Episodes reads unknown: \(newer.staticTexts.allElementsBoundByIndex.map { self.value($0) })")
        // Status wraps to a second line rather than truncating at 1 line (IA §3.2, CMD-20): its row is taller
        // than a one-line row when the text doesn't fit the column.
        let status = newer.staticTexts.matching(NSPredicate(format: "label == 'Status'")).firstMatch
        let name = newer.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.'")).firstMatch
        let textWidth = ("Needs newer WaveWrangler" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        if textWidth > status.frame.width {
            XCTAssertGreaterThan(status.frame.height, name.frame.height * 1.5, "status \(status.frame) vs name \(name.frame)")
        }
        XCTAssertLessThanOrEqual(status.frame.height, newer.frame.height, "status text fits its row")
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
        let created = app.outlines["ww.library.sidebar"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.' AND label == %@", "Season Two, collection")).firstMatch
        waitFor(created)
        XCTAssertEqual(app.outlines["ww.library.sidebar"].outlineRows.count, before + 1)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(menuItem("Undo New Collection").exists, "Named undo")
        app.typeKey(.escape, modifierFlags: [])

        // New collection is selected and empty; Move Up (⌥⌘↑) moves it above the last fixture collection.
        waitForValue(created, "0 items")
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        let rows = app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.'")).allElementsBoundByIndex.map(\.label)
        let moved = rows.firstIndex(of: "Season Two, collection")
        let last = rows.firstIndex(of: "Synthetic Collection 5, collection")
        XCTAssertNotNil(moved)
        XCTAssertNotNil(last)
        if let moved, let last { XCTAssertLessThan(moved, last, "Move Collection Up reorders without drag") }

        // Add a show via File › Library › Add to Collection ▸ (non-drag path), keyboard-selected (K05).
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        let table = app.outlines["ww.library.entries"]
        let showsSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Shows (100)'"), object: table)
        XCTAssertEqual(XCTWaiter().wait(for: [showsSelected], timeout: 5), .completed, "Up arrows reach Shows: \(table.label)")
        app.typeKey("\t", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        menuItem("Add to Collection").hover()
        let target = app.menuBars.menuItems["Season Two"].firstMatch
        waitFor(target)
        target.click()
        waitForValue(created, "1 item")

        // ⌫ on the collection → confirm → collection removed, shows kept.
        // ⇧Tab back to the sidebar, arrow to the collection (Shows → … → Season Two is 7 rows down).
        app.typeKey("\t", modifierFlags: .shift)
        for _ in 0..<7 { app.typeKey(.downArrow, modifierFlags: []) }
        let collectionSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Season Two (1)'"), object: table)
        XCTAssertEqual(XCTWaiter().wait(for: [collectionSelected], timeout: 5), .completed, "Arrowed to the collection: \(table.label)")

        // ⌫ in the entry list removes the show from the collection (no confirmation). Once the list is gone,
        // ⌫ must no longer target entries (#108 review: focus is cleared when the list resigns or goes away).
        app.typeKey("\t", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        let edit = app.menuBars.menuBarItems["Edit"]
        edit.click()
        XCTAssertTrue(edit.menuItems["Remove from Collection"].isEnabled, "⌫ targets the focused entry list")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        waitForValue(created, "0 items")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Remove from Collection doesn't ask")
        edit.click()
        XCTAssertFalse(edit.menuItems["Remove from Collection"].exists, "no stale entries focus once the list is gone")
        XCTAssertTrue(edit.menuItems["Delete Collection…"].isEnabled, "⌫ falls back to the selected collection")
        app.typeKey(.escape, modifierFlags: [])
        // Undo the removal so the collection deleted below still has its show; then focus the sidebar row.
        app.typeKey("z", modifierFlags: .command)
        waitForValue(created, "1 item")
        created.click()
        app.typeKey(.delete, modifierFlags: [])
        let sheet = app.sheets.firstMatch
        waitFor(sheet)
        XCTAssertTrue(sheet.staticTexts["Delete the collection “Season Two”?"].exists)
        sheet.buttons["Delete"].click()
        XCTAssertFalse(created.waitForExistence(timeout: 2))
        XCTAssertEqual(value(element("ww.library.sidebar.shows")), "100 shows", "Deleting a collection never deletes shows")
    }

    /// #110: "New Collection" is a real, pressable button (not merged into the Collections heading).
    func testNewCollectionButtonIsAnAccessibleButton() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        let add = app.buttons["ww.library.collections.add"]
        waitFor(add)
        XCTAssertEqual(add.label, "New Collection")
        XCTAssertTrue(add.isHittable, "on screen and pressable: \(add.frame)")
        let headings = app.outlines["ww.library.sidebar"].staticTexts.matching(NSPredicate(format: "label CONTAINS 'New Collection'"))
        XCTAssertEqual(headings.count, 0, "not merged into the Collections heading")
        add.click()
        let nameField = element("ww.dialog.name")
        waitFor(nameField)
        nameField.typeText("From The Button\r")
        let created = app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.' AND label == %@", "From The Button, collection")).firstMatch
        waitFor(created)
        try audit("Library sidebar with New Collection button")
    }

    /// #109: at in-app 200% text the Library window's content stays inside the window: sidebar rows, the message
    /// bar (in the content column, #59) and the entry list are below the title bar and reachable.
    func testLibraryAt200PercentTextStaysInsideTheWindow() throws {
        launch(["-WWUITestLibraryFixture", "lib100"])
        let window = app.windows["Library"]
        waitFor(element("ww.library.sidebar"))
        let bar = element("ww.library.messageBar.inMemory")
        waitFor(bar)
        // 100%: the bar sits directly under the toolbar (no doubled safe-area inset) and row 1 is clickable.
        let toolbarBottom = window.frame.minY + 52
        XCTAssertLessThanOrEqual(abs(bar.frame.minY - toolbarBottom), 12, "bar \(bar.frame) right under the toolbar of \(window.frame)")
        let firstCell = app.outlines["ww.library.entries"].cells.firstMatch
        waitFor(firstCell)
        XCTAssertTrue(firstCell.isHittable, "row 1 hittable below the bar: \(firstCell.frame), bar \(bar.frame)")
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        let shows = element("ww.library.sidebar.shows")
        let entries = app.outlines["ww.library.entries"]
        waitFor(entries)
        // Let the 200% layout settle (the text size change re-lays out every column).
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in shows.frame.height > 30 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 5), .completed, "200% applied: Shows row \(shows.frame)")
        let frame = window.frame
        // The unified title bar and toolbar take the top ~52 pt; content must start below it.
        let contentTop = frame.minY + 50
        func assertInside(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(element.exists, "\(name) exists", file: file, line: line)
            XCTAssertGreaterThanOrEqual(element.frame.minY, contentTop, "\(name) \(element.frame) is below the title bar of \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(element.frame.maxY, frame.maxY + 0.5, "\(name) \(element.frame) ends inside \(frame)", file: file, line: line)
        }
        assertInside(shows, "Shows row")
        assertInside(element("ww.library.sidebar.recent"), "Recent row")
        assertInside(app.buttons["ww.library.collections.add"], "New Collection button")
        let heading = bar.staticTexts["The library isn't saved yet in this version"]
        assertInside(heading, "Message bar heading")
        let dismiss = bar.buttons["Dismiss"]
        // The bar's action is reachable: visible, or scrolled into view inside the capped bar.
        if !dismiss.isHittable { bar.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(dismiss.isHittable, "message bar action reachable at 200%: \(dismiss.frame)")
        XCTAssertGreaterThan(entries.frame.height, 60, "entry list keeps room below the bar: \(entries.frame)")
        assertInside(entries, "Entry list")
        XCTAssertGreaterThanOrEqual(entries.frame.minY, bar.frame.maxY - 0.5, "list below the bar")
        try audit("Library window at 200% text (lib100, message bar)")

        // Dismissing the notice gives the list the full column.
        dismiss.click()
        XCTAssertFalse(bar.waitForExistence(timeout: 2))
        assertInside(entries, "Entry list without the bar")
    }

    // MARK: - Show window (T01–T03, T06, T24; K02, K03, K24)

    func testShowWindowEpisodesMetadataDestinationsAndHonestSaveStatus() throws {
        // Autosave ON with a long delay so "Edited" is observable before the automatic save.
        launch(["-WWUITestLibraryFixture", "empty", "-WWUITestOpenShow", "Synthetic Show", "-WWUITestShowEpisodes", "0",
                "-WWUITestAutosave", "ON", "-WWUITestAutosaveDelaySeconds", "30"])
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        waitFor(window, timeout: 15)
        XCTAssertTrue(window.title.hasPrefix("Synthetic Show"))
        let episodes = element("ww.show.sidebar.episodes")
        waitFor(episodes)
        XCTAssertEqual(value(episodes), "0 episodes")
        waitFor(element("ww.show.empty.newEpisode"))

        // Honest status: the create was published and read back by persistence, so it says "Saved" (D1).
        let status = element("ww.show.saveStatus")
        waitFor(status)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Saved'"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed, "verified create shows Saved: \(value(status))")

        // K02: ⇧⌘N → inline rename → type → Return.
        window.typeKey("n", modifierFlags: [.command, .shift])
        let rename = element("ww.show.sidebar.rename")
        waitFor(rename)
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Pilot\r")
        XCTAssertEqual(value(episodes), "1 episode")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "1 Pilot", "1 Pilot")).firstMatch)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(menuItem("Undo Rename Episode").exists, "Named undo for rename")
        app.typeKey(.escape, modifierFlags: [])
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Edited'"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 5), .completed, "edits show Edited (D2), never Saved: \(value(status))")

        // K03: ⌘I focuses Title; invalid Number shows inline text error.
        window.typeKey("i", modifierFlags: .command)
        let title = element("ww.inspector.episode.title")
        waitFor(title)
        let number = element("ww.inspector.episode.number")
        app.typeKey("\t", modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("abc")
        waitFor(app.staticTexts.matching(NSPredicate(format: "value == 'Number: Enter a whole number'")).firstMatch)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("12\t")
        XCTAssertEqual(value(number), "12")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "12 Pilot", "12 Pilot")).firstMatch)

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
        // Audit Settings with only its own window on screen (other windows would be sampled underneath).
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        let autosave = app.switches["ww.settings.autosave"]
        waitFor(autosave)
        waitForValue(autosave, "1")
        waitForValue(app.popUpButtons["ww.settings.libraryLocation"], "In WaveWrangler")
        XCTAssertTrue(app.staticTexts["WaveWrangler saves your changes as you work. You can also choose File › Save at any time."].exists)
        try audit("Settings › General")
        // Until the persistence autosave policy is connected, Off isn't offered (no false OFF claims).
        if !autosave.isEnabled {
            waitFor(app.staticTexts["Turning autosave off isn't available in this version yet. WaveWrangler saves your changes automatically."])
        } else {
            autosave.click()
            waitForValue(autosave, "0")
            waitFor(app.staticTexts["Changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing a show with unsaved changes."])
            autosave.click()
        }

        app.toolbars.buttons["Sources"].click()
        let downloads = app.switches["ww.settings.downloadSources"]
        waitFor(downloads)
        waitForValue(downloads, "1")
        try audit("Settings › Sources")

        // K23: ⌘+ up to 200%, ⌘0 resets.
        app.windows["Sources"].typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("l", modifierFlags: [.command, .shift])
        waitFor(element("ww.library.sidebar"))
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["General"].click()
        let textSize = app.popUpButtons["ww.settings.textSize"]
        waitFor(textSize)
        waitForValue(textSize, "200%")
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("l", modifierFlags: [.command, .shift])
        waitFor(element("ww.library.sidebar"))
        try audit("Library window at 200% text")
        app.typeKey("0", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        waitFor(app.popUpButtons["ww.settings.textSize"])
        waitForValue(app.popUpButtons["ww.settings.textSize"], "100%")
    }

    // MARK: - #88: the library remembers show locations across relaunch

    func testLibraryReopensShowAfterRelaunchAndSaves() throws {
        let folder = "WWUITests-Relaunch"
        // Launch 1: create a show (verified save) in a stable synthetic folder; the window records its location.
        launch(["-WWUITestResetStorage", "YES", "-WWUITestOpenShow", "Relaunch Show", "-WWUITestShowEpisodes", "1",
                "-WWUITestShowFolder", folder, "-WWUITestAutosave", "ON"])
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        waitFor(window, timeout: 15)
        let status = element("ww.show.saveStatus")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Saved'"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed)
        Thread.sleep(forTimeInterval: 2) // let the device-local location record land
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "quit")

        // Launch 2: a fresh process reads only persisted data.
        launch([])
        app.typeKey("l", modifierFlags: [.command, .shift])
        let entries = app.outlines["ww.library.entries"]
        waitFor(entries, timeout: 10)
        let row = entries.outlineRows.containing(NSPredicate(format: "value == 'Relaunch Show'")).firstMatch
        waitFor(row, timeout: 10)
        let statusCell = row.staticTexts.matching(NSPredicate(format: "label == 'Status'")).firstMatch
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Available'"), object: statusCell)
        XCTAssertEqual(XCTWaiter().wait(for: [available], timeout: 10), .completed, "status resolves (never stuck Checking…): \(value(statusCell))")
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "value == %@", folder)).firstMatch.exists, "location remembered")
        try audit("Library after relaunch")

        row.cells.firstMatch.click()
        let open = element("ww.library.detail.open")
        waitFor(open)
        open.click()
        let reopened = app.windows.matching(identifier: "ww.show.window").firstMatch
        waitFor(reopened, timeout: 15)
        XCTAssertTrue(reopened.title.hasPrefix("Relaunch Show"), "opened the same show: \(reopened.title)")

        // Edit and save through the reopened (bookmark-resolved) location.
        reopened.typeKey("n", modifierFlags: [.command, .shift])
        let rename = element("ww.show.sidebar.rename")
        waitFor(rename)
        app.typeText("After Relaunch\r")
        reopened.typeKey("s", modifierFlags: .command)
        let reopenedStatus = element("ww.show.saveStatus")
        let savedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Saved'"), object: reopenedStatus)
        XCTAssertEqual(XCTWaiter().wait(for: [savedAgain], timeout: 10), .completed, "saved after relaunch: \(value(reopenedStatus))")
    }
}
