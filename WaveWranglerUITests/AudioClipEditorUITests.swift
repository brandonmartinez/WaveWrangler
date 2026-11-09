import AppKit
import XCTest

@MainActor
final class AudioClipEditorUITests: XCTestCase {
    private func launch(dialogue: Bool = false, minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Audio Clip Editor",
            "-WWUITestShowFolder", "WWUITests-AudioEditor-\(UUID())", "-WWUITestShowEpisodes", "1",
        ]
        if dialogue {
            app.launchArguments += [
                "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
                "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES",
            ]
        }
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.controlBar.more"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    func testEmptyEpisodeAddAudioEditsUndoAndAllLayouts() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-stereo.wav")
        try wave().write(to: file)
        let original = try Data(contentsOf: file)
        let app = launch()
        defer { app.terminate() }
        chooseAudio(file, in: app)
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(clips(app).count, 0, "Opening review must not create canonical placeholders.")
        replace(app.textFields["ww.addAudio.trackName"], with: "Ambience")
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(wait {
            let visible = clips(app).allElementsBoundByIndex
            return visible.count == 1 && visible[0].isHittable
        }, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["ww.addAudio.error"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["No audio in this window"].exists)
        clips(app).firstMatch.click()
        let trackName = app.textFields["ww.audioClip.trackName"]
        replace(trackName, with: "Atmosphere")
        app.buttons["ww.audioClip.renameTrack"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioTrack.select.' AND label == 'Atmosphere'"))
            .firstMatch.waitForExistence(timeout: 5))
        focusTimeline(in: app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { trackName.value as? String == "Ambience" }, app.debugDescription)
        let start = app.textFields["ww.audioClip.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
        replace(start, with: "0.25")
        app.buttons["ww.audioClip.move"].click()
        app.checkBoxes["ww.audioClip.pinned"].click()
        app.buttons["ww.audioClip.duplicate"].click()
        XCTAssertTrue(wait { clips(app).count == 2 }, app.debugDescription)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        replace(playhead, with: "0.5")
        playhead.typeKey(.return, modifierFlags: [])
        app.buttons["ww.audioClip.split"].click()
        XCTAssertTrue(wait { clips(app).count == 3 }, app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { clips(app).count == 2 }, app.debugDescription)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { clips(app).count == 3 })
        for layout in ["By recorder", "By speaker", "Overlay", "Speakers only"] {
            selectTimelineLayout(layout, in: app)
            XCTAssertEqual(clips(app).count, 3, "\(layout) must keep Audio Tracks outside recorder comparison filtering.")
            XCTAssertEqual(app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'alignment.waveforms.track.'")).count, 0)
        }
        let inspector = app.buttons["ww.sidebar.recording"]
        if inspector.value as? String == "Shown" { inspector.click() }
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        app.descendants(matching: .any)["ww.controlBar.add"].click()
        app.menuItems["New Audio Track"].click()
        let destinationHeader = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioTrack.select.' AND label == 'Audio 2'")).firstMatch
        let sourceHeader = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioTrack.select.' AND label == 'Ambience'")).firstMatch
        XCTAssertTrue(destinationHeader.waitForExistence(timeout: 5) && destinationHeader.isHittable, app.debugDescription)
        let moving = try XCTUnwrap(clips(app).allElementsBoundByIndex.first { $0.isSelected && $0.isHittable })
        let movingID = moving.identifier
        let grip = moving.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(
            dx: 36, dy: destinationHeader.frame.midY - sourceHeader.frame.midY)))
        let moved = app.buttons[movingID]
        moved.click()
        let destination = app.popUpButtons["ww.audioClip.destination"]
        XCTAssertTrue(wait { destination.value as? String == "Audio 2" }, app.debugDescription)
        XCTAssertGreaterThan(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? 0, 0.25)
        XCTAssertEqual(String(describing: app.checkBoxes["ww.audioClip.pinned"].value ?? ""), "1")
        focusTimeline(in: app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { destination.value as? String == "Ambience" })
        XCTAssertEqual(Double(app.textFields["ww.audioClip.start"].value as? String ?? "") ?? 0, 0.25, accuracy: 1 / 48_000)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { destination.value as? String == "Audio 2" })
        replace(app.textFields["ww.audioClip.trimStart"], with: "1")
        app.buttons["ww.audioClip.trim"].click()
        XCTAssertEqual(app.textFields["ww.audioClip.trimStart"].value as? String, "1")
        focusTimeline(in: app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { app.textFields["ww.audioClip.trimStart"].value as? String == "0" })
        app.buttons["ww.audioClip.delete"].click()
        XCTAssertTrue(wait { clips(app).count == 2 })
        focusTimeline(in: app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { clips(app).count == 3 })
        if inspector.value as? String == "Shown" { inspector.click() }
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        let editorScreenshot = XCTAttachment(screenshot: app.windows["ww.show.window"].screenshot())
        editorScreenshot.name = "F5 synthetic multitrack Audio Clip editor"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)
        app.buttons["ww.mixer.toggle"].click()
        let master = app.descendants(matching: .any)["ww.mixer.strip.master.name"]
        XCTAssertTrue(master.waitForExistence(timeout: 5) && master.isHittable, app.debugDescription)
        let audioName = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.mixer.strip.audio.' AND identifier ENDSWITH '.name'")).firstMatch
        XCTAssertTrue(audioName.waitForExistence(timeout: 5) && audioName.isHittable, app.debugDescription)
        XCTAssertEqual(audioName.label, "Ambience")
        let controls = app.descendants(matching: .any)["alignment.waveforms.controls"]
        XCTAssertTrue(controls.exists)
        XCTAssertTrue(app.descendants(matching: .any)["ww.controlBar.listeningMode"].isHittable)
        XCTAssertTrue(app.buttons["alignment.waveforms.transport.play"].isEnabled)
        app.buttons["ww.mixer.detach"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let mixerScreenshot = XCTAttachment(screenshot: mixer.screenshot())
        mixerScreenshot.name = "F5 synthetic Audio Track production mixer"
        mixerScreenshot.lifetime = .keepAlways
        add(mixerScreenshot)
        mixer.buttons["ww.mixer.reattach"].click()
        XCTAssertTrue(wait { !mixer.exists })
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true },
                      app.debugDescription)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDialogueAddAudioMixerAndDetachedReviewKeepFixedChrome() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-bed.wav")
        try wave().write(to: file)
        let app = launch(dialogue: true, minimum: true)
        defer { app.terminate() }
        chooseAudio(file, in: app)
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 10))
        replace(app.textFields["ww.addAudio.position"], with: "0.5")
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(wait { clips(app).count == 1 }, app.debugDescription)
        let origin = app.windows["ww.show.window"]
        let top = app.textFields["alignment.waveforms.playhead"].frame
        app.buttons["ww.review.toggle"].click()
        let detach = app.buttons["ww.review.detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 10) && detach.isHittable, app.debugDescription)
        detach.click()
        let detached = app.windows["ww.review.window"]
        XCTAssertTrue(detached.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(origin.frame.contains(app.buttons["ww.controlBar.more"].frame))
        XCTAssertTrue(origin.frame.contains(app.textFields["alignment.waveforms.playhead"].frame))
        XCTAssertTrue(app.buttons["ww.controlBar.more"].isEnabled)
        XCTAssertTrue(app.textFields["alignment.waveforms.playhead"].isEnabled)
        replace(detached.textFields["ww.review.search"], with: "Host")
        detached.buttons["ww.review.reattach"].click()
        XCTAssertTrue(wait { !detached.exists })
        XCTAssertTrue(app.buttons["ww.controlBar.more"].isHittable)
        XCTAssertTrue(app.textFields["alignment.waveforms.playhead"].isHittable)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].frame.minY, top.minY, accuracy: 1)
        app.buttons["ww.review.detach"].click()
        XCTAssertTrue(detached.waitForExistence(timeout: 5))
        XCTAssertEqual(detached.textFields["ww.review.search"].value as? String, "Host",
                       "A new detached window must use the existing shared review model.")
        detached.buttons["ww.review.reattach"].click()
        XCTAssertTrue(wait { !detached.exists })
        app.buttons["ww.mixer.toggle"].click()
        let detachMixer = app.buttons["ww.bottomPane.detachMixer"]
        XCTAssertTrue(detachMixer.waitForExistence(timeout: 5) && detachMixer.isHittable, app.debugDescription)
        detachMixer.click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        XCTAssertTrue(mixer.descendants(matching: .any)["ww.mixer.strip.master.name"].isHittable)
        mixer.buttons["ww.mixer.reattach"].click()
        XCTAssertTrue(wait { !mixer.exists })
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].frame.minY, top.minY, accuracy: 1)
        playProductionMix(in: app)
        XCTAssertTrue(wait {
            (app.descendants(matching: .any)["ww.controlBar.listeningMode"].value as? String) == "Production Mix"
        }, app.debugDescription)
        XCTAssertTrue(wait { app.buttons["alignment.waveforms.transport.play"].label == "Pause" }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.play"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.controlBar.listeningMode"].isHittable)
        XCTAssertEqual(app.textFields["alignment.waveforms.playhead"].frame.minY, top.minY, accuracy: 1)
        XCTAssertEqual(clips(app).count, 1)
    }

    func testCanceledReviewAndUnsupportedAudioNeverPublishClips() throws {
        let root = try mediaFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("synthetic.wav")
        let bad = root.appendingPathComponent("unsupported.mp3")
        try wave().write(to: valid)
        try Data("Not a qualified MP3".utf8).write(to: bad)
        let app = launch()
        defer { app.terminate() }
        chooseAudio(valid, in: app)
        XCTAssertTrue(app.buttons["ww.addAudio.cancel"].waitForExistence(timeout: 10))
        app.buttons["ww.addAudio.cancel"].click()
        XCTAssertTrue(wait { !app.buttons["ww.addAudio.import"].exists })
        XCTAssertEqual(clips(app).count, 0)
        chooseAudio(bad, in: app)
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 10))
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.addAudio.error"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(clips(app).count, 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.audioTrack.select.'")).count, 0)
        XCTAssertEqual(try Data(contentsOf: bad), Data("Not a qualified MP3".utf8))
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

    private func focusTimeline(in app: XCUIApplication) {
        app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).click()
    }

    private func chooseAudio(_ file: URL, in app: XCUIApplication) {
        chooseAddAudio(in: app)
        let identifier = "com.apple.appkit.xpc.openAndSavePanelService"
        var host: XCUIApplication?
        XCTAssertTrue(wait {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil {
                let service = XCUIApplication(bundleIdentifier: identifier)
                if service.state != .notRunning { host = service; return true }
            }
            if app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists {
                host = app
                return true
            }
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func mediaFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WWUITests-F5-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wave() -> Data {
        let rate = 44_100, frames = 44_100
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
            let amplitude = [0.15, 0.8, 0.35, 0.95, 0.25, 0.65][min(5, frame * 6 / frames)]
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 330) * 14_000 * amplitude))
            append(Int16(sin(Double(frame) / Double(rate) * 2 * .pi * 517) * 8_000 * amplitude))
        }
        return bytes
    }
}
