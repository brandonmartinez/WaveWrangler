import XCTest

@MainActor
final class TranscriptReviewSafetyUITests: XCTestCase {
    func testCleanupRemainsScrollableAndRecoverableAtMinimumWindow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestMinimumShowWindow", "YES",
            "-WWUITestOpenShow", "Minimum Cleanup Fixture",
            "-WWUITestShowFolder", "WWUITests-Cleanup-Minimum-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.cleanup.heading"].waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 760, accuracy: 2)
        XCTAssertFalse(app.buttons["ww.cleanup.transcribe"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15))
        let scroll = app.scrollViews["ww.cleanup.workspace"]
        XCTAssertTrue(scroll.exists)
        XCTAssertLessThanOrEqual(scroll.frame.height, window.frame.height)
        XCTAssertTrue(window.frame.contains(scroll.frame), app.debugDescription)
        for id in ["ww.cleanup.transport.play", "ww.cleanup.tool.in", "ww.cleanup.tool.out",
                   "ww.cleanup.range.markIn", "ww.cleanup.range.markOut", "ww.cleanup.zoom",
                   "ww.cleanup.laneHeight"] {
            let control = app.descendants(matching: .any)[id]
            XCTAssertTrue(control.exists, id)
            XCTAssertGreaterThanOrEqual(control.frame.minX, scroll.frame.minX, id)
            XCTAssertLessThanOrEqual(control.frame.maxX, scroll.frame.maxX, id)
        }
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.cleanup.heading"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["ww.review.action.acceptShorten"].exists,
                       "The retired synthetic acceptance shell is not exposed")
    }
}
