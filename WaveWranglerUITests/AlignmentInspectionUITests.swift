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
        chooseEpisodeMenu("Place Anchor at Playhead")
        XCTAssertTrue(app.textFields["alignment.anchors.first.source"].waitForExistence(timeout: 2))
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
        XCTAssertTrue(app.tables["ww.alignment.groups"].exists)
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
        XCTAssertTrue(app.textFields["alignment.numeric.rate"].waitForExistence(timeout: 2))
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
        app.typeKey(.return, modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["alignment.auditionStatus"].exists)
    }

    func testTM210BlockedStateAndRemedyAreLabelled() {
        selectTargetEpoch()
        chooseEpisodeMenu("Reject Proposal")
        app.typeKey("i", modifierFlags: [.command, .control])
        XCTAssertTrue(app.staticTexts["ww.inspector.alignment.evidence"].waitForExistence(timeout: 2))
    }

    func testTM211DependentsNoticeIsReadableWithoutFocusMove() {
        selectTargetEpoch()
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(app.staticTexts["ww.alignment.dependents"].exists)
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
        XCTAssertTrue(app.buttons["ww.show.blocked.goToSetup"].exists)
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
}
