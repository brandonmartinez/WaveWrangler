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

            scrollToFullyVisible(reason, in: inspector)
            XCTAssertTrue(reason.isHittable, "\(title)'s refusal reason is visible in the inspector")
        }
    }

    func testNativeInspectorClipsToMinimumWindowAndSetupStaysFixed() {
        let window = app.windows["ww.show.window"]
        XCTAssertEqual(window.frame.width, 760, accuracy: 2)
        XCTAssertEqual(window.frame.height, 492, accuracy: 2)
        let inspector = app.scrollViews["ww.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        let content = app.descendants(matching: .any)["ww.show.contentInspector"]
        XCTAssertTrue(
            window.frame.contains(content.frame),
            "The split AX group must fit the window rather than its document: content \(content.frame), window \(window.frame)"
        )
        XCTAssertTrue(
            window.frame.contains(inspector.frame),
            "The AX scroll viewport must be bounded by the window: scroll \(inspector.frame), content \(content.frame), window \(window.frame)"
        )
        XCTAssertLessThan(inspector.frame.height, 440, "The inspector must not report its document height as its viewport")
        XCTAssertTrue(inspector.isHittable, "The native scroll viewport has an in-window hit point")
        let analysis = app.staticTexts["ww.review.inspector.analysisState"]
        XCTAssertTrue(inspector.frame.contains(analysis.frame), "Visible document text is clipped to the scroll viewport")

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
        for _ in 0..<18 where reason.frame.maxY > inspector.frame.maxY - 3 {
            inspector.scroll(byDeltaX: 0, deltaY: -180)
        }
        let lastLine = CGRect(x: reason.frame.minX + 2, y: reason.frame.maxY - 36,
                              width: reason.frame.width - 4, height: 32)
        XCTAssertTrue(window.frame.contains(lastLine), "The refusal's last line must be in the window")
        XCTAssertTrue(inspector.frame.contains(lastLine), "Scroll to make the last line visible inside the clip")
        let measured = measureWindowCrop(lastLine)
        XCTAssertGreaterThanOrEqual(measured?["glyphPixels"] as? Int ?? 0, 40, "The last line must be rendered, not just in AX")
        XCTAssertGreaterThanOrEqual(measured?["glyphP75"] as? Double ?? 0, 4.5, "The last line must be legible")
        XCTAssertTrue(app.buttons["ww.review.remedy.setup"].isHittable, "Setup remains fixed after scrolling to the refusal")
    }

    func testWideMinimumWindowReachesLastLaneAndTimeDomainAt200PercentInLightAndDark() {
        let baseArguments = app.launchArguments
        for appearance in ["aqua", "darkAqua"] {
            app.terminate()
            app.launchArguments = baseArguments + ["-WWUITestAppearance", appearance]
            app.launch()
            app.activate()
            XCTAssertTrue(app.windows["ww.show.window"].waitForExistence(timeout: 5))
            selectFirstEpisode()
            app.buttons["ww.show.destination.review"].click()
            XCTAssertTrue(app.chooseMenu(["View", "Hide Inspector"]))
            XCTAssertFalse(app.scrollViews["ww.inspector"].exists)
            XCTAssertTrue(app.chooseMenu(["View", "Hide Sidebar"]))
            for _ in 0..<5 { app.typeKey("+", modifierFlags: .command) }
            assertTextSize200()

            let window = app.windows["ww.show.window"]
            XCTAssertEqual(window.frame.width, 760, accuracy: 2)
            XCTAssertEqual(window.frame.height, 492, accuracy: 2)

            let scroll = app.scrollViews["ww.review.wideContentScroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 3), "\(appearance): wide Review needs a vertical viewport")
            XCTAssertGreaterThanOrEqual(scroll.frame.width, 620, "\(appearance): exercise the wide layout")
            XCTAssertTrue(window.frame.contains(scroll.frame), "\(appearance): the scroll viewport stays inside the window")

            let first = app.descendants(matching: .any)["ww.review.occurrence.synthetic-001"]
            XCTAssertTrue(first.isHittable)
            first.click()
            let occurrences = app.descendants(matching: .any)["ww.review.occurrences"]
            XCTAssertTrue(Acceptance.hasKeyboardFocus(occurrences), "The native table owns keyboard focus")

            for identifier in ["ww.review.lane.speaker-b-primary", "ww.review.timeline.domain.output"] {
                let field = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(field.exists, "\(appearance): \(identifier) is present in AX")
                Acceptance.record(self, "\(appearance) \(identifier): initial \(field.frame), viewport \(scroll.frame)")
                for attempt in 0..<18 where field.exists && !scroll.frame.contains(field.frame) {
                    scroll.scroll(byDeltaX: 0, deltaY: -180)
                    if attempt == 0 {
                        Acceptance.record(self, "\(appearance) \(identifier): after first scroll \(field.frame)")
                    }
                }
                XCTAssertTrue(scroll.frame.contains(field.frame),
                              "\(appearance): \(identifier) \(field.frame) scrolls fully into \(scroll.frame)")
                XCTAssertTrue(window.frame.contains(field.frame), "\(appearance): \(identifier) fits inside the window")
                XCTAssertTrue(field.isHittable, "\(appearance): \(identifier) has an in-window hit point")
                XCTAssertFalse((field.value as? String ?? "").isEmpty, "\(appearance): \(identifier) has an AX value")
            }

            XCTAssertTrue(Acceptance.hasKeyboardFocus(occurrences), "Scrolling must not steal the table's first responder")
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(Acceptance.waitFor(timeout: 3) {
                app.descendants(matching: .any)["ww.review.timeline.selectedOccurrence"].value as? String
                    == "Synthetic example occurrence 2"
            }, "\(appearance): keyboard selection updates the timeline after scrolling")
        }
    }

    func testVisibleReviewTextHasContrastAt100And200PercentInLightAndDark() {
        continueAfterFailure = true
        let inspector = app.scrollViews["ww.inspector"]
        Acceptance.attach(self, png: app.windows["ww.show.window"].screenshot().pngRepresentation, name: "initial-review-window")
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
                    XCTAssertTrue(
                        app.windows["ww.show.window"].frame.contains(blocked.frame),
                        "\(appearance) \(percent)% blocked copy must not extend beyond the window"
                    )
                    measureVisibleText(blocked, in: app.windows["ww.show.window"], label: "\(appearance) \(percent)% blocked")
                }
            }
        }
    }

    func testBlockedReviewCoreAXAndKeyboardSetupRecovery() throws {
        let window = app.windows["ww.show.window"]
        let inspector = app.scrollViews["ww.inspector"]
        let setup = app.buttons["ww.review.remedy.setup"]
        let heading = app.staticTexts["ww.review.inspector.heading"]
        let blocked = app.descendants(matching: .any)["ww.review.blockedReason"]
        let accept = app.buttons["ww.review.action.acceptShorten"]
        let reason = app.staticTexts["ww.review.action.acceptShorten.reason"]
        let refusal = "Accept is blocked: no current proposal or transcript timing is connected; the alignment map, all-lane backing, protection coverage, and edit policy are unverified."

        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.contains(inspector.frame), "The AX scroll viewport must stay within the show window")
        XCTAssertTrue(heading.exists && heading.isHittable, "The Review heading is exposed and reachable")
        XCTAssertEqual(heading.value as? String, "Review Inspector")
        XCTAssertTrue(blocked.exists && blocked.isHittable, "The blocked state is exposed in the detail")
        XCTAssertTrue((blocked.value as? String ?? "").contains("No live Primary"))
        XCTAssertTrue(inspector.descendants(matching: .staticText)["ww.review.inspector.analysisState"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.occurrence.synthetic-001"].exists)
        XCTAssertTrue(setup.exists && setup.isEnabled && setup.isHittable, "Setup is a fixed, actionable AX button")
        XCTAssertEqual(setup.label, "Go to Setup (⌘1)")
        XCTAssertTrue(window.frame.contains(setup.frame))
        XCTAssertTrue(accept.exists && !accept.isEnabled, "Accept remains blocked")
        XCTAssertEqual(accept.label, "Accept Shorten when safe")
        XCTAssertEqual(accept.value as? String, refusal)
        XCTAssertTrue(reason.exists && inspector.descendants(matching: .staticText)["ww.review.action.acceptShorten.reason"].exists)
        XCTAssertEqual(reason.value as? String, refusal, "The entire refusal is reachable in AX")

        for _ in 0..<18 where !inspector.frame.contains(reason.frame) {
            inspector.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(reason.isHittable, "The refusal scrolls to an in-window hit point")
        XCTAssertTrue(setup.isHittable, "Setup remains fixed after scrolling the inspector")
        measureVisibleText(blocked, in: window, label: "core task blocked")
        measureVisibleText(setup, in: window, label: "core task Setup remedy", minimumLineHeight: 14)

        let filter = app.textFields["ww.review.filter"]
        filter.click()
        XCTAssertTrue(Acceptance.hasKeyboardFocus(filter))
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(Acceptance.hasKeyboardFocus(filter), "Audit after the field editor relinquishes focus")
        let unwaived = try AcceptanceAudit.run(
            app, surface: "transcript-review-core-ax", test: self, types: AcceptanceAudit.essentialTypes
        )
        XCTAssertTrue(unwaived.isEmpty, unwaived.joined(separator: "\n"))

        filter.click()
        XCTAssertTrue(Acceptance.hasKeyboardFocus(filter))
        if UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0 {
            XCTAssertTrue(tabToFocus(setup), "With Full Keyboard Access, Tab reaches the Setup remedy")
            XCTAssertTrue(Acceptance.hasKeyboardFocus(setup))
            app.typeKey(.space, modifierFlags: [])
        } else {
            app.typeKey("1", modifierFlags: .command)
        }
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5), "Keyboard-only recovery opens Setup")
        XCTAssertFalse(app.buttons["ww.review.action.acceptShorten"].exists, "Recovery leaves blocked Review")
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
        XCTAssertFalse(app.scrollViews["ww.inspector"].exists, "The old AX scroll tree is gone before auditing the detail")
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(Acceptance.hasKeyboardFocus(filter), "Audit the stable tree after leaving the filter's field editor")
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
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(Acceptance.hasKeyboardFocus(filter), "Move focus off the filter and the pointer off toolbar help")
        let window = app.windows["ww.show.window"]
        let selectedTitle = app.staticTexts["ww.review.occurrence.synthetic-001"]
        XCTAssertTrue(selectedTitle.exists)
        measureVisibleText(selectedTitle, in: window, label: "selected occurrence title", minimumLineHeight: 14)

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
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    private func tabToFocus(_ element: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if Acceptance.hasKeyboardFocus(element) { return true }
            app.typeKey(.tab, modifierFlags: [])
        }
        return Acceptance.hasKeyboardFocus(element)
    }

    private func scrollToFullyVisible(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<18 where element.exists {
            let frame = element.frame
            let visible = frame.height > scroll.frame.height
                ? scroll.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                : scroll.frame.contains(frame)
            if visible { break }
            scroll.scroll(byDeltaX: 0, deltaY: frame.midY < scroll.frame.minY ? 180 : -180)
        }
    }

    private func measureVisibleText(_ element: XCUIElement, in container: XCUIElement, label: String,
                                    minimumLineHeight: CGFloat = 20) {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.frame.contains(container.frame), "\(label): the measured viewport must fit in the window")
        let visible = element.frame.intersection(container.frame).intersection(window.frame)
        XCTAssertGreaterThanOrEqual(visible.height, minimumLineHeight, "\(label): at least one full line must be visibly reachable")
        XCTAssertTrue(element.isHittable, "\(label): text needs a real visible hit point")
        guard visible.height >= minimumLineHeight, element.isHittable else { return }
        if label.hasSuffix("blocked") {
            Acceptance.attach(self, png: window.screenshot().pngRepresentation, name: "\(label)-window")
        }
        let measured = measureWindowCrop(visible)
        let count = measured?["glyphPixels"] as? Int ?? 0
        let p75 = measured?["glyphP75"] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(count, 40, "\(label): visible glyph pixels, measured \(String(describing: measured))")
        XCTAssertGreaterThanOrEqual(p75, 4.5, "\(label): glyph p75, measured \(String(describing: measured))")
        Acceptance.record(self, "\(label): \(count) glyph px, p75 \(p75)")
    }

    private func measureWindowCrop(_ region: CGRect) -> [String: Any]? {
        let window = app.windows["ww.show.window"]
        guard window.frame.contains(region),
              let image = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(image.width) / window.frame.width
        let pixels = CGRect(x: (region.minX - window.frame.minX) * scale,
                            y: (region.minY - window.frame.minY) * scale,
                            width: region.width * scale, height: region.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: pixels) else { return nil }
        return ContrastMeter.measure(NSImage(cgImage: crop, size: pixels.size))
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
