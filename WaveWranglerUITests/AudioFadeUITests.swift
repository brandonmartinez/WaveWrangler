import AppKit
import XCTest

@MainActor
final class AudioFadeUITests: XCTestCase {
    func testAutomationToolDragsPointsInTimeAndFlatSegmentsInLevelWithUndo() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-automation.wav")
        try wave().write(to: file)
        let original = try Data(contentsOf: file)
        let app = launch()
        defer { app.terminate() }
        try importAudio(file, in: app)
        fade(app, direction: "out", start: "1", duration: "1", level: "0.25")
        fade(app, direction: "out", start: "4", duration: "1", level: "0")
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        let clip = clips(app).firstMatch, clipFrame = clip.frame, clipValue = clip.value as? String
        let tools = app.menuButtons["alignment.waveforms.tool"]
        if !tools.exists || !tools.isHittable { openTimelineMore(in: app) }
        XCTAssertTrue(tools.isHittable, app.debugDescription)
        tools.click()
        app.menuItems["Automation"].click()
        closeTimelineMore(in: app)
        let first = automationPoint(1, in: app), second = automationPoint(2, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10) && first.isHittable, app.debugDescription)
        let before = try automationValue(first)
        XCTAssertEqual(first.frame.midX, clip.frame.minX + clip.frame.width / 3, accuracy: 1)
        XCTAssertEqual(first.frame.midY, clip.frame.minY + 6 + (clip.frame.height - 12) * 0.75, accuracy: 1)
        screenshot(app, name: "Automation handles before pointer drag")
        let origin = first.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        origin.click(forDuration: 0.2, thenDragTo: origin.withOffset(.init(dx: 40, dy: -20)))
        XCTAssertTrue(wait { automationSnapshot(first).map { $0.frame != before.frame } == true },
                      "Point timing did not change; current value: \(text(first))")
        let moved = try automationValue(first)
        XCTAssertGreaterThan(moved.frame, before.frame)
        XCTAssertEqual(moved.level, before.level, accuracy: 1e-12, "Point drags ignore vertical movement.")
        XCTAssertEqual(clip.frame, clipFrame)
        XCTAssertEqual(clip.value as? String, clipValue)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { automationSnapshot(first)?.frame == before.frame })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { automationSnapshot(first)?.frame == moved.frame })
        let held = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioAutomation.level.' AND identifier CONTAINS '.1.2.'")).firstMatch
        XCTAssertTrue(held.waitForExistence(timeout: 5) && held.isHittable, app.debugDescription)
        let time1 = try automationValue(first).frame, time2 = try automationValue(second).frame
        let levelOrigin = held.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        levelOrigin.click(forDuration: 0.2, thenDragTo: levelOrigin.withOffset(.init(dx: 30, dy: -18)))
        XCTAssertTrue(wait { automationSnapshot(first).map { $0.level > moved.level } == true })
        let raised1 = try automationValue(first), raised2 = try automationValue(second)
        XCTAssertEqual(raised1.frame, time1, "Level drags ignore horizontal movement.")
        XCTAssertEqual(raised2.frame, time2)
        XCTAssertEqual(raised1.level, raised2.level, accuracy: 1e-12)
        XCTAssertEqual(clip.frame, clipFrame)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { automationSnapshot(first)?.level == moved.level })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { automationSnapshot(first)?.level == raised1.level })
        screenshot(app, name: "Graphical automation point timing and flat-level handles")
        tools.click()
        app.menuItems["Pointer"].click()
        XCTAssertTrue(wait { !first.exists })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func automationPoint(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'ww.audioAutomation.point.' AND identifier ENDSWITH %@", ".\(index)")).firstMatch
    }

    private func automationValue(_ element: XCUIElement) throws -> (frame: Double, level: Double) {
        try XCTUnwrap(automationSnapshot(element))
    }

    private func automationSnapshot(_ element: XCUIElement) -> (frame: Double, level: Double)? {
        guard element.exists else { return nil }
        let parts = text(element).components(separatedBy: "; amplitude ")
        guard parts.count == 2, let frame = Double(parts[0].replacingOccurrences(of: "Local frame ", with: "")),
              let level = Double(parts[1]) else { return nil }
        return (frame, level)
    }

    func testFadeInLowFullSilenceNumericPointEditingRemovalUndoAndSave() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-stereo.wav")
        try wave().write(to: file)
        let bytes = try Data(contentsOf: file)
        let app = launch()
        defer { app.terminate() }
        try importAudio(file, in: app)
        openFade(app, direction: "in", start: "0")
        XCTAssertTrue(app.textFields["ww.audioFade.startLevel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ww.audioFade.startLevel"].value as? String, "0")
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioFade.startSilence"].value ?? ""), "1")
        XCTAssertEqual(app.textFields["ww.audioFade.level"].value as? String, "1.0")
        XCTAssertTrue(app.buttons["ww.audioFade.apply"].isEnabled, "Unity Fade In must work without changing a field.")
        screenshot(app, name: "Editable fade endpoints default to Silence and current unity level")
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "2 fade points" })
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "0 fade points" })
        fade(app, direction: "in", start: "0", duration: "0.5", level: "0.25")
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "2 fade points")
        fade(app, direction: "in", start: "1", duration: "0.5", level: "1", startLevel: "0.25")
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "4 fade points")
        fade(app, direction: "out", start: "3", duration: "1", level: "0.1", startLevel: "0.75")
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "7 fade points")
        point(1, in: app)
        XCTAssertEqual(app.textFields["ww.audioFade.localFrame"].value as? String, "24000")
        replace(app.textFields["ww.audioFade.level"], with: "0.2")
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        app.checkBoxes["ww.audioFade.replace"].click()
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioFade.apply"].exists })
        point(1, in: app)
        XCTAssertEqual(app.textFields["ww.audioFade.level"].value as? String, "0.2")
        app.checkBoxes["ww.audioFade.remove"].click()
        XCTAssertTrue(app.checkBoxes["ww.audioFade.replace"].waitForExistence(timeout: 5))
        app.checkBoxes["ww.audioFade.replace"].click()
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "6 fade points" })
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "7 fade points" })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "6 fade points" })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        XCTAssertTrue(clips(app).firstMatch.isHittable)
        screenshot(app, name: "F8 linear fade sequence and visible clip points")
    }

    func testProgramEndModeInvalidFieldsAndConflictingAutomationRequireExplicitReplacement() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-conflict.wav")
        try wave().write(to: file)
        let app = launch(dialogue: true)
        defer { app.terminate() }
        try importAudio(file, in: app)
        fade(app, direction: "out", start: "1", duration: "1", level: "0.25")
        openFade(app, direction: "out", start: "1.5")
        app.popUpButtons["ww.audioFade.lengthMode"].click()
        app.menuItems["End (program seconds)"].click()
        replace(app.textFields["ww.audioFade.length"], with: "2.5")
        XCTAssertTrue(app.staticTexts["ww.audioFade.preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["ww.audioFade.replace"].exists)
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        app.checkBoxes["ww.audioFade.replace"].click()
        replace(app.textFields["ww.audioFade.length"], with: "nan")
        XCTAssertTrue(app.staticTexts["ww.audioFade.refusal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        replace(app.textFields["ww.audioFade.length"], with: "1.5")
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        replace(app.textFields["ww.audioFade.length"], with: "100")
        XCTAssertTrue(app.staticTexts["ww.audioFade.refusal"].exists)
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        replace(app.textFields["ww.audioFade.length"], with: "2.5")
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioFade.replace"].value ?? ""), "0",
                       "Changing the preview revokes approval of the previous replacement.")
        app.checkBoxes["ww.audioFade.silence"].click()
        replace(app.textFields["ww.audioFade.level"], with: "inf")
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].isEnabled)
        replace(app.textFields["ww.audioFade.level"], with: "1")
        XCTAssertTrue(text(app.staticTexts["ww.audioFade.refusal"]).contains("decrease"))
        app.checkBoxes["ww.audioFade.silence"].click()
        XCTAssertTrue(app.checkBoxes["ww.audioFade.replace"].waitForExistence(timeout: 5))
        app.checkBoxes["ww.audioFade.replace"].click()
        screenshot(app, name: "F8 conflict review with explicit replacement and exact Silence")
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioFade.apply"].exists })
        point(2, in: app)
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioFade.silence"].value ?? ""), "1")
        app.buttons["ww.audioFade.cancel"].click()
        XCTAssertTrue(wait {
            !app.sheets.firstMatch.exists && !app.buttons["ww.audioFade.apply"].exists
                && app.buttons["alignment.waveforms.transport.play"].isEnabled
                && app.buttons["ww.audioFade.out"].isEnabled
        }, "Point editing must finish dismissing before the next seek and fade action.")
        let selected = clips(app).firstMatch
        XCTAssertEqual(selected.value as? String, "Program start 0.000 seconds; duration 6.000 seconds; 3 fade points")
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue(wait {
            let bounds = text(ruler).split(separator: " ").compactMap { Double($0) }
            return bounds.count == 2 && bounds.last.map { $0 > 7 } == true
        }, "The fitted program must extend beyond the selected six-second clip.")
        let programBounds = text(ruler).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(programBounds.count, 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(programBounds.first), 0)
        XCTAssertGreaterThan(try XCTUnwrap(programBounds.last), 7)
        seek(app, to: "7")
        let playhead = app.textFields["alignment.waveforms.playhead"]
        XCTAssertTrue(wait { playhead.value as? String == "00:00:07.000" },
                      "Return must commit the actual program playhead outside the selected six-second clip.")
        let fadeOut = app.buttons["ww.audioFade.out"]
        reveal(fadeOut, in: app)
        fadeOut.click()
        let refusal = app.descendants(matching: .any)["ww.audioEditor.error"]
        XCTAssertTrue(wait {
            text(refusal).contains("audible") && !app.sheets.firstMatch.exists
                && !app.buttons["ww.audioFade.apply"].exists
        }, "An actual outside-selected-clip production position must refuse without a new fade sheet.")
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].exists)
        XCTAssertTrue(text(refusal).contains("audible"))
    }

    func testFadesKeepFixedChromeLanesAndProductionWithDetachedReview() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-dialogue-bed.wav")
        try wave().write(to: file)
        let app = launch(dialogue: true, minimum: true)
        defer { app.terminate() }
        try importAudio(file, in: app)
        let origin = app.windows["ww.show.window"]
        XCTAssertEqual(origin.frame.width, 760, accuracy: 1)
        XCTAssertEqual(origin.frame.height, 492, accuracy: 1)
        XCTAssertEqual(app.scrollViews["ww.inspector"].frame.width, 300, accuracy: 1)
        app.buttons["ww.review.toggle"].click()
        let detach = app.buttons["ww.review.detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 5) && detach.isHittable, app.debugDescription)
        XCTAssertTrue(origin.frame.contains(detach.frame), "Review detach must be inside the actual minimum-size window.")
        detach.click()
        let review = app.windows["ww.review.window"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        focusWindow(origin, in: app)
        let chrome = app.textFields["alignment.waveforms.playhead"].frame
        let clip = clips(app).firstMatch, lane = clip.frame
        fade(app, direction: "out", start: "0.5", duration: "0.5", level: "0.25")
        fade(app, direction: "out", start: "2", duration: "0.5", level: "0")
        for time in ["0.25", "0.5", "1.5", "2.75"] {
            seek(app, to: time)
            XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].frame, chrome)
            XCTAssertEqual(clip.frame, lane)
        }
        XCTAssertTrue(app.descendants(matching: .any)["ww.controlBar.listeningMode"].isHittable)
        seek(app, to: "0.5")
        playProductionMix(in: app)
        XCTAssertTrue(wait { app.buttons["alignment.waveforms.transport.play"].label == "Pause" },
                      app.debugDescription)
        app.buttons["alignment.waveforms.transport.play"].click()
        screenshot(app, name: "F8 detached review keeps fixed timeline chrome and unchanged clip lane")
        focusWindow(review, in: app)
        review.buttons["ww.review.reattach"].click()
        XCTAssertTrue(wait { !review.exists })
    }

    private func launch(dialogue: Bool = false, minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Clip Fades",
            "-WWUITestShowFolder", "WWUITests-F8-\(UUID())", "-WWUITestShowEpisodes", "1",
        ]
        if dialogue {
            app.launchArguments += ["-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
                "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES"]
        }
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.controlBar.more"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func importAudio(_ file: URL, in app: XCUIApplication) throws {
        chooseAddAudio(in: app)
        let identifier = "com.apple.appkit.xpc.openAndSavePanelService"
        var host: XCUIApplication?
        XCTAssertTrue(wait {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil {
                let service = XCUIApplication(bundleIdentifier: identifier)
                if service.state != .notRunning { host = service; return true }
            }
            if app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists { host = app; return true }
            return false
        })
        let picker = try XCTUnwrap(host)
        Thread.sleep(forTimeInterval: 1)
        picker.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        picker.typeText(file.path)
        picker.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        picker.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 10), app.debugDescription)
        replace(app.textFields["ww.addAudio.position"], with: "0")
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(clips(app).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        clips(app).firstMatch.click()
    }

    private func fade(_ app: XCUIApplication, direction: String, start: String, duration: String, level: String,
                      startLevel: String? = nil) {
        openFade(app, direction: direction, start: start)
        XCTAssertTrue(app.textFields["ww.audioFade.length"].waitForExistence(timeout: 5), app.debugDescription)
        replace(app.textFields["ww.audioFade.length"], with: duration)
        if let startLevel {
            if String(describing: app.checkBoxes["ww.audioFade.startSilence"].value ?? "") == "1" {
                app.checkBoxes["ww.audioFade.startSilence"].click()
            }
            replace(app.textFields["ww.audioFade.startLevel"], with: startLevel)
        }
        if level != "0" {
            if String(describing: app.checkBoxes["ww.audioFade.silence"].value ?? "") == "1" {
                app.checkBoxes["ww.audioFade.silence"].click()
            }
            replace(app.textFields["ww.audioFade.level"], with: level)
        }
        XCTAssertTrue(app.buttons["ww.audioFade.apply"].isEnabled, app.debugDescription)
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioFade.apply"].exists })
    }

    private func openFade(_ app: XCUIApplication, direction: String, start: String) {
        seek(app, to: start)
        let action = app.buttons["ww.audioFade.\(direction)"]
        reveal(action, in: app)
        action.click()
    }

    private func point(_ index: Int, in app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["ww.audioFade.points"]
        reveal(menu, in: app)
        menu.click()
        let item = app.menuItems["ww.audioFade.point.\(index)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        XCTAssertTrue(app.textFields["ww.audioFade.localFrame"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["ww.inspector"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<12 where !element.isHittable {
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? 160 : -160)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func seek(_ app: XCUIApplication, to value: String) {
        let field = app.textFields["alignment.waveforms.playhead"]
        replace(field, with: value)
        field.typeKey(.return, modifierFlags: [])
    }

    private func timelineFocus(_ app: XCUIApplication) {
        app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
            .coordinate(withNormalizedOffset: .init(dx: 0.05, dy: 0.3)).click()
    }

    private func clips(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.audioClip.' AND label BEGINSWITH 'Audio Clip:'"))
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5) && field.isHittable)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func text(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let sheet = app.sheets.firstMatch
        let attachment = XCTAttachment(screenshot: sheet.exists ? sheet.screenshot()
                                       : app.windows["ww.show.window"].screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func focusWindow(_ window: XCUIElement, in app: XCUIApplication) {
        let title = window.title.components(separatedBy: " \u{2013} ").first ?? window.title
        app.menuBars.menuBarItems["Window"].click()
        let matching = app.menuBars.menuItems.matching(NSPredicate(
            format: "title BEGINSWITH %@ OR label BEGINSWITH %@", title, title))
        let item = window.identifier == "ww.show.window"
            ? matching.matching(NSPredicate(format:
                "NOT (title CONTAINS %@ OR label CONTAINS %@)", "Transcript & Review", "Transcript & Review")).firstMatch
            : matching.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func mediaFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WWUITests-F8-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wave() -> Data {
        let rate = 48_000, frames = rate * 6
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(frames * 4))
        for frame in 0..<frames {
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 330) * 12_000))
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 550) * 8_000))
        }
        return data
    }
}
