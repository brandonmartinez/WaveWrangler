import AppKit
import XCTest

@MainActor
final class AudioInsertionUITests: XCTestCase {
    func testIntroPreviewSelectedOverhangUndoAndProductionInDetachedReview() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-f7-bed.wav")
        try wave(seconds: 40).write(to: file)
        let original = try Data(contentsOf: file)
        let app = launch(dialogue: true, minimum: true)
        defer { app.terminate() }
        chooseAudio(file, in: app)
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["ww.addAudio.import"].click()
        let clip = clips(app).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 20), app.debugDescription)
        clip.click()
        let start = app.textFields["ww.audioClip.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
        let origin = app.windows["ww.show.window"]
        XCTAssertEqual(origin.frame.width, 760, accuracy: 1)
        XCTAssertEqual(origin.frame.height, 492, accuracy: 1)
        XCTAssertEqual(app.scrollViews["ww.inspector"].frame.width, 300, accuracy: 1)
        app.buttons["ww.review.toggle"].click()
        let detach = app.buttons["ww.review.detach"]
        XCTAssertTrue(wait {
            detach.exists && origin.frame.contains(detach.frame) && detach.isHittable
        }, "Detach Review must remain inside the minimum window with the inspector open: \(app.debugDescription)")
        detach.click()
        let review = app.windows["ww.review.window"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        focusWindow(origin, in: app)
        openInsertion(intro: true, in: app)
        let preview = app.staticTexts["ww.audioInsertion.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields["ww.audioInsertion.position"].value as? String, "0.000000000")
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "10.000000000")
        XCTAssertTrue(displayedText(preview).contains("0.000000000 to 10.000000000"), displayedText(preview))
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioInsertion.retarget"].value ?? ""), "0")
        app.checkBoxes["ww.audioInsertion.retarget"].click()
        XCTAssertTrue(app.sheets.firstMatch.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "40.000000000 s of audio", "40.000000000 s of audio")).firstMatch.exists)
        screenshot(app, name: "F7 explicit intro preview with intact forty-second bed")
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioInsertion.apply"].exists }, app.debugDescription)
        XCTAssertEqual(Double(start.value as? String ?? "") ?? .nan, 0, accuracy: 1 / 48_000)
        XCTAssertTrue(wait { regionCount(app) == "1 regions" }, app.debugDescription)
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { regionCount(app) == "0 regions" }, app.debugDescription)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { regionCount(app) == "1 regions" }, app.debugDescription)
        XCTAssertEqual(clips(app).count, 1)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "10.25")
        playhead.typeKey(.return, modifierFlags: [])
        app.buttons["ww.audioWorkspace.playMix"].click()
        let status = app.descendants(matching: .any)["alignment.waveforms.transport.status"]
        XCTAssertTrue(wait {
            displayedText(status).hasPrefix("Playing the production mix")
        }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.play"].click()
        XCTAssertTrue(app.buttons["ww.audioWorkspace.sourceAudition"].isHittable)
        focusWindow(review, in: app)
        review.buttons["ww.review.reattach"].click()
        XCTAssertTrue(wait { !review.exists })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMiddleInsertEndPreviewShortenRemoveAndUndo() throws {
        let app = launch(dialogue: true)
        defer { app.terminate() }
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "1")
        playhead.typeKey(.return, modifierFlags: [])
        openInsertion(intro: false, in: app)
        XCTAssertTrue(app.textFields["ww.audioInsertion.position"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ww.audioInsertion.position"].value as? String, "1.000000000")
        replace(app.textFields["ww.audioInsertion.length"], with: "3")
        let preview = app.staticTexts["ww.audioInsertion.preview"]
        XCTAssertTrue(wait { displayedText(preview).contains("1.000000000 to 4.000000000") }, app.debugDescription)
        app.popUpButtons["ww.audioInsertion.lengthMode"].click()
        app.menuItems["End (program seconds)"].click()
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "4.000000000")
        XCTAssertTrue(displayedText(preview).contains("1.000000000 to 4.000000000"))
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { regionCount(app) == "1 regions" }, app.debugDescription)
        openFirstRegion(app)
        replace(app.textFields["ww.audioInsertion.length"], with: "1")
        XCTAssertTrue(wait { displayedText(preview).contains("1.000000000 to 2.000000000") }, app.debugDescription)
        screenshot(app, name: "F7 inserted-time duration and affected dialogue preview")
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioInsertion.apply"].exists })
        openFirstRegion(app)
        app.checkBoxes["ww.audioInsertion.remove"].click()
        XCTAssertTrue(wait { displayedText(preview).contains("Remove PROGRAM time at 1.000000000") }, app.debugDescription)
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { regionCount(app) == "0 regions" })
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { regionCount(app) == "1 regions" })
        openFirstRegion(app)
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "1.000000000")
        app.buttons["ww.audioInsertion.cancel"].click()
        timelineFocus(app)
        app.typeKey("z", modifierFlags: .command)
        openFirstRegion(app)
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "3.000000000")
        app.buttons["ww.audioInsertion.cancel"].click()
    }

    func testEmptySignedProgramRefusesInvalidDurationAndNestedInsertion() {
        let app = launch(dialogue: false)
        defer { app.terminate() }
        openInsertion(intro: true, in: app)
        XCTAssertTrue(app.textFields["ww.audioInsertion.position"].waitForExistence(timeout: 5))
        replace(app.textFields["ww.audioInsertion.position"], with: "-2")
        replace(app.textFields["ww.audioInsertion.length"], with: "0")
        XCTAssertTrue(app.staticTexts["ww.audioInsertion.refusal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ww.audioInsertion.apply"].isEnabled)
        replace(app.textFields["ww.audioInsertion.length"], with: "nan")
        XCTAssertFalse(app.buttons["ww.audioInsertion.apply"].isEnabled)
        replace(app.textFields["ww.audioInsertion.length"], with: "86401")
        XCTAssertFalse(app.buttons["ww.audioInsertion.apply"].isEnabled)
        replace(app.textFields["ww.audioInsertion.length"], with: "4")
        XCTAssertTrue(wait {
            displayedText(app.staticTexts["ww.audioInsertion.preview"]).contains("-2.000000000 to 2.000000000")
        }, app.debugDescription)
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { regionCount(app) == "1 regions" })
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "0")
        playhead.typeKey(.return, modifierFlags: [])
        openInsertion(intro: false, in: app)
        XCTAssertTrue(app.staticTexts["ww.audioInsertion.refusal"].waitForExistence(timeout: 5))
        XCTAssertTrue(displayedText(app.staticTexts["ww.audioInsertion.refusal"]).contains("cannot nest"))
        XCTAssertFalse(app.buttons["ww.audioInsertion.apply"].isEnabled)
        app.buttons["ww.audioInsertion.cancel"].click()
        XCTAssertEqual(regionCount(app), "1 regions")
    }

    private func launch(dialogue: Bool, minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Inserted Time",
            "-WWUITestShowFolder", "WWUITests-F7-\(UUID())", "-WWUITestShowEpisodes", "1",
        ]
        if dialogue {
            app.launchArguments += ["-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
                "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES"]
        }
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["ww.audioInsertion.regions"].waitForExistence(timeout: 20),
                      app.debugDescription)
        return app
    }

    private func openInsertion(intro: Bool, in app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["ww.audioInsertion.regions"]
        XCTAssertTrue(wait { menu.exists && menu.isEnabled && menu.isHittable }, app.debugDescription)
        menu.click()
        let command = app.menuItems[intro ? "Insert Intro…" : "Insert & Ripple…"]
        XCTAssertTrue(command.waitForExistence(timeout: 5) && command.isEnabled, app.debugDescription)
        command.click()
    }

    private func displayedText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
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

    private func regionCount(_ app: XCUIApplication) -> String? {
        app.descendants(matching: .any)["ww.audioInsertion.regions"].value as? String
    }

    private func openFirstRegion(_ app: XCUIApplication) {
        app.descendants(matching: .any)["ww.audioInsertion.regions"].click()
        let item = app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.audioInsertion.region.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        XCTAssertTrue(app.textFields["ww.audioInsertion.length"].waitForExistence(timeout: 5))
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

    private func timelineFocus(_ app: XCUIApplication) {
        app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
            .coordinate(withNormalizedOffset: .init(dx: 0.05, dy: 0.3)).click()
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.exists, app.debugDescription)
        let attachment = XCTAttachment(screenshot: sheet.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chooseAudio(_ file: URL, in app: XCUIApplication) {
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
        guard let host else { return }
        Thread.sleep(forTimeInterval: 1)
        host.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        host.typeText(file.path)
        host.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        host.typeKey(.return, modifierFlags: [])
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WWUITests-F7-media-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func wave(seconds: Int) -> Data {
        let rate = 48_000, frames = rate * seconds
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: "RIFF".utf8); append(UInt32(36 + frames * 4))
        bytes.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        bytes.append(contentsOf: "data".utf8); append(UInt32(frames * 4))
        for frame in 0..<frames {
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 330) * 12_000))
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 517) * 7_000))
        }
        return bytes
    }
}
