import XCTest

@MainActor
final class TranscriptReviewUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["ww.review.heading"].waitForExistence(timeout: 5))
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    func testReviewShellExposesSyntheticPrimaryBackupAndBlockedStates() {
        XCTAssertTrue(app.staticTexts["ww.review.provisionalNotice"].exists)
        XCTAssertTrue(app.staticTexts["ww.review.blockedReason"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.lane.speaker-a-primary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.lane.speaker-a-backup"].exists)
        XCTAssertTrue(app.staticTexts["ww.review.inspector.analysisState"].exists)
        XCTAssertTrue(app.staticTexts["ww.review.inspector.defaultMode"].exists)
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.tokenID"].value as? String,
            "token-stub-001"
        )
        XCTAssertTrue(
            (app.descendants(matching: .any)["ww.review.inspector.proposal"].value as? String ?? "")
                .contains("no analysis")
        )

        for identifier in [
            "acceptShorten", "lift", "reject", "singleLaneAudition", "fullPreview",
        ] {
            let action = app.buttons["ww.review.action.\(identifier)"]
            XCTAssertTrue(action.exists, "\(identifier) remains discoverable")
            XCTAssertEqual(action.elementType, .button)
            XCTAssertFalse(action.isEnabled, "\(identifier) stays blocked without policy/map evidence")
            XCTAssertFalse((action.value as? String ?? "").isEmpty, "\(identifier) exposes its block reason")
        }

        let fullPreview = app.buttons["ww.review.action.fullPreview"]
        XCTAssertTrue((fullPreview.value as? String ?? "").contains("every affected lane"))
        XCTAssertTrue(app.buttons["ww.review.remedy.setup"].exists)
    }

    func testTimelineListsDistinctTimeDomainsWithoutInventedValues() {
        for domain in ["source", "group", "aligned", "output"] {
            let field = app.descendants(matching: .any)["ww.review.timeline.domain.\(domain)"]
            XCTAssertTrue(field.exists, "\(domain) time has a distinct accessible field")
            XCTAssertTrue((field.value as? String ?? "").contains("Not established"))
        }
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.occurrences"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.timelinePane"].exists)
    }

    func testKeyboardOccurrenceSelectionUpdatesTheInspector() {
        let firstOccurrence = app.descendants(matching: .any)["ww.review.occurrence.synthetic-001"]
        XCTAssertTrue(firstOccurrence.waitForExistence(timeout: 3))
        firstOccurrence.click()
        let selection = app.descendants(matching: .any)["ww.review.inspector.selection"]
        XCTAssertEqual(selection.label, "Selected occurrence")
        XCTAssertEqual(selection.value as? String, "Synthetic example occurrence 1")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(Acceptance.waitFor(timeout: 3) {
            selection.value as? String == "Synthetic example occurrence 2"
        })
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.timeline.selectedOccurrence"].value as? String,
            "Synthetic example occurrence 2"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.tokenID"].value as? String,
            "token-stub-002"
        )
        XCTAssertFalse(app.buttons["ww.review.action.acceptShorten"].isEnabled)
    }

    func testReturnAndEscapeWhileFilteringDoNotAcceptOrAudition() {
        let filter = app.textFields["ww.review.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        filter.click()
        XCTAssertTrue(Acceptance.hasKeyboardFocus(filter))
        filter.typeText("synthetic")
        let typedValue = filter.value as? String

        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(filter.value as? String, typedValue)
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(app.buttons["ww.review.action.acceptShorten"].isEnabled)
        XCTAssertFalse(app.buttons["ww.review.action.singleLaneAudition"].isEnabled)
        XCTAssertTrue(app.staticTexts["ww.review.inspector.analysisState"].exists)
    }

    func testBlockedReviewRemedyReturnsToSetup() {
        app.buttons["ww.review.remedy.setup"].click()
        XCTAssertTrue(app.buttons["ww.show.destination.setup"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["ww.setup.sources"].waitForExistence(timeout: 3))
    }

    private func selectFirstEpisode() {
        let episode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ww.show.sidebar.episode."))
            .firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5), "The synthetic show has a selectable episode")
        episode.click()
    }
}
