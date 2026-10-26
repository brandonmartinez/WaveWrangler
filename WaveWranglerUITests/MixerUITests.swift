import XCTest

@MainActor
final class MixerUITests: XCTestCase {
    private func launch(minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Mixer UI Fixture",
            "-WWUITestShowFolder", "WWUITests-Mixer-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestCleanupFixture", "YES", "-WWUITestCleanupTimelineFixture", "YES",
            "-WWUITestTranscriptFixture", "YES",
        ]
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.mixer.toggle"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    func testReviewMixerResizeDetachReattachAndOriginClose() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.review.toggle"].click()
        let review = app.descendants(matching: .any)["ww.review.panel"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        let before = review.frame.height
        let divider = app.splitGroups.splitters.firstMatch
        if divider.exists && divider.isHittable {
            let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.click(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: -30)))
        }
        app.buttons["ww.mixer.toggle"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.mixer.docked"].waitForExistence(timeout: 10))
        XCTAssertFalse(review.exists)
        app.buttons["ww.mixer.detach"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mixer.title.contains("Mixer"))
        app.buttons["ww.mixer.focusDetached"].click()
        XCTAssertEqual(app.windows.matching(identifier: "ww.mixer.window").count, 1)
        mixer.buttons["ww.mixer.reattach"].click()
        XCTAssertTrue(wait { !mixer.exists })
        XCTAssertTrue(app.descendants(matching: .any)["ww.mixer.docked"].exists)
        app.buttons["ww.review.toggle"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(review.frame.height, before - 40)
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.mixer.detach"].click()
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let origin = app.windows["ww.show.window"]
        origin.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !mixer.exists }, "An auxiliary mixer must not outlive its originating editor.")
    }

    func testMasterRemainsVisibleWhileSpeakerStripsScrollAtMinimumWidth() {
        let app = launch(minimum: true)
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        let master = app.descendants(matching: .any)["ww.mixer.strip.master.name"]
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        let frame = master.frame
        let speakers = app.scrollViews["ww.mixer.speakers"]
        XCTAssertTrue(speakers.exists)
        speakers.scroll(byDeltaX: 350, deltaY: 0)
        XCTAssertTrue(master.isHittable, app.debugDescription)
        XCTAssertEqual(master.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(master.frame.width, frame.width, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pinned Master and horizontally scrolled speaker strips"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testGenericAppleEditorDirtyUndoSaveAndDetachedCloseReopen() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.mixer.detach"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let add = mixer.descendants(matching: .any)["ww.mixer.strip.master.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.click()
        let lowpass = app.menuItems["AULowpass"]
        XCTAssertTrue(lowpass.waitForExistence(timeout: 5), app.debugDescription)
        lowpass.click()
        let actions = mixer.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.actions'")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5), app.debugDescription)
        actions.click()
        app.menuItems["Generic Parameters"].click()
        let editor = app.windows["ww.mixer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        let value = editor.textFields["ww.mixer.parameter.0"]
        XCTAssertTrue(value.waitForExistence(timeout: 10), app.debugDescription)
        value.click()
        value.typeKey("a", modifierFlags: .command)
        value.typeText("1000")
        value.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(wait { (value.value as? String)?.contains("1000") == true || (value.value as? String)?.contains("1,000") == true },
                      "Parameter field: \(String(describing: value.value)). \(app.debugDescription)")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true },
                      app.debugDescription)
        editor.buttons["ww.mixer.editor.done"].click()
        XCTAssertTrue(wait { !editor.exists })
        mixer.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !mixer.exists })
        app.buttons["ww.mixer.detach"].click()
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let open = mixer.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.editor'")).firstMatch
        open.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !editor.exists })
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.staticTexts["ww.mixer.error"].exists, app.debugDescription)
    }
}
