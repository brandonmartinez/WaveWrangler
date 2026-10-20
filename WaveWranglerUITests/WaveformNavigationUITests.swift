import AppKit
import ApplicationServices
import XCTest

@MainActor
final class WaveformNavigationUITests: XCTestCase {
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
        zoom.adjust(toNormalizedSliderPosition: 1)
        let markers = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.' AND identifier ENDSWITH '.start'"))
        XCTAssertTrue(wait { markers.count == 2 }, app.debugDescription)
        let previous = markers.element(boundBy: 0)
        let previousRegionID = String(previous.identifier.dropLast(".start".count))
        previous.click()
        XCTAssertEqual(app.buttons["ww.sidebar.transcript"].value as? String, "Hidden",
                       "Compact marker review must not open a sidebar and resize the timeline")
        app.typeKey(.escape, modifierFlags: [])
        reveal(playhead, in: app)
        playhead.click()
        playhead.typeKey("a", modifierFlags: .command)
        playhead.typeText("2.15")
        playhead.typeKey(.return, modifierFlags: [])
        let edited = markers.element(boundBy: 1)
        reveal(edited, in: app)
        let id = edited.identifier
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
        let hittable = element.isHittable
        if !hittable {
            capture(app, name: "Unavailable marker action before coordinate diagnostic")
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.brandonmartinez.wavewrangler")
            if applications.count == 1, let application = applications.first {
                var hit: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(
                    AXUIElementCreateApplication(application.processIdentifier),
                    Float(element.frame.midX), Float(element.frame.midY), &hit)
                var details = "hit result=\(result), trusted=\(AXIsProcessTrusted())\n"
                if let hit {
                    for attribute in [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
                                      kAXDescriptionAttribute, "AXActivationPoint"] {
                        var value: CFTypeRef?
                        let status = AXUIElementCopyAttributeValue(hit, attribute as CFString, &value)
                        details += "\(attribute): \(status), \(String(describing: value))\n"
                    }
                }
                let hitAttachment = XCTAttachment(string: details)
                hitAttachment.name = "Marker action native accessibility hit"
                hitAttachment.lifetime = .keepAlways
                add(hitAttachment)
            }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            capture(app, name: "Unavailable marker action after coordinate diagnostic")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Marker action coordinate diagnostic"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(hittable, element.debugDescription)
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
