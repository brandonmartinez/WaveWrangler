import XCTest

@MainActor
final class VisualAlignmentUITests: XCTestCase {
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
            XCTAssertTrue(waitUntil { confirm.exists }, app.debugDescription)
            let detailScroll = app.scrollViews["ww.setup.inspector"]
            for _ in 0..<8 where !confirm.isHittable {
                detailScroll.scroll(byDeltaX: 0, deltaY: -150)
            }
            XCTAssertTrue(confirm.isHittable, app.debugDescription)
            confirm.click()
            let dialog = app.sheets.firstMatch
            XCTAssertTrue(dialog.buttons["Confirm Original"].waitForExistence(timeout: 5))
            dialog.buttons["Confirm Original"].click()
            XCTAssertTrue(waitUntil { !confirm.exists }, app.debugDescription)
        }

        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 }, app.debugDescription)
        let overlayMode = app.segmentedControls["alignment.waveforms.layout"].buttons["Overlay"]
        scrollTo(overlayMode, in: app)
        overlayMode.click()
        let speakerOverlays = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.overlay."
        ))
        XCTAssertTrue(waitUntil { speakerOverlays.count == 2 })
        XCTAssertTrue(speakerOverlays.allElementsBoundByIndex.contains { $0.label.contains("Host") })
        XCTAssertTrue(speakerOverlays.allElementsBoundByIndex.contains { $0.label.contains("Guest") })
        app.segmentedControls["alignment.waveforms.layout"].buttons["Separate lanes"].click()
        XCTAssertTrue(app.buttons["alignment.waveforms.fitTimeline"].exists)
        XCTAssertTrue(app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.group.", "Studio"
        )).firstMatch.exists)
        XCTAssertTrue(app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.group.", "Remote"
        )).firstMatch.exists)
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        XCTAssertTrue(place.isEnabled)
        place.click()
        let revision = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "guest.wav"
        )).firstMatch
        scrollTo(target, in: app)
        target.click()
        let nudge = app.buttons["Nudge later 10 ms"]
        scrollTo(nudge, in: app)
        if !nudge.isEnabled {
            let other = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "alignment.waveforms.select.", "host.wav"
            )).firstMatch
            scrollTo(other, in: app)
            other.click()
        }
        XCTAssertTrue(nudge.isEnabled)
        nudge.click()
        XCTAssertTrue(waitUntil {
            (revision.value as? String ?? revision.label).contains("Map revision 2")
                && app.buttons["alignment.waveforms.load"].label == "Refresh audio"
        }, app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") })
        let remoteToggle = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.group.", "Remote"
        )).firstMatch
        scrollTo(remoteToggle, in: app)
        remoteToggle.click()
        XCTAssertTrue(waitUntil { tracks.count == 1 })
        let play = app.buttons["alignment.waveforms.transport.play"]
        scrollTo(play, in: app)
        play.click()
        let status = app.staticTexts["alignment.waveforms.transport.status"]
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 1 timed track") },
                      app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(remoteToggle, in: app)
        remoteToggle.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        scrollTo(play, in: app)
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
        XCTAssertTrue(waitUntil { tracks.count == 2 })
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
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
            "-WWUITestDelayWaveformPublication", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        let revision = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.66)
        XCTAssertTrue(waitUntil { tracks.count == 2 && app.buttons["alignment.waveforms.load"].label == "Refresh audio" })
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.track.", "synthetic-remote.wav"
        )).firstMatch
        let separateMode = app.segmentedControls["alignment.waveforms.layout"].buttons["Separate lanes"]

        func dragAndAssert(_ surface: XCUIElement, expectedRevision: Int, previous: Double) -> Double {
            scrollTo(surface, in: app)
            let width = surface.frame.width
            XCTAssertGreaterThan(width, 100)
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 12, dy: 0)))
            let status = app.staticTexts["alignment.waveforms.status"]
            XCTAssertTrue(waitUntil { status.label.contains("visual preview") },
                          "The accepted drag should retain its visible position while the revised tile loads")
            XCTAssertEqual(tracks.count, 2, "Saving must not remove the measured waveform lanes")
            XCTAssertFalse(app.staticTexts["No waveforms showing"].exists)
            XCTAssertFalse(app.buttons["alignment.waveforms.transport.play"].isEnabled)
            XCTAssertTrue(waitUntil {
                (revision.value as? String ?? revision.label).contains("Map revision \(expectedRevision)")
                    && !status.label.contains("visual preview")
                    && app.buttons["alignment.waveforms.load"].label == "Refresh audio"
            }, app.debugDescription)
            scrollTo(separateMode, in: app)
            separateMode.click()
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
        let first = dragAndAssert(target, expectedRevision: 2, previous: 0)
        let overlayMode = app.segmentedControls["alignment.waveforms.layout"].buttons["Overlay"]
        scrollTo(overlayMode, in: app)
        overlayMode.click()
        let overlay = app.staticTexts["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(waitUntil { overlay.exists })
        _ = dragAndAssert(overlay, expectedRevision: 3, previous: first)
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
        ]
        app.launch()
        defer { app.terminate() }
        openAlignment(in: app)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let revision = app.staticTexts["alignment.waveforms.revision"]
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertFalse(app.sliders["alignment.waveforms.scrubber"].exists)
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
        let handle = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertTrue(waitUntil { (Double(playhead.value as? String ?? "") ?? -1) > beforeDrag },
                      "Dragging the ruler marker should move the shared audible playhead")
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
        let overlayMode = app.segmentedControls["alignment.waveforms.layout"].buttons["Overlay"]
        scrollTo(overlayMode, in: app)
        overlayMode.click()
        let overlay = app.staticTexts["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("2 enabled tracks") }, app.debugDescription)
        let normalize = app.checkBoxes["alignment.waveforms.normalizeView"]
        scrollTo(normalize, in: app)
        XCTAssertTrue(normalize.exists)
        normalize.click()
        XCTAssertTrue(app.staticTexts["alignment.waveforms.normalizeNote"].exists)
        normalize.click()
        XCTAssertFalse(app.staticTexts["alignment.waveforms.normalizeNote"].exists)
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        let revision = app.descendants(matching: .any).matching(identifier: "alignment.waveforms.revision").firstMatch
        XCTAssertTrue(waitUntil {
            revision.exists && (revision.value as? String ?? revision.label).contains("Map revision 1")
        })
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "synthetic-remote.wav"
        )).firstMatch
        scrollTo(target, in: app)
        target.click()
        let nudge = app.buttons["Nudge later 10 ms"]
        scrollTo(nudge, in: app)
        XCTAssertTrue(nudge.isEnabled)
        nudge.click()
        XCTAssertTrue(waitUntil {
            revision.exists && (revision.value as? String ?? revision.label).contains("Map revision 2")
        })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            revision.exists && (revision.value as? String ?? revision.label).contains("Map revision 1")
        }, "Undo must restore the prior verified map. \(app.debugDescription)")
        XCTAssertTrue(waitUntil {
            overlay.exists && (overlay.value as? String ?? overlay.label).contains("2 enabled tracks")
        }, "Undo must restore both measured tracks in the overlay.")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil {
            revision.exists && (revision.value as? String ?? revision.label).contains("Map revision 2")
        })
        XCTAssertTrue(waitUntil {
            overlay.exists && (overlay.value as? String ?? overlay.label).contains("2 enabled tracks")
        }, "Redo must restore both measured tracks in the overlay.")
        let trackToggle = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.enabled."
        )).allElementsBoundByIndex.first { $0.label.contains("synthetic-remote.wav") }
        let toggle = try XCTUnwrap(trackToggle)
        scrollTo(toggle, in: app)
        toggle.click()
        let muted = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", "Hidden and muted", "Hidden and muted")
        ).firstMatch
        XCTAssertTrue(waitUntil { muted.exists })
        toggle.click()
        XCTAssertTrue(waitUntil { !muted.exists })
        let group = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.group.", "Remote recorder"
        )).firstMatch
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { !target.exists })
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("1 enabled track") })
        let play = app.buttons["alignment.waveforms.transport.play"]
        scrollTo(play, in: app)
        play.click()
        let status = app.descendants(matching: .any).matching(identifier: "alignment.waveforms.transport.status").firstMatch
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 1 timed track") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { target.exists })
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("2 enabled tracks") })
        scrollTo(play, in: app)
        play.click()
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 2 timed tracks") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        let separateMode = app.segmentedControls["alignment.waveforms.layout"].buttons["Separate lanes"]
        scrollTo(separateMode, in: app)
        separateMode.click()
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
        let advanced = app.disclosureTriangles["Advanced epoch timing"]
        scrollTo(advanced, in: app)
        if String(describing: advanced.value ?? "") == "0" { advanced.click() }
        let offset = app.textFields["alignment.waveforms.offset"]
        scrollTo(offset, in: app)
        XCTAssertTrue(offset.isHittable)
        offset.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("-180")
        app.typeKey(.tab, modifierFlags: [])
        let apply = app.buttons["alignment.waveforms.apply"]
        scrollTo(apply, in: app)
        XCTAssertTrue(apply.isEnabled)
        apply.click()
        attachHierarchy(app, name: "Manual correction publication")
        let revision = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") }, app.debugDescription)
        let targetState = app.staticTexts[target.identifier.replacingOccurrences(of: ".select.", with: ".state.")]
        XCTAssertTrue(waitUntil {
            (targetState.value as? String ?? targetState.label) == "Set by you"
        })
        let compare = app.buttons["alignment.waveforms.compare"]
        scrollTo(compare, in: app)
        XCTAssertTrue(compare.isEnabled)
        compare.click()
        let listening = app.staticTexts["alignment.waveforms.auditionStatus"]
        XCTAssertTrue(waitUntil { (listening.value as? String ?? listening.label).contains("reference channel 1 left") })
        compare.click()
        XCTAssertTrue(waitUntil { compare.label == "Compare Aligned Audio" })
        scrollTo(offset, in: app)
        offset.click()
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (offset.value as? String ?? "") == "0" })
        XCTAssertTrue(waitUntil { tracks.count == 2 }, "Undo must restore actual audio envelopes, not mock data")
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        let referencePoint = app.textFields["alignment.waveforms.referencePoint"]
        let targetPoint = app.textFields["alignment.waveforms.targetPoint"]
        replace(referencePoint, with: "0.6", in: app)
        replace(targetPoint, with: "0.78", in: app)
        let match = app.buttons["Match Anchor"]
        scrollTo(match, in: app)
        match.click()
        replace(referencePoint, with: "1.6", in: app)
        replace(targetPoint, with: "1.78", in: app)
        scrollTo(match, in: app)
        match.click()
        let anchors = app.buttons["Apply 2 Anchors"]
        scrollTo(anchors, in: app)
        XCTAssertTrue(anchors.isEnabled)
        anchors.click()
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") }, app.debugDescription)
        XCTAssertEqual(app.staticTexts["ww.alignment.anchor.0.sourceTime"].value as? String, "00:00:00.780")
        XCTAssertEqual(app.staticTexts["ww.alignment.anchor.0.alignedTime"].value as? String, "00:00:00.600")
        XCTAssertEqual(app.staticTexts["ww.alignment.anchor.1.sourceTime"].value as? String, "00:00:01.780")
        XCTAssertEqual(app.staticTexts["ww.alignment.anchor.1.alignedTime"].value as? String, "00:00:01.600")
        XCTAssertTrue((app.staticTexts["ww.inspector.alignment.basis"].value as? String ?? "").contains("Fitted from"))
        scrollTo(offset, in: app)
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
        load.click()
        XCTAssertEqual(load.label, "Cancel", "Switch episodes while the actual decoded result is awaiting publication")
        let second = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "ww.show.sidebar.episode.", "Synthetic Episode 2", "Synthetic Episode 2"
        )).firstMatch
        XCTAssertTrue(second.exists)
        second.click()
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

    func testMeasuredOverviewOpensExactWindowAndEpisodeSwitchClearsIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Visual Alignment Overview",
            "-WWUITestShowEpisodes", "2", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES",
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
        let zoom = app.sliders["alignment.waveforms.zoom"]
        scrollTo(zoom, in: app)
        zoom.adjust(toNormalizedSliderPosition: 0.82)
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })

        app.disclosureTriangles["Episode overview"].click()
        let overviews = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.overview.track.")
        )
        XCTAssertTrue(waitUntil { overviews.count == 2 })
        for overview in overviews.allElementsBoundByIndex {
            XCTAssertTrue(
                overview.label.contains("complete measured PCM overview")
                    || (overview.value as? String ?? "").contains("complete measured PCM overview")
            )
        }
        let oldOverviewIDs = Set(overviews.allElementsBoundByIndex.map(\.identifier))
        let oldTrackIDs = Set(tracks.allElementsBoundByIndex.map(\.identifier))
        let status = app.staticTexts["alignment.waveforms.overview.status"]
        XCTAssertTrue((status.value as? String ?? status.label).contains("2 cached PCM overviews"))
        let overviewActions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.overview.open.")
        )
        XCTAssertEqual(overviewActions.count, 2)
        let oldActionIDs = Set(overviewActions.allElementsBoundByIndex.map(\.identifier))
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.overview.open.", "synthetic-remote.wav"
        )).firstMatch
        XCTAssertTrue(target.exists)
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let revision = app.staticTexts["alignment.waveforms.revision"]
        scrollTo(revision, in: app)
        XCTAssertTrue(revision.exists)
        let storedRevision = revision.value as? String ?? revision.label
        replace(playhead, with: "-1", in: app)
        XCTAssertTrue(waitUntil { (Double(playhead.value as? String ?? "") ?? -1) >= 0 },
                      "Out-of-range overview navigation must be refused")
        replace(playhead, with: "3.5", in: app)
        XCTAssertTrue(waitUntil { target.isEnabled })
        scrollTo(target, in: app)
        XCTAssertTrue(target.isHittable)
        target.click()
        XCTAssertTrue(waitUntil {
            tracks.count == 2 && load.label == "Refresh audio"
        }, app.debugDescription)
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("Visible aligned time ruler"))
        XCTAssertEqual(revision.value as? String ?? revision.label, storedRevision)
        scrollTo(target, in: app)
        XCTAssertEqual(Set(overviews.allElementsBoundByIndex.map(\.identifier)), oldOverviewIDs)
        attachHierarchy(app, name: "Measured episode overview opened exact audio window without editing timing")
        let second = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "ww.show.sidebar.episode.", "Synthetic Episode 2", "Synthetic Episode 2"
        )).firstMatch
        XCTAssertTrue(second.exists)
        second.click()
        XCTAssertTrue(waitUntil { app.windows["ww.show.window"].title.contains("Synthetic Episode 2") })
        XCTAssertTrue(waitUntil {
            oldOverviewIDs.isDisjoint(with: Set(overviews.allElementsBoundByIndex.map(\.identifier)))
        })
        XCTAssertTrue(waitUntil { overviews.count == 2 })
        XCTAssertTrue(oldOverviewIDs.isDisjoint(with: Set(overviews.allElementsBoundByIndex.map(\.identifier))))
        XCTAssertEqual(overviewActions.count, 2)
        XCTAssertTrue(oldActionIDs.isDisjoint(with: Set(overviewActions.allElementsBoundByIndex.map(\.identifier))))
        XCTAssertTrue(oldTrackIDs.isDisjoint(with: Set(tracks.allElementsBoundByIndex.map(\.identifier))))
        attachHierarchy(app, name: "Second episode overview replaces all first-episode waveform identities")
    }

    private func openAlignment(in app: XCUIApplication) {
        let destination = app.buttons["ww.show.destination.alignment"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.click()
        XCTAssertTrue(destination.isSelected)
    }

    private func chooseImportFolder(_ folder: URL, in app: XCUIApplication) {
        let service = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
        XCTAssertTrue(waitUntil {
            service.state != .notRunning || app.windows["open-panel"].exists
                || app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists
        }, "The sandboxed import panel must appear")
        Thread.sleep(forTimeInterval: 2)
        let target = service.state == .notRunning ? app : service
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

    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        scrollTo(field, in: app)
        XCTAssertTrue(field.isHittable)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        app.typeKey(.tab, modifierFlags: [])
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

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["ww.alignment.workspace"]
        for _ in 0..<10 {
            if element.exists {
                if element.isHittable, scroll.frame.insetBy(dx: 0, dy: 25).contains(element.frame) { return }
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.midY ? 150 : -150)
            } else {
                scroll.scroll(byDeltaX: 0, deltaY: -150)
            }
        }
    }
}
