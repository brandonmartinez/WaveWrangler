import XCTest

@MainActor
final class UnifiedWorkspaceUITests: XCTestCase {
    func testIntegratedWorkspaceManagementSelectionCycleAndReadableTranscript() {
        exerciseWorkspace(minimumSize: false)
    }

    func testMinimumWorkspaceRetainsManagementListeningAndReview() {
        exerciseWorkspace(minimumSize: true)
    }

    func testTranscriptZoomProgressesFromHiddenThroughSentencePhraseWordAndMarkers() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Transcript Zoom Fixture",
            "-WWUITestShowFolder", "WWUITests-TranscriptZoom-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES",
            "-WWUITestTranscriptFixture", "YES", "-WWUITestTranscriptZoomFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        app.activate()
        let ruler = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 20), app.debugDescription)
        let row = app.descendants(matching: .any).matching(identifier: "ww.transcript.timeline").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        let zoom = app.sliders["alignment.waveforms.zoom"]
        reveal(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0)
        let range = app.staticTexts["alignment.waveforms.ruler"]
        let times = (range.value as? String ?? range.label).split(separator: " ").compactMap { Double($0) }
        let maximum = try XCTUnwrap(times.count == 2 ? times[1] - times[0] : nil)
        XCTAssertGreaterThan(maximum, 5)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        XCTAssertEqual(tracks.count, 2)
        let laneSpacing = tracks.element(boundBy: 1).frame.minY - tracks.firstMatch.frame.minY
        let stages = [("Hidden", 2.0), ("Sentences", 60.0), ("Phrases", 120.0),
                      ("Words", 280.0), ("Words with timing markers", 560.0)]
        for (title, pixelsPerSecond) in stages {
            playhead.click()
            playhead.typeKey("a", modifierFlags: .command)
            playhead.typeText("2.2")
            playhead.typeKey(.return, modifierFlags: [])
            let duration = Double(ruler.frame.width) / pixelsPerSecond
            let level = min(1, max(0, log(maximum / duration) / log(maximum / 0.5)))
            zoom.adjust(toNormalizedSliderPosition: level)
            XCTAssertTrue(wait { row.label.hasPrefix("Timeline transcript: \(title).") },
                          "\(title): \(app.debugDescription)")
            XCTAssertEqual(tracks.element(boundBy: 1).frame.minY - tracks.firstMatch.frame.minY,
                           laneSpacing, accuracy: 1, "Transcript zoom never changes lane spacing.")
            let units = row.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.cleanup.word.'"))
            let labels = units.allElementsBoundByIndex.map(\.label)
            switch title {
            case "Hidden":
                XCTAssertTrue(labels.isEmpty)
            case "Sentences":
                XCTAssertEqual(labels.count, 2)
                XCTAssertEqual(labels.first, "Welcome to this synthetic episode where we compare two recordings.")
            case "Phrases":
                XCTAssertEqual(labels.count, 4)
                XCTAssertTrue(labels.allSatisfy { $0.split(separator: " ").count == 5 })
            default:
                XCTAssertGreaterThan(labels.count, 1)
                XCTAssertTrue(labels.allSatisfy { $0.split(separator: " ").count == 1 },
                              "Touching word intervals must stay individually selectable.")
                XCTAssertTrue(units.allElementsBoundByIndex.allSatisfy {
                    ($0.value as? String)?.hasPrefix(title + ". Approximate aligned interval") == true
                })
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Transcript zoom - \(title)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let word = row.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ww.cleanup.word.'")).firstMatch
        XCTAssertTrue(word.isHittable)
        word.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ww.transcript.full.'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testUnsavedEpisodeNotesDoNotBlockPointerSeekingScrubbingOrPanning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestAutosave", "OFF",
            "-WWUITestOpenShow", "Unsaved Timeline Navigation Fixture",
            "-WWUITestShowFolder", "WWUITests-Navigation-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        app.activate()
        let ruler = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 20), app.debugDescription)
        let episodeSidebar = app.buttons["ww.sidebar.episode"]
        XCTAssertTrue(episodeSidebar.waitForExistence(timeout: 5), app.debugDescription)
        episodeSidebar.click()
        let notes = app.textViews["ww.inspector.episode.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5), app.debugDescription)
        notes.click()
        notes.typeText("Synthetic unsaved navigation check")
        let playhead = app.textFields["alignment.waveforms.playhead"]
        reveal(ruler, in: app)
        let before = playhead.value as? String
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).click()
        XCTAssertTrue(wait { playhead.value as? String != before },
                      "An unsaved note must not block clicking the ruler to seek.")
        let marker = app.descendants(matching: .any)["alignment.waveforms.ruler.playhead"]
        XCTAssertTrue(marker.exists)
        let beforeScrub = Double(playhead.value as? String ?? "") ?? -1
        let visibleRange = app.staticTexts["alignment.waveforms.ruler"]
        let viewport = { visibleRange.value as? String ?? visibleRange.label }
        let beforeScrubRange = viewport()
        let cap = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        cap.click(forDuration: 0.1, thenDragTo: cap.withOffset(CGVector(dx: 20, dy: 0)))
        XCTAssertTrue(wait { (Double(playhead.value as? String ?? "") ?? -1) > beforeScrub },
                      "Dragging the visible playhead cap must change time while the document is dirty.")
        XCTAssertEqual(viewport(), beforeScrubRange, "Scrubbing does not pan the viewport.")
        let afterScrub = playhead.value as? String
        let beforePan = viewport()
        let empty = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4))
        empty.click(forDuration: 0.1, thenDragTo: empty.withOffset(CGVector(dx: -40, dy: 0)))
        XCTAssertTrue(wait { viewport() != beforePan },
                      "Dragging empty ruler space must pan while the document is dirty.")
        XCTAssertEqual(playhead.value as? String, afterScrub, "Panning does not scrub the playhead.")
        XCTAssertEqual(notes.value as? String, "Synthetic unsaved navigation check")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pointer navigation with unsaved episode notes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func exerciseWorkspace(minimumSize: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Unified Workspace Fixture",
            "-WWUITestShowFolder", "WWUITests-Unified-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES",
            "-WWUITestTranscriptFixture", "YES",
        ]
        if minimumSize { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        defer {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Native workspace final state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
        app.activate()
        let addButton = app.buttons["ww.audioWorkspace.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 20), app.debugDescription)
        addButton.click()
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.outlines["ww.setup.speakers"].exists)
        app.buttons["Done"].click()
        XCTAssertTrue(wait { addButton.isHittable })
        if !minimumSize {
            app.typeKey("i", modifierFlags: [.command, .shift])
            let cancelImport = app.buttons["Cancel"]
            XCTAssertTrue(cancelImport.waitForExistence(timeout: 10), app.debugDescription)
            cancelImport.click()
            XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
            app.buttons["Done"].click()
            XCTAssertTrue(wait { addButton.isHittable })
            XCTAssertTrue(app.buttons["ww.show.destination.alignment"].isSelected,
                          "File Import keeps the integrated workspace rather than navigating to legacy Setup.")
        }
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'alignment.waveforms.track.'"))
        XCTAssertTrue(wait { tracks.count == 2 }, app.debugDescription)
        let muteHost = app.buttons["Mute Host"]
        reveal(muteHost, in: app)
        muteHost.click()
        XCTAssertEqual(muteHost.value as? String, "On")
        let soloHost = app.buttons["Solo Host"]
        soloHost.click()
        let layout = app.descendants(matching: .any)["alignment.waveforms.layout"]
        reveal(layout, in: app)
        layout.radioButtons["By recorder"].click()
        let muteRecorder = app.buttons["Mute Studio recorder"]
        reveal(muteRecorder, in: app)
        muteRecorder.click()
        let sourceMute = app.buttons["Mute synthetic-studio.wav"]
        XCTAssertEqual(sourceMute.value as? String, "Off", "Group Mute does not erase or set member choices.")
        muteRecorder.click()
        reveal(layout, in: app)
        layout.radioButtons["By speaker"].click()
        reveal(muteHost, in: app)
        XCTAssertEqual(muteHost.value as? String, "On")
        XCTAssertEqual(soloHost.value as? String, "On")
        muteHost.click()
        soloHost.click()
        XCTAssertEqual(tracks.count, 2, "Solo/Mute and grouping never hide or duplicate recordings.")
        let waveform = tracks.firstMatch
        reveal(waveform, in: app)
        XCTAssertTrue(waveform.isHittable)
        let start = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        let playSelection = app.buttons["Play selection"].firstMatch
        XCTAssertTrue(playSelection.waitForExistence(timeout: 5), app.debugDescription)
        playSelection.click()
        XCTAssertTrue(wait { app.buttons["alignment.waveforms.transport.play"].label == "Pause" }, app.debugDescription)
        let stop = app.buttons["alignment.waveforms.transport.stop"]
        reveal(stop, in: app)
        stop.click()
        reveal(playSelection, in: app)
        app.buttons["Cycle selection"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["Cycle start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Cycle end"].exists)
        let locator = app.images["Cycle end"]
        reveal(locator, in: app)
        let before = locator.frame.midX
        let beforeEndTime = locator.value as? String
        let cycleStart = app.images["Cycle start"]
        let beforeStart = cycleStart.frame.midX
        let beforeStartTime = cycleStart.value as? String
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let beforePlayhead = playhead.value as? String
        XCTAssertNotNil(beforeEndTime)
        XCTAssertNotNil(beforeStartTime)
        XCTAssertNotNil(beforePlayhead)
        let handle = locator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.click(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 20, dy: 0)))
        XCTAssertTrue(wait { locator.frame.midX > before + 10 }, app.debugDescription)
        XCTAssertNotEqual(locator.value as? String, beforeEndTime, "Dragging changes the cycle time, not just its screen position.")
        XCTAssertEqual(cycleStart.frame.midX, beforeStart, accuracy: 0.5, "Cycle dragging does not pan the timeline.")
        XCTAssertEqual(cycleStart.value as? String, beforeStartTime)
        XCTAssertEqual(playhead.value as? String, beforePlayhead, "Cycle dragging does not scrub the playhead.")
        let transcriptSidebar = app.buttons["ww.sidebar.transcript"]
        if transcriptSidebar.value as? String != "Shown" { transcriptSidebar.click() }
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ww.transcript.full.'")).firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["Transcript for visible window"].exists)
        if !minimumSize {
            let reviews = app.buttons["ww.cleanup.fillers.history"]
            reveal(reviews, in: app, scrollID: "ww.inspector")
            reviews.click()
            XCTAssertTrue(wait { reviews.value as? String == "Expanded" }, app.debugDescription)
            let review = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "ww.cleanup.filler.review.")).firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
            reveal(review, in: app, scrollID: "ww.inspector")
            review.click()
            let context = app.buttons["Play with context"].firstMatch
            XCTAssertTrue(context.waitForExistence(timeout: 5), app.debugDescription)
            let loop = app.buttons["ww.cleanup.filler.loop"]
            reveal(loop, in: app)
            loop.click()
            context.click()
            let stopReview = app.buttons["ww.cleanup.filler.stop"]
            XCTAssertTrue(stopReview.waitForExistence(timeout: 5), app.debugDescription)
            reveal(stopReview, in: app)
            XCTAssertTrue(stopReview.isHittable, app.debugDescription)
            stopReview.click()
            XCTAssertTrue(wait {
                !stopReview.exists && app.buttons["alignment.waveforms.transport.play"].label == "Play"
            }, app.debugDescription)
            loop.click()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native integrated workspace, marquee, cycle and readable transcript"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Export…"].click()
        XCTAssertTrue(app.staticTexts["ww.show.blocked.heading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Export isn't available yet"].exists)
        app.buttons["ww.show.destination.alignment"].click()
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollID: String = "ww.alignment.workspace") {
        let scroll = app.scrollViews[scrollID]
        for _ in 0..<12 where !element.isHittable {
            scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY > scroll.frame.midY ? -120 : 120)
        }
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return condition()
    }
}
