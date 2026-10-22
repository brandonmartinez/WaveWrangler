import XCTest

@MainActor
final class WaveformNavigationUITests: XCTestCase {
    func testFillSpaceDropdownAndConsolidatedToolbar() throws {
        let app = launch("Fitted tracks", singlePrimary: true)
        defer { app.terminate() }
        XCTAssertTrue(tracks(in: app).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        let sidebar = app.buttons["ww.sidebar.recording"]
        if sidebar.value as? String == "Shown" { sidebar.click() }
        let picker = app.popUpButtons["alignment.waveforms.layout"]
        XCTAssertTrue(picker.isHittable)
        picker.click()
        let options = ["By recorder", "By speaker", "Overlay", "Speakers only"].map { picker.menuItems[$0] }
        XCTAssertTrue(options.allSatisfy(\.exists))
        XCTAssertEqual(options.map(\.frame.minY), options.map(\.frame.minY).sorted())
        app.typeKey(.escape, modifierFlags: [])
        selectTimelineLayout("Speakers only", in: app)
        let fit = app.descendants(matching: .any)["alignment.waveforms.fillSpace"]
        XCTAssertTrue(fit.isHittable, app.debugDescription)
        fit.click()
        let track = tracks(in: app).firstMatch
        XCTAssertTrue(wait { track.frame.height > 220 }, app.debugDescription)
        let scroll = app.scrollViews["ww.alignment.workspace"]
        XCTAssertEqual(scroll.scrollBars.count, 0, "Fitted rows use the viewport without a vertical scrollbar")
        let fittedHeight = track.frame.height
        selectTimelineLayout("By recorder", in: app)
        XCTAssertTrue(wait { track.frame.height >= 64 && track.frame.height < fittedHeight })
        selectTimelineLayout("Overlay", in: app)
        XCTAssertTrue(app.sliders["alignment.waveforms.laneHeight"].exists == false)
        selectTimelineLayout("Speakers only", in: app)
        XCTAssertTrue(wait { track.frame.height > 220 })
        let slider = app.sliders["alignment.waveforms.laneHeight"]
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(wait {
            guard let value = slider.value as? NSNumber else { return false }
            return abs(track.frame.height - value.doubleValue) <= 1.5
        },
                      "Manual slider=\(String(describing: slider.value)), row height=\(track.frame.height), fit=\(String(describing: fit.value))")
        XCTAssertEqual(String(describing: fit.value ?? ""), "0")
        let play = app.buttons["alignment.waveforms.transport.play"]
        let cycle = app.buttons["ww.timeline.cycle"]
        XCTAssertEqual(cycle.label, "Cycle")
        XCTAssertEqual(cycle.frame.midY, play.frame.midY, accuracy: 2)
        XCTAssertLessThan(cycle.frame.width, 50, "Cycle is icon-only")
        let workflow = app.buttons["ww.workflow.alignTracks"]
        let transcribe = app.buttons["ww.workflow.transcribeTracks"]
        XCTAssertEqual(app.buttons.matching(identifier: "ww.workflow.alignTracks").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "ww.workflow.transcribeTracks").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "alignment.waveforms.load").count, 1)
        XCTAssertLessThan(picker.frame.maxX, workflow.frame.minX)
        XCTAssertLessThan(workflow.frame.maxX, transcribe.frame.minX)
        let refresh = app.buttons["alignment.waveforms.load"]
        let tool = app.menuButtons["alignment.waveforms.tool"]
        XCTAssertTrue(refresh.isHittable && tool.isHittable && transcribe.isHittable)
        XCTAssertGreaterThan(refresh.frame.maxX, tool.frame.maxX)
        let chrome = app.descendants(matching: .any)["alignment.waveforms.controls"]
        XCTAssertLessThan(chrome.frame.maxX - refresh.frame.maxX, 30, "Refresh is at the trailing edge")
        capture(app, name: "Selected-view dropdown and single trailing control group")
        fit.click()
        XCTAssertTrue(wait { track.frame.height > 220 })
        app.typeKey("s", modifierFlags: .command)
        let arguments = app.launchArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "-WWUITestShowFolder"))
        let file = "\(arguments[index + 1])/Fitted tracks.wwshow"
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenWithoutShowWindows", file]
        app.launch()
        app.activate()
        XCTAssertTrue(fit.waitForExistence(timeout: 20))
        XCTAssertEqual(String(describing: fit.value ?? ""), "1", "Fill Space is remembered per episode")
    }

    func testCycleStripCreatesSharedRangeWithoutHijackingRulerGestures() throws {
        let app = launch("Ruler cycle")
        defer { app.terminate() }
        XCTAssertTrue(tracks(in: app).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let area = app.descendants(matching: .any)["alignment.waveforms.ruler.cycleArea"]
        XCTAssertTrue(area.isHittable)
        let before = try viewport(in: app)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let originalTime = playhead.value as? String
        let start = area.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = area.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(wait { app.buttons["ww.timeline.cycle"].value as? String == "On" }, app.debugDescription)
        XCTAssertTrue(area.label.contains(" to "), app.debugDescription)
        XCTAssertEqual(playhead.value as? String, originalTime, "Cycle creation is not a seek")
        XCTAssertEqual(try viewport(in: app).start, before.start, accuracy: 0.002)
        XCTAssertTrue(app.buttons["ww.timeline.selection.actions"].exists
            || app.descendants(matching: .any)["ww.timeline.selection.actions"].exists)
        let surface = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        let originalRange = area.label
        let locator = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 36.0 / 44.0))
        locator.click(forDuration: 0.1,
                      thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 36.0 / 44.0)))
        XCTAssertNotEqual(area.label, originalRange, "Existing cycle locators still edit the shared range")
        XCTAssertEqual(playhead.value as? String, originalTime, "Locator editing is not a seek")
        let cycleRange = area.label
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.25)).click()
        XCTAssertNotEqual(playhead.value as? String, originalTime, "The upper ruler still seeks")
        XCTAssertEqual(area.label, cycleRange)
        let beforeScrub = playhead.value as? String
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.25)).click(forDuration: 0.1,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.25)))
        XCTAssertNotEqual(playhead.value as? String, beforeScrub, "Dragging the upper playhead still scrubs")
        XCTAssertEqual(try viewport(in: app).start, before.start, accuracy: 0.002, "Scrubbing is not panning")
        XCTAssertEqual(area.label, cycleRange)
        let pan = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25))
        pan.click(forDuration: 0.1, thenDragTo: pan.withOffset(CGVector(dx: -50, dy: 0)))
        XCTAssertTrue(wait { (try? self.viewport(in: app).start) != before.start })
        XCTAssertEqual(area.label, cycleRange, "Upper-ruler panning does not redefine the loop")
        XCTAssertEqual(app.buttons["alignment.waveforms.followPlayhead"].value as? String, "Off")
        capture(app, name: "Dedicated cycle creation strip preserves ruler navigation")
    }

    func testFollowPagesDuringPlaybackAndManualPanRequiresExplicitEnable() throws {
        let app = launch("Paged playback")
        defer { app.terminate() }
        XCTAssertTrue(tracks(in: app).firstMatch.waitForExistence(timeout: 20))
        let follow = app.buttons["alignment.waveforms.followPlayhead"]
        XCTAssertEqual(follow.value as? String, "On")
        let zoom = app.sliders["alignment.waveforms.zoom"]
        zoom.dragHorizontalSliderToMaximum()
        let playhead = app.textFields["alignment.waveforms.playhead"]
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("1")
        playhead.typeKey(.return, modifierFlags: [])
        let old = try viewport(in: app)
        let play = app.buttons["alignment.waveforms.transport.play"]
        play.click()
        XCTAssertTrue(wait { play.label == "Pause" })
        XCTAssertTrue(wait { (try? self.viewport(in: app).start) ?? old.start > old.start })
        XCTAssertEqual(play.label, "Pause", "Following does not stop playback")
        let track = tracks(in: app).firstMatch
        track.scroll(byDeltaX: -400, deltaY: 0)
        XCTAssertTrue(wait { follow.value as? String == "Off" })
        let manual = try viewport(in: app)
        follow.click()
        XCTAssertEqual(follow.value as? String, "On")
        XCTAssertEqual(play.label, "Pause")
        XCTAssertTrue(wait { (try? self.viewport(in: app).start) != manual.start })
        play.click()
        follow.click()
        XCTAssertEqual(follow.value as? String, "Off")
        app.typeKey("s", modifierFlags: .command)
        let arguments = app.launchArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "-WWUITestShowFolder"))
        let file = "\(arguments[index + 1])/Paged playback.wwshow"
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenWithoutShowWindows", file]
        app.launch()
        app.activate()
        XCTAssertTrue(follow.waitForExistence(timeout: 20))
        XCTAssertEqual(follow.value as? String, "Off", "The explicit follow choice is saved per episode")
    }

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
                      "Saved vertical position must be restored after waveform tracks finish loading: \(scrolledFrame) -> \(track.frame), scroll \(app.scrollViews["ww.alignment.workspace"].frame)")
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

    private func launch(_ name: String, minimum: Bool = false, singlePrimary: Bool = false) -> XCUIApplication {
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
        if singlePrimary { app.launchArguments += ["-WWUITestSinglePrimaryFixture", "YES"] }
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
