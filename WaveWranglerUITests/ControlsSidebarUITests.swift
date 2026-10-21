import XCTest

@MainActor
final class ControlsSidebarUITests: XCTestCase {
    func testDefaultWorkspaceActivityTogglesKeepDetailedAlignmentOffTheCanvas() {
        exerciseSidebars(minimumSize: false)
    }

    func testMinimumWorkspaceKeepsActivityTogglesToolsAndListeningPresetsReachable() {
        exerciseSidebars(minimumSize: true)
    }

    func testCommandReviewToolIsTemporaryAndMarkerUsesOneCenteredToolbar() throws {
        let app = launch()
        defer { app.terminate() }
        let candidate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.' AND label CONTAINS 'Um,'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 20), app.debugDescription)
        let region = app.buttons[candidate.identifier]
        app.menuButtons["alignment.waveforms.commandTool"].click()
        app.menuItems["Reject"].click()
        let primary = app.menuButtons["alignment.waveforms.tool"]
        XCTAssertEqual(primary.value as? String, "Pointer")
        reveal(region, in: app)
        XCUIElement.perform(withKeyModifiers: .command) { region.click() }
        XCTAssertTrue(wait { region.label.contains("Not a filler") }, app.debugDescription)
        XCTAssertEqual(primary.value as? String, "Pointer", "Command-click must not reassign the primary tool.")
        let actions = app.descendants(matching: .any).matching(identifier: "ww.timeline.selection.actions")
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.count, 1, "Only the selected region owns the compact toolbar.")
        XCTAssertEqual(app.popovers.count, 0, "Marker review no longer opens a second detailed popup.")
        XCTAssertFalse(app.textFields["ww.cleanup.filler.start.seconds"].exists)
        XCTAssertFalse(app.textFields["ww.cleanup.filler.end.seconds"].exists)
        let rails = app.descendants(matching: .any).matching(identifier: "ww.cleanup.fillers.rails").firstMatch
        let toolbar = actions.firstMatch
        XCTAssertGreaterThanOrEqual(toolbar.frame.minX, rails.frame.minX - 1)
        XCTAssertLessThanOrEqual(toolbar.frame.maxX, rails.frame.maxX + 1)
        let interval = (region.value as? String ?? "").split(separator: " ").compactMap { Double($0) }
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let visible = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(interval.count, 2)
        XCTAssertEqual(visible.count, 2)
        let midpoint = (try XCTUnwrap(interval.first) + XCTUnwrap(interval.last)) / 2
        let visibleStart = try XCTUnwrap(visible.first)
        let duration = try XCTUnwrap(visible.last) - visibleStart
        let intervalCenter = rails.frame.minX + (midpoint - visibleStart) / duration * rails.frame.width
        let center = min(max(rails.frame.minX + toolbar.frame.width / 2, intervalCenter),
                         rails.frame.maxX - toolbar.frame.width / 2)
        XCTAssertEqual(toolbar.frame.midX, center, accuracy: 2)
        app.buttons["ww.cleanup.filler.clearReview"].click()
        XCTAssertTrue(wait { region.label.contains("Pending") })
        region.click()
        XCTAssertTrue(region.label.contains("Pending"), "Releasing Command restores Pointer, not another review action.")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { region.label.contains("Not a filler") }, "Clear review is an undoable decision, not deletion.")
        app.buttons["ww.cleanup.filler.reviewed"].click()
        XCTAssertTrue(wait { region.label.contains("Reviewed unchanged") })
        XCTAssertTrue(app.buttons["ww.cleanup.filler.revert"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Single centered marker toolbar with temporary Command tool"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func exerciseSidebars(minimumSize: Bool) {
        let app = launch(minimumSize: minimumSize)
        defer { app.terminate() }
        let recording = app.buttons["ww.sidebar.recording"]
        let alignment = app.buttons["ww.sidebar.alignment"]
        let transcript = app.buttons["ww.sidebar.transcript"]
        let episode = app.buttons["ww.sidebar.episode"]
        XCTAssertTrue(recording.waitForExistence(timeout: 20), app.debugDescription)
        for toggle in [recording, alignment, transcript, episode] {
            XCTAssertTrue(toggle.isHittable, toggle.debugDescription)
        }
        XCTAssertFalse(app.outlines["ww.alignment.groups"].exists, "The recording inspector is contextual, not the detailed table.")
        alignment.click()
        XCTAssertEqual(alignment.value as? String, "Shown")
        XCTAssertEqual(recording.value as? String, "Hidden")
        XCTAssertTrue(app.outlines["ww.alignment.groups"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews["ww.inspector.alignment.details"].exists)
        alignment.click()
        XCTAssertEqual(alignment.value as? String, "Hidden")
        XCTAssertTrue(wait { !app.outlines["ww.alignment.groups"].exists })
        episode.click()
        XCTAssertTrue(app.textFields["ww.inspector.episode.title"].waitForExistence(timeout: 5))
        transcript.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ww.transcript.full.'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(episode.value as? String, "Hidden")
        let primary = app.menuButtons["alignment.waveforms.tool"]
        reveal(primary, in: app)
        XCTAssertTrue(primary.isHittable)
        XCTAssertTrue(app.menuButtons["alignment.waveforms.commandTool"].isHittable)
        let preset = app.buttons["ww.listening.preset.soloPrimaries"]
        XCTAssertTrue(preset.isHittable)
        XCTAssertTrue(app.buttons["ww.audioWorkspace.add"].isHittable)
        preset.click()
        XCTAssertEqual(preset.value as? String, "On")
        XCTAssertTrue(app.buttons["ww.listening.restore"].exists)
        app.buttons["ww.listening.restore"].click()
        XCTAssertEqual(preset.value as? String, "Off")
        XCTAssertFalse(app.buttons["ww.listening.restore"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = minimumSize ? "Minimum window sidebar activities and listening presets" : "Default window sidebar activities"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launch(minimumSize: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Controls Sidebar Fixture",
            "-WWUITestShowFolder", "WWUITests-ControlsSidebar-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES",
        ]
        if minimumSize { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<16 {
            if element.isHittable { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? 200 : -200)
        }
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [condition], timeout: 5) == .completed
    }
}
