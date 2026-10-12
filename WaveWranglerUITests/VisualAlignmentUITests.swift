import XCTest

@MainActor
final class VisualAlignmentUITests: XCTestCase {
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
        let overlayMode = app.buttons["alignment.waveforms.layout.overlay"]
        scrollTo(overlayMode, in: app)
        overlayMode.click()
        let overlay = app.staticTexts["alignment.waveforms.overlay"]
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("2 enabled tracks") }, app.debugDescription)
        let place = app.buttons["alignment.waveforms.placeInitial"]
        scrollTo(place, in: app)
        place.click()
        let revision = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
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
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 1") })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (revision.value as? String ?? revision.label).contains("Map revision 2") })
        let trackToggle = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.enabled."
        )).allElementsBoundByIndex.first { $0.label.contains("synthetic-remote.wav") }
        let toggle = try XCTUnwrap(trackToggle)
        scrollTo(toggle, in: app)
        toggle.click()
        XCTAssertTrue(waitUntil { app.staticTexts["Hidden and muted"].exists })
        toggle.click()
        XCTAssertTrue(waitUntil { !app.staticTexts["Hidden and muted"].exists })
        let group = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.group.", "Remote recorder"
        )).firstMatch
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { !target.exists })
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("1 enabled track.") })
        let play = app.buttons["alignment.waveforms.transport.play"]
        scrollTo(play, in: app)
        play.click()
        let status = app.staticTexts["alignment.waveforms.transport.status"]
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 1 enabled track") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        scrollTo(group, in: app)
        group.click()
        XCTAssertTrue(waitUntil { target.exists })
        XCTAssertTrue(waitUntil { (overlay.value as? String ?? overlay.label).contains("2 enabled tracks") })
        scrollTo(play, in: app)
        play.click()
        XCTAssertTrue(waitUntil { (status.value as? String ?? status.label).contains("Playing 2 enabled tracks") }, app.debugDescription)
        app.buttons["alignment.waveforms.transport.stop"].click()
        let separateMode = app.buttons["alignment.waveforms.layout.separate"]
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
        let reopened = app.staticTexts["alignment.waveforms.revision"]
        XCTAssertTrue(waitUntil { (reopened.value as? String ?? reopened.label).contains("Map revision 2") })
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
        attachHierarchy(app, name: "Decoded waveform accessibility")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Actual synthetic audio before manual alignment"
        before.lifetime = .keepAlways
        add(before)
        let findings = try AcceptanceAudit.run(
            app, surface: "measured visual alignment", test: self, types: AcceptanceAudit.essentialTypes
        )
        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "\n"))

        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "alignment.waveforms.select.", "synthetic-remote.wav"
        )).firstMatch
        target.click()
        let advanced = app.disclosureTriangles["Advanced epoch timing"]
        scrollTo(advanced, in: app)
        if advanced.value as? String == "0" { advanced.click() }
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

        let zoom = app.buttons["alignment.waveforms.span.1.0"]
        scrollTo(zoom, in: app)
        zoom.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        replace(app.textFields["alignment.waveforms.start"], with: "0.5", in: app)
        load.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("0.500 to 1.500"))
        let next = app.buttons["Next"]
        next.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("1.500 to 2.500"))
        app.buttons["Previous"].click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("0.500 to 1.500"))
        attachHierarchy(app, name: "Zoomed genuine audio in second episode; first-episode identities absent")
    }

    func testMeasuredOverviewOpensExactWindowAndEpisodeSwitchClearsIt() throws {
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
        let span = app.buttons["alignment.waveforms.span.1.0"]
        scrollTo(span, in: app)
        span.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Refresh audio" })

        let overviewDisclosure = app.disclosureTriangles["Episode overview"]
        scrollTo(overviewDisclosure, in: app)
        overviewDisclosure.click()
        let build = app.buttons["alignment.waveforms.overview.load"]
        scrollTo(build, in: app)
        XCTAssertTrue(build.isEnabled)
        build.click()
        let overviews = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.overview.track.")
        )
        XCTAssertTrue(waitUntil { overviews.count == 2 && build.label == "Build Episode Overview" })
        for overview in overviews.allElementsBoundByIndex {
            XCTAssertTrue(
                overview.label.contains("complete measured PCM overview")
                    || (overview.value as? String ?? "").contains("complete measured PCM overview")
            )
        }
        let oldOverviewIDs = Set(overviews.allElementsBoundByIndex.map(\.identifier))
        let oldTrackIDs = Set(tracks.allElementsBoundByIndex.map(\.identifier))
        let status = app.staticTexts["alignment.waveforms.overview.status"]
        XCTAssertTrue((status.value as? String ?? status.label).contains("2 complete PCM overviews"))
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
        let start = app.textFields["alignment.waveforms.start"]
        let playhead = app.textFields["alignment.waveforms.playhead"]
        let revision = app.staticTexts["alignment.waveforms.revision"]
        scrollTo(revision, in: app)
        XCTAssertTrue(revision.exists)
        let storedRevision = revision.value as? String ?? revision.label
        let targetPoint = app.textFields["alignment.waveforms.targetPoint"]
        scrollTo(targetPoint, in: app)
        let storedTargetPoint = try XCTUnwrap(targetPoint.value as? String)

        replace(playhead, with: "-1", in: app)
        XCTAssertTrue(waitUntil { !target.isEnabled }, "Out-of-range AX navigation must be unavailable")
        scrollTo(start, in: app)
        XCTAssertEqual(Double(start.value as? String ?? ""), 0)
        replace(playhead, with: "3.5", in: app)
        XCTAssertTrue(waitUntil { target.isEnabled })
        scrollTo(target, in: app)
        XCTAssertTrue(target.isHittable)
        target.click()
        scrollTo(start, in: app)
        XCTAssertTrue(waitUntil {
            tracks.count == 2 && load.label == "Refresh audio"
                && Double(start.value as? String ?? "") == 3
        }, app.debugDescription)
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("3.000 to 4.000"))
        XCTAssertEqual(revision.value as? String ?? revision.label, storedRevision)
        scrollTo(targetPoint, in: app)
        XCTAssertEqual(targetPoint.value as? String, storedTargetPoint, "Overview navigation must not create an anchor")
        scrollTo(target, in: app)
        XCTAssertEqual(Set(overviews.allElementsBoundByIndex.map(\.identifier)), oldOverviewIDs)
        attachHierarchy(app, name: "Measured episode overview opened exact audio window without editing timing")
        let findings = try AcceptanceAudit.run(
            app, surface: "measured episode overview", test: self, types: AcceptanceAudit.essentialTypes
        )
        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "\n"))

        let second = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "ww.show.sidebar.episode.", "Synthetic Episode 2", "Synthetic Episode 2"
        )).firstMatch
        XCTAssertTrue(second.exists)
        second.click()
        XCTAssertTrue(waitUntil { app.windows["ww.show.window"].title.contains("Synthetic Episode 2") })
        XCTAssertTrue(waitUntil {
            overviews.count == 0 && overviewActions.count == 0 && tracks.count == 0
                && build.label == "Build Episode Overview"
        })
        scrollTo(build, in: app)
        build.click()
        XCTAssertTrue(waitUntil { overviews.count == 2 && build.label == "Build Episode Overview" })
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

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(20)
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
