import XCTest

@MainActor
final class WaveformNavigationUITests: XCTestCase {
    func testTimelineSlidersExposeNativeValuesAndReceiveKeyboardInput() throws {
        let app = launch("Native timeline sliders")
        defer { app.terminate() }
        XCTAssertTrue(tracks(in: app).firstMatch.waitForExistence(timeout: 20))
        let playhead = app.textFields["alignment.waveforms.playhead"].value as? String
        for identifier in ["alignment.waveforms.zoom", "alignment.waveforms.laneHeight"] {
            let slider = app.sliders[identifier]
            reveal(slider, in: app)
            XCTAssertTrue(slider.isEnabled && slider.isHittable)
            let thumb = slider.descendants(matching: .valueIndicator).firstMatch
            XCTAssertTrue(thumb.exists)
            if let value = thumb.value as? NSNumber {
                XCTAssertTrue(value.doubleValue.isFinite)
            } else {
                XCTAssertFalse(try XCTUnwrap(thumb.value as? String).isEmpty)
            }
            slider.adjust(toNormalizedSliderPosition: 0.6)
            XCTAssertEqual(slider.normalizedSliderPosition, 0.6, accuracy: 0.03)
            slider.click()
            let before = slider.normalizedSliderPosition
            slider.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertGreaterThan(slider.normalizedSliderPosition, before)
            slider.dragHorizontalSliderToMaximum()
            let maximum = identifier == "alignment.waveforms.zoom" ? 1.0 : 220.0
            XCTAssertEqual(try XCTUnwrap(slider.value as? NSNumber).doubleValue, maximum, accuracy: 0.000001)
            XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playhead)
        }
        let visible = try viewport(in: app)
        let position = app.textFields["alignment.waveforms.playhead"]
        reveal(position, in: app)
        position.click()
        position.typeKey("a", modifierFlags: .command)
        position.typeText("\(visible.start + visible.duration / 2)")
        position.typeKey(.return, modifierFlags: [])
        let handle = app.steppers["alignment.waveforms.ruler.playhead"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5),
                      "The visible playhead remains an actual adjustable accessibility control: \(app.debugDescription)")
        XCTAssertEqual(handle.label, "Aligned playhead")
        XCTAssertEqual(handle.frame.width, 20, accuracy: 1)
        XCTAssertEqual(handle.frame.height, 44, accuracy: 1)
        XCTAssertTrue(app.windows["ww.show.window"].frame.contains(handle.frame))
        let surface = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        XCTAssertEqual(handle.frame.midX, surface.frame.midX, accuracy: 2,
                       "The accessibility frame must follow the visible playhead, not remain at the ruler origin")
    }

    func testNativeScrollAxesPanZoomResizeAndKeepVerticalScrolling() throws {
        let app = launch("Native scroll", minimum: true)
        defer { app.terminate() }
        let track = tracks(in: app).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 20), app.debugDescription)
        reveal(track, in: app)
        let before = try viewport(in: app)
        let playhead = app.textFields["alignment.waveforms.playhead"].value as? String
        let height = track.frame.height
        track.scroll(byDeltaX: -40, deltaY: 0)
        XCTAssertTrue(wait { (try? self.viewport(in: app).start) != before.start }, app.debugDescription)
        let panned = try viewport(in: app)
        XCTAssertEqual(panned.duration, before.duration, accuracy: 0.002)
        XCTAssertEqual(track.frame.height, height, accuracy: 1)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playhead)
        XCUIElement.perform(withKeyModifiers: [.option]) {
            track.scroll(byDeltaX: 20, deltaY: 0)
        }
        XCTAssertTrue(wait { (try? self.viewport(in: app).duration) != panned.duration }, app.debugDescription)
        let zoomed = try viewport(in: app)
        XCTAssertEqual(zoomed.start + zoomed.duration / 2, panned.start + panned.duration / 2,
                       accuracy: 0.15, "Option-horizontal zoom is anchored at the pointer over the track")
        XCTAssertEqual(track.frame.height, height, accuracy: 1)
        XCUIElement.perform(withKeyModifiers: [.option]) {
            track.scroll(byDeltaX: 0, deltaY: 8)
        }
        XCTAssertTrue(wait { abs(track.frame.height - height) > 2 }, app.debugDescription)
        let resized = track.frame.height
        XCTAssertEqual(try viewport(in: app).start, zoomed.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomed.duration, accuracy: 0.002)
        let oldY = track.frame.minY
        track.scroll(byDeltaX: 0, deltaY: -100)
        XCTAssertTrue(wait { abs(track.frame.minY - oldY) > 5 },
                      "Ordinary vertical scrolling must still move the workspace, not resize or pan time")
        XCTAssertEqual(track.frame.height, resized, accuracy: 1)
        XCTAssertEqual(try viewport(in: app).start, zoomed.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomed.duration, accuracy: 0.002)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playhead)
        capture(app, name: "Native scroll axes preserve timeline and ordinary vertical scrolling")
    }

    func testEditingAnotherMarkersBoundaryKeepsItsSelectionZoomAndViewportThroughUndoRedo() throws {
        let app = launch("Marker viewport")
        defer { app.terminate() }
        let track = tracks(in: app).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 20), app.debugDescription)
        reveal(track, in: app)
        let recordingSidebar = app.buttons["ww.sidebar.recording"]
        if recordingSidebar.value as? String == "Shown" { recordingSidebar.click() }
        let playhead = app.textFields["alignment.waveforms.playhead"]
        reveal(playhead, in: app)
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("2.25")
        playhead.typeKey(.return, modifierFlags: [])
        let zoom = app.sliders["alignment.waveforms.zoom"]
        reveal(zoom, in: app)
        zoom.dragHorizontalSliderToMaximum()
        XCTAssertEqual(try XCTUnwrap(zoom.value as? NSNumber).doubleValue, 1, accuracy: 0.000001)
        // Zoom preserves the viewport center; pan both starts into view before testing an edit.
        let zoomedWindow = try viewport(in: app)
        let centeredStart = 2.25 - zoomedWindow.duration / 2
        let ruler = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        let pan = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.8))
        pan.click(forDuration: 0.1, thenDragTo: pan.withOffset(CGVector(
            dx: (zoomedWindow.start - centeredStart) / zoomedWindow.duration * ruler.frame.width,
            dy: 0)))
        XCTAssertEqual(try viewport(in: app).start, centeredStart, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomedWindow.duration, accuracy: 0.002)
        XCTAssertEqual(playhead.value as? String, "2.250", "Setup pans without seeking or changing zoom")
        let markers = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.' AND identifier ENDSWITH '.start'"))
        XCTAssertTrue(wait { markers.count == 2 }, app.debugDescription)
        let previous = markers.element(boundBy: 0)
        let previousHandleID = previous.identifier
        let previousRegionID = String(previousHandleID.dropLast(".start".count))
        previous.click()
        XCTAssertEqual(app.buttons["ww.sidebar.transcript"].value as? String, "Hidden",
                       "Compact marker review must not open a sidebar and resize the timeline")
        app.typeKey(.escape, modifierFlags: [])
        reveal(playhead, in: app)
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("2.15")
        playhead.typeKey(.return, modifierFlags: [])
        let edited = markers.matching(NSPredicate(format: "identifier != %@", previousHandleID)).firstMatch
        reveal(edited, in: app)
        let id = edited.identifier
        XCTAssertNotEqual(id, previousHandleID, "The regression must edit a different marker")
        let originalValue = edited.value as? String
        let originalX = edited.frame.midX
        let oldViewport = try viewport(in: app)
        let oldPlayhead = playhead.value as? String
        let point = edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.click(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 18, dy: 0)))
        XCTAssertTrue(wait { edited.value as? String != originalValue }, app.debugDescription)
        XCTAssertGreaterThan(edited.frame.midX, originalX + 10)
        XCTAssertEqual(edited.identifier, id, "The edited marker must remain active rather than reverting to the earlier selection")
        XCTAssertEqual(try viewport(in: app).start, oldViewport.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, oldViewport.duration, accuracy: 0.002)
        XCTAssertEqual(playhead.value as? String, oldPlayhead, "A boundary edit is not a seek")
        XCTAssertEqual(app.buttons["ww.sidebar.transcript"].value as? String, "Hidden",
                       "Boundary edits preserve the user's sidebar visibility")
        let changedValue = edited.value as? String
        let editedRegion = app.buttons[String(id.dropLast(".start".count))]
        let previousRegion = app.buttons[previousRegionID]
        let reject = app.buttons["ww.cleanup.filler.reject"]
        reveal(reject, in: app)
        reject.click()
        XCTAssertTrue(wait { editedRegion.label.contains("Not a filler") },
                      "Compact review actions must follow the actively edited marker, not the stale selection\n\(app.debugDescription)")
        XCTAssertFalse(previousRegion.label.contains("Not a filler"))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { !editedRegion.label.contains("Not a filler") })
        XCTAssertEqual(edited.value as? String, changedValue, "Undoing review does not undo the boundary edit")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { edited.value as? String == originalValue }, app.debugDescription)
        XCTAssertEqual(try viewport(in: app).start, oldViewport.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, oldViewport.duration, accuracy: 0.002)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { edited.value as? String == changedValue }, app.debugDescription)
        XCTAssertEqual(try viewport(in: app).start, oldViewport.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, oldViewport.duration, accuracy: 0.002)
        XCTAssertEqual(playhead.value as? String, oldPlayhead)
        capture(app, name: "Edited marker stays in place through Undo and Redo")
    }

    private func launch(_ name: String, minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", name,
            "-WWUITestShowFolder", "WWUITests-WaveformNavigation-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES",
        ]
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        return app
    }

    private func tracks(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
    }

    private func viewport(in app: XCUIApplication) throws -> (start: Double, duration: Double) {
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let numbers = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(numbers.count, 2, ruler.debugDescription)
        let start = try XCTUnwrap(numbers.first)
        let end = try XCTUnwrap(numbers.last)
        return (start, end - start)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<12 {
            if element.isHittable, scroll.frame.contains(element.frame) { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY > scroll.frame.midY ? -100 : 100)
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
