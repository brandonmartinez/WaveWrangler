import AppKit
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
            "-WWUITestMinimumShowWindow", "YES",
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

    func testNativeInspectorClipsToMinimumWindowAndSetupStaysFixed() {
        let window = app.windows["ww.show.window"]
        XCTAssertEqual(window.frame.width, 760, accuracy: 2)
        XCTAssertEqual(window.frame.height, 492, accuracy: 2)
        let inspector = app.scrollViews["ww.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.contains(inspector.frame), "The AX scroll viewport must be bounded by the window: \(inspector.frame)")
        XCTAssertLessThan(inspector.frame.height, 440, "The inspector must not report its document height as its viewport")

        let setup = app.buttons["ww.review.remedy.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.contains(setup.frame))
        XCTAssertTrue(setup.isHittable, "Setup has a real hit point before any scrolling")
        inspector.swipeUp()
        XCTAssertTrue(setup.isHittable, "Setup remains fixed when the document scrolls")
        XCTAssertTrue(window.frame.contains(inspector.frame), "Scrolling cannot expand the AX viewport")
    }

    func testAcceptRefusalIsCompleteAndItsLastLineIsReachableAt200Percent() {
        for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
        assertTextSize200()
        let window = app.windows["ww.show.window"]
        let inspector = app.scrollViews["ww.inspector"]
        let button = app.buttons["ww.review.action.acceptShorten"]
        let reason = app.staticTexts["ww.review.action.acceptShorten.reason"]
        let expected = "Accept is blocked: no current proposal or transcript timing is connected; the alignment map, all-lane backing, protection coverage, and edit policy are unverified."

        XCTAssertTrue(button.exists)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.value as? String, expected)
        XCTAssertTrue(reason.exists)
        XCTAssertEqual(reason.value as? String, expected, "No refusal clause may be truncated from AX")
        scrollToFullyVisible(reason, in: inspector)
        XCTAssertTrue(reason.isHittable, "The complete refusal must have an in-window hit point")
        XCTAssertTrue(window.frame.contains(reason.frame), "The complete refusal's last line must fit in the window: \(reason.frame)")
        XCTAssertTrue(inspector.frame.contains(reason.frame), "Scroll to make the last line visible inside the clip")
        if inspector.frame.contains(reason.frame) {
            let shot = reason.screenshot()
            guard let cg = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let lastLine = cg.cropping(to: CGRect(x: 0, y: CGFloat(cg.height) * 0.7,
                                                       width: cg.width, height: CGFloat(cg.height) * 0.3)) else {
                return XCTFail("The refusal's last line must produce visible pixels")
            }
            let pixels = ContrastMeter.measure(NSImage(cgImage: lastLine, size: .init(width: CGFloat(lastLine.width), height: CGFloat(lastLine.height))))
            XCTAssertGreaterThanOrEqual(pixels?["glyphPixels"] as? Int ?? 0, 40, "The last line must be rendered, not just in AX")
        }
        XCTAssertTrue(app.buttons["ww.review.remedy.setup"].isHittable, "Setup remains fixed after scrolling to the refusal")
    }

    func testVisibleReviewTextHasContrastAt100And200PercentInLightAndDark() {
        continueAfterFailure = true
        let inspector = app.scrollViews["ww.inspector"]
        let baseArguments = app.launchArguments
        for appearance in ["aqua", "darkAqua"] {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = baseArguments + ["-WWUITestAppearance", appearance]
            app.launch()
            app.activate()
            let episode = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ww.show.sidebar.episode.")).firstMatch
            XCTAssertTrue(episode.waitForExistence(timeout: 5))
            episode.click()
            app.buttons["ww.show.destination.review"].click()
            for percent in [100, 200] {
                if percent == 200 {
                    for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
                    assertTextSize200()
                }
                for (name, identifier) in [
                    ("analysisState", "ww.review.inspector.analysisState"),
                    ("refusal", "ww.review.action.acceptShorten.reason"),
                    ("defaultMode", "ww.review.inspector.defaultMode"),
                ] {
                    let element = app.staticTexts[identifier]
                    XCTAssertTrue(element.exists, "\(appearance) \(percent)% \(name) must exist in AX")
                    guard element.exists else { continue }
                    scrollToFullyVisible(element, in: inspector)
                    measureVisibleText(element, in: inspector, label: "\(appearance) \(percent)% \(name)")
                }
                let blocked = app.descendants(matching: .any)["ww.review.blockedReason"]
                XCTAssertTrue(blocked.exists, "\(appearance) \(percent)% blocked copy must exist")
                if blocked.exists {
                    measureVisibleText(blocked, in: app.windows["ww.show.window"], label: "\(appearance) \(percent)% blocked")
                }
            }
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
        let showWindow = app.windows["ww.show.window"]
        XCTAssertTrue(
            showWindow.frame.contains(app.scrollViews["ww.inspector"].frame),
            "The scrollable inspector AX viewport must remain inside the show window"
        )
        XCTAssertTrue(showWindow.frame.contains(setupRemedy.frame), "The remedy remains inside the show window")
        XCTAssertTrue(setupRemedy.isHittable, "The remedy has a visible hit point without scrolling")

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

    private func scrollToFullyVisible(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<16 where element.exists && !scroll.frame.contains(element.frame) {
            if element.frame.midY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
    }

    private func measureVisibleText(_ element: XCUIElement, in container: XCUIElement, label: String) {
        XCTAssertTrue(container.frame.contains(element.frame), "\(label): text must be wholly in its visible container")
        XCTAssertTrue(element.isHittable, "\(label): text needs a real visible hit point")
        guard container.frame.contains(element.frame), element.isHittable else { return }
        let shot = element.screenshot()
        let measured = ContrastMeter.measure(shot.image)
        let count = measured?["glyphPixels"] as? Int ?? 0
        let p75 = measured?["glyphP75"] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(count, 40, "\(label): visible glyph pixels, measured \(String(describing: measured))")
        XCTAssertGreaterThanOrEqual(p75, 4.5, "\(label): glyph p75, measured \(String(describing: measured))")
        Acceptance.record(self, "\(label): \(count) glyph px, p75 \(p75)")
    }

    private func assertTextSize200() {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["ww.settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "Verify the real in-app text setting, not a launch override")
        XCTAssertEqual(app.popUpButtons["ww.settings.textSize"].value as? String, "200%")
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(settings.exists)
        app.windows["ww.show.window"].click()
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
