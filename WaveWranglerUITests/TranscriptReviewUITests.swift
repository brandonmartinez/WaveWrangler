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
        if let app, app.state != .notRunning { app.terminate() }
    }

    func testReviewShellExposesSyntheticPrimaryBackupAndBlockedStates() {
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.provisionalNotice"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.blockedReason"].exists)
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
                .contains("Synthetic contextual filler proposal 1")
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.proposalTiming"].value as? String,
            "Timing unavailable — no word timing or source-frame interval."
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.proposalSource"].value as? String,
            "Source unavailable — no selected Primary is connected or authorized."
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.proposalProtection"].value as? String,
            "Protection unsupported — coverage is not established."
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
        let inspectorHeading = app.staticTexts["ww.review.inspector.heading"]
        XCTAssertTrue(inspectorHeading.waitForExistence(timeout: 3))

        let firstOccurrence = app.descendants(matching: .any)["ww.review.occurrence.synthetic-001"]
        XCTAssertTrue(firstOccurrence.waitForExistence(timeout: 3))
        firstOccurrence.click()
        let occurrences = app.descendants(matching: .any)["ww.review.occurrences"]
        XCTAssertTrue(
            Acceptance.hasKeyboardFocus(occurrences)
                || occurrences.descendants(matching: .outline).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus)
                || occurrences.descendants(matching: .table).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus),
            "The native occurrence list or its outline/table owns keyboard focus"
        )
        XCTAssertTrue(
            inspectorHeading.exists,
            "The Review inspector remains selected after choosing an occurrence"
        )
        let tokenID = app.descendants(matching: .any)["ww.review.inspector.tokenID"]
        XCTAssertEqual(tokenID.value as? String, "token-stub-001")

        let inspector = app.scrollViews["ww.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        for _ in 0..<4 { inspector.swipeUp() }
        XCTAssertTrue(
            Acceptance.hasKeyboardFocus(occurrences)
                || occurrences.descendants(matching: .outline).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus)
                || occurrences.descendants(matching: .table).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus),
            "Scrolling the inspector must not steal the native occurrence table's first responder"
        )
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(Acceptance.waitFor(timeout: 3) {
            tokenID.value as? String == "token-stub-002"
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

    func testKeyboardProposalSelectionUpdatesAccessibleProvisionalDetails() {
        let firstProposal = app.descendants(matching: .any)["ww.review.proposal.synthetic-proposal-001"]
        XCTAssertTrue(firstProposal.waitForExistence(timeout: 3))
        XCTAssertTrue(firstProposal.label.contains("Synthetic contextual filler proposal 1"))
        XCTAssertTrue(firstProposal.label.contains("synthetic-proposal-001"))
        firstProposal.click()

        let proposals = app.descendants(matching: .any)["ww.review.proposals"]
        XCTAssertTrue(
            Acceptance.hasKeyboardFocus(proposals)
                || proposals.descendants(matching: .outline).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus)
                || proposals.descendants(matching: .table).allElementsBoundByIndex.contains(where: Acceptance.hasKeyboardFocus),
            "The native synthetic proposal list or its table owns keyboard focus"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.proposalID"].value as? String,
            "synthetic-proposal-001"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["ww.review.inspector.proposalStatus"].value as? String,
            "Provisional synthetic proposal — not verified or actionable."
        )

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(Acceptance.waitFor(timeout: 3) {
            app.descendants(matching: .any)["ww.review.inspector.proposalID"].value as? String
                == "synthetic-proposal-002"
        })
        let secondProposal = app.descendants(matching: .any)["ww.review.proposal.synthetic-proposal-002"]
        XCTAssertTrue(secondProposal.label.contains("Synthetic contextual filler proposal 2"))
        XCTAssertTrue(secondProposal.label.contains("synthetic-proposal-002"))
        XCTAssertTrue(
            (app.descendants(matching: .any)["ww.review.inspector.proposalTiming"].value as? String ?? "")
                .contains("Timing unavailable")
        )
        XCTAssertTrue(
            (app.descendants(matching: .any)["ww.review.inspector.proposalSource"].value as? String ?? "")
                .contains("no selected Primary")
        )
        XCTAssertTrue(
            (app.descendants(matching: .any)["ww.review.inspector.proposalProtection"].value as? String ?? "")
                .contains("Protection unsupported")
        )
        for identifier in ["acceptShorten", "lift", "reject", "singleLaneAudition", "fullPreview"] {
            XCTAssertFalse(app.buttons["ww.review.action.\(identifier)"].isEnabled, "\(identifier) remains disabled")
        }
    }

    func testReturnAndEscapeWhileFilteringDoNotAcceptOrAudition() {
        let filter = app.textFields["ww.review.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        XCTAssertTrue(filter.isHittable, "The filter must be visible before keyboard focus is requested")
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

    func testEpisodeInfoFromReviewShowsEditableTitleAndKeepsReviewSelection() {
        let occurrence = app.descendants(matching: .any)["ww.review.occurrence.synthetic-002"]
        XCTAssertTrue(occurrence.waitForExistence(timeout: 3))
        occurrence.click()
        XCTAssertEqual(app.descendants(matching: .any)["ww.review.inspector.tokenID"].value as? String, "token-stub-002")
        let timelineSelection = app.descendants(matching: .any)["ww.review.timeline.selectedOccurrence"]
        XCTAssertEqual(timelineSelection.value as? String, "Synthetic example occurrence 2")

        app.menuBars.menuBarItems["Episode"].click()
        let episodeInfo = app.menuItems["Episode Info"]
        XCTAssertTrue(episodeInfo.waitForExistence(timeout: 3))
        XCTAssertTrue(episodeInfo.isEnabled, "Episode Info is available for the selected episode in Review")
        episodeInfo.click()

        let title = app.textFields["ww.inspector.episode.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Episode Info must render the episode inspector, not Review")
        XCTAssertTrue(title.isEnabled && title.isHittable, "Episode Title must be editable")
        XCTAssertTrue(Acceptance.hasKeyboardFocus(title), "Episode Info moves keyboard focus to Title")
        title.typeText(" Review Edit")
        XCTAssertTrue((title.value as? String ?? "").hasSuffix(" Review Edit"))

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.review.inspector.heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["ww.review.inspector.tokenID"].value as? String, "token-stub-002")
        XCTAssertEqual(timelineSelection.value as? String, "Synthetic example occurrence 2")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["ww.setup.sources"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.review.inspector.heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["ww.review.inspector.tokenID"].value as? String, "token-stub-002")
        XCTAssertEqual(timelineSelection.value as? String, "Synthetic example occurrence 2")
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The keyboard shortcut reopens Episode Info from Review")
        XCTAssertTrue(Acceptance.hasKeyboardFocus(title))
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
