import XCTest

@MainActor
final class TranscriptReviewSafetyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Synthetic Review Fixture",
            "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows["ww.show.window"].waitForExistence(timeout: 5))
        let reviewDestination = app.buttons["ww.show.destination.review"]
        XCTAssertTrue(reviewDestination.waitForExistence(timeout: 5))
        reviewDestination.click()
        XCTAssertTrue(app.staticTexts["ww.review.heading"].waitForExistence(timeout: 5))
    }

    override func tearDown() async throws {
        if app.state != .notRunning { app.terminate() }
    }

    func testShowInfoSelectionPrecedesReviewInDetailAndInspector() {
        let showInfo = app.descendants(matching: .any)["ww.show.sidebar.showInfo"]
        XCTAssertTrue(showInfo.waitForExistence(timeout: 3))
        showInfo.click()

        XCTAssertTrue(app.staticTexts["ww.show.showInfoSummary.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["ww.inspector.show.title"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["ww.review.heading"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ww.review.inspector"].exists)
    }

    func testEachDisabledEditActionShowsItsOwnRefusalReason() {
        let actions = [
            ("acceptShorten", "Accept Shorten when safe", "Accept is blocked"),
            ("lift", "Lift — preserve timing", "Lift is blocked"),
            ("reject", "Reject proposal", "Reject is blocked"),
        ]
        let inspector = app.scrollViews["ww.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))

        for (identifier, title, reasonPrefix) in actions {
            let action = app.buttons["ww.review.action.\(identifier)"]
            let reason = app.staticTexts["ww.review.action.\(identifier).reason"]
            XCTAssertTrue(action.exists, "\(title) stays discoverable")
            XCTAssertFalse(action.isEnabled, "\(title) remains safely disabled")
            XCTAssertTrue(reason.exists, "\(title) has a visible refusal reason")
            XCTAssertEqual(reason.label, "\(title) blocked")
            XCTAssertTrue((reason.value as? String ?? "").hasPrefix(reasonPrefix))

            for _ in 0..<8 where !reason.isHittable {
                inspector.swipeUp()
            }
            XCTAssertTrue(reason.isHittable, "\(title)'s refusal reason is visible in the inspector")
        }
    }

    func testBlockedReviewKeepsVisibleFocusAndKeyboardRecoveryAndPassesAudits() throws {
        let filter = app.textFields["ww.review.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        filter.click()
        XCTAssertTrue(Acceptance.hasKeyboardFocus(filter), "The review filter shows keyboard focus")
        XCTAssertTrue(filter.isHittable, "The focused control remains visible")

        let setupRemedy = app.buttons["ww.review.remedy.setup"]
        XCTAssertTrue(setupRemedy.waitForExistence(timeout: 3))
        XCTAssertTrue(setupRemedy.isEnabled)

        let unwaived = try AcceptanceAudit.run(
            app,
            surface: "transcript-review-blocked",
            test: self,
            types: AcceptanceAudit.types
        )
        XCTAssertTrue(unwaived.isEmpty, unwaived.joined(separator: "\n"))

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.tables["ww.setup.sources"].waitForExistence(timeout: 5))
    }
}
