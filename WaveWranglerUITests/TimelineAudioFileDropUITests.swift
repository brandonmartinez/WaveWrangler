import AppKit
import XCTest

@MainActor
final class TimelineAudioFileDropUITests: XCTestCase {
    func testFinderDropsReachEmptyCanvasWaveformBlockAndBlankLaneAtCapturedFrames() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WW-F6-Finder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.wav"), fresh = root.appendingPathComponent("fresh.wav")
        let bytes = Self.wave()
        try bytes.write(to: first); try bytes.write(to: fresh)
        let app = launch()
        defer { app.terminate() }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(NSWorkspace.shared.open(root))
        let window = finder.windows[root.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        arrangeFinder(window, finder: finder, app: app)
        let empty = app.staticTexts["ww.audioDrop.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        let initialViewport = try viewport(app)
        drop(first.lastPathComponent, window: window, finder: finder, app: app,
             to: empty.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)))
        let start = try reviewPosition(app)
        XCTAssertEqual(start, initialViewport.start + initialViewport.duration / 2, accuracy: 1.0 / 48_000)
        XCTAssertEqual(app.popUpButtons["ww.addAudio.layout"].value as? String, "Sequential, in the order above")
        replace(app.textFields["ww.addAudio.trackName"], with: "Drop Track")
        confirmImport(app, visibleClips: 1)
        var clip = clips(app).firstMatch
        clip.click()
        XCTAssertEqual(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? .nan,
                       start, accuracy: 1.0 / 48_000)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "\(start + 1)")
        playhead.typeKey(.return, modifierFlags: [])
        app.buttons["alignment.waveforms.fitTimeline"].click()
        let fittedViewport = try viewport(app)
        app.buttons["alignment.waveforms.zoomOut"].click()
        app.buttons["alignment.waveforms.zoomOut"].click()
        let ruler = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        let pan = ruler.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.4))
        let beforePan = try viewport(app)
        XCTAssertGreaterThan(beforePan.duration, fittedViewport.duration)
        let beforePanPlayhead = try XCTUnwrap(playhead.value as? String)
        pan.click(forDuration: 0.1, thenDragTo: pan.withOffset(.init(dx: -15, dy: 0)))
        XCTAssertTrue(wait { (try? self.viewport(app).start) != beforePan.start })
        XCTAssertEqual(playhead.value as? String, beforePanPlayhead, "Panning must not scrub the playhead.")
        clip = clips(app).firstMatch
        let blockFrame = clip.frame
        let laneFrame = app.staticTexts["ww.audioDrop.newTrack"].frame
        let geometryEvidence = XCTAttachment(string: "Native clip AX frame: \(blockFrame); lane canvas: \(laneFrame)")
        geometryEvidence.name = "F6 visible block versus lane geometry before the exact midpoint drop"
        geometryEvidence.lifetime = .keepAlways
        add(geometryEvidence)
        XCTAssertGreaterThan(blockFrame.width, 30)
        XCTAssertGreaterThan(blockFrame.minX, app.windows["ww.show.window"].frame.minX + 190)
        XCTAssertLessThan(blockFrame.width, laneFrame.width, "A clip's native AX frame must not cover the whole lane.")
        XCTAssertGreaterThan(blockFrame.minX, laneFrame.minX)
        XCTAssertLessThan(blockFrame.maxX, laneFrame.maxX)
        drop(first.lastPathComponent, window: window, finder: finder, app: app,
             to: clip.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)))
        XCTAssertEqual(try reviewPosition(app), start + 1, accuracy: 1.0 / 48_000)
        XCTAssertEqual(app.popUpButtons["ww.addAudio.track"].value as? String, "Drop Track")
        XCTAssertFalse(app.textFields["ww.addAudio.trackName"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "Reuse this episode", "Reuse this episode")).firstMatch.exists)
        app.buttons["ww.addAudio.cancel"].click()
        XCTAssertTrue(wait { !app.buttons["ww.addAudio.import"].exists })
        XCTAssertEqual(clips(app).count, 1)
        drop(fresh.lastPathComponent, window: window, finder: finder, app: app,
             to: clip.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)))
        XCTAssertEqual(try reviewPosition(app), start + 1, accuracy: 1.0 / 48_000)
        confirmImport(app, visibleClips: 2)
        let original = clips(app).matching(NSPredicate(format: "identifier == %@", clip.identifier)).firstMatch
        let blankOffset = min(36, ruler.frame.maxX - original.frame.maxX - 10)
        XCTAssertGreaterThan(blankOffset, 2)
        let blank = original.coordinate(withNormalizedOffset: .init(dx: 1, dy: 0.8))
            .withOffset(.init(dx: blankOffset, dy: 0))
        let blankTime = start + 2 + blankOffset / original.frame.width * 2
        drop(first.lastPathComponent, window: window, finder: finder, app: app, to: blank)
        XCTAssertEqual(try reviewPosition(app), blankTime, accuracy: 1.0 / 48_000)
        XCTAssertEqual(app.popUpButtons["ww.addAudio.track"].value as? String, "Drop Track")
        confirmImport(app, visibleClips: 3)
        ruler.coordinate(withNormalizedOffset: .init(dx: 0.05, dy: 0.2)).click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { self.clips(app).count == 2 })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { self.clips(app).count == 3 })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true })
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: fresh), bytes)
        let placementEvidence = XCTAttachment(screenshot: app.windows["ww.show.window"].screenshot())
        placementEvidence.name = "F6 Finder placements after control, Undo, save, and source-byte assertions"
        placementEvidence.lifetime = .keepAlways
        add(placementEvidence)
        for _ in 0..<7 {
            app.descendants(matching: .any)["ww.audioWorkspace.audioTracks"].click()
            app.menuItems["New Audio Track"].click()
        }
        let lastTrack = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioTrack.select.' AND label == 'Audio 8'")).firstMatch
        let workspace = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<10 where !lastTrack.isHittable { workspace.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(lastTrack.isHittable)
        let currentOriginal = app.buttons[clip.identifier].frame
        let windowFrame = app.windows["ww.show.window"].frame
        let scrolledDrop = app.windows["ww.show.window"].coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: currentOriginal.midX - windowFrame.minX,
                              dy: lastTrack.frame.midY - windowFrame.minY))
        drop(first.lastPathComponent, window: window, finder: finder, app: app, to: scrolledDrop)
        XCTAssertEqual(app.popUpButtons["ww.addAudio.track"].value as? String, "Audio 8")
        XCTAssertEqual(try reviewPosition(app), start + 1, accuracy: 1.0 / 48_000)
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(wait {
            !app.descendants(matching: .any)["ww.trackProcessing.overlay"].exists
                && self.clips(app).allElementsBoundByIndex.contains { $0.isHittable }
        }, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["ww.addAudio.error"].exists, app.debugDescription)
        let placedOnScrolledLane = try XCTUnwrap(clips(app).allElementsBoundByIndex.first { $0.isHittable })
        placedOnScrolledLane.click()
        XCTAssertEqual(app.popUpButtons["ww.audioClip.destination"].value as? String, "Audio 8")
        XCTAssertEqual(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? .nan,
                       start + 1, accuracy: 1.0 / 48_000)
    }

    func testFinderFolderDropReportsRefusalWithoutRecursingOrAddingClips() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WW-F6-Folder-\(UUID())")
        let nested = root.appendingPathComponent("Do not recurse")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.wave().write(to: nested.appendingPathComponent("not-selected.wav"))
        let app = launch()
        defer { app.terminate() }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(NSWorkspace.shared.open(root))
        let window = finder.windows[root.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        arrangeFinder(window, finder: finder, app: app)
        drop(nested.lastPathComponent, window: window, finder: finder, app: app,
             to: app.staticTexts["ww.audioDrop.empty"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)))
        XCTAssertFalse(app.buttons["ww.addAudio.import"].isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "1 folders (not scanned)", "1 folders (not scanned)")).firstMatch.exists)
        XCTAssertEqual(clips(app).count, 0)
        app.buttons["ww.addAudio.cancel"].click()
        XCTAssertTrue(wait { !app.buttons["ww.addAudio.import"].exists })
        XCTAssertEqual(clips(app).count, 0)
    }

    func testFinderMultiFileDropConfirmsOrderAndCreatesOneSequentialUndoBatch() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WW-F6-Multiple-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let long = root.appendingPathComponent("long.wav"), short = root.appendingPathComponent("short.wav")
        try Self.wave().write(to: long); try Self.wave(frames: 24_000).write(to: short)
        let app = launch()
        defer { app.terminate() }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(NSWorkspace.shared.open(root))
        let window = finder.windows[root.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        arrangeFinder(window, finder: finder, app: app)
        finder.activate()
        let destination = app.staticTexts["ww.audioDrop.empty"]
            .coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        exposeDropDestination(destination, window: window, finder: finder, app: app)
        func item(_ name: String) -> XCUIElement {
            window.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR value == %@", name, name)).firstMatch
        }
        XCTAssertTrue(item(long.lastPathComponent).waitForExistence(timeout: 5))
        item(long.lastPathComponent).click()
        XCUIElement.perform(withKeyModifiers: .command) { item(short.lastPathComponent).click() }
        item(short.lastPathComponent).coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo: destination)
        app.activate()
        waitForReview(app)
        let candidates = app.checkBoxes.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.addAudio.candidate.'"))
        XCTAssertEqual(candidates.count, 2)
        let shortRow = candidates.matching(NSPredicate(format: "label CONTAINS 'short.wav'")).firstMatch
        let shortID = String(shortRow.identifier.dropFirst("ww.addAudio.candidate.".count))
        let earlier = app.buttons["ww.addAudio.earlier.\(shortID)"]
        if earlier.isEnabled { earlier.click() }
        let longRow = candidates.matching(NSPredicate(format: "label CONTAINS 'long.wav'")).firstMatch
        XCTAssertFalse(earlier.isEnabled)
        XCTAssertLessThan(shortRow.frame.minY, longRow.frame.minY, "The review must visibly place short.wav first.")
        let start = try reviewPosition(app)
        confirmImport(app, visibleClips: 2)
        let first = clips(app).matching(NSPredicate(format: "label == 'Audio Clip: short.wav'")).firstMatch
        let second = clips(app).matching(NSPredicate(format: "label == 'Audio Clip: long.wav'")).firstMatch
        XCTAssertTrue(first.exists && second.exists)
        XCTAssertNotEqual(first.identifier, second.identifier)
        let clipMenu = app.menuButtons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioTrack.clips.'")).firstMatch
        clipMenu.click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'short.wav'")).firstMatch.click()
        XCTAssertTrue(wait { first.isSelected })
        XCTAssertEqual(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? .nan,
                       start, accuracy: 1.0 / 48_000)
        XCTAssertEqual(app.textFields["ww.audioClip.trimStart"].value as? String, "0")
        XCTAssertEqual(app.textFields["ww.audioClip.trimEnd"].value as? String, "24000")
        clipMenu.click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'long.wav'")).firstMatch.click()
        XCTAssertTrue(wait { second.isSelected })
        XCTAssertEqual(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? .nan,
                       start + 0.5, accuracy: 1.0 / 48_000)
        XCTAssertEqual(app.textFields["ww.audioClip.trimStart"].value as? String, "0")
        XCTAssertEqual(app.textFields["ww.audioClip.trimEnd"].value as? String, "96000")
        app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
            .coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.2)).click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { self.clips(app).count == 0 })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { self.clips(app).count == 2 })
        XCTAssertEqual(try Data(contentsOf: long), Self.wave())
        XCTAssertEqual(try Data(contentsOf: short), Self.wave(frames: 24_000))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.removeValue(forKey: "WW_SETUP_ENGINE")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestResetSourceAccess", "YES",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Timeline file drops",
            "-WWUITestShowFolder", "WWUITests-F6-\(UUID())", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        return app
    }

    private func arrangeFinder(_ window: XCUIElement, finder: XCUIApplication, app: XCUIApplication) {
        finder.activate()
        finder.typeKey("1", modifierFlags: .command)
        let corner = window.coordinate(withNormalizedOffset: .init(dx: 1, dy: 1)).withOffset(.init(dx: -1, dy: -1))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(.init(
            dx: min(0, 620 - window.frame.width), dy: min(0, 420 - window.frame.height))))
        let old = window.frame, main = app.windows["ww.show.window"].frame
        let title = window.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0)).withOffset(.init(dx: 0, dy: 8))
        title.click(forDuration: 0.1, thenDragTo: title.withOffset(.init(
            dx: main.maxX - old.maxX, dy: main.minY + 40 - old.minY)))
        app.activate()
    }

    private func exposeDropDestination(_ destination: XCUICoordinate, window: XCUIElement,
                                       finder: XCUIApplication, app: XCUIApplication) {
        let point = destination.screenPoint
        if window.frame.contains(point) {
            let old = window.frame
            let top = app.windows["ww.show.window"].frame.minY
            let targetY = top + old.height < point.y ? top : point.y + 8
            let title = window.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0))
                .withOffset(.init(dx: 0, dy: 8))
            title.click(forDuration: 0.1, thenDragTo: title.withOffset(.init(dx: 0, dy: targetY - old.minY)))
            XCTAssertTrue(wait { !window.frame.contains(point) }, "The owned Finder window still covers the drop point.")
        }
        XCTAssertEqual(destination.screenPoint, point, "Moving Finder must not change the actual drop destination.")
        let occludingFrames = finder.windows.allElementsBoundByIndex.map(\.frame).filter { $0.contains(point) }
        XCTAssertTrue(occludingFrames.isEmpty, "Finder windows still cover drop point \(point): \(occludingFrames)")
    }

    private func drop(_ name: String, window: XCUIElement, finder: XCUIApplication, app: XCUIApplication,
                      to destination: XCUICoordinate) {
        finder.activate()
        exposeDropDestination(destination, window: window, finder: finder, app: app)
        let item = window.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", name, name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), finder.debugDescription)
        item.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo: destination)
        app.activate()
        waitForReview(app)
    }

    private func waitForReview(_ app: XCUIApplication) {
        let review = app.buttons["ww.addAudio.import"]
        let refusal = app.descendants(matching: .any)["ww.addAudio.error"]
        let settled = wait { review.exists || refusal.exists }
        let reason = refusal.exists ? String(describing: refusal.value ?? refusal.label) : "Import review was not presented."
        let presented = settled && review.exists && !refusal.exists
        if !presented, app.windows["ww.show.window"].exists {
            let evidence = XCTAttachment(screenshot: app.windows["ww.show.window"].screenshot())
            evidence.name = "F6 file-drop review refusal"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(presented, "\(reason)\n\(app.debugDescription)")
    }

    private func clips(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.audioClip.' AND label BEGINSWITH 'Audio Clip:'"))
    }

    private func confirmImport(_ app: XCUIApplication, visibleClips: Int) {
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(wait {
            self.clips(app).count == visibleClips
                && !app.descendants(matching: .any)["ww.trackProcessing.overlay"].exists
                && self.clips(app).firstMatch.isHittable
        }, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["ww.addAudio.error"].exists, app.debugDescription)
    }

    private func reviewPosition(_ app: XCUIApplication) throws -> Double {
        try XCTUnwrap(Double(app.textFields["ww.addAudio.position"].value as? String ?? ""))
    }

    private func viewport(_ app: XCUIApplication) throws -> (start: Double, duration: Double) {
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let numbers = (ruler.value as? String ?? ruler.label).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(numbers.count, 2)
        return (try XCTUnwrap(numbers.first), try XCTUnwrap(numbers.last) - XCTUnwrap(numbers.first))
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(value)
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func wave(frames: Int = 96_000) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(48_000)); put(UInt32(96_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(frames * 2))
        for frame in 0..<frames { put(Int16(frame % 1000 - 500)) }
        return data
    }
}
