import AppKit
import XCTest

/// Opt-in documentation capture, using only generated recordings and seeded synthetic transcripts.
@MainActor
final class DocumentationScreenshotUITests: XCTestCase {
    func testCaptureProductGuideScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WW_DOCUMENTATION_SCREENSHOTS"] == "1",
                          "Documentation capture requires an explicitly selected, leased VM run.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestAppearance", "darkAqua",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "The Signal Studio",
            "-WWUITestShowFolder", "WWUITests-Documentation-\(UUID())",
            "-WWUITestShowEpisodes", "3", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestCleanupFixture", "YES", "-WWUITestCleanupTimelineFixture", "YES",
            "-WWUITestTranscriptFixture", "YES", "-WWUITestDocumentationFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        app.activate()
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        XCTAssertTrue(app.buttons["ww.show.export"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { app.buttons["ww.show.export"].isEnabled })
        clickTimelineButton("alignment.waveforms.load", in: app)
        let tracks = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        XCTAssertTrue(wait { tracks.count == 2 }, app.debugDescription)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WWUITests-Documentation-Audio-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { XCTFail("Could not remove generated documentation audio: \(error)") }
        }
        let music = folder.appendingPathComponent("Theme Music.wav")
        try generatedMusic().write(to: music)
        try importMusic(music, in: app)
        set(app.textFields["ww.audioClip.trackName"], to: "Theme Music")
        app.buttons["ww.audioClip.renameTrack"].click()
        addFade("in", at: "0", duration: "1", in: app)
        addFade("out", at: "9", duration: "3", in: app)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { app.buttons["ww.show.export"].isEnabled })
        let playhead = app.textFields["alignment.waveforms.playhead"]
        set(playhead, to: "4")
        playhead.typeKey(.return, modifierFlags: [])
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        let inspector = app.buttons["ww.sidebar.recording"]
        if inspector.value as? String == "Shown" { inspector.click() }
        selectTimelineLayout("By speaker", in: app)
        adjustTimelineSlider("alignment.waveforms.laneHeight", to: 0, in: app)
        app.descendants(matching: .any)["ww.controlBar.listeningMode"].click()
        app.menuItems["ww.audioWorkspace.playMix"].click()
        app.buttons["ww.mixer.toggle"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.mixer.docked"].waitForExistence(timeout: 10))
        resizeBottomPane(to: 650, in: app, window: window)
        let masterFader = app.descendants(matching: .any)["ww.mixer.strip.master.fader"]
        XCTAssertTrue(masterFader.isHittable && window.frame.contains(masterFader.frame), app.debugDescription)
        XCTAssertTrue(tracks.element(boundBy: 1).isHittable)
        capture("episode-workspace", element: window)
        app.buttons["ww.bottomPane.detachMixer"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        capture("mixer", element: mixer)
        mixer.buttons["ww.mixer.reattach"].click()
        app.buttons["ww.mixer.toggle"].click()
        adjustTimelineSlider("alignment.waveforms.laneHeight", to: 0.36, in: app)

        let clip = clips(in: app).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 10))
        clip.click()
        if inspector.value as? String != "Shown" { inspector.click() }
        refitInspectorLayout(in: app)
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        XCTAssertTrue(wait { tracks.firstMatch.frame.minX > window.frame.minX + 150 }, app.debugDescription)
        capture("audio-clips-and-fades", element: window)
        if inspector.value as? String == "Shown" { inspector.click() }
        app.buttons["ww.sidebar.alignment"].click()
        XCTAssertTrue(app.scrollViews["ww.inspector.alignment.details"].waitForExistence(timeout: 10))
        refitInspectorLayout(in: app)
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        capture("alignment-review", element: window)
        app.buttons["ww.sidebar.alignment"].click()
        app.buttons["ww.review.toggle"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.review.panel"].waitForExistence(timeout: 10))
        resizeBottomPane(to: 240, in: app, window: window)
        clickTimelineButton("alignment.waveforms.fitTimeline", in: app)
        capture("transcript-review", element: window)
        app.buttons["ww.review.toggle"].click()

        app.buttons["ww.show.export"].click()
        XCTAssertTrue(app.buttons["ww.export.start"].waitForExistence(timeout: 10))
        app.checkBoxes["ww.export.format.mp3"].click()
        app.checkBoxes["ww.export.format.m4a"].click()
        capture("export", element: app.sheets.firstMatch)
        app.buttons["ww.export.close"].click()
        app.buttons["ww.show.recordings"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
        capture("recordings-and-speakers", element: app.sheets.firstMatch)
        app.sheets.buttons["Done"].click()
        EpisodeLibraryNavigation.browseCurrentShow(in: app)
        let library = app.windows["ww.library.window"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let episode = library.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.show.sidebar.episode.'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.click()
        XCTAssertTrue(library.textFields["ww.inspector.episode.title"].waitForExistence(timeout: 5))
        capture("library", element: library)
    }

    private func importMusic(_ file: URL, in app: XCUIApplication) throws {
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
        guard let picker = host else { return }
        Thread.sleep(forTimeInterval: 1)
        picker.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        picker.typeText(file.path)
        picker.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        picker.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["ww.addAudio.import"].waitForExistence(timeout: 15))
        set(app.textFields["ww.addAudio.trackName"], to: "Theme Music")
        app.buttons["ww.addAudio.import"].click()
        XCTAssertTrue(clips(in: app).firstMatch.waitForExistence(timeout: 20))
        clips(in: app).firstMatch.click()
    }

    private func addFade(_ direction: String, at start: String, duration: String, in app: XCUIApplication) {
        let field = app.textFields["alignment.waveforms.playhead"]
        set(field, to: start)
        field.typeKey(.return, modifierFlags: [])
        let button = app.buttons["ww.audioFade.\(direction)"]
        let inspector = app.scrollViews["ww.inspector"]
        for _ in 0..<12 where !button.isHittable {
            inspector.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(button.isHittable)
        button.click()
        XCTAssertTrue(app.textFields["ww.audioFade.length"].waitForExistence(timeout: 5))
        set(app.textFields["ww.audioFade.length"], to: duration)
        app.buttons["ww.audioFade.apply"].click()
        XCTAssertTrue(app.buttons["ww.audioFade.apply"].waitForNonExistence(timeout: 5))
    }

    private func clips(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.audioClip.' AND label BEGINSWITH 'Audio Clip:'"))
    }

    private func resizeBottomPane(to height: CGFloat, in app: XCUIApplication, window: XCUIElement) {
        let picker = app.descendants(matching: .any)["ww.bottomPane.content"]
        XCTAssertTrue(picker.exists && picker.frame.height > 0, app.debugDescription)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        // The native divider is above the header's six-point padding.
        let grip = origin.withOffset(CGVector(
            dx: window.frame.width / 2, dy: picker.frame.minY - window.frame.minY - 7))
        let target = origin
            .withOffset(CGVector(dx: window.frame.width / 2, dy: window.frame.height - height))
        grip.click(forDuration: 0.1, thenDragTo: target)
    }

    private func refitInspectorLayout(in app: XCUIApplication) {
        for _ in 0..<2 {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuItems["Zoom"].click()
        }
    }

    private func set(_ field: XCUIElement, to text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5) && field.isHittable)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func capture(_ name: String, element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func generatedMusic() -> Data {
        let rate = 48_000, frames = rate * 12
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(frames * 4))
        for frame in 0..<frames {
            let time = Double(frame) / Double(rate)
            let pulse = 0.35 + 0.65 * pow(sin(time * .pi * 2), 2)
            append(Int16(sin(time * 2 * .pi * 220) * pulse * 12_000))
            append(Int16(sin(time * 2 * .pi * 330) * pulse * 10_000))
        }
        return data
    }
}
