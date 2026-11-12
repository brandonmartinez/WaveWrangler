import XCTest

@MainActor
final class MixerUITests: XCTestCase {
    private func launch(minimum: Bool = false, autosave: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES",
            "-WWUITestAutosave", autosave ? "ON" : "OFF", "-WWUITestOpenShow", "Mixer UI Fixture",
            "-WWUITestShowFolder", "WWUITests-Mixer-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestCleanupFixture", "YES", "-WWUITestCleanupTimelineFixture", "YES",
            "-WWUITestTranscriptFixture", "YES",
        ]
        if minimum { app.launchArguments += ["-WWUITestMixerOverflowFixture", "YES"] }
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.mixer.toggle"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    func testAutoInputGainIsExplicitPerSpeakerAndUsesTheSettingsTarget() throws {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        let input = app.buttons.matching(NSPredicate(
            format: "identifier ENDSWITH '.input' AND label CONTAINS 'input information and appearance'")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), app.debugDescription)
        let strip = String(input.identifier.dropLast(".input".count))
        let gain = app.textFields["\(strip).inputGain"]
        XCTAssertTrue(gain.exists)
        let initialGain = gain.value as? String
        input.click()
        let disclosure = app.disclosureTriangles["Auto Input Gain"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), app.debugDescription)
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        let run = app.buttons["\(strip).autoInputGain.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5) && run.isEnabled, app.debugDescription)
        XCTAssertEqual(gain.value as? String, initialGain, "Opening the control must not analyze or adjust gain.")
        app.buttons["\(strip).autoInputGain.settings"].click()
        let settings = app.windows["ww.settings.window"]
        let target = settings.textFields["ww.settings.autoInputGain.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        target.click()
        target.typeKey("a", modifierFlags: .command)
        target.typeText("-24")
        target.typeKey(.return, modifierFlags: [])
        settings.typeKey("w", modifierFlags: .command)
        if !run.exists {
            input.click()
            disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH 'Target:' AND value CONTAINS '-24'")).firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertEqual(gain.value as? String, initialGain, "Changing the preference must not alter existing gain.")
        run.click()
        let status = app.staticTexts["\(strip).autoInputGain.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), app.debugDescription)
        let message = status.value as? String ?? status.label
        XCTAssertTrue(message.contains("Set input gain"), message)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Per-speaker Auto Input Gain result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let applied = gain.value as? String
        XCTAssertNotEqual(applied, initialGain)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { gain.value as? String == initialGain })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { gain.value as? String == applied })
    }

    func testOptionClickOpensReviewAndMixerDirectlyInSeparateWindows() {
        let app = launch()
        defer { app.terminate() }
        let main = app.windows["ww.show.window"]
        XCTAssertTrue(main.waitForExistence(timeout: 20))
        for panel in ["review", "mixer"] {
            let toggle = main.buttons["ww.\(panel).toggle"]
            let docked = main.descendants(matching: .any)[panel == "review" ? "ww.review.panel" : "ww.mixer.docked"]
            let window = app.windows["ww.\(panel).window"]
            let hide = main.buttons["ww.bottomPane.hide"]
            if hide.exists { hide.click() }
            toggle.click()
            XCTAssertTrue(docked.waitForExistence(timeout: 5), "\(panel) still opens docked on an ordinary click.")
            toggle.click()
            XCTAssertTrue(docked.waitForNonExistence(timeout: 5))

            XCUIElement.perform(withKeyModifiers: .option) { toggle.click() }
            XCTAssertTrue(window.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(docked.exists)
            XCTAssertFalse(hide.exists, "Option-click from hidden must not open the bottom pane.")
            XCUIElement.perform(withKeyModifiers: .option) { toggle.click() }
            XCTAssertEqual(app.windows.matching(identifier: "ww.\(panel).window").count, 1)
            XCTAssertFalse(hide.exists, "Refocusing a detached window must not open the bottom pane.")

            window.buttons["ww.\(panel).reattach"].click()
            XCTAssertTrue(window.waitForNonExistence(timeout: 5))
            XCTAssertTrue(docked.waitForExistence(timeout: 5))
            XCUIElement.perform(withKeyModifiers: .option) { toggle.click() }
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            XCTAssertFalse(docked.exists, "Option-click also detaches an already-docked panel.")
            toggle.click()
            XCTAssertTrue(window.exists, "An ordinary click retains the detached window.")
            XCTAssertEqual(app.windows.matching(identifier: "ww.\(panel).window").count, 1)
            window.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(window.waitForNonExistence(timeout: 5))
            XCTAssertTrue(main.exists)
        }
    }

    private func insertPills(in scope: XCUIElement) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(NSPredicate(
            format: "identifier MATCHES %@", "ww\\.mixer\\.slot\\.[A-Fa-f0-9-]+"))
    }

    func testReviewMixerResizeDetachReattachAndOriginClose() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.review.toggle"].click()
        let review = app.descendants(matching: .any)["ww.review.panel"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        let before = review.frame.height
        let divider = app.splitGroups.splitters.firstMatch
        if divider.exists && divider.isHittable {
            let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.click(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: -30)))
        }
        app.buttons["ww.mixer.toggle"].click()
        XCTAssertTrue(app.descendants(matching: .any)["ww.mixer.docked"].waitForExistence(timeout: 10))
        XCTAssertFalse(review.exists)
        XCTAssertFalse(app.buttons["ww.mixer.play"].exists)
        XCTAssertFalse(app.buttons["ww.mixer.stop"].exists)
        XCTAssertFalse(app.staticTexts["Bottom pane"].exists)
        app.buttons["ww.bottomPane.detachMixer"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mixer.title.contains("Mixer"))
        XCTAssertFalse(app.descendants(matching: .any)["ww.mixer.docked"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ww.bottomPane.content"].exists)
        app.buttons["ww.mixer.toggle"].click()
        XCTAssertEqual(app.windows.matching(identifier: "ww.mixer.window").count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["ww.bottomPane.content"].exists,
                       "Focusing the detached mixer must not reopen an empty docked pane.")
        mixer.buttons["ww.mixer.reattach"].click()
        XCTAssertTrue(wait { !mixer.exists })
        XCTAssertTrue(app.descendants(matching: .any)["ww.mixer.docked"].exists)
        app.buttons["ww.review.toggle"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(review.frame.height, before - 40)
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.bottomPane.detachMixer"].click()
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let origin = app.windows["ww.show.window"]
        origin.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !mixer.exists }, "An auxiliary mixer must not outlive its originating editor.")
    }

    func testMasterRemainsVisibleWhileSpeakerStripsScrollAtMinimumWidth() {
        let app = launch(minimum: true)
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        let master = app.descendants(matching: .any)["ww.mixer.strip.master.name"]
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        let frame = master.frame
        let speakers = app.scrollViews["ww.mixer.speakers"]
        XCTAssertTrue(speakers.exists)
        let scrollbar = app.scrollBars["ww.mixer.trackScrollbar"]
        XCTAssertTrue(scrollbar.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollbar.isHittable, "Overflow must have a persistent, usable horizontal scrollbar.")
        XCTAssertGreaterThan(scrollbar.frame.width, scrollbar.frame.height)
        let speakerNames = speakers.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH '.name'"))
        let firstName = app.descendants(matching: .any)[speakerNames.firstMatch.identifier]
        let originalX = firstName.frame.minX
        let knob = scrollbar.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        knob.click(forDuration: 0.1,
                   thenDragTo: scrollbar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(wait { firstName.frame.minX < originalX - 10 })
        speakers.scroll(byDeltaX: 350, deltaY: 0)
        XCTAssertTrue(master.isHittable, app.debugDescription)
        XCTAssertEqual(master.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(master.frame.width, frame.width, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Empty"].exists)
        let mode = app.descendants(matching: .any)["ww.controlBar.listeningMode"].firstMatch
        mode.click()
        app.menuItems["Source Audition"].click()
        let masterGain = app.textFields["ww.mixer.strip.master.gain"]
        XCTAssertTrue(wait { masterGain.exists && !masterGain.isEnabled })
        let addEffect = app.descendants(matching: .any)["ww.mixer.strip.master.add"]
        XCTAssertFalse(addEffect.isEnabled)
        let inputGain = app.textFields.matching(NSPredicate(format: "identifier ENDSWITH '.inputGain'")).firstMatch
        XCTAssertTrue(inputGain.isEnabled, "Recording gain still applies to source listening.")
        mode.click()
        app.menuItems["Production Mix"].click()
        XCTAssertTrue(wait { masterGain.isEnabled && addEffect.isEnabled })
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pinned Master and horizontally scrolled speaker strips"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testGenericAppleEditorDirtyUndoSaveAndDetachedCloseReopen() {
        let app = launch(autosave: true)
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.bottomPane.detachMixer"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let add = mixer.descendants(matching: .any)["ww.mixer.strip.master.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.click()
        app.menuItems["Apple"].hover()
        app.menuItems["AULowpass"].click()
        let pill = insertPills(in: mixer).firstMatch
        guard pill.waitForExistence(timeout: 10) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Mixer after adding an effect"
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
            XCTFail(app.debugDescription)
            return
        }
        pill.hover()
        let actions = mixer.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.actions'")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5), app.debugDescription)
        actions.hover()
        actions.click()
        app.menuItems["Generic Parameters"].click()
        let editor = app.windows["ww.mixer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(mixer.staticTexts["\(pill.identifier).name"].waitForExistence(timeout: 5),
                      "Opening generic parameters must restore the insert name without another pointer movement.")
        XCTAssertFalse(actions.exists)
        let value = editor.textFields["ww.mixer.parameter.0"]
        XCTAssertTrue(value.waitForExistence(timeout: 10), app.debugDescription)
        value.click()
        value.typeKey("a", modifierFlags: .command)
        value.typeText("1000")
        value.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(wait { (value.value as? String)?.contains("1000") == true || (value.value as? String)?.contains("1,000") == true },
                      "Parameter field: \(String(describing: value.value)). \(app.debugDescription)")
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true },
                      "Automatic save must finish with the insert editor open.\n\(app.debugDescription)")
        value.click()
        value.typeKey("a", modifierFlags: .command)
        value.typeText("2000")
        value.typeKey(.return, modifierFlags: [])
        editor.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(wait { (app.buttons["ww.show.saveStatus"].value as? String)?.hasPrefix("Saved") == true },
                      app.debugDescription)
        editor.buttons["ww.mixer.editor.done"].click()
        XCTAssertTrue(wait { !editor.exists })
        mixer.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !mixer.exists })
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.bottomPane.detachMixer"].click()
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        insertPills(in: mixer).firstMatch.hover()
        let open = mixer.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.editor'")).firstMatch
        open.hover()
        open.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !editor.exists })
        mixer.typeKey("z", modifierFlags: .command)
        mixer.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.staticTexts["ww.mixer.error"].exists, app.debugDescription)
    }

    func testConsoleControlsAndSharedGapPreservingInsertRows() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.bottomPane.detachMixer"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let masterFader = mixer.descendants(matching: .any)["ww.mixer.strip.master.fader"]
        let speakerFader = mixer.descendants(matching: .any).matching(NSPredicate(
            format: "identifier MATCHES %@", "ww\\.mixer\\.strip\\.[A-Fa-f0-9-]+\\.fader")).firstMatch
        XCTAssertEqual(masterFader.frame.height, speakerFader.frame.height, accuracy: 1)
        let masterName = mixer.staticTexts["ww.mixer.strip.master.name"]
        XCTAssertEqual(masterName.frame.width, 144, accuracy: 1)
        let speakers = mixer.scrollViews["ww.mixer.speakers"]
        let firstName = speakers.descendants(matching: .any).matching(NSPredicate(
            format: "identifier ENDSWITH '.name'")).firstMatch
        XCTAssertEqual(firstName.frame.minX, speakers.frame.minX, accuracy: 1,
                       "Track strips stay left-aligned when the viewport is wider than their content.")
        XCTAssertFalse(mixer.scrollBars["ww.mixer.trackScrollbar"].exists)
        let empty = mixer.descendants(matching: .any)["ww.mixer.strip.master.add"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        empty.click()
        app.menuItems["Apple"].hover()
        app.menuItems["AULowpass"].click()
        let lowpass = insertPills(in: mixer).firstMatch
        XCTAssertTrue(lowpass.waitForExistence(timeout: 5))
        let lowpassID = lowpass.identifier
        lowpass.hover()
        let actions = mixer.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.actions'")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.hover()
        actions.click()
        app.menuItems["Move Later"].click()
        XCTAssertTrue(wait { mixer.descendants(matching: .any)["ww.mixer.strip.master.empty.2"].exists })
        let first = mixer.descendants(matching: .any)["ww.mixer.strip.master.add"]
        let movedLowpass = mixer.descendants(matching: .any)[lowpassID]
        XCTAssertLessThan(first.frame.minY, movedLowpass.frame.minY, "Moving to an empty row must leave the preceding row blank.")
        let blanks = mixer.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.empty.2'"))
        XCTAssertGreaterThanOrEqual(blanks.count, 2, "All strips share the furthest occupied row plus a trailing blank.")
        first.click()
        app.menuItems["Apple"].hover()
        app.menuItems["AUHipass"].click()
        XCTAssertTrue(wait { insertPills(in: mixer).count == 2 })
        let highpass = insertPills(in: mixer).matching(NSPredicate(format: "label BEGINSWITH 'AUHipass,'")).firstMatch
        let highpassID = highpass.identifier
        let target = mixer.descendants(matching: .any)["ww.mixer.strip.master.add"]
        XCTAssertGreaterThan(target.frame.minY, movedLowpass.frame.minY)
        let grip = mixer.descendants(matching: .any)["\(highpassID).drag"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.3, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        guard wait({ mixer.descendants(matching: .any)["ww.mixer.strip.master.empty.3"].exists }) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Mixer after dragging to an empty row"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Dragging onto the trailing blank must leave the old row empty and extend every rack.\n\(app.debugDescription)")
            return
        }
        let movedHighpass = mixer.descendants(matching: .any)[highpassID]
        XCTAssertGreaterThan(movedHighpass.frame.minY, movedLowpass.frame.minY)
        mixer.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { movedHighpass.frame.minY < movedLowpass.frame.minY })
        mixer.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { movedHighpass.frame.minY > movedLowpass.frame.minY })
        let thirdBlank = mixer.descendants(matching: .any)["ww.mixer.strip.master.empty.3"]
        thirdBlank.click()
        app.menuItems["Apple"].hover()
        app.menuItems["AUParametricEQ"].click()
        XCTAssertTrue(wait { insertPills(in: mixer).count == 3 })
        let eq = insertPills(in: mixer).matching(NSPredicate(format: "label BEGINSWITH 'AUParametricEQ,'")).firstMatch
        let eqID = eq.identifier
        let beforeReorderLowpassY = movedLowpass.frame.minY
        let beforeReorderHighpassY = movedHighpass.frame.minY
        mixer.descendants(matching: .any)["\(eqID).drag"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo: movedLowpass.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let movedEQ = mixer.descendants(matching: .any)[eqID]
        XCTAssertTrue(wait { movedEQ.frame.minY < movedLowpass.frame.minY
            && movedLowpass.frame.minY < movedHighpass.frame.minY })
        XCTAssertEqual(movedEQ.frame.minY, beforeReorderLowpassY, accuracy: 1)
        XCTAssertEqual(movedLowpass.frame.minY, beforeReorderHighpassY, accuracy: 1,
                       "Moving last to first shifts the intervening effects instead of swapping endpoints.")
        XCTAssertEqual(insertPills(in: mixer).count, 3, "Reordering must not copy an effect.")
        mixer.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { movedEQ.frame.minY > movedHighpass.frame.minY })
        mixer.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait { movedEQ.frame.minY < movedLowpass.frame.minY })
        mixer.descendants(matching: .any)["\(eqID).drag"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo: movedHighpass.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(wait { movedLowpass.frame.minY < movedHighpass.frame.minY
            && movedHighpass.frame.minY < movedEQ.frame.minY },
                      "Moving first to last shifts the intervening effects upward.")
        XCTAssertEqual(insertPills(in: mixer).count, 3)
        mixer.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(wait { movedEQ.frame.minY < movedLowpass.frame.minY })
        XCUIElement.perform(withKeyModifiers: .option) { movedHighpass.click() }
        XCTAssertTrue(wait { movedHighpass.label.contains("bypassed") }, app.debugDescription)
        XCUIElement.perform(withKeyModifiers: .option) {
            movedHighpass.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        }
        XCTAssertTrue(wait { !movedHighpass.label.contains("bypassed") },
                      "Option-click must toggle bypass even over the disclosure control.")
        movedHighpass.doubleClick()
        let editor = app.windows["ww.mixer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue(mixer.staticTexts["\(highpassID).name"].waitForExistence(timeout: 5),
                      "Opening the native editor must clear the insert's hover and keyboard-focus controls.")
        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(wait { !editor.exists })
    }

    func testConsoleResetsAndSpeakerAppearance() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.mixer.toggle"].click()
        app.buttons["ww.bottomPane.detachMixer"].click()
        let mixer = app.windows["ww.mixer.window"]
        XCTAssertTrue(mixer.waitForExistence(timeout: 5))
        let masterFader = mixer.descendants(matching: .any)["ww.mixer.strip.master.fader"]
        let pan = mixer.descendants(matching: .any).matching(NSPredicate(
            format: "identifier ENDSWITH '.pan.dial'")).firstMatch
        pan.click()
        let panField = mixer.textFields.matching(NSPredicate(format: "identifier ENDSWITH '.pan'")).firstMatch
        let originalPan = panField.value as? String
        pan.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait { panField.value as? String != originalPan })
        XCUIElement.perform(withKeyModifiers: .option) { pan.click() }
        XCTAssertTrue(wait { panField.value as? String == originalPan })
        pan.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait { panField.value as? String != originalPan })
        pan.doubleClick()
        XCTAssertTrue(wait { panField.value as? String == originalPan })
        let inputGain = mixer.descendants(matching: .any).matching(NSPredicate(
            format: "identifier ENDSWITH '.inputGain.dial'")).firstMatch
        let inputField = mixer.textFields.matching(NSPredicate(format: "identifier ENDSWITH '.inputGain'")).firstMatch
        inputGain.click()
        mixer.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(wait { inputField.value as? String != "0.00" })
        XCUIElement.perform(withKeyModifiers: .option) { inputGain.click() }
        XCTAssertTrue(wait { inputField.value as? String == "0.00" }, app.debugDescription)
        XCTAssertTrue(masterFader.exists)
        mixer.scrollViews["ww.mixer.console"].scroll(byDeltaX: 0, deltaY: -200)
        let before = mixer.textFields["ww.mixer.strip.master.gain"].value as? String
        masterFader.click()
        masterFader.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(wait { (mixer.textFields["ww.mixer.strip.master.gain"].value as? String) != before })
        XCUIElement.perform(withKeyModifiers: .option) { masterFader.click() }
        XCTAssertTrue(wait { mixer.textFields["ww.mixer.strip.master.gain"].value as? String == before })
        let identity = mixer.buttons.matching(NSPredicate(
            format: "identifier MATCHES %@", "ww\\.mixer\\.strip\\.[A-Fa-f0-9-]+\\.input")).firstMatch
        identity.click()
        XCTAssertTrue(mixer.buttons["workspace.speaker.chooseAvatar"].waitForExistence(timeout: 5))
        XCTAssertTrue(mixer.popUpButtons["workspace.speaker.color"].exists)
        XCTAssertFalse(mixer.checkBoxes["workspace.speaker.host"].exists)
        mixer.typeKey(.escape, modifierFlags: [])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Console controls reset to defaults"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
