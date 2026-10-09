import XCTest

/// #114: destructive confirmation sheets work from the keyboard (Return confirms, Esc cancels), also after the
/// earlier text input and menu use that, on macOS 27, leave a system remote view holding the keyboard focus.
@MainActor
final class SheetKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100"]
        app.launch()
        app.activate()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "\(element.value ?? "")" }

    private func collectionSelectionSnapshot(in entries: XCUIElement, stage: String) -> (valid: Bool, details: String) {
        let sidebarShows = element("ww.library.sidebar.shows")
        let sidebarValue = sidebarShows.exists ? value(sidebarShows) : "<missing>"
        let entriesLabel = entries.exists ? entries.label : "<missing>"
        let showMatches = entries.exists
            ? entries.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.entry.' AND label BEGINSWITH 'Synthetic Show'")).allElementsBoundByIndex
            : []
        let show = showMatches.first { $0.exists }
        var showIdentifier = "<missing>"
        var showLabel = "<missing>"
        var showRowExists = false
        var showRowSelected = false
        if let show {
            showIdentifier = show.identifier
            showLabel = show.label
            let row = entries.outlineRows.containing(.staticText, identifier: show.identifier).firstMatch
            showRowExists = row.exists
            if showRowExists { showRowSelected = row.isSelected }
        }
        let selectedRows = entries.exists
            ? entries.outlineRows.allElementsBoundByIndex.filter(\.isSelected).map(\.label)
            : []
        let valid = entriesLabel == "Shows (100)" && sidebarValue == "100 shows" && showRowSelected
        let details = "\(stage): entries=\(entriesLabel), sidebarShows=\(sidebarValue), entry=\(showIdentifier) [\(showLabel)], rowExists=\(showRowExists), rowSelected=\(showRowSelected), selectedRows=\(selectedRows)"
        return (valid, details)
    }

    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.value(element) == expected }, object: nil)], timeout: timeout)
        XCTAssertEqual(done, .completed, "\(element) value \(value(element)), expected \(expected)", file: file, line: line)
    }

    private func collection(_ name: String) -> XCUIElement {
        app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.' AND label == %@", "\(name), collection")).firstMatch
    }

    /// The sheet that ⌫ opened, with its question. Fails with the sheet's state if it isn't there.
    private func confirmationSheet(_ question: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "confirmation sheet", file: file, line: line)
        XCTAssertTrue(sheet.staticTexts[question].exists, "sheet asks “\(question)”: \(sheet.staticTexts.allElementsBoundByIndex.map { self.value($0) })", file: file, line: line)
        return sheet
    }

    private func assertDismissed(_ sheet: XCUIElement, by key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "\(key) dismisses the sheet: \(sheet.debugDescription.prefix(1500))", file: file, line: line)
    }

    func testDeleteCollectionAndRemoveFromLibraryConfirmWithReturnAndCancelWithEscAfterTextInputAndMenus() throws {
        let sidebar = app.outlines["ww.library.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        XCTAssertEqual(value(element("ww.library.sidebar.shows")), "100 shows")

        // Menu use and text input: File › Library › New Collection… → type a name → Return (the name sheet's
        // default button).
        app.menuBars.menuItems["New Collection…"].firstMatch.click()
        let nameField = element("ww.dialog.name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Keyboard Sheet\r")
        let created = collection("Keyboard Sheet")
        XCTAssertTrue(created.waitForExistence(timeout: 5))

        // Menu use: add the first show to it with File › Library › Add to Collection ▸ (submenu tracking).
        let entries = app.outlines["ww.library.entries"]
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        app.typeKey("\t", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        let afterKeyboardDown = collectionSelectionSnapshot(in: entries, stage: "after keyboard Down, before menu hover")
        app.menuBars.menuItems["Add to Collection"].firstMatch.hover()
        let target = app.menuBars.menuItems["Keyboard Sheet"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let beforeSubmenuClick = collectionSelectionSnapshot(in: entries, stage: "after submenu hover, before click")
        XCTAssertTrue(afterKeyboardDown.valid && beforeSubmenuClick.valid,
                      "Add to Collection requires the keyboard-selected Synthetic Show in Shows.\n\(afterKeyboardDown.details)\n\(beforeSubmenuClick.details)")
        target.click()
        waitForValue(created, "1 item")

        // Delete Collection: Esc cancels, Return confirms; the collection's show stays in the library.
        app.typeKey("\t", modifierFlags: .shift)
        for _ in 0..<10 { app.typeKey(.downArrow, modifierFlags: []) }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Keyboard Sheet (1)'"), object: entries)], timeout: 5), .completed,
                       "arrowed to the new collection: \(entries.label)")
        app.typeKey(.delete, modifierFlags: [])
        var sheet = confirmationSheet("Delete the collection “Keyboard Sheet”?")
        app.typeKey(.escape, modifierFlags: [])
        assertDismissed(sheet, by: "Esc")
        XCTAssertTrue(created.exists, "Esc cancels: the collection is kept")
        app.typeKey(.delete, modifierFlags: [])
        sheet = confirmationSheet("Delete the collection “Keyboard Sheet”?")
        app.typeKey(.return, modifierFlags: [])
        assertDismissed(sheet, by: "Return")
        XCTAssertTrue(created.waitForNonExistence(timeout: 5), "Return confirms: the collection is deleted")
        XCTAssertEqual(value(element("ww.library.sidebar.shows")), "100 shows", "deleting a collection keeps its shows")

        // Remove from Library: select Shows, Tab into the entries, select a show; Esc cancels, Return confirms.
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Shows (100)'"), object: entries)], timeout: 5), .completed,
                       "back on Shows: \(entries.label)")
        app.typeKey("\t", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Remove from Library asks first")
        let question = sheet.staticTexts.allElementsBoundByIndex.map { self.value($0) }.first { $0.hasPrefix("Remove") } ?? ""
        XCTAssertTrue(question.hasPrefix("Remove “Synthetic Show"), "sheet asks to remove the selected show: \(question)")
        app.typeKey(.escape, modifierFlags: [])
        assertDismissed(sheet, by: "Esc")
        XCTAssertEqual(value(element("ww.library.sidebar.shows")), "100 shows", "Esc cancels: nothing removed")
        app.typeKey(.delete, modifierFlags: [])
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        assertDismissed(sheet, by: "Return")
        waitForValue(element("ww.library.sidebar.shows"), "99 shows")
    }
}
