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
        app.buttons["ww.review.toggle"].click()
        app.buttons["ww.review.detach"].click()
        let review = app.windows["ww.review.window"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let intro = app.buttons["ww.audioInsertion.intro"]
        XCTAssertTrue(intro.isHittable && intro.isEnabled, app.debugDescription)
        intro.click()
        let preview = app.staticTexts["ww.audioInsertion.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields["ww.audioInsertion.position"].value as? String, "0.000000000")
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "10.000000000")
        XCTAssertTrue(preview.label.contains("0.000000000 to 10.000000000"), preview.label)
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioInsertion.retarget"].value ?? ""), "0")
        app.checkBoxes["ww.audioInsertion.retarget"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '40.000000000 s of audio'")).firstMatch.exists)
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
            (status.value as? String ?? status.label).hasPrefix("Playing the production mix")
        }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.play"].click()
        XCTAssertTrue(app.buttons["ww.audioWorkspace.sourceAudition"].isHittable)
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
        app.buttons["ww.audioInsertion.insert"].click()
        XCTAssertTrue(app.textFields["ww.audioInsertion.position"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ww.audioInsertion.position"].value as? String, "1.000000000")
        replace(app.textFields["ww.audioInsertion.length"], with: "3")
        let preview = app.staticTexts["ww.audioInsertion.preview"]
        XCTAssertTrue(wait { preview.label.contains("1.000000000 to 4.000000000") }, app.debugDescription)
        app.popUpButtons["ww.audioInsertion.lengthMode"].click()
        app.menuItems["End (program seconds)"].click()
        XCTAssertEqual(app.textFields["ww.audioInsertion.length"].value as? String, "4.000000000")
        XCTAssertTrue(preview.label.contains("1.000000000 to 4.000000000"))
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { regionCount(app) == "1 regions" }, app.debugDescription)
        openFirstRegion(app)
        replace(app.textFields["ww.audioInsertion.length"], with: "1")
        XCTAssertTrue(wait { preview.label.contains("1.000000000 to 2.000000000") }, app.debugDescription)
        screenshot(app, name: "F7 inserted-time duration and affected dialogue preview")
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { !app.buttons["ww.audioInsertion.apply"].exists })
        openFirstRegion(app)
        app.checkBoxes["ww.audioInsertion.remove"].click()
        XCTAssertTrue(wait { preview.label.contains("Remove PROGRAM time at 1.000000000") }, app.debugDescription)
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
        app.buttons["ww.audioInsertion.intro"].click()
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
        XCTAssertTrue(wait { app.staticTexts["ww.audioInsertion.preview"].label.contains("-2.000000000 to 2.000000000") })
        app.buttons["ww.audioInsertion.apply"].click()
        XCTAssertTrue(wait { regionCount(app) == "1 regions" })
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "0")
        playhead.typeKey(.return, modifierFlags: [])
        app.buttons["ww.audioInsertion.insert"].click()
        XCTAssertTrue(app.staticTexts["ww.audioInsertion.refusal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ww.audioInsertion.refusal"].label.contains("cannot nest"))
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
        XCTAssertTrue(app.buttons["ww.audioInsertion.intro"].waitForExistence(timeout: 20), app.debugDescription)
        return app
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
        let attachment = XCTAttachment(screenshot: app.windows["ww.show.window"].screenshot())
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
