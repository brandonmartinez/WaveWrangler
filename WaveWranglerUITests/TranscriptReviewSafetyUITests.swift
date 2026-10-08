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
        selectFirstEpisode()
        let reviewDestination = app.buttons["ww.show.destination.review"]
        XCTAssertTrue(reviewDestination.waitForExistence(timeout: 5))
        reviewDestination.click()
        XCTAssertTrue(reviewDestination.isSelected, "Selecting Review updates the destination control")
        XCTAssertFalse(
            app.descendants(matching: .any)["ww.show.showInfoSummary.title"].exists,
            "Selecting an episode leaves the Show Info surface"
        )
        let reviewHeading = app.descendants(matching: .any)["ww.review.heading"]
        let reviewHeadingFound = reviewHeading.waitForExistence(timeout: 5)
        let reviewState = [
            "selected=\(reviewDestination.isSelected)",
            "notice=\(app.descendants(matching: .any)["ww.review.provisionalNotice"].exists)",
            "timeline=\(app.descendants(matching: .any)["ww.review.timelinePane"].exists)",
            "inspector=\(app.staticTexts["ww.review.inspector.heading"].exists)",
            "showInfo=\(app.descendants(matching: .any)["ww.show.showInfoSummary.title"].exists)",
            "setup=\(app.descendants(matching: .any)["ww.setup.sources"].exists)",
        ].joined(separator: "; ")
        XCTAssertTrue(reviewHeadingFound, "Review heading missing after selection: \(reviewState)")
    }

    override func tearDown() async throws {
        if app.state != .notRunning { app.terminate() }
    }

    func testShowInfoSelectionPrecedesReviewInDetailAndInspector() {
        let showInfo = app.descendants(matching: .any)["ww.show.sidebar.showInfo"]
        XCTAssertTrue(showInfo.waitForExistence(timeout: 3))
        showInfo.click()

        XCTAssertTrue(app.staticTexts["ww.show.showInfoSummary.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["ww.inspector.showInfo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["ww.review.heading"].exists)
        XCTAssertFalse(app.staticTexts["ww.review.inspector.heading"].exists)
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
        XCTAssertTrue(setupRemedy.label.contains("⌘1"))

        let hideInspector = app.buttons["Hide Inspector"]
        XCTAssertTrue(hideInspector.waitForExistence(timeout: 3))
        hideInspector.click()
        XCTAssertTrue(app.buttons["Show Inspector"].waitForExistence(timeout: 3))
        let detailAudit = try AcceptanceAudit.run(
            app,
            surface: "transcript-review-blocked-detail",
            test: self,
            types: .parentChild
        )
        XCTAssertTrue(detailAudit.isEmpty, detailAudit.joined(separator: "\n"))
        app.buttons["Show Inspector"].click()
        XCTAssertTrue(setupRemedy.waitForExistence(timeout: 3))
        filter.click()

        let unwaived = try AcceptanceAudit.run(
            app,
            surface: "transcript-review-blocked",
            test: self,
            types: AcceptanceAudit.types
        )
        XCTAssertTrue(unwaived.isEmpty, unwaived.joined(separator: "\n"))

        filter.click()
        if UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0 {
            XCTAssertTrue(tabToFocus(setupRemedy), "Full Keyboard Access makes the inspector remedy tab-reachable")
            XCTAssertTrue(Acceptance.hasKeyboardFocus(setupRemedy))
            XCTAssertTrue(setupRemedy.isHittable, "The focused remedy remains visible")
            app.typeKey(.space, modifierFlags: [])
        } else {
            // With Full Keyboard Access off, macOS skips buttons in Tab order; use the visible View > Setup ⌘1 command.
            app.typeKey("1", modifierFlags: .command)
        }
        XCTAssertTrue(app.tables["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    private func tabToFocus(_ element: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if Acceptance.hasKeyboardFocus(element) { return true }
            app.typeKey(.tab, modifierFlags: [])
        }
        return Acceptance.hasKeyboardFocus(element)
    }

    private func selectFirstEpisode() {
        let showInfo = app.descendants(matching: .any)["ww.show.sidebar.showInfo"]
        XCTAssertTrue(showInfo.waitForExistence(timeout: 5))
        showInfo.click()
        XCTAssertTrue(app.staticTexts["ww.show.showInfoSummary.title"].waitForExistence(timeout: 5))

        let episode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ww.show.sidebar.episode."))
            .firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5), "The synthetic show has a selectable episode")
        episode.click()
        XCTAssertFalse(
            app.descendants(matching: .any)["ww.show.showInfoSummary.title"].exists,
            "Selecting the synthetic episode leaves Show Info"
        )
    }
}
