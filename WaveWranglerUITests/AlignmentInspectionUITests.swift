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
            "-WWUITestMinimumShowWindow", "YES",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.outlines["ww.alignment.groups"].waitForExistence(timeout: 5))
    }

    func testTM201ReachEveryAlignmentControl() {
        let window = app.windows["ww.show.window"]
        XCTAssertEqual(window.frame.width, 760, accuracy: 2)
        XCTAssertEqual(window.frame.height, 492, accuracy: 2)
        let group = app.staticTexts["Studio recorder"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(stateHeading("Reference").waitForExistence(timeout: 2))
        selectTargetEpoch()
        XCTAssertTrue(app.staticTexts["ww.inspector.alignment.evidence"].waitForExistence(timeout: 2))
        for identifier in [
            "alignment.analyse", "alignment.acceptProposal", "alignment.rejectProposal",
            "alignment.editNumeric", "alignment.placeAnchors", "alignment.placeAnchorAtPlayhead",
            "alignment.deleteAnchor", "alignment.startNewEpoch", "ww.alignment.audition.play",
            "ww.alignment.audition.range.start", "ww.alignment.audition.range.duration",
        ] {
            assertReachable(app.descendants(matching: .any)[identifier], in: window)
        }
    }

    func testTM202PlaceAnchorFromMenu() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        let anchorsBefore = Set(anchorFields().allElementsBoundByIndex.map(\.identifier))
        replace(app.textFields["ww.alignment.audition.range.start"], with: "0.5")
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "2")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForText("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForText("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
        chooseEpisodeMenu("Place Anchor at Playhead")
        XCTAssertTrue(waitForAnchorFieldCount(anchorsBefore.count + 1, timeout: 15))
        let anchorsAfter = anchorFields().allElementsBoundByIndex
        guard let appendedID = anchorsAfter.map(\.identifier).first(where: { !anchorsBefore.contains($0) }),
              let initial = Double(app.textFields[appendedID].value as? String ?? "")
        else { return XCTFail("Expected one newly appended numeric anchor field") }
        let appended = app.textFields[appendedID]
        let replacement = String(format: "%.3f", initial + 0.001)
        app.typeKey("a", modifierFlags: .command)
        app.typeText(replacement)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue(replacement, in: appended))
    }

    func testTM203EditAnchorTimeNumerically() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        selectAnchorRow(0)
        app.typeKey(.return, modifierFlags: [])
        let aligned = app.textFields["ww.alignment.anchor.0.alignedTime"]
        XCTAssertTrue(aligned.waitForExistence(timeout: 2))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("0.125")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("0.125", in: app.textFields["ww.alignment.anchor.0.alignedTime"]))
        selectAnchorRow(0)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForAnyValue(["0", "0.000"], in: app.textFields["ww.alignment.anchor.0.alignedTime"]))
    }

    func testTM204DeleteAnchorCommandIsKeyboardReachable() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        selectAnchorRow(1)
        app.typeKey(.delete, modifierFlags: [])
        let confirmation = app.sheets.buttons["Delete Anchor"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        let anchors = app.outlines["ww.alignment.anchors"]
        XCTAssertTrue(waitForRowCount(0, in: anchors, timeout: 15))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForRowCount(2, in: anchors, timeout: 15))
    }

    func testTM205CorrectEpochNumericallyReturnAndEscape() {
        selectTargetEpoch()
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let rate = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 2))
        rate.typeKey("a", modifierFlags: .command)
        rate.typeText("12.5")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let preserved = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(preserved.waitForExistence(timeout: 2))
        XCTAssertEqual(preserved.value as? String, "12.500")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTM206AcceptProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
    }

    func testTM207RejectProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Reject Proposal")
        XCTAssertTrue(stateHeading("Unsupported — not attempted").waitForExistence(timeout: 5))
    }

    func testTM208StartNewEpochCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        replace(app.textFields["alignment.anchors.second.source"], with: "0.5")
        replace(app.textFields["alignment.anchors.second.aligned"], with: "0.5")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        selectAnchorRow(1)
        chooseEpisodeMenu("Start New Epoch at Anchor")
        XCTAssertTrue(waitForText("Started Epoch 3", in: app.staticTexts["alignment.status"], timeout: 15))
        let epoch = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Epoch 3", "Epoch 3"
        )).firstMatch
        XCTAssertTrue(epoch.waitForExistence(timeout: 5))
    }

    func testTM209AuditionAndStopShortcuts() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "2")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForText("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForText("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
    }

    func testTM210BlockedStateAndRemedyAreLabelled() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.start"], with: "2.5")
        let heading = app.staticTexts["ww.alignment.region.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 2))
        XCTAssertEqual(heading.value as? String, "Gap — clock restarted")
        XCTAssertTrue(app.buttons["Go to Epoch After"].exists)
    }

    func testTM211DependentsNoticeIsReadableWithoutFocusMove() {
        selectTargetEpoch()
        let notice = app.staticTexts["ww.alignment.dependents"]
        makeReachable(notice)
        guard let total = dependentTotal(from: notice) else {
            return XCTFail("Expected current dependent count, got \(text(of: notice))")
        }
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(
            waitForStaleDependents(in: notice, previousTotal: total, timeout: 15),
            "Expected an affected dependent to become stale, got \(text(of: notice))"
        )
    }

    func testTM212NoRecorderGroupBlockedPanel() throws {
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
        guard UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0 else {
            throw XCTSkip("Tab-only recovery requires system Full Keyboard Access")
        }
        XCTAssertTrue(tabToFocus(goToSetup))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.tables["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    func testAlignmentWindowSmokeAndResize() throws {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.exists)
        window.doubleClick()
        let contentInspector = app.descendants(matching: .any)["ww.show.contentInspector"]
        let sidebar = app.descendants(matching: .any)["ww.show.sidebar.episodes"]
        let newEpisode = app.buttons["New Episode"]
        XCTAssertTrue(contentInspector.waitForExistence(timeout: 2))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        XCTAssertTrue(newEpisode.waitForExistence(timeout: 2))
        var layoutContainerFindings = 0
        try app.performAccessibilityAudit(
            for: [.elementDetection, .sufficientElementDescription, .hitRegion, .action]
        ) { issue in
            guard issue.auditType == .sufficientElementDescription,
                  let element = issue.element,
                  element.elementType == .group
            else { return false }
            let isContent = self.approximatelyEqual(element.frame, contentInspector.frame)
            let isSidebar = self.approximatelyEqual(element.frame, sidebar.frame)
            guard isContent || isSidebar else { return false }
            layoutContainerFindings += 1
            print(
                "AUDIT WAIVED [show-layout-container] \(issue.compactDescription) — " +
                "noninteractive container whose labeled children remain exposed"
            )
            return true
        }
        XCTAssertLessThanOrEqual(layoutContainerFindings, 2)
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
        let window = app.windows["ww.show.window"]
        let titlebarBottom = window.frame.minY + 56
        var titlebarFindings = 0
        try app.performAccessibilityAudit(for: [.contrast]) { issue in
            guard issue.auditType == .contrast, let element = issue.element,
                  element.elementType == .staticText,
                  (element.value as? String ?? element.label) == "Empty Alignment",
                  element.frame.maxY <= titlebarBottom
            else { return false }
            titlebarFindings += 1
            print("AUDIT WAIVED [blocked-titlebar] \(issue.compactDescription) — AppKit window title outside the blocked content")
            return true
        }
        XCTAssertLessThanOrEqual(titlebarFindings, 1)
    }

    private func chooseEpisodeMenu(_ item: String) {
        app.menuBars.menuBarItems["Episode"].click()
        app.menuItems[item].click()
    }

    private func selectAnchorRow(_ index: Int) {
        let scroll = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<12 {
            scroll.swipeDown()
        }
        let table = app.outlines["ww.alignment.anchors"]
        let window = app.windows["ww.show.window"]
        for _ in 0..<12 where !table.frame.intersects(window.frame) {
            scroll.swipeUp()
        }
        XCTAssertTrue(table.frame.intersects(window.frame))
        let rows = table.descendants(matching: .outlineRow)
        XCTAssertGreaterThan(rows.count, index)
        let row = rows.element(boundBy: index)
        XCTAssertGreaterThan(row.frame.width, 0)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
    }

    private func selectTargetEpoch() {
        let state = stateHeading("Proposed — not confirmed")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        state.click()
    }

    private func stateHeading(_ heading: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", heading, heading
        )).firstMatch
    }

    private func replace(_ field: XCUIElement, with text: String) {
        makeReachable(field)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        field.typeKey(.return, modifierFlags: [])
    }

    private func waitForText(
        _ prefix: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func dependentTotal(from element: XCUIElement) -> Int? {
        let value = text(of: element)
        guard value.contains(" dependent job"), value.hasSuffix(" current; none stale."),
              let first = value.split(separator: " ").first
        else { return nil }
        return Int(first)
    }

    private func waitForStaleDependents(
        in element: XCUIElement,
        previousTotal: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let parts = text(of: element).split(separator: " ")
            if parts.count >= 4, let stale = Int(parts[0]), parts[1] == "of",
               let total = Int(parts[2]), stale > 0, total >= previousTotal, total >= stale,
               text(of: element).hasSuffix("stale.") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func makeReachable(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scroll = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<12 where !element.exists || !element.isHittable {
            if element.exists, element.frame.midY < scroll.frame.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        XCTAssertTrue(element.exists, "\(element.identifier) exists after scrolling", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(element.identifier) is hittable after scrolling", file: file, line: line)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private func assertReachable(
        _ element: XCUIElement,
        in window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        makeReachable(element, file: file, line: line)
        XCTAssertTrue(
            window.frame.intersects(element.frame),
            "\(element.identifier) is reachable by scrolling",
            file: file,
            line: line
        )
        if element.isEnabled {
            XCTAssertTrue(element.isHittable, "\(element.identifier) is hittable", file: file, line: line)
        }
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
            if table.descendants(matching: .outlineRow).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return table.descendants(matching: .outlineRow).count == count
    }

    private func anchorFields() -> XCUIElementQuery {
        app.textFields.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "ww.alignment.anchor."
        ))
    }

    private func waitForAnchorFieldCount(
        _ count: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if anchorFields().count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return anchorFields().count == count
    }

}
