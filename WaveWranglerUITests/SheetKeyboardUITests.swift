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

    private func keyboardFocusSnapshot(sidebar: XCUIElement, entries: XCUIElement) -> String {
        let candidates: [(String, XCUIElement)] = [
            ("sidebar", sidebar),
            ("entries", entries),
            ("new-collection", app.buttons["ww.library.collections.add"]),
            ("open-show", app.buttons["ww.library.detail.open"])
        ]
        var focused: [String] = []
        let states = candidates.map { name, candidate -> String in
            guard candidate.exists else { return "\(name)=unknown" }
            let hasFocus = Acceptance.hasKeyboardFocus(candidate)
            if hasFocus { focused.append(name) }
            return "\(name)=\(hasFocus ? "yes" : "no")"
        }
        return "focus=\(focused.isEmpty ? "unknown" : focused.joined(separator: ",")); \(states.joined(separator: " "))"
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
        XCTAssertTrue(sheet.staticTexts[question].exists, "sheet asks “\(question)”", file: file, line: line)
        return sheet
    }

    private func assertDismissed(_ sheet: XCUIElement, by key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "\(key) dismisses the confirmation sheet", file: file, line: line)
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
        for _ in 0..<10 { app.typeKey(.upArrow, modifierFlags: []) }
        app.typeKey("\t", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        let entries = app.outlines["ww.library.entries"]
        let showName = entries.staticTexts.matching(NSPredicate(format: "label == %@", "Synthetic Show 001")).firstMatch
        XCTAssertTrue(showName.waitForExistence(timeout: 5), "exact synthetic target Synthetic Show 001 exists")
        XCTAssertEqual(showName.elementType, .staticText, "synthetic target element type")
        XCTAssertTrue(showName.identifier.hasPrefix("ww.library.entry."), "synthetic target identifier: \(showName.identifier)")
        let showRow = entries.outlineRows.containing(NSPredicate(format: "identifier == %@", showName.identifier)).firstMatch
        XCTAssertTrue(showRow.waitForExistence(timeout: 5), "outline row containing \(showName.identifier)")
        XCTAssertEqual(showRow.elementType, .outlineRow, "synthetic target row element type")
        let selected = showRow.isSelected
        XCTAssertTrue(selected, "Down must select Synthetic Show 001 before menu interaction; rowSelected=\(selected); \(keyboardFocusSnapshot(sidebar: sidebar, entries: entries))")
        print("KEYBOARD FOCUS after Down: rowSelected=\(selected); \(keyboardFocusSnapshot(sidebar: sidebar, entries: entries))")
        app.menuBars.menuItems["Add to Collection"].firstMatch.hover()
        let target = app.menuBars.menuItems["Keyboard Sheet"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
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
        let removeShowName = entries.staticTexts.matching(NSPredicate(format: "label == %@", "Synthetic Show 001")).firstMatch
        XCTAssertTrue(removeShowName.waitForExistence(timeout: 5), "exact synthetic target Synthetic Show 001 exists")
        XCTAssertEqual(removeShowName.elementType, .staticText, "synthetic target element type")
        XCTAssertTrue(removeShowName.identifier.hasPrefix("ww.library.entry."), "synthetic target identifier: \(removeShowName.identifier)")
        let removeShowRow = entries.outlineRows.containing(NSPredicate(format: "identifier == %@", removeShowName.identifier)).firstMatch
        XCTAssertTrue(removeShowRow.waitForExistence(timeout: 5), "outline row containing \(removeShowName.identifier)")
        XCTAssertEqual(removeShowRow.elementType, .outlineRow, "synthetic target row element type")
        let removeShowSelected = removeShowRow.isSelected
        XCTAssertTrue(removeShowSelected, "Down must select Synthetic Show 001 before delete; rowSelected=\(removeShowSelected); \(keyboardFocusSnapshot(sidebar: sidebar, entries: entries))")
        print("KEYBOARD FOCUS before Delete: rowSelected=\(removeShowSelected); \(keyboardFocusSnapshot(sidebar: sidebar, entries: entries))")
        app.typeKey(.delete, modifierFlags: [])
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Remove from Library asks first")
        let question = sheet.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove “Synthetic Show 001")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "sheet asks to remove the selected Synthetic Show 001")
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
