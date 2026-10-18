import XCTest

@MainActor
final class TranscriptReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    private func launch(aligned: Bool, publicWAV: String? = nil, timeline: Bool = false) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Cleanup Fixture",
            "-WWUITestShowFolder", "WWUITests-Cleanup-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
        ]
        if aligned {
            app.launchArguments += ["-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES"]
        }
        if let publicWAV { app.launchArguments += ["-WWUITestCleanupPublicSpeech", publicWAV] }
        if timeline { app.launchArguments += ["-WWUITestCleanupTimelineFixture", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows["ww.show.window"].waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.cleanup.heading"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testUnalignedEpisodeCannotTranscribeOrFabricateWordsAndHasRecoveryNavigation() {
        launch(aligned: false)
        openPrecisionRange()
        XCTAssertFalse(app.buttons["ww.cleanup.transcribe"].isEnabled)
        XCTAssertFalse(app.buttons["ww.cleanup.range.apply"].isEnabled)
        XCTAssertFalse(app.buttons["ww.cleanup.load"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["ww.review.occurrence.synthetic-001"].exists)
        XCTAssertFalse(app.staticTexts["ww.cleanup.ready"].exists)
        XCTAssertTrue(app.buttons["ww.cleanup.settings"].exists)
        XCTAssertFalse(app.buttons["Choose Local Model…"].exists)
        app.buttons["Go to Alignment"].click()
        XCTAssertTrue(app.buttons["ww.show.destination.alignment"].isSelected)
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ww.cleanup.heading"].waitForExistence(timeout: 5))
        app.buttons["Manage Recordings"].click()
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    func testAlignedPrimaryLoadsRealWaveformsAndSharedRangeIsUndoable() {
        launch(aligned: true)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15), app.debugDescription)
        let lanes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.speaker.'"))
        XCTAssertEqual(lanes.count, 1, "The Backup is not a cleanup speaker lane")
        openPrecisionRange()
        let inField = app.textFields["ww.cleanup.tracksIn"]
        let outField = app.textFields["ww.cleanup.tracksOut"]
        replace(inField, with: "1")
        replace(outField, with: "4")
        app.buttons["ww.cleanup.range.apply"].click()
        XCTAssertTrue(wait { (inField.value as? String) == "1.000000" && (outField.value as? String) == "4.000000" })
        XCTAssertTrue(wait { self.app.buttons["ww.cleanup.load"].label == "Refresh audio" })
        app.buttons["ww.cleanup.load"].click()
        let loaded = app.staticTexts["ww.cleanup.loadedWindow"]
        XCTAssertTrue(wait { (loaded.value as? String ?? loaded.label).hasPrefix("Measured Primary waveforms") },
                      app.debugDescription)
        let summary = app.staticTexts["ww.cleanup.range.summary"]
        XCTAssertTrue((summary.value as? String ?? summary.label).contains("1.000"))
        XCTAssertTrue((summary.value as? String ?? summary.label).contains("4.000"))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { (inField.value as? String ?? "").isEmpty && (outField.value as? String ?? "").isEmpty },
                      app.debugDescription)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { (inField.value as? String) == "1.000000" })
        app.buttons["ww.cleanup.range.reset"].click()
        XCTAssertTrue(wait { (inField.value as? String ?? "").isEmpty })
    }

    func testInvalidMarkersAreRejectedWithoutChangingAcceptedRange() {
        launch(aligned: true)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15))
        openPrecisionRange()
        replace(app.textFields["ww.cleanup.tracksIn"], with: "4")
        replace(app.textFields["ww.cleanup.tracksOut"], with: "1")
        app.buttons["ww.cleanup.range.apply"].click()
        XCTAssertTrue(app.staticTexts["ww.cleanup.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].exists)
        app.buttons["ww.cleanup.range.reset"].click()
        XCTAssertTrue(wait { (app.textFields["ww.cleanup.tracksIn"].value as? String ?? "").isEmpty })
    }

    func testOptedInPublicSpeechTranscribesThroughTheRealEpisodeWorkspace() throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["WW_CLEANUP_UI_DOWNLOAD_MODEL"], ["baseEnglish", "turbo"].contains(model),
              let wav = env["WW_CLEANUP_PUBLIC_48K_WAV"] else {
            throw XCTSkip("Opt in to a real model download with WW_CLEANUP_UI_DOWNLOAD_MODEL=baseEnglish or turbo and the licensed public 48 kHz control.")
        }
        launch(aligned: true, publicWAV: wav)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15))
        app.buttons["ww.cleanup.settings"].click()
        let settings = app.windows["ww.settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        let picker = settings.popUpButtons["ww.settings.transcription.model"]
        picker.click()
        app.menuItems[model == "turbo" ? "Whisper Turbo (recommended)" : "Whisper Base English"].click()
        if !settings.descendants(matching: .any)["ww.settings.transcription.installed"].exists {
            settings.buttons["ww.settings.transcription.download"].click()
            XCTAssertTrue(wait(timeout: 600) {
                settings.descendants(matching: .any)["ww.settings.transcription.installed"].exists
            }, app.debugDescription)
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { self.app.buttons["ww.cleanup.transcribe"].isEnabled }, app.debugDescription)
        app.buttons["ww.cleanup.transcribe"].click()
        let status = app.staticTexts["ww.cleanup.status"]
        let completed = NSPredicate(format: "label BEGINSWITH 'Transcribed 1 speaker locally' OR value BEGINSWITH 'Transcribed 1 speaker locally'")
        expectation(for: completed, evaluatedWith: status)
        waitForExpectations(timeout: 120)
        XCTAssertFalse(app.staticTexts["ww.cleanup.error"].exists, app.debugDescription)
        let middle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'middle,'")).firstMatch
        XCTAssertTrue(middle.waitForExistence(timeout: 10),
                      "Actual recognized words, not a synthetic review fixture")
        app.buttons["ww.cleanup.fitTimeline"].click()
        assertWordPosition(middle)
        middle.click()
        let interval = (middle.value as? String ?? "").split(separator: " ")
        let wordStart = try XCTUnwrap(interval.count > 3 ? Double(interval[3]) : nil)
        XCTAssertTrue(wait {
            abs((Double(self.app.textFields["ww.cleanup.playhead"].value as? String ?? "") ?? -1) - wordStart) < 0.002
        })
        let oldRuler = text(app.staticTexts["ww.cleanup.ruler"])
        app.sliders["ww.cleanup.zoom"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(wait { self.text(self.app.staticTexts["ww.cleanup.ruler"]) != oldRuler })
        assertWordPosition(middle)
        capture("Time-aligned transcription")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'middle,'")).firstMatch.exists)
    }

    func testTranscriptionSetupIsGlobalSettingsNotAnEpisodeFilePicker() {
        launch(aligned: false)
        app.buttons["ww.cleanup.settings"].click()
        let settings = app.windows["ww.settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        let picker = settings.popUpButtons["ww.settings.transcription.model"]
        XCTAssertTrue(picker.exists)
        XCTAssertTrue(settings.buttons["ww.settings.transcription.download"].exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        picker.click()
        app.menuItems["Whisper Base English"].click()
        let workers = settings.popUpButtons["ww.settings.transcription.workers"]
        XCTAssertTrue(workers.exists)
        workers.click()
        app.menuItems["2 workers"].click()
        let hardware = settings.popUpButtons["ww.settings.transcription.backend"]
        XCTAssertTrue(hardware.exists)
        hardware.click()
        XCTAssertTrue(app.menuItems["Automatic"].exists)
        XCTAssertTrue(app.menuItems["CPU + GPU / Metal"].exists)
        XCTAssertFalse(app.menuItems["Neural Engine"].exists)
        app.menuItems["CPU / Accelerate"].click()
        let threads = settings.popUpButtons["ww.settings.transcription.threads"]
        XCTAssertTrue(threads.exists)
        threads.click()
        app.menuItems["2"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(text(app.staticTexts["ww.cleanup.model"]).contains("Base English"))
        app.buttons["ww.cleanup.settings"].click()
        XCTAssertTrue((picker.value as? String ?? "").contains("Base English"))
        XCTAssertTrue((workers.value as? String ?? "").contains("2 workers"))
        XCTAssertTrue((hardware.value as? String ?? "").contains("CPU / Accelerate"))
        XCTAssertEqual(threads.value as? String, "2")
    }

    private func text(_ element: XCUIElement) -> String { element.value as? String ?? element.label }

    private func assertWordPosition(_ word: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let interval = (word.value as? String ?? "").split(separator: " ")
        guard interval.count > 3, let time = Double(interval[3]) else {
            XCTFail("Missing actual recognizer interval: \(word.debugDescription)", file: file, line: line)
            return
        }
        let ruler = text(app.staticTexts["ww.cleanup.ruler"])
        let numbers = ruler.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 2 else { XCTFail("Missing viewport times: \(ruler)", file: file, line: line); return }
        let waveform = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ww.cleanup.waveform.'")).firstMatch
        let expected = waveform.frame.minX + max(0, time - numbers[0]) / (numbers[1] - numbers[0]) * waveform.frame.width
        XCTAssertEqual(word.frame.minX, expected, accuracy: 2, "Word and waveform use the same aligned-time scale", file: file, line: line)
        XCTAssertGreaterThanOrEqual(word.frame.minY, waveform.frame.maxY, "Words are below their Primary waveform", file: file, line: line)
    }

    func testCompactSharedTimelineHasZoomScaleClickMarkersAndNoTrackMoves() {
        launch(aligned: true, timeline: true)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15))
        let waveforms = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.waveform.'"))
        XCTAssertTrue(wait { waveforms.count == 2 && self.app.buttons["ww.cleanup.load"].label == "Refresh audio" },
                      app.debugDescription)
        XCTAssertEqual(waveforms.element(boundBy: 0).frame.height, 96, accuracy: 2)
        let gap = waveforms.element(boundBy: 1).frame.minY - waveforms.element(boundBy: 0).frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0)
        XCTAssertLessThan(gap, 40, "No empty transcript-sized spacers or separate track cards")
        let details = app.buttons.matching(identifier: "Details")
        XCTAssertLessThan(details.element(boundBy: 0).frame.maxX, waveforms.element(boundBy: 0).frame.minX)
        XCTAssertTrue(app.sliders["ww.cleanup.zoom"].exists)
        XCTAssertTrue(app.sliders["ww.cleanup.laneHeight"].exists)
        app.buttons["ww.cleanup.fitTimeline"].click()
        app.buttons["ww.cleanup.tool.in"].click()
        waveforms.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        XCTAssertTrue(wait {
            let text = self.app.staticTexts["ww.cleanup.range.summary"]
            return (text.value as? String ?? text.label).contains("2.400")
        })
        app.buttons["ww.cleanup.tool.out"].click()
        waveforms.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(wait {
            let text = self.app.staticTexts["ww.cleanup.range.summary"]
            return (text.value as? String ?? text.label).contains("6.000")
        })
        app.buttons["ww.cleanup.tool.seek"].click()
        capture("Compact Primary timeline with shared In and Out")
        let playhead = app.textFields["ww.cleanup.playhead"]
        waveforms.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        XCTAssertTrue(wait { (Double(playhead.value as? String ?? "") ?? 0) > 10 },
                      "Banter beyond Tracks Out remains available without resetting the markers")
        let beforeDrag = Double(playhead.value as? String ?? "") ?? -1
        let point = waveforms.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.click(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertEqual(Double(playhead.value as? String ?? "") ?? -1, beforeDrag, accuracy: 0.001)
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'alignment.waveforms.'")).firstMatch.exists)
        app.checkBoxes["ww.cleanup.normalizeView"].click()
        XCTAssertEqual((app.checkBoxes["ww.cleanup.normalizeView"].value as? NSNumber)?.boolValue, true)
        let heightSlider = app.sliders["ww.cleanup.laneHeight"]
        heightSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).click()
        XCTAssertTrue(wait { waveforms.element(boundBy: 0).frame.height > 130 })
        let zoom = app.sliders["ww.cleanup.zoom"]
        zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).click()
        let ruler = app.staticTexts["ww.cleanup.ruler"]
        XCTAssertTrue(wait { !(ruler.value as? String ?? ruler.label).contains("to 12.000") })
        XCTAssertEqual(Double(playhead.value as? String ?? "") ?? -1, beforeDrag, accuracy: 0.001)
    }

    func testContinuousPrimaryPlaybackCrossesFiveSecondChunksAndWorkingMarkers() {
        launch(aligned: true, timeline: true)
        XCTAssertTrue(app.descendants(matching: .any)["ww.cleanup.ready"].waitForExistence(timeout: 15))
        openPrecisionRange()
        replace(app.textFields["ww.cleanup.tracksIn"], with: "2")
        replace(app.textFields["ww.cleanup.tracksOut"], with: "4")
        app.buttons["ww.cleanup.range.apply"].click()
        let playhead = app.textFields["ww.cleanup.playhead"]
        replace(playhead, with: "0")
        app.typeKey(.return, modifierFlags: [])
        let play = app.buttons["ww.cleanup.transport.play"]
        XCTAssertTrue(wait { play.isEnabled })
        play.click()
        XCTAssertTrue(wait { (Double(playhead.value as? String ?? "") ?? 0) > 1 }, app.debugDescription)
        let hear = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.enabled.'")).firstMatch
        hear.click()
        XCTAssertTrue(wait(timeout: 15) { (Double(playhead.value as? String ?? "") ?? 0) > 6.5 },
                      "Playback continues across bounded chunks and beyond the analysis-only Tracks Out")
        play.click()
        let paused = Double(playhead.value as? String ?? "") ?? -1
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(Double(playhead.value as? String ?? "") ?? -1, paused, accuracy: 0.08)
        XCTAssertFalse(app.staticTexts["ww.cleanup.error"].exists, app.debugDescription)
        app.buttons["ww.cleanup.transport.stop"].click()
        XCTAssertTrue(wait { (Double(playhead.value as? String ?? "") ?? -1) < 0.01 })
    }

    private func openPrecisionRange() {
        if !app.textFields["ww.cleanup.tracksIn"].exists {
            app.descendants(matching: .any)["ww.cleanup.range.precision"].click()
        }
        XCTAssertTrue(app.textFields["ww.cleanup.tracksIn"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func wait(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
