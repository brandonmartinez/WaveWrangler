import AppKit
import XCTest

@MainActor
final class VisualAlignmentUITests: XCTestCase {
    func testUngroupedOnboardingInEveryLayoutAndResizableRecordings() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "WWUITests-Onboarding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeAlignmentWAV(to: root.appending(path: "first.wav"), delayFrames: 0)
        try writeAlignmentWAV(to: root.appending(path: "second.wav"), delayFrames: 0)
        let originals = try ["first.wav", "second.wav"].map { try Data(contentsOf: root.appending(path: $0)) }
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Source Onboarding",
            "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        defer { app.terminate() }
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: [.command, .shift])
        chooseImportFolder(root, in: app)
        XCTAssertTrue(app.buttons["ww.import.confirm"].waitForExistence(timeout: 10))
        app.buttons["ww.import.confirm"].click()
        XCTAssertTrue(waitUntil { !app.descendants(matching: .any)["ww.import.review"].exists })
        XCTAssertFalse(app.buttons["ww.setup.authorizeOriginals"].exists)
        app.buttons["ww.show.destination.alignment"].click()
        let section = app.descendants(matching: .any)["alignment.ungrouped"]
        XCTAssertTrue(section.waitForExistence(timeout: 15), app.debugDescription)
        app.descendants(matching: .any)["alignment.waveforms.fillSpace"].click()
        for mode in ["By recorder", "By speaker", "Overlay", "Speakers only"] {
            selectTimelineLayout(mode, in: app)
            XCTAssertTrue(section.exists, "\(mode) must retain the independent Ungrouped section")
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'alignment.ungrouped.source.'"))
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allElementsBoundByIndex.contains { $0.label.contains("first.wav") })
            XCTAssertTrue(rows.allElementsBoundByIndex.contains { $0.label.contains("second.wav") })
            XCTAssertEqual(app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'alignment.waveforms.track.'")).count, 0)
        }
        let firstRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.ungrouped.source.' AND label CONTAINS 'first.wav'")).firstMatch
        let add = firstRow.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.ungrouped.add.'")).firstMatch
        scrollTo(add, in: app)
        add.click()
        add.menuItems["New Recorder Group…"].click()
        let name = app.textFields["ww.setup.nameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        app.typeText("Field recorder")
        app.sheets.buttons["Create"].click()
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'alignment.ungrouped.source.'"))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { rows.count == 2 })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { rows.count == 1 })
        let secondRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.ungrouped.source.' AND label CONTAINS 'second.wav'")).firstMatch
        let second = secondRow.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'alignment.ungrouped.add.'")).firstMatch
        scrollTo(second, in: app)
        second.click()
        second.menuItems["Field recorder"].click()
        XCTAssertTrue(waitUntil { !section.exists })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { rows.count == 1 })

        app.buttons["Add recordings or speakers"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        // The outline document can exceed its viewport while adaptive columns refit.
        let sourceViewport = sheet.scrollViews.containing(.outline, identifier: "ww.setup.sources").firstMatch
        XCTAssertTrue(sourceViewport.waitForExistence(timeout: 5))
        // Sheets resize symmetrically horizontally; stay above the details-layout breakpoint.
        let initial = sheet.frame
        let initialRight = sheet.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        initialRight.click(forDuration: 0.1, thenDragTo: initialRight.withOffset(CGVector(dx: -50, dy: 0)))
        let initialBottom = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        initialBottom.click(forDuration: 0.1, thenDragTo: initialBottom.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertTrue(waitUntil { sheet.frame.width < initial.width - 70 && sheet.frame.height < initial.height - 60 },
                      "Recordings & Speakers must shrink in both dimensions: \(initial) -> \(sheet.frame)")
        let before = sheet.frame
        let viewportBefore = sourceViewport.frame
        attachHierarchy(app, name: "Recordings sheet and source viewport after shrinking")
        let right = sheet.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        right.click(forDuration: 0.1, thenDragTo: right.withOffset(CGVector(dx: 40, dy: 0)))
        let bottom = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        bottom.click(forDuration: 0.1, thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertTrue(waitUntil { sheet.frame.width > before.width + 70 && sheet.frame.height > before.height + 70 },
                      "Recordings & Speakers must resize in width and height: \(app.debugDescription)")
        attachHierarchy(app, name: "Recordings sheet and source viewport after expanding")
        XCTAssertGreaterThan(sourceViewport.frame.width, viewportBefore.width + 40)
        XCTAssertGreaterThan(sourceViewport.frame.height, viewportBefore.height + 20)
        XCTAssertTrue(sheet.sliders["ww.setup.split"].exists)
        sheet.buttons["Done"].click()
        XCTAssertEqual(try ["first.wav", "second.wav"].map { try Data(contentsOf: root.appending(path: $0)) }, originals)
    }

    func testLegacyRecordingsUseOneBulkApproval() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Older Recordings",
            "-WWUITestShowEpisodes", "1", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestLegacyOriginals", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        app.typeKey("1", modifierFlags: .command)
        let review = app.buttons["ww.setup.authorizeOriginals"]
        XCTAssertTrue(review.waitForExistence(timeout: 15), app.debugDescription)
        review.click()
        let list = app.descendants(matching: .any)["ww.setup.originalAuthorization.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(list.staticTexts["synthetic-studio.wav"].exists)
        XCTAssertTrue(list.staticTexts["synthetic-remote.wav"].exists)
        app.buttons["ww.setup.originalAuthorization.approve"].click()
        XCTAssertTrue(waitUntil { !review.exists }, app.debugDescription)
        XCTAssertFalse(app.buttons["ww.inspector.source.confirmOriginal"].exists)
        openAlignment(in: app)
        assertLoadedRecordings(["synthetic-studio.wav", "synthetic-remote.wav"], in: app)
        let align = app.buttons["ww.workflow.alignTracks"]
        XCTAssertTrue(align.exists && align.isEnabled)
        XCTAssertTrue(app.buttons["ww.workflow.transcribeTracks"].exists)
        XCTAssertFalse(app.buttons["Begin editing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ww.listening.savedPolicy"].exists)
        align.click()
        XCTAssertTrue(app.sheets.buttons["Analyze Tracks"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertFalse(app.staticTexts["Review Tracks Alignment"].exists)
        align.click()
        app.sheets.buttons["Analyze Tracks"].click()
        XCTAssertTrue(app.staticTexts["Review Tracks Alignment"].waitForExistence(timeout: 30),
                      app.debugDescription)
        XCTAssertTrue(app.buttons["ww.workflow.acceptAlignment"].exists)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil { !app.staticTexts["Review Tracks Alignment"].exists })
    }

    func testNormalImportThroughSavedManualPlayback() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WWUITests-NormalAlignment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appending(path: "Recordings", directoryHint: .isDirectory)
        let studio = sources.appending(path: "Studio", directoryHint: .isDirectory)
        let remote = sources.appending(path: "Remote", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let host = studio.appending(path: "host.wav")
        let guest = remote.appending(path: "guest.wav")
        try writeAlignmentWAV(to: host, delayFrames: 0)
        try writeAlignmentWAV(to: guest, delayFrames: 8_640)
        let original = try [host, guest].map { try Data(contentsOf: $0) }

        let app = XCUIApplication()
        let folder = "WWUITests-NormalAudio-\(UUID().uuidString)"
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Normal Import Fixture",
            "-WWUITestShowFolder", folder,
            "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        defer { app.terminate() }
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: [.command, .shift])
        chooseImportFolder(sources, in: app)
        let review = app.descendants(matching: .any)["ww.import.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.buttons["ww.import.confirm"].label, "Import 2")
        let accept = app.buttons["Accept All Suggestions"]
        XCTAssertTrue(accept.isEnabled)
        accept.click()
        app.buttons["ww.import.confirm"].click()
        XCTAssertTrue(waitUntil { !review.exists })
        XCTAssertTrue(waitUntil { app.outlines["ww.setup.speakers"].outlineRows.count == 2 })

        for name in ["host.wav", "guest.wav"] {
            let outline = app.outlines["ww.setup.sources"]
            let details = app.buttons["ww.setup.detailsToggle"]
            if details.label == "Hide Details" { details.click() }
            let row = outline.outlineRows.containing(NSPredicate(
                format: "identifier BEGINSWITH 'ww.setup.source.' AND (label == %@ OR value == %@)",
                name, name
            )).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            let speaker = row.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'ww.setup.source.' AND identifier ENDSWITH '.speaker'"
            )).firstMatch
            XCTAssertTrue(waitUntil {
                speaker.exists && (speaker.value as? String) == (name == "host.wav" ? "Host" : "Guest")
            }, "Accepted import suggestions should classify each synthetic speaker")
            XCTAssertTrue(row.isHittable, app.debugDescription)
            for offset in [0.15, 0.3, 0.03] {
                row.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)).click()
                if waitUntil({
                    row.isSelected && (outline.value as? String) == "1 selected"
                        && app.staticTexts["Details — \(name)"].exists
                }, timeout: 2) { break }
            }
            XCTAssertTrue(row.isSelected && (outline.value as? String) == "1 selected"
                && app.staticTexts["Details — \(name)"].exists, app.debugDescription)
            if details.label == "Show Details" { details.click() }
            let inspector = app.descendants(matching: .any)["ww.inspector.source.name"]
            XCTAssertTrue(waitUntil {
                inspector.exists && (inspector.value as? String ?? inspector.label).contains(name)
            }, app.debugDescription)
            let confirm = app.buttons["ww.inspector.source.confirmOriginal"]
            XCTAssertFalse(confirm.exists, "Explicit import already authorizes this recording")
            XCTAssertFalse(app.buttons["ww.setup.authorizeOriginals"].exists)
        }

        openAlignment(in: app)
        assertLoadedRecordings(["host.wav", "guest.wav"], in: app)
        selectTimelineLayout("Overlay", in: app)
        let speakerOverlays = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.overlay."
        ))
        for speaker in ["Host", "Guest"] {
            let overlay = speakerOverlays.matching(NSPredicate(format: "label CONTAINS %@", speaker)).firstMatch
            scrollTo(overlay, in: app)
            XCTAssertTrue(overlay.isHittable)
        }
        selectTimelineLayout("By recorder", in: app)
        XCTAssertTrue(app.buttons["alignment.waveforms.fitTimeline"].exists)
        for group in ["Studio", "Remote"] {
            let mute = app.scrollViews["ww.alignment.workspace"].buttons["Mute \(group)"]
            scrollTo(mute, in: app)
            XCTAssertTrue(mute.isHittable)
        }
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        XCTAssertTrue(place.isEnabled)
        place.click()
        let revision = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        unlockTarget(in: app)
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "guest.wav"
        )).firstMatch
        scrollTo(target, in: app)
        target.click()
        showAdvancedTiming(in: app)
        let nudge = app.buttons["Nudge later 10 ms"]
        scrollTo(nudge, in: app, sidebar: "recording")
        XCTAssertTrue(waitUntil { nudge.isEnabled })
        nudge.click()
        XCTAssertTrue(waitUntil {
            (revision.value as? String ?? revision.label).contains("Map revision 2")
                && app.buttons["alignment.waveforms.load"].label == "Refresh audio"
        }, app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") })
        let remoteToggle = app.scrollViews["ww.alignment.workspace"].buttons["Mute Remote"]
        scrollTo(remoteToggle, in: app)
        remoteToggle.click()
        XCTAssertTrue(waitUntil { (remoteToggle.value as? String) == "On" })
        assertMeasuredRecordings(["host.wav", "guest.wav"], in: app)
        let play = app.buttons["alignment.waveforms.transport.play"]
        XCTAssertTrue(play.isHittable)
        play.click()
        let status = app.staticTexts["alignment.waveforms.transport.status"]
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 1 timed track") },
                      app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(remoteToggle, in: app)
        remoteToggle.click()
        assertMeasuredRecordings(["host.wav", "guest.wav"], in: app)
        play.click()
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 2 timed tracks") },
                      app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        app.typeKey("s", modifierFlags: .command)
        let save = app.descendants(matching: .any).matching(identifier: "ww.show.saveStatus").firstMatch
        XCTAssertTrue(waitUntil { (save.value as? String ?? save.label).hasPrefix("Saved") })
        app.terminate()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestOpenWithoutShowWindows", "\(folder)/Normal Import Fixture.wwshow",
        ]
        app.launch()
        openAlignment(in: app)
        XCTAssertTrue(waitUntil {
            (app.staticTexts["alignment.waveforms.revision"].value as? String
                ?? app.staticTexts["alignment.waveforms.revision"].label).contains("Map revision 2")
        })
        assertLoadedRecordings(["host.wav", "guest.wav"], in: app)
        XCTAssertEqual(try [host, guest].map { try Data(contentsOf: $0) }, original)
    }

    func testShortDragsCommitOnlyTheirPointerSizedMapDelta() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Small Drag Fixture",
            "-WWEditingPlaybackPolicy", "keepChoices",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestUnplacedAlignmentFixture", "YES",
            "-WWUITestDelayWaveformPublication", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        XCTAssertFalse(app.staticTexts["alignment.waveforms.revision"].exists)
        let tool = app.menuButtons["alignment.waveforms.tool"]
        scrollTo(tool, in: app)
        tool.click()
        app.menuItems["Move recorder"].click()
        replace(app.textFields["alignment.waveforms.playhead"], with: "2.5", in: app)
        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.66)
        XCTAssertTrue(waitUntil { tracks.count == 2 && app.buttons["alignment.waveforms.load"].label == "Refresh audio" })
        let target = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.track.", "synthetic-remote.wav"
        )).firstMatch

        func dragAndAssert(_ surface: XCUIElement, expectedRevision: Int, previous: Double) -> Double {
            scrollTo(surface, in: app)
            let width = surface.frame.width
            XCTAssertGreaterThan(width, 100)
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 12, dy: 0)))
            let status = app.scrollViews["ww.alignment.workspace"]
            let processing = app.descendants(matching: .any)["ww.trackProcessing.overlay"]
            let zoom = app.sliders["alignment.waveforms.zoom"]
            XCTAssertTrue(zoom.exists, "Fixed track chrome remains present during the save.")
            XCTAssertTrue(waitForMapRevision(expectedRevision, in: app), app.debugDescription)
            XCTAssertTrue(waitUntil { !processing.exists && surface.exists },
                          "Verified timing must restore the interactive waveform surface")
            let shownRecordings = app.scrollViews["ww.alignment.workspace"].buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Mute synthetic-"
            ))
            XCTAssertEqual(shownRecordings.count, 2, "Both measured recordings must return in either layout")
            XCTAssertFalse(app.staticTexts["No waveforms showing"].exists)
            XCTAssertTrue(waitUntil {
                (status.value as? String ?? status.label).contains("updated in place")
                    && app.buttons["alignment.waveforms.load"].label == "Refresh audio"
            }, app.debugDescription)
            selectTimelineLayout("By recorder", in: app)
            XCTAssertTrue(waitUntil { target.exists && target.label.contains("Stored offset ") })
            let storedText = target.label.components(separatedBy: "Stored offset ").last?
                .components(separatedBy: " milliseconds").first ?? ""
            let stored = Double(storedText)
            XCTAssertNotNil(stored)
            XCTAssertGreaterThan((stored ?? 0) - previous, 0)
            XCTAssertLessThan((stored ?? 0) - previous, 500,
                              "A short pointer movement must not become a multi-second saved offset")
            return stored ?? 0
        }
        let first = dragAndAssert(target, expectedRevision: 1, previous: 0)
        selectTimelineLayout("By speaker", in: app)
        let second = dragAndAssert(target, expectedRevision: 2, previous: first)
        selectTimelineLayout("Overlay", in: app)
        let overlay = app.descendants(matching: .any)["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(waitUntil { overlay.exists })
        _ = dragAndAssert(overlay, expectedRevision: 3, previous: second)
    }

    func testRulerAndTimeFieldNavigateAllSyntheticRecorderWindows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Shared Timeline Fixture",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestUnplacedAlignmentFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let revision = app.staticTexts["alignment.waveforms.revision"]
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertFalse(app.sliders["alignment.waveforms.scrubber"].exists)
        XCTAssertTrue(waitUntil {
            revision.exists && (revision.value as? String ?? revision.label).contains("Map revision 1")
        }, app.debugDescription)
        replace(playhead, with: "3.5", in: app)
        XCTAssertTrue(waitUntil {
            (Double(playhead.value as? String ?? "") ?? -1) > 2
                && (ruler.value as? String ?? ruler.label).contains("Visible aligned time ruler")
        }, "Editing aligned time must move the shared playhead")
        XCTAssertTrue(waitUntil {
            tracks.count == 2 && !app.buttons["alignment.waveforms.load"].label.contains("Cancel")
        }, app.debugDescription)
        XCTAssertTrue((revision.value as? String ?? revision.label).contains("Map revision 1"))
        replace(playhead, with: "4.5", in: app)
        XCTAssertTrue(waitUntil {
            tracks.count == 2 && app.buttons["alignment.waveforms.load"].label == "Refresh audio"
                && abs((Double(playhead.value as? String ?? "") ?? -1) - 4.5) < 0.01
        }, app.debugDescription)
        XCTAssertTrue((revision.value as? String ?? revision.label).contains("Map revision 1"))

        let rulerSurface = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"]
        scrollTo(rulerSurface, in: app)
        XCTAssertTrue(rulerSurface.exists)
        rulerSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.8)).click()
        XCTAssertTrue(waitUntil { (Double(playhead.value as? String ?? "") ?? -1) < 4.5 })
        let marker = app.descendants(matching: .any)["alignment.waveforms.ruler.playhead"]
        XCTAssertTrue(marker.exists)
        XCTAssertTrue(marker.label.contains("Aligned playhead"))
        let beforeDrag = Double(playhead.value as? String ?? "") ?? -1
        let handle = rulerSurface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: marker.frame.midX - rulerSurface.frame.minX, dy: 37
        ))
        handle.click(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 12, dy: 0)))
        let markerMoved = waitUntil { (Double(playhead.value as? String ?? "") ?? -1) > beforeDrag }
        if !markerMoved { attachDisplay(app, name: "Ruler after marker drag") }
        XCTAssertTrue(markerMoved,
                      "Dragging the ruler marker should move the shared audible playhead")
        let afterDrag = Double(playhead.value as? String ?? "") ?? -1
        let beforePan = ruler.value as? String ?? ruler.label
        let emptyRuler = rulerSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
        emptyRuler.click(forDuration: 0.3, thenDragTo: emptyRuler.withOffset(CGVector(dx: -60, dy: 0)))
        XCTAssertTrue(waitUntil { (ruler.value as? String ?? ruler.label) != beforePan },
                      "Dragging empty ruler space should still pan the shared timeline")
        XCTAssertEqual(Double(playhead.value as? String ?? "") ?? -1, afterDrag, accuracy: 0.001)
    }

    func testUntimedSoloAndPairedPointsAllowManualPlacementThenFurtherDragging() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Paired Manual Alignment",
            "-WWUITestShowEpisodes", "1", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES", "-WWUITestUnplacedAlignmentFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        openAlignment(in: app)
        selectTimelineLayout("By recorder", in: app)
        func track(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'alignment.waveforms.track.' AND label CONTAINS %@", name)).firstMatch
        }
        let reference = track("synthetic-studio.wav")
        let target = track("synthetic-remote.wav")
        scrollTo(reference, in: app)
        XCTAssertTrue(reference.exists, app.debugDescription)
        scrollTo(target, in: app)
        XCTAssertTrue(target.exists, app.debugDescription)
        let solo = app.scrollViews["ww.alignment.workspace"].buttons["Solo synthetic-remote.wav"]
        scrollTo(solo, in: app)
        solo.click()
        XCTAssertTrue(app.descendants(matching: .any)["alignment.waveforms.sourceTime"].waitForExistence(timeout: 5))
        let play = app.buttons["alignment.waveforms.transport.play"]
        scrollTo(play, in: app)
        play.click()
        let status = app.descendants(matching: .any)["alignment.waveforms.transport.status"]
        XCTAssertTrue(waitUntil {
            (status.value as? String ?? status.label).contains("original source time")
        }, app.debugDescription)
        XCTAssertFalse(app.staticTexts["alignment.waveforms.revision"].exists)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(solo, in: app)
        solo.click()
        replace(app.textFields["alignment.waveforms.playhead"], with: "2.5", in: app)
        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertTrue(waitUntil { !app.descendants(matching: .any)["ww.trackProcessing.overlay"].exists })
        let anchors = app.descendants(matching: .any)["alignment.waveforms.anchorPoints"]
        scrollTo(reference, in: app)
        reference.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        anchors.click()
        app.menuItems["Mark reference point"].click()
        scrollTo(target, in: app)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        anchors.click()
        app.menuItems["Link matching point"].click()
        anchors.click()
        app.menuItems["Apply offset from this pair"].click()
        XCTAssertTrue(waitForMapRevision(1, in: app), app.debugDescription)
        XCTAssertFalse(app.textFields["alignment.numeric.rate"].exists, "Point matching must not require numeric entry")
        let tool = app.menuButtons["alignment.waveforms.tool"]
        scrollTo(tool, in: app)
        tool.click()
        app.menuItems["Move recorder"].click()
        scrollTo(target, in: app)
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertTrue(waitForMapRevision(2, in: app), app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForMapRevision(1, in: app))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForMapRevision(2, in: app))
    }

    func testEnabledManualGroupMoveAndPlaybackOnSyntheticRecorders() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let folder = "WWUITests-ManualAudio-\(UUID().uuidString)"
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Manual Recorder Fixture",
            "-WWUITestShowFolder", folder,
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestUnplacedAlignmentFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 }, app.debugDescription)
        selectTimelineLayout("Overlay", in: app)
        let overlay = app.descendants(matching: .any)["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(waitUntil { overlay.label.contains("2 tracks") }, app.debugDescription)
        let normalize = app.checkBoxes["alignment.waveforms.normalizeView"]
        scrollTo(normalize, in: app)
        if !normalize.exists { attachDisplay(app, name: "Overlay comparison controls") }
        XCTAssertTrue(normalize.exists)
        normalize.click()
        XCTAssertEqual(String(describing: normalize.value ?? ""), "1")
        normalize.click()
        XCTAssertEqual(String(describing: normalize.value ?? ""), "0")
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        let revision = app.descendants(matching: .any).matching(identifier: "alignment.waveforms.revision").firstMatch
        XCTAssertTrue(waitForMapRevision(1, in: app))
        selectTimelineLayout("By recorder", in: app)
        unlockTarget(in: app)
        selectTimelineLayout("Overlay", in: app)
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "synthetic-remote.wav"
        )).firstMatch
        scrollTo(target, in: app)
        target.click()
        let nudge = app.buttons["Nudge later 10 ms"]
        scrollTo(nudge, in: app, sidebar: "recording")
        XCTAssertTrue(nudge.isEnabled)
        nudge.click()
        XCTAssertTrue(waitForMapRevision(2, in: app))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForMapRevision(1, in: app),
                      "Undo must restore the prior verified map. \(app.debugDescription)")
        XCTAssertTrue(waitUntil {
            overlay.exists && overlay.label.contains("2 tracks")
        }, "Undo must restore both measured tracks in the overlay.")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForMapRevision(2, in: app))
        XCTAssertTrue(waitUntil {
            overlay.exists && overlay.label.contains("2 tracks")
        }, "Redo must restore both measured tracks in the overlay.")
        let toggle = app.scrollViews["ww.alignment.workspace"].buttons["Mute synthetic-remote.wav"]
        scrollTo(toggle, in: app)
        toggle.click()
        XCTAssertTrue(waitUntil { (toggle.value as? String) == "On" && target.exists })
        toggle.click()
        XCTAssertTrue(waitUntil { (toggle.value as? String) == "Off" })
        selectTimelineLayout("By recorder", in: app)
        let group = app.scrollViews["ww.alignment.workspace"].buttons["Mute Remote recorder"]
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { target.exists && (group.value as? String) == "On" })
        let play = app.buttons["alignment.waveforms.transport.play"]
        scrollTo(play, in: app)
        play.click()
        let status = app.descendants(matching: .any).matching(identifier: "alignment.waveforms.transport.status").firstMatch
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 1 timed track") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { target.exists })
        XCTAssertTrue(waitUntil { (group.value as? String) == "Off" })
        scrollTo(play, in: app)
        play.click()
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 2 timed tracks") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        selectTimelineLayout("By recorder", in: app)
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        app.typeKey("s", modifierFlags: .command)
        let saveStatus = app.descendants(matching: .any).matching(identifier: "ww.show.saveStatus").firstMatch
        XCTAssertTrue(waitUntil { (saveStatus.value as? String ?? saveStatus.label).hasPrefix("Saved") })
        app.terminate()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestOpenWithoutShowWindows", "\(folder)/Manual Recorder Fixture.wwshow",
        ]
        app.launch()
        openAlignment(in: app)
        let reopened = app.descendants(matching: .any).matching(identifier: "alignment.waveforms.revision").firstMatch
        XCTAssertTrue(waitUntil {
            reopened.exists && (reopened.value as? String ?? reopened.label).contains("Map revision 2")
        })
    }

    func testActualWaveformsManualCorrectionAndUndo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestOpenShow", "Visual Alignment Fixture",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestUnplacedAlignmentFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let load = app.buttons["alignment.waveforms.load"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 }, "Actual decoding must publish both waveform lanes")
        for track in tracks.allElementsBoundByIndex {
            XCTAssertTrue(track.label.contains("measured amplitude bins"))
        }
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        XCTAssertTrue(waitForMapRevision(1, in: app), app.debugDescription)
        unlockTarget(in: app)
        attachHierarchy(app, name: "Decoded waveform display")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Actual synthetic audio before manual alignment"
        before.lifetime = .keepAlways
        add(before)
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "synthetic-remote.wav"
        )).firstMatch
        target.click()
        showAdvancedTiming(in: app)
        let offset = app.textFields["alignment.waveforms.offset"]
        scrollTo(offset, in: app, sidebar: "recording")
        if !offset.isHittable { attachDisplay(app, name: "Advanced timing after disclosure activation") }
        XCTAssertTrue(offset.isHittable)
        offset.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("-180")
        app.typeKey(.tab, modifierFlags: [])
        let apply = app.buttons["alignment.waveforms.apply"]
        scrollTo(apply, in: app, sidebar: "recording")
        XCTAssertTrue(apply.isEnabled)
        apply.click()
        attachHierarchy(app, name: "Manual correction publication")
        XCTAssertTrue(waitForMapRevision(2, in: app), app.debugDescription)
        let targetState = app.staticTexts["ww.inspector.alignment.state"]
        XCTAssertTrue(waitUntil {
            (targetState.value as? String ?? targetState.label) == "Set by you"
        })
        let compare = app.buttons["alignment.waveforms.compare"]
        scrollTo(compare, in: app, sidebar: "recording")
        XCTAssertTrue(compare.isEnabled)
        compare.click()
        let listening = app.staticTexts["alignment.waveforms.transport.status"]
        XCTAssertTrue(waitUntil { (listening.value as? String ?? listening.label).contains("reference channel 1 left") })
        compare.click()
        XCTAssertTrue(waitUntil { compare.label == "Compare Aligned Audio" })
        scrollTo(offset, in: app, sidebar: "recording")
        offset.click()
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (offset.value as? String ?? "") == "0" })
        XCTAssertTrue(waitUntil { tracks.count == 2 }, "Undo must restore actual audio envelopes, not mock data")
        XCTAssertTrue(waitForMapRevision(1, in: app), app.debugDescription)
        let referencePoint = app.textFields["alignment.waveforms.referencePoint"]
        let targetPoint = app.textFields["alignment.waveforms.targetPoint"]
        replace(referencePoint, with: "0.6", in: app, sidebar: "recording")
        replace(targetPoint, with: "0.78", in: app, sidebar: "recording")
        let match = app.buttons["Match Anchor"]
        scrollTo(match, in: app, sidebar: "recording")
        match.click()
        replace(referencePoint, with: "1.6", in: app, sidebar: "recording")
        replace(targetPoint, with: "1.78", in: app, sidebar: "recording")
        scrollTo(match, in: app, sidebar: "recording")
        match.click()
        let anchors = app.buttons["Apply 2 Anchors"]
        scrollTo(anchors, in: app, sidebar: "recording")
        XCTAssertTrue(anchors.isEnabled)
        anchors.click()
        XCTAssertTrue(waitForMapRevision(2, in: app), app.debugDescription)
        showSidebar("alignment", in: app)
        for (identifier, value) in [
            ("ww.alignment.anchor.0.sourceTime", "00:00:00.780"),
            ("ww.alignment.anchor.0.alignedTime", "00:00:00.600"),
            ("ww.alignment.anchor.1.sourceTime", "00:00:01.780"),
            ("ww.alignment.anchor.1.alignedTime", "00:00:01.600"),
        ] {
            let cell = app.staticTexts[identifier]
            scrollTo(cell, in: app, sidebar: "alignment")
            XCTAssertEqual(cell.value as? String, value)
        }
        let evidence = app.disclosureTriangles["Timing evidence"]
        scrollTo(evidence, in: app, sidebar: "recording")
        if String(describing: evidence.value ?? "") == "0" {
            evidence.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 27, dy: 0)).click()
        }
        let basis = app.staticTexts["ww.inspector.alignment.basis"]
        scrollTo(basis, in: app, sidebar: "recording")
        XCTAssertTrue((basis.value as? String ?? "").contains("Fitted from"))
        showAdvancedTiming(in: app)
        scrollTo(offset, in: app, sidebar: "recording")
        XCTAssertEqual(Double(offset.value as? String ?? ""), -180)
        scrollTo(target, in: app)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Measured waveforms after matching two anchors"
        after.lifetime = .keepAlways
        add(after)
    }

    func testZoomPanAndEpisodeSwitchDiscardLateWaveforms() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Visual Alignment Switch",
            "-WWUITestShowEpisodes", "2", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES", "-WWUITestDelayWaveformPublication", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let load = app.buttons["alignment.waveforms.load"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        let oldIDs = Set(tracks.allElementsBoundByIndex.map(\.identifier))
        scrollTo(load, in: app)
        load.click()
        XCTAssertTrue(waitUntil { load.label == "Cancel" }, "The delayed decode must expose real cancellation")
        XCTAssertTrue(load.isEnabled)
        load.click()
        XCTAssertTrue(waitUntil { load.label == "Refresh audio" }, "Cancel must end the in-flight waveform load")
        XCTAssertEqual(tracks.count, 0, "Canceled refresh must not expose a partially decoded result")
        load.click()
        XCTAssertTrue(waitUntil { load.label == "Cancel" },
                      "Switch episodes while the actual decoded result is awaiting publication")
        EpisodeLibraryNavigation.openEpisode(containing: "Synthetic Episode 2", in: app, destination: "2")
        XCTAssertTrue(waitUntil { app.windows["ww.show.window"].title.contains("Synthetic Episode 2") })
        XCTAssertTrue(waitUntil { load.exists && load.label == "Refresh audio" && tracks.count == 2 })
        XCTAssertTrue(oldIDs.isDisjoint(with: Set(tracks.allElementsBoundByIndex.map(\.identifier))))

        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.82)
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        replace(app.textFields["alignment.waveforms.playhead"], with: "1", in: app)
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("Visible aligned time ruler"))
        replace(app.textFields["alignment.waveforms.playhead"], with: "3", in: app)
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        XCTAssertTrue((Double(app.textFields["alignment.waveforms.playhead"].value as? String ?? "") ?? 0) > 2)
        attachHierarchy(app, name: "Zoomed genuine audio in second episode; first-episode identities absent")
    }

    func testMainTimelineNavigationNeedsNoSecondaryOverviewAndEpisodeSwitchClearsTracks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Visual Alignment Overview",
            "-WWUITestShowEpisodes", "2", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestUnplacedAlignmentFixture", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let load = app.buttons["alignment.waveforms.load"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        XCTAssertTrue(waitForMapRevision(1, in: app))
        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.82)
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })

        let overviewDisclosure = app.disclosureTriangles.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Episode overview")
        ).firstMatch
        XCTAssertFalse(overviewDisclosure.exists)
        let oldTrackIDs = Set(tracks.allElementsBoundByIndex.map(\.identifier))
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let revision = app.staticTexts["alignment.waveforms.revision"]
        scrollTo(revision, in: app, sidebar: "recording")
        XCTAssertTrue(revision.exists)
        let storedRevision = revision.value as? String ?? revision.label
        replace(playhead, with: "-86401", in: app)
        XCTAssertTrue(waitUntil { (Double(playhead.value as? String ?? "") ?? -1) >= 0 },
                      "Out-of-range timeline navigation must be refused")
        replace(playhead, with: "3.5", in: app)
        XCTAssertTrue(waitUntil {
            tracks.count == 2 && load.label == "Refresh audio"
        }, app.debugDescription)
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("Visible aligned time ruler"))
        XCTAssertEqual(revision.value as? String ?? revision.label, storedRevision)
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), oldTrackIDs)
        attachHierarchy(app, name: "Main timeline navigated without a secondary overview or timing edit")
        EpisodeLibraryNavigation.openEpisode(containing: "Synthetic Episode 2", in: app, destination: "2")
        XCTAssertTrue(waitUntil { app.windows["ww.show.window"].title.contains("Synthetic Episode 2") })
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        XCTAssertFalse(overviewDisclosure.exists)
        XCTAssertTrue(oldTrackIDs.isDisjoint(with: Set(tracks.allElementsBoundByIndex.map(\.identifier))))
        attachHierarchy(app, name: "Second episode replaces all first-episode waveform identities")
    }

    private func unlockTarget(in app: XCUIApplication) {
        let lock = app.buttons.matching(NSPredicate(format: "label == 'Lock position' AND value == 'Locked'")).firstMatch
        let unlocked = app.buttons.matching(NSPredicate(format: "label == 'Lock position' AND value == 'Unlocked'")).firstMatch
        for _ in 0..<8 {
            if unlocked.exists { return }
            if lock.exists { break }
            app.scrollViews["ww.alignment.workspace"].scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertTrue(lock.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(lock, in: app)
        let identifier = lock.identifier
        lock.click()
        let updated = app.buttons[identifier]
        scrollTo(updated, in: app)
        XCTAssertTrue(waitUntil { updated.exists && (updated.value as? String) == "Unlocked" })
    }

    private func openAlignment(in app: XCUIApplication) {
        let destination = app.buttons["ww.show.destination.alignment"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.click()
        XCTAssertTrue(destination.isSelected)
        showSidebar("recording", in: app)
    }

    private func showSidebar(_ activity: String, in app: XCUIApplication) {
        let toggle = app.buttons["ww.sidebar.\(activity)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The \(activity) activity toggle must be exposed")
        if toggle.value as? String != "Shown" { toggle.click() }
        XCTAssertTrue(waitUntil { toggle.value as? String == "Shown" })
        let root = activity == "alignment" ? "ww.inspector.alignment.details" : "ww.inspector"
        XCTAssertTrue(app.scrollViews[root].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func showAdvancedTiming(in app: XCUIApplication) {
        showSidebar("recording", in: app)
        let advanced = app.scrollViews["ww.inspector"].disclosureTriangles["Advanced timing"]
        scrollTo(advanced, in: app, sidebar: "recording")
        if String(describing: advanced.value ?? "") == "0" {
            advanced.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 27, dy: 0)).click()
        }
        XCTAssertTrue(waitUntil { String(describing: advanced.value ?? "") == "1" })
        XCTAssertTrue(app.scrollViews["ww.inspector"].textFields["alignment.waveforms.offset"].exists,
                      "Reopening an activity recreates its disclosure state; reveal timing before reading it")
    }

    private func chooseImportFolder(_ folder: URL, in app: XCUIApplication) {
        let identifier = "com.apple.appkit.xpc.openAndSavePanelService"
        var service: XCUIApplication?
        var panelHost: XCUIApplication?
        guard waitUntil({
            // A cold guest registers this service only after its first native panel opens.
            if service == nil, NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil {
                service = XCUIApplication(bundleIdentifier: identifier)
            }
            if let service, service.state != .notRunning {
                panelHost = service
                return true
            }
            if app.windows["open-panel"].exists || app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists {
                panelHost = app
                return true
            }
            return false
        }), let target = panelHost else {
            return XCTFail("The sandboxed import panel must appear before addressing its host")
        }
        Thread.sleep(forTimeInterval: 2)
        target.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        target.typeText(folder.path)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        target.typeKey(.return, modifierFlags: [])
    }

    private func writeAlignmentWAV(to url: URL, delayFrames: Int) throws {
        let rate = 48_000
        let frames = rate * 5
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(frames * 2))
        for frame in 0..<frames {
            let time = Double(frame - delayFrames) / Double(rate)
            let active = (0.6..<0.85).contains(time)
                || (1.6..<1.85).contains(time) || (3.2..<3.45).contains(time)
            append(active ? Int16(sin(time * 2 * .pi * 330) * 18_000) : 0)
        }
        try data.write(to: url, options: .atomic)
    }

    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication, sidebar: String? = nil) {
        scrollTo(field, in: app, sidebar: sidebar)
        XCTAssertTrue(field.isHittable)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        app.typeKey(.tab, modifierFlags: [])
    }

    private func attachDisplay(_ app: XCUIApplication, name: String) {
        attachHierarchy(app, name: name)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func attachHierarchy(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForMapRevision(_ revision: Int, in app: XCUIApplication) -> Bool {
        showSidebar("recording", in: app)
        let text = "Map revision \(revision)"
        return app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "alignment.waveforms.revision", text, text
        )).firstMatch.waitForExistence(timeout: 20)
    }

    private func recordingsAreLoaded(_ count: Int, in app: XCUIApplication) -> Bool {
        let status = app.scrollViews["ww.alignment.workspace"]
        return status.exists && !app.descendants(matching: .any)["ww.trackProcessing.overlay"].exists
            && (status.value as? String ?? status.label).contains("\(count) recordings loaded")
    }

    private func assertLoadedRecordings(_ names: [String], in app: XCUIApplication) {
        XCTAssertTrue(waitUntil { recordingsAreLoaded(names.count, in: app) }, app.debugDescription)
        assertMeasuredRecordings(names, in: app)
    }

    private func assertMeasuredRecordings(_ names: [String], in app: XCUIApplication) {
        for name in names {
            let track = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "alignment.waveforms.track.", name
            )).firstMatch
            scrollTo(track, in: app)
            XCTAssertTrue(track.label.contains("measured amplitude bins."), "Expected a measured waveform for \(name)")
        }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, sidebar: String? = nil) {
        if let sidebar { showSidebar(sidebar, in: app) }
        // Listening controls intentionally share identifiers across the canvas and Recording activity.
        let scroll = sidebar.map { app.scrollViews[$0 == "alignment" ? "ww.inspector.alignment.details" : "ww.inspector"] }
            ?? app.scrollViews["ww.alignment.workspace"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        if sidebar == nil, element.exists, !element.identifier.isEmpty,
           !scroll.descendants(matching: .any).matching(identifier: element.identifier).firstMatch.exists {
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            XCTAssertTrue(app.windows["ww.show.window"].frame.contains(center),
                          "Anchored controls must stay inside the show window")
            XCTAssertTrue(element.isHittable, "Anchored controls must be directly hittable without scrolling tracks")
            return
        }
        if !element.exists {
            for _ in 0..<12 {
                if element.exists { break }
                scroll.scroll(byDeltaX: 0, deltaY: 200)
            }
        }
        for _ in 0..<40 {
            guard element.exists else {
                scroll.scroll(byDeltaX: 0, deltaY: -80)
                continue
            }
            let viewport = scroll.frame.intersection(app.windows["ww.show.window"].frame)
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if viewport.contains(center), element.isHittable { return }
            if viewport.minY <= center.y, center.y <= viewport.maxY,
               center.x < viewport.minX || center.x > viewport.maxX {
                let key = element.identifier.isEmpty ? element.label : element.identifier
                let horizontal = scroll.descendants(matching: .scrollView).allElementsBoundByIndex
                    .filter { $0.descendants(matching: .any).matching(identifier: key).firstMatch.exists }
                    .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? scroll
                horizontal.scroll(byDeltaX: center.x > viewport.midX ? -80 : 80, deltaY: 0)
            } else {
                scroll.scroll(byDeltaX: 0, deltaY: center.y < viewport.midY ? 80 : -80)
            }
        }
        XCTAssertTrue(element.exists, "Control must exist in its owning scroll area: \(element.debugDescription)\n\(app.debugDescription)")
        if element.exists {
            XCTAssertTrue(scroll.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)),
                          "\(element.identifier) must be inside its activity's viewport")
            XCTAssertTrue(element.isHittable, "\(element.identifier) must be hittable after scrolling")
        }
    }
}
