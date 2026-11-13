import AppKit
import XCTest

@MainActor
final class EpisodeExportUITests: XCTestCase {
    private func launch(slowExport: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Export Fixture",
            "-WWUITestShowFolder", "WWUITests-Export-\(UUID())", "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
        ]
        if slowExport { app.launchArguments += ["-WWUITestExportSlowValidation", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.show.export"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(wait { app.buttons["ww.show.export"].isEnabled })
        return app
    }

    func testMenuToolbarShareCompactSheetSupportedOptionsAndSoftwareLicenses() throws {
        let app = launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Export…"].click()
        let start = app.buttons["ww.export.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(start.isEnabled, "An explicit destination is required.")
        XCTAssertTrue(app.popUpButtons["ww.export.wave.bits"].exists)
        evidence("Whole-episode export sheet at default size", app: app)
        app.checkBoxes["ww.export.format.mp3"].click()
        app.checkBoxes["ww.export.format.m4a"].click()
        reveal(app.popUpButtons["ww.export.mp3.mode"], in: app)
        app.popUpButtons["ww.export.mp3.mode"].click()
        app.menuItems["Variable bitrate"].click()
        XCTAssertTrue(app.popUpButtons["ww.export.mp3.quality"].exists)
        app.popUpButtons["ww.export.mp3.rate"].click()
        XCTAssertFalse(app.menuItems["88.2 kHz"].exists || app.menuItems["96 kHz"].exists)
        app.typeKey(.escape, modifierFlags: [])
        reveal(app.popUpButtons["ww.export.m4a.bitrate"], in: app)
        XCTAssertFalse(app.popUpButtons["ww.export.m4a.mode"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(wait { !start.exists }, "Escape must dismiss an idle export sheet.")
        app.buttons["ww.show.export"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertEqual(String(describing: app.checkBoxes["ww.export.format.mp3"].value ?? ""), "0",
                       "Canceled choices must not become successful preferences.")
        app.buttons["ww.export.close"].click()
        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(app.menuItems["Export"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Software Licenses…"].click()
        let window = app.windows["ww.licenses.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["WaveWrangler - MIT"].exists)
        window.staticTexts["LAME - source, replacement, and release gates"].click()
        XCTAssertTrue(window.staticTexts["ww.licenses.text"].waitForExistence(timeout: 5))
        let text = window.staticTexts["ww.licenses.text"]
        evidence("Linked Software Licenses and relink notice", app: app)
        XCTAssertTrue(wait { (text.value as? String ?? text.label).contains("complete source rebuild/relink") },
                      app.debugDescription)
    }

    func testMultiFormatPublicationRemembersSuccessAndCollisionNeverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WWUITests-Exports-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = launch()
        defer { app.terminate() }
        app.buttons["ww.show.export"].click()
        XCTAssertTrue(app.buttons["ww.export.start"].waitForExistence(timeout: 10))
        app.checkBoxes["ww.export.format.mp3"].click()
        app.checkBoxes["ww.export.format.m4a"].click()
        reveal(app.popUpButtons["ww.export.normalization"], in: app)
        app.popUpButtons["ww.export.normalization"].click()
        app.menuItems["Podcast"].click()
        reveal(app.textFields["ww.export.filename"], in: app)
        replace(app.textFields["ww.export.filename"], with: "Verified Episode")
        reveal(app.buttons["ww.export.chooseDirectory"], in: app)
        app.buttons["ww.export.chooseDirectory"].click()
        try choose(folder, in: app)
        let omissions = app.checkBoxes["ww.export.acceptOmissions"]
        XCTAssertTrue(omissions.waitForExistence(timeout: 5))
        reveal(omissions, in: app)
        omissions.click()
        XCTAssertTrue(wait { app.buttons["ww.export.start"].isEnabled }, app.debugDescription)
        let metadataDisclosure = app.disclosureTriangles["Metadata & Artwork (export only)"]
        reveal(metadataDisclosure, in: app)
        metadataDisclosure
            .coordinate(withNormalizedOffset: .init(dx: 0.12, dy: 0.5)).click()
        let title = app.textFields["ww.export.metadata.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        reveal(title, in: app)
        replace(title, with: "Export-only title")
        XCTAssertFalse(app.buttons["ww.export.start"].isEnabled,
                       "Changing metadata must revoke the earlier omission acknowledgment.")
        reveal(omissions, in: app)
        omissions.click()
        XCTAssertTrue(wait { app.buttons["ww.export.start"].isEnabled })
        evidence("Explicit omissions acknowledged after metadata edit", app: app)
        app.buttons["ww.export.start"].click()
        let result = app.staticTexts["ww.export.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertEqual(result.value as? String ?? result.label, "Export completed")
        let files = ["wav", "mp3", "m4a"].map { folder.appendingPathComponent("Verified Episode.\($0)") }
        let originals = try files.map { try Data(contentsOf: $0) }
        XCTAssertTrue(originals.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(app.buttons.matching(identifier: "Reveal in Finder").count, 3)
        evidence("Verified three-format export receipts", app: app)
        for (index, file) in files.enumerated() {
            let attachment = XCTAttachment(data: originals[index], uniformTypeIdentifier: "public.audio")
            attachment.name = file.lastPathComponent
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["ww.export.close"].click()
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["ww.export.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: app.checkBoxes["ww.export.format.mp3"].value ?? ""), "1")
        XCTAssertEqual(String(describing: app.checkBoxes["ww.export.format.m4a"].value ?? ""), "1")
        reveal(app.textFields["ww.export.filename"], in: app)
        replace(app.textFields["ww.export.filename"], with: "Verified Episode")
        reveal(omissions, in: app)
        omissions.click()
        XCTAssertTrue(wait { app.buttons["ww.export.start"].isEnabled })
        app.buttons["ww.export.start"].click()
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertNotEqual(result.value as? String ?? result.label, "Export completed")
        XCTAssertEqual(app.buttons.matching(identifier: "Reveal in Finder").count, 0)
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), originals[index])
        }
        evidence("Collision refusal preserves earlier deliveries", app: app)
    }

    func testRunningExportKeepsItsSheetThroughCloseAndQuitAndConfirmsCancellation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WWUITests-CanceledExport-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = launch(slowExport: true)
        defer { app.terminate() }
        app.buttons["ww.show.export"].click()
        XCTAssertTrue(app.buttons["ww.export.start"].waitForExistence(timeout: 10))
        app.checkBoxes["ww.export.format.mp3"].click()
        reveal(app.buttons["ww.export.chooseDirectory"], in: app)
        app.buttons["ww.export.chooseDirectory"].click()
        try choose(folder, in: app)
        let omissions = app.checkBoxes["ww.export.acceptOmissions"]
        reveal(omissions, in: app)
        omissions.click()
        XCTAssertTrue(wait { app.buttons["ww.export.start"].isEnabled })
        app.buttons["ww.export.start"].click()
        let cancel = app.buttons["ww.export.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(app.sheets.buttons["Keep Exporting"].waitForExistence(timeout: 5))
        app.sheets.buttons["Keep Exporting"].click()
        XCTAssertTrue(cancel.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(cancel.exists)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(wait { app.state == .runningForeground && cancel.exists }, app.debugDescription)
        evidence("Running export survives close and quit", app: app)
        cancel.click()
        XCTAssertTrue(app.sheets.buttons["Cancel Export"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel Export"].click()
        let result = app.staticTexts["ww.export.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue((result.value as? String ?? result.label).lowercased().contains("canceled"))
        XCTAssertFalse(app.staticTexts["Canceling export; waiting for cleanup."].exists)
        XCTAssertFalse(app.staticTexts["CancellationError()"].exists)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        evidence("Confirmed cancellation completes cleanup", app: app)
        app.buttons["ww.export.close"].click()
        app.buttons["ww.show.export"].click()
        XCTAssertTrue(app.buttons["ww.export.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: app.checkBoxes["ww.export.format.mp3"].value ?? ""), "0")
        XCTAssertFalse(app.buttons["ww.export.start"].isEnabled)
        app.buttons["ww.export.close"].click()
    }

    private func evidence(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        field.typeKey(.tab, modifierFlags: [])
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["ww.export.scroll"]
        for _ in 0..<18 {
            if element.isHittable && scroll.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? 160 : -160)
        }
        XCTAssertTrue(element.isHittable && scroll.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)),
                      app.debugDescription)
    }

    private func choose(_ folder: URL, in app: XCUIApplication) throws {
        let identifier = "com.apple.appkit.xpc.openAndSavePanelService"
        var host: XCUIApplication?
        XCTAssertTrue(wait {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil {
                let service = XCUIApplication(bundleIdentifier: identifier)
                if service.state != .notRunning { host = service; return true }
            }
            if app.sheets.count > 1 { host = app; return true }
            return false
        })
        let picker = try XCTUnwrap(host)
        picker.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        picker.typeText(folder.path)
        picker.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        picker.typeKey(.return, modifierFlags: [])
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
