import XCTest

@MainActor
final class VisualAlignmentUITests: XCTestCase {
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
        load.click()
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
        load.click()
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
        XCTAssertTrue(waitUntil { load.exists && load.label == "Load Audio Window" && tracks.count == 0 })
        load.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 })
        XCTAssertTrue(oldIDs.isDisjoint(with: Set(tracks.allElementsBoundByIndex.map(\.identifier))))

        let zoom = app.buttons["alignment.waveforms.span.1.0"]
        scrollTo(zoom, in: app)
        zoom.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Load Audio Window" })
        replace(app.textFields["alignment.waveforms.start"], with: "0.5", in: app)
        load.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Load Audio Window" })
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("0.500 to 1.500"))
        let next = app.buttons["Next"]
        next.click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Load Audio Window" })
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("1.500 to 2.500"))
        app.buttons["Previous"].click()
        XCTAssertTrue(waitUntil { tracks.count == 2 && load.label == "Load Audio Window" })
        XCTAssertTrue((ruler.value as? String ?? ruler.label).contains("0.500 to 1.500"))
        attachHierarchy(app, name: "Zoomed genuine audio in second episode; first-episode identities absent")
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
