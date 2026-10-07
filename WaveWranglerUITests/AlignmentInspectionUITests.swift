import XCTest

@MainActor
final class AlignmentInspectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Alignment Fixture",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.tables["ww.alignment.groups"].waitForExistence(timeout: 5))
    }

    func testTM201ReachEveryAlignmentControl() {
        let group = app.staticTexts["Studio recorder"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Reference"].waitForExistence(timeout: 2))
        selectTargetEpoch()
        app.typeKey("i", modifierFlags: [.command, .control])
        XCTAssertTrue(app.staticTexts["ww.inspector.alignment.evidence"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["alignment.analyse"].exists)
        XCTAssertTrue(app.buttons["alignment.editNumeric"].exists)
        XCTAssertTrue(app.buttons["alignment.placeAnchors"].exists)
        XCTAssertTrue(app.buttons["ww.alignment.audition.play"].exists)
    }

    func testTM202PlaceAnchorFromMenu() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(app.staticTexts["Set by you"].waitForExistence(timeout: 5))
        replace(app.textFields["ww.alignment.audition.range.start"], with: "1")
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "1")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForLabel("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
        chooseEpisodeMenu("Place Anchor at Playhead")
        let appended = app.textFields["ww.alignment.anchor.2.alignedTime"]
        XCTAssertTrue(appended.waitForExistence(timeout: 5))
        XCTAssertTrue(appended.value(forKey: "hasKeyboardFocus") as? Bool == true)
    }

    func testTM203EditAnchorTimeNumerically() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        let anchor = app.staticTexts["ww.alignment.anchor.0.sourceTime"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        anchor.click()
        app.typeKey(.return, modifierFlags: [])
        let aligned = app.textFields["ww.alignment.anchor.0.alignedTime"]
        XCTAssertTrue(aligned.waitForExistence(timeout: 2))
        aligned.typeKey("a", modifierFlags: .command)
        aligned.typeText("0.125")
        aligned.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("0.125", in: app.textFields["ww.alignment.anchor.0.alignedTime"]))
        anchor.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForAnyValue(["0", "0.000"], in: app.textFields["ww.alignment.anchor.0.alignedTime"]))
    }

    func testTM204DeleteAnchorCommandIsKeyboardReachable() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        let anchor = app.staticTexts["ww.alignment.anchor.1.sourceTime"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        anchor.click()
        app.typeKey(.delete, modifierFlags: [])
        let confirmation = app.sheets.buttons["Delete Anchor"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        let anchors = app.tables["ww.alignment.anchors"]
        XCTAssertTrue(waitForRowCount(0, in: anchors))
        app.tables["ww.alignment.groups"].click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForRowCount(2, in: anchors))
    }

    func testTM205CorrectEpochNumericallyReturnAndEscape() {
        selectTargetEpoch()
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let rate = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 2))
        rate.typeKey("a", modifierFlags: .command)
        rate.typeText("12.5")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Set by you"].waitForExistence(timeout: 5))
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let preserved = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(preserved.waitForExistence(timeout: 2))
        XCTAssertEqual(preserved.value as? String, "12.5")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTM206AcceptProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(app.staticTexts["Set by you"].waitForExistence(timeout: 5))
    }

    func testTM207RejectProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Reject Proposal")
        XCTAssertTrue(app.staticTexts["Unsupported — not attempted"].waitForExistence(timeout: 5))
    }

    func testTM208StartNewEpochCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        let anchor = app.staticTexts["ww.alignment.anchor.1.sourceTime"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        anchor.click()
        chooseEpisodeMenu("Start New Epoch at Anchor")
        XCTAssertTrue(app.staticTexts["Epoch 2"].waitForExistence(timeout: 5))
    }

    func testTM209AuditionAndStopShortcuts() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "2")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForLabel("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
    }

    func testTM210BlockedStateAndRemedyAreLabelled() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.start"], with: "2.5")
        let heading = app.staticTexts["ww.alignment.region.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 2))
        XCTAssertEqual(heading.label, "Gap — clock restarted")
        XCTAssertTrue(app.buttons["Go to Epoch After"].exists)
    }

    func testTM211DependentsNoticeIsReadableWithoutFocusMove() {
        selectTargetEpoch()
        XCTAssertTrue(app.staticTexts["1 dependent job current; none stale."].waitForExistence(timeout: 5))
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(app.staticTexts["1 of 1 dependent job stale."].waitForExistence(timeout: 5))
    }

    func testTM212NoRecorderGroupBlockedPanel() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenShow", "Empty Alignment", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.show.blocked.heading"].waitForExistence(timeout: 5))
        let goToSetup = app.buttons["ww.show.blocked.goToSetup"]
        XCTAssertTrue(goToSetup.exists)
        XCTAssertTrue(tabToFocus(goToSetup))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.tables["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    func testAlignmentWindowSmokeAndResize() throws {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.exists)
        window.doubleClick()
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .hitRegion, .action])
    }

    func testBlockedRecoveryContrastAudit() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenShow", "Empty Alignment", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.show.blocked.heading"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.contrast])
    }

    private func chooseEpisodeMenu(_ item: String) {
        app.menuBars.menuBarItems["Episode"].click()
        app.menuItems[item].click()
    }

    private func selectTargetEpoch() {
        let state = app.staticTexts["Proposed — not confirmed"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        state.click()
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        field.typeKey(.return, modifierFlags: [])
    }

    private func waitForLabel(
        _ prefix: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func tabToFocus(_ element: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if element.value(forKey: "hasKeyboardFocus") as? Bool == true { return true }
            app.typeKey(.tab, modifierFlags: [])
        }
        return element.value(forKey: "hasKeyboardFocus") as? Bool == true
    }

    private func waitForValue(
        _ value: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitForAnyValue([value], in: element, timeout: timeout)
    }

    private func waitForAnyValue(
        _ values: [String],
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "value IN %@", values)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForRowCount(
        _ count: Int,
        in table: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if table.descendants(matching: .tableRow).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return table.descendants(matching: .tableRow).count == count
    }
}
