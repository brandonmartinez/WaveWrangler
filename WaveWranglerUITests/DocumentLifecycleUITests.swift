import AppKit
import XCTest

/// Native document lifecycle under the autosave policy (WW-005/049 C6; closes AS01/AS05 when run).
///
/// Run only with GUI permission: `scripts/test.sh --ui`. Each test creates a synthetic `.wwshow` with
/// `wwpersist-probe` (path in `WW_PROBE`), launches the app with `-WWUITestHooks YES` (isolated preferences
/// and storage), opens the document and verifies disk truth independently by reading the file.
@MainActor
final class DocumentLifecycleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!

    private static let autosaveOn = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.on")
    private static let autosaveOff = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tests

    /// C2b recovery presentation (#84; M1-DUR-026 relaunch route): after a crash with unpublished edits, reopening
    /// the show offers "Restore unsaved changes from <time>". Discard asks first (Esc cancels). Restore puts the
    /// changes back as unsaved (dirty, disk unchanged); ⌘S publishes them, and the offer is resolved.
    func testRelaunchWithEditCheckpointOffersRestore() throws {
        let document = try makeDocument("Relaunch Restore")
        try crashWithUnpublishedEdit(document, title: "Unsaved before the crash")

        var window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        let bar = messageBar(window)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the unsaved-changes offer appears on open")
        record("offer: \(bar.label) | \(bar.value as? String ?? "")")
        XCTAssertTrue(bar.label.hasPrefix("Restore unsaved changes from "), bar.label)
        XCTAssertTrue((bar.value as? String)?.contains("never saved") == true, "VoiceOver value is the visible body")
        XCTAssertTrue(bar.buttons["Restore Unsaved Changes"].exists && bar.buttons["Discard…"].exists)
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1", "opening never applies or publishes the checkpoint")

        bar.buttons["Discard…"].click()
        let confirm = app.sheets.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Discard asks for confirmation")
        record("discard sheet buttons: \(confirm.buttons.allElementsBoundByIndex.map(\.title))")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor(timeout: 3) { !confirm.exists })
        XCTAssertTrue(bar.exists, "Cancel keeps the offer")

        bar.buttons["Restore Unsaved Changes"].click()
        XCTAssertTrue(waitFor(timeout: 5) { !bar.exists }, "the offer is resolved by Restore")
        let field = showTitleField(window)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Unsaved before the crash")
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1", "a restore never saves")
        let status = window.descendants(matching: .any).matching(identifier: "ww.show.saveStatus").firstMatch
        if status.exists { XCTAssertFalse((status.value as? String ?? "").hasPrefix("Saved"), "restored changes are unsaved") }

        // Undo of the restore offers the record again; Redo restores it again (one undo step).
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(messageBar(window).waitForExistence(timeout: 5), "Undo of Restore offers the unsaved changes again")
        XCTAssertTrue(messageBar(window).label.hasPrefix("Restore unsaved changes from "))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(timeout: 5) { !self.messageBar(window).exists }, "Redo restores again")
        XCTAssertEqual(showTitleField(window).value as? String, "Unsaved before the crash")

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitFor(timeout: 5) { self.diskTitle(document) == "Unsaved before the crash" }, "⌘S publishes the restored changes")
        forceQuit()
        window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(messageBar(window).exists, "a verified save resolved the offer")
    }

    /// Two crashed sessions leave two records with different edits: each is offered on its own, newest first, and
    /// acting on one never removes the other.
    func testTwoCrashedSessionsAreOfferedOneAfterAnother() throws {
        let document = try makeDocument("Relaunch Two Sessions")
        try crashWithUnpublishedEdit(document, title: "Session A edits")
        // Session B: reopen, leave A's offer undecided, edit and crash again.
        var window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        XCTAssertTrue(messageBar(window).waitForExistence(timeout: 10))
        try edit(window, title: "Session B edits")
        assertDiskTitle(document, stays: "Synthetic Trial Show 1", for: 3)
        forceQuit()

        window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        let bar = messageBar(window)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let first = bar.label
        bar.buttons["Restore Unsaved Changes"].click()
        XCTAssertEqual(showTitleField(window).value as? String, "Session B edits", "the newest record is offered first")
        // The other session's record is still offered (never deleted with B).
        XCTAssertTrue(waitFor(timeout: 5) { self.messageBar(window).exists && self.messageBar(window).label.hasPrefix("Restore unsaved changes from ") })
        record("two sessions: first \(first) | then \(messageBar(window).label)")
        messageBar(window).buttons["Restore Unsaved Changes"].click()
        XCTAssertEqual(showTitleField(window).value as? String, "Session A edits")
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1", "restores never save")
    }

    /// C2b: if the show was saved since the checkpoint's base, the offer is "Unsaved changes based on an older
    /// revision" and opens only as a separate untitled copy: never restored over, merged into or published.
    func testRelaunchAfterNewerSaveOffersOnlySeparateCopy() throws {
        let document = try makeDocument("Relaunch Older")
        try crashWithUnpublishedEdit(document, title: "Unsaved on the old revision")
        try runProbe(["save", "--file", document.path, "--title", "Saved elsewhere"])
        XCTAssertEqual(diskTitle(document), "Saved elsewhere")

        let window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        let bar = messageBar(window)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        record("offer: \(bar.label) | \(bar.value as? String ?? "")")
        XCTAssertEqual(bar.label, "Unsaved changes based on an older revision")
        XCTAssertFalse(bar.buttons["Restore Unsaved Changes"].exists)
        bar.buttons["Open as Separate Copy"].click()
        let copy = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Untitled'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "a separate untitled copy opens")
        let copyField = showTitleField(copy)
        XCTAssertTrue(copyField.waitForExistence(timeout: 5))
        XCTAssertEqual(copyField.value as? String, "Unsaved on the old revision")
        XCTAssertEqual(diskTitle(document), "Saved elsewhere", "never merged or published")
        XCTAssertEqual(showTitleField(window).value as? String, "Saved elsewhere")
    }

    /// AS05 (Close): OFF never autosaves; Close offers Save / Don't Save / Cancel; Cancel keeps the work.
    func testAutosaveOffCloseOffersSaveDontSaveCancel() throws {
        let document = try makeDocument("Close Off")
        let window = try launchAndOpen(document, autosave: false)
        try edit(window, title: "Edited while OFF")
        assertDiskTitle(document, stays: "Synthetic Trial Show 1", for: 2.5)

        app.typeKey("w", modifierFlags: .command)
        let sheet = try closeSheet()
        XCTAssertTrue(sheet.buttons["Save"].exists)
        XCTAssertTrue(dontSave(in: sheet).exists)
        XCTAssertTrue(sheet.buttons["Cancel"].exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Cancel keeps the window open")
        XCTAssertEqual(window.textFields["Show title"].value as? String, "Edited while OFF")
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1")

        app.typeKey("w", modifierFlags: .command)
        try closeSheet().buttons["Save"].click()
        XCTAssertTrue(waitFor(timeout: 5) { self.diskTitle(document) == "Edited while OFF" }, "explicit Save works with autosave OFF")
        XCTAssertTrue(waitFor(timeout: 5) { !window.exists })
    }

    /// AS05 (Quit): OFF dirty Quit shows the native review; Cancel keeps the app and work; Don't Save quits
    /// without writing.
    func testAutosaveOffQuitOffersReview() throws {
        let document = try makeDocument("Quit Off")
        let window = try launchAndOpen(document, autosave: false)
        try edit(window, title: "Unsaved at Quit")

        app.typeKey("q", modifierFlags: .command)
        let sheet = try closeSheet()
        XCTAssertTrue(sheet.buttons["Save"].exists && dontSave(in: sheet).exists && sheet.buttons["Cancel"].exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        XCTAssertNotEqual(app.state, .notRunning, "Cancel keeps the app running")

        app.typeKey("q", modifierFlags: .command)
        dontSave(in: try closeSheet()).click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Don't Save quits")
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1", "nothing was written")
    }

    /// ON: an edit is published (verified on disk) within the 2 s gate; Close and Quit don't prompt.
    func testAutosaveOnPublishesAndCloseDoesNotPrompt() throws {
        let document = try makeDocument("Close On")
        let window = try launchAndOpen(document, autosave: true)
        try edit(window, title: "Autosaved ON")
        let committed = Date()
        XCTAssertTrue(waitFor(timeout: 5) { self.diskTitle(document) == "Autosaved ON" })
        let elapsed = Date().timeIntervalSince(committed)
        record("ON committed-edit-to-disk (native app, 1 s policy) \(String(format: "%.3f", elapsed)) s")
        XCTAssertLessThanOrEqual(elapsed, 2.0, "WW-005 provisional ≤2 s")
        // #87: once the autosave is verified ("Saved"), the window no longer says "Edited" either.
        let status = window.descendants(matching: .any).matching(identifier: "ww.show.saveStatus").firstMatch
        XCTAssertTrue(waitFor(timeout: 3) { (status.value as? String ?? status.label).hasPrefix("Saved") }, "status reaches Saved")
        XCTAssertTrue(waitFor(timeout: 3) { !self.windowSaysEdited(window) }, "no \"— Edited\" after a verified autosave")
        record("after autosave: title \(window.title) | status \(status.value as? String ?? status.label)")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1.5), "no prompt with autosave ON")
        XCTAssertTrue(waitFor(timeout: 5) { !window.exists })
    }

    func testAutosaveOnQuitPublishesAndTerminates() throws {
        let document = try makeDocument("Quit On")
        let window = try launchAndOpen(document, autosave: true)
        try edit(window, title: "Saved by Quit")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertEqual(diskTitle(document), "Saved by Quit")
    }

    /// Dynamic toggle: OFF keeps pending edits; ON publishes them; work queued just before OFF is skipped
    /// (AS01); Close prompts only while OFF.
    func testDynamicToggle() throws {
        let document = try makeDocument("Toggle")
        let window = try launchAndOpen(document, autosave: false)
        try edit(window, title: "Pending while OFF")
        assertDiskTitle(document, stays: "Synthetic Trial Show 1", for: 2.5)

        post(Self.autosaveOn)
        XCTAssertTrue(waitFor(timeout: 5) { self.diskTitle(document) == "Pending while OFF" }, "OFF → ON publishes pending edits")

        // AS01: edit while ON, turn OFF before the 1 s quiet delay elapses.
        try edit(window, title: "Queued then OFF")
        post(Self.autosaveOff)
        assertDiskTitle(document, stays: "Pending while OFF", for: 3)

        app.typeKey("w", modifierFlags: .command)
        try closeSheet().buttons["Cancel"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 2))

        post(Self.autosaveOn)
        XCTAssertTrue(waitFor(timeout: 5) { self.diskTitle(document) == "Queued then OFF" })
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1.5))
        XCTAssertTrue(waitFor(timeout: 5) { !window.exists })
    }

    // MARK: - Helpers

    private func makeDocument(_ name: String) throws -> URL {
        let url = workDirectory.appending(path: "\(name).wwshow")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        probe.arguments = ["create", "--file", url.path, "--seed", "1"]
        probe.standardOutput = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0)
        XCTAssertEqual(diskTitle(url), "Synthetic Trial Show 1")
        return url
    }

    private func launchAndOpen(_ document: URL, autosave: Bool, extraArguments: [String] = []) throws -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = [
            "-WWUITestHooks", "YES",
            "-WWUITestAutosave", autosave ? "ON" : "OFF",
            "-ApplePersistenceIgnoreState", "YES",
        ] + extraArguments
        app.launch()
        // A clean launch-time Untitled show would host the document as a tab; close it first (clean ⇒ no prompt).
        let untitled = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Untitled'")).firstMatch
        if untitled.waitForExistence(timeout: 3) {
            untitled.click()
            app.typeKey("w", modifierFlags: .command)
            _ = waitFor(timeout: 3) { !untitled.exists }
        }
        app.open(document)
        let name = document.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "document window opened")
        // Make sure the policy reached the gate (the hook applies it when the first document is created).
        post(autosave ? Self.autosaveOn : Self.autosaveOff)
        Thread.sleep(forTimeInterval: 0.3)
        return window
    }

    /// Ends the app abruptly (like a crash or force quit): no save, no close, no termination review.
    private func forceQuit() {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "com.brandonmartinez.wavewrangler") {
            running.forceTerminate()
        }
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "app force-quit")
    }

    private func runProbe(_ arguments: [String]) throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        probe.arguments = arguments
        probe.standardOutput = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0)
    }

    private func messageBar(_ window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "ww.show.messageBar").firstMatch
    }

    private func showTitleField(_ window: XCUIElement) -> XCUIElement {
        let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
        if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
        return window.textFields["Show title"]
    }

    /// Edits with autosave ON but a 30 s cadence (no publication expected within 1.5 s, so ShowDocument writes a
    /// C2b edit checkpoint at quiescence), then force-quits before anything is published.
    private func crashWithUnpublishedEdit(_ document: URL, title: String) throws {
        let window = try launchAndOpen(document, autosave: true, extraArguments: Self.slowAutosave)
        try edit(window, title: title)
        assertDiskTitle(document, stays: "Synthetic Trial Show 1", for: 3)
        forceQuit()
        XCTAssertEqual(diskTitle(document), "Synthetic Trial Show 1", "nothing was published before the crash")
    }

    private static let slowAutosave = ["-WWUITestAutosaveDelay", "30"]

    private func edit(_ window: XCUIElement, title: String) throws {
        // The show title lives in the Show Info inspector of the library/workspace UI.
        let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
        if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
        let field = window.textFields["Show title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        field.typeKey(.return, modifierFlags: [])
    }

    /// "— Edited" in the window title or subtitle (AppKit's edited-document suffix).
    private func windowSaysEdited(_ window: XCUIElement) -> Bool {
        window.title.contains("Edited")
            || window.staticTexts.matching(NSPredicate(format: "value CONTAINS '— Edited' OR label CONTAINS '— Edited'")).count > 0
    }

    private func closeSheet() throws -> XCUIElement {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "native Save / Don't Save / Cancel decision")
        let labels = sheet.buttons.allElementsBoundByIndex.map(\.title)
        record("sheet buttons: \(labels)")
        return sheet
    }

    private func dontSave(in sheet: XCUIElement) -> XCUIElement {
        sheet.buttons.matching(NSPredicate(format: "title BEGINSWITH 'Don' OR label BEGINSWITH 'Don'")).firstMatch
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func diskTitle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any], let show = payload["show"] as? [String: Any]
        else { return nil }
        return show["title"] as? String
    }

    private func assertDiskTitle(_ url: URL, stays title: String, for seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            XCTAssertEqual(diskTitle(url), title, "no automatic write", file: file, line: line)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func record(_ line: String) {
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[evidence] \(line)")
    }
}
