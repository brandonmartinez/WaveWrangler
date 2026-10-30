import AppKit
import XCTest

@MainActor
final class AudioFadeUITests: XCTestCase {
    func testFadeInLowFullSilenceNumericPointEditingRemovalUndoAndSave() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-stereo.wav")
        try wave().write(to: file)
        let bytes = try Data(contentsOf: file)
        let app = launch()
        defer { app.terminate() }
        try importAudio(file, in: app)
        fade(app, direction: "in", start: "0", duration: "0.5", level: "0.25", initializingSilence: true)
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "2 fade points")
        fade(app, direction: "in", start: "1", duration: "0.5", level: "1")
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "4 fade points")
        fade(app, direction: "out", start: "3", duration: "1", level: "0")
        XCTAssertEqual(text(app.staticTexts["ww.audioFade.count"]), "6 fade points")
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
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "5 fade points" })
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "6 fade points" })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { text(app.staticTexts["ww.audioFade.count"]) == "5 fade points" })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        app.buttons["alignment.waveforms.fitTimeline"].click()
        XCTAssertTrue(clips(app).firstMatch.isHittable)
        screenshot(app, name: "F8 linear fade sequence and visible clip points")
    }

    func testProgramEndModeInvalidFieldsAndConflictingAutomationRequireExplicitReplacement() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-conflict.wav")
        try wave().write(to: file)
        let app = launch()
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
        openFade(app, direction: "out", start: "7")
        XCTAssertFalse(app.buttons["ww.audioFade.apply"].exists)
        XCTAssertTrue(text(app.descendants(matching: .any)["ww.audioEditor.error"]).contains("audible"))
    }

    func testFadesKeepFixedChromeLanesAndProductionWithDetachedReview() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f8-dialogue-bed.wav")
        try wave().write(to: file)
        let app = launch(dialogue: true, minimum: true)
        defer { app.terminate() }
        try importAudio(file, in: app)
        app.buttons["ww.review.toggle"].click()
        let detach = app.buttons["ww.review.detach"], origin = app.windows["ww.show.window"]
        XCTAssertTrue(detach.waitForExistence(timeout: 5) && detach.isHittable, app.debugDescription)
        XCTAssertTrue(origin.frame.contains(detach.frame), "Review detach must be inside the actual minimum-size window.")
        detach.click()
        let review = app.windows["ww.review.window"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let chrome = app.textFields["alignment.waveforms.playhead"].frame
        let clip = clips(app).firstMatch, lane = clip.frame
        fade(app, direction: "out", start: "0.5", duration: "0.5", level: "0.25")
        fade(app, direction: "out", start: "2", duration: "0.5", level: "0")
        for time in ["0.25", "0.5", "1.5", "2.75"] {
            seek(app, to: time)
            XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].frame, chrome)
            XCTAssertEqual(clip.frame, lane)
        }
        XCTAssertTrue(app.buttons["ww.audioWorkspace.playMix"].isHittable)
        seek(app, to: "0.5")
        app.buttons["ww.audioWorkspace.playMix"].click()
        let status = app.descendants(matching: .any)["alignment.waveforms.transport.status"]
        XCTAssertTrue(wait { (status.value as? String ?? status.label).hasPrefix("Playing the production mix") },
                      app.debugDescription)
        app.buttons["alignment.waveforms.transport.play"].click()
        screenshot(app, name: "F8 detached review keeps fixed timeline chrome and unchanged clip lane")
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
        XCTAssertTrue(app.buttons["ww.audioWorkspace.addAudio"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func importAudio(_ file: URL, in app: XCUIApplication) throws {
        app.buttons["ww.audioWorkspace.addAudio"].click()
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
                      initializingSilence: Bool = false) {
        openFade(app, direction: direction, start: start)
        XCTAssertTrue(app.textFields["ww.audioFade.length"].waitForExistence(timeout: 5), app.debugDescription)
        replace(app.textFields["ww.audioFade.length"], with: duration)
        if initializingSilence { app.checkBoxes["ww.audioFade.initializeSilence"].click() }
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
        let attachment = XCTAttachment(screenshot: app.windows["ww.show.window"].screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
