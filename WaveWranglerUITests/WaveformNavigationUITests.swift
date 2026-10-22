import XCTest

@MainActor
final class WaveformNavigationUITests: XCTestCase {
    func testZoomCentersOnPlayheadAfterPanningWithoutSeeking() throws {
        let app = launch("Playhead-centered zoom")
        defer { app.terminate() }
        let track = tracks(in: app).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 20), app.debugDescription)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        reveal(playhead, in: app)
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("2.25")
        playhead.typeKey(.return, modifierFlags: [])
        let zoom = app.sliders["alignment.waveforms.zoom"]
        for level in [0.4, 0.85, 0.6] {
            reveal(zoom, in: app)
            zoom.adjust(toNormalizedSliderPosition: level)
            XCTAssertTrue(wait {
                guard let window = try? self.viewport(in: app) else { return false }
                return abs(window.start + window.duration / 2 - 2.25) < 0.002
            }, "Both zoom directions keep the playhead centered: \(app.debugDescription)")
            XCTAssertEqual(playhead.value as? String, "2.250", "Zooming is not a seek")
        }
        reveal(track, in: app)
        track.scroll(byDeltaX: -300, deltaY: 0)
        let panned = try viewport(in: app)
        XCTAssertGreaterThan(abs(panned.start + panned.duration / 2 - 2.25), 0.1)
        XCUIElement.perform(withKeyModifiers: [.option]) {
            track.scroll(byDeltaX: 20, deltaY: 0)
        }
        XCTAssertTrue(wait {
            guard let window = try? self.viewport(in: app) else { return false }
            return abs(window.start + window.duration / 2 - 2.25) < 0.002
        }, "Option-scroll returns zoom to the playhead even after panning away")
        XCTAssertEqual(playhead.value as? String, "2.250")
    }

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
        let rulerSurface = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        XCTAssertEqual(rulerSurface.frame.minX, track.frame.minX, accuracy: 2)
        XCTAssertEqual(rulerSurface.frame.width, track.frame.width, accuracy: 2,
                       "The pinned ruler must use the tracks' measured width, excluding the native scroll gutter")
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
        XCTAssertEqual(zoomed.start + zoomed.duration / 2, try XCTUnwrap(Double(playhead ?? "")),
                       accuracy: 0.002, "Option-horizontal zoom centers on the playhead")
        XCTAssertEqual(track.frame.height, height, accuracy: 1)
        XCUIElement.perform(withKeyModifiers: [.option]) {
            track.scroll(byDeltaX: 0, deltaY: 8)
        }
        XCTAssertTrue(wait { abs(track.frame.height - height) > 2 }, app.debugDescription)
        let resized = track.frame.height
        XCTAssertEqual(try viewport(in: app).start, zoomed.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomed.duration, accuracy: 0.002)
        let controls = [
            app.textFields["alignment.waveforms.playhead"],
            app.sliders["alignment.waveforms.zoom"],
            app.sliders["alignment.waveforms.laneHeight"],
            app.descendants(matching: .any)["alignment.waveforms.layout"],
            app.menuButtons["alignment.waveforms.tool"],
            app.descendants(matching: .any)["alignment.waveforms.ruler.surface"],
        ]
        let fixedFrames = controls.map(\.frame)
        XCTAssertTrue(controls.allSatisfy(\.isHittable), "Track controls are reachable before scrolling")
        let oldY = track.frame.minY
        track.scroll(byDeltaX: 0, deltaY: -100)
        XCTAssertTrue(wait { abs(track.frame.minY - oldY) > 5 },
                      "Ordinary vertical scrolling must still move the workspace, not resize or pan time")
        XCTAssertEqual(track.frame.height, resized, accuracy: 1)
        XCTAssertEqual(try viewport(in: app).start, zoomed.start, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomed.duration, accuracy: 0.002)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].value as? String, playhead)
        for (control, frame) in zip(controls, fixedFrames) {
            XCTAssertTrue(control.isHittable, "\(control.identifier) stays reachable while tracks scroll")
            XCTAssertEqual(control.frame.minY, frame.minY, accuracy: 1,
                           "\(control.identifier) is anchored to the workspace chrome")
            XCTAssertEqual(control.frame.minX, frame.minX, accuracy: 1)
        }
        capture(app, name: "Native scroll axes preserve timeline and ordinary vertical scrolling")
        let scrolledFrame = track.frame
        let args = app.launchArguments
        let folderIndex = try XCTUnwrap(args.firstIndex(of: "-WWUITestShowFolder"))
        let file = "\(args[folderIndex + 1])/Native scroll.wwshow"
        app.typeKey("s", modifierFlags: .command)
        app.terminate()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestMinimumShowWindow", "YES",
            "-WWUITestOpenWithoutShowWindows", file,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(track.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(wait { abs(track.frame.minY - scrolledFrame.minY) <= 2 },
                      "Saved vertical position must be restored after waveform tracks finish loading")
        XCTAssertEqual(track.frame.height, scrolledFrame.height, accuracy: 1)
    }

    func testEditingAnotherMarkersBoundaryKeepsItsSelectionZoomAndViewportThroughUndoRedo() throws {
        let app = launch("Marker viewport")
        defer { app.terminate() }
        let track = tracks(in: app).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 20), app.debugDescription)
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
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
        let zoomedWindow = try viewport(in: app)
        let centeredStart = 2.25 - zoomedWindow.duration / 2
        XCTAssertEqual(try viewport(in: app).start, centeredStart, accuracy: 0.002)
        XCTAssertEqual(try viewport(in: app).duration, zoomedWindow.duration, accuracy: 0.002)
        XCTAssertEqual(playhead.value as? String, "2.250", "Zooming does not seek")
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
            let chrome = app.descendants(matching: .any)["alignment.waveforms.controls"]
            if element.isHittable,
               scroll.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                || chrome.frame.contains(element.frame) { return }
            let distance = element.frame.midY - scroll.frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: -min(100, max(-100, distance)))
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
