import AppKit
import XCTest

/// Integrated M1 keyboard tasks not covered by the lane suites (accessibility-acceptance T01, T02 undo,
/// T03 persistence, T15, T16, T17, T20, T24), driven with key events plus AX focus checks, with an
/// accessibility audit on each new surface. Synthetic documents only (`wwpersist-probe`, `WW_PROBE`).
///
/// Menu-bar commands without a shortcut use XCUITest's menu API (the keyboard path to the menu bar, ⌃F2,
/// needs Full Keyboard Access, which is a user-manual exit item). Each task records Pass/Fail with its
/// findings into `a11y001-core-tasks.json`; a failed task fails the test at the end.
@MainActor
final class CoreTasksKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []

    private static let autosaveOff = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")
    private static let original = "Synthetic Trial Show 1"

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerCoreTasks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tasks

    /// T01 (K01): ⌘N → save panel (location first) → name + folder by keyboard → Create → new show window.
    func testT01CreateShowFromSavePanel() throws {
        try task("T01") {
            launch([])
            app.typeKey("n", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 5) { self.app.dialogs.firstMatch.exists || self.app.sheets.firstMatch.exists }, "save panel shown")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Keyboard Show")
            app.typeKey("g", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.5)
            app.typeText(workDirectory.path + "\r")
            Thread.sleep(forTimeInterval: 0.5)
            app.typeKey(.return, modifierFlags: [])
            let file = workDirectory.appending(path: "Keyboard Show.wwshow")
            check(Acceptance.waitFor(timeout: 10) { FileManager.default.fileExists(atPath: file.path) }, "show file created at the chosen location")
            let window = app.windows.matching(identifier: "ww.show.window").firstMatch
            check(window.waitForExistence(timeout: 10), "new show window")
            check(window.title.hasPrefix("Keyboard Show"), "window title = show name: \(window.title)")
            let episodes = element("ww.show.sidebar.episodes")
            check(episodes.waitForExistence(timeout: 5) && value(episodes) == "0 episodes", "Episodes — 0 episodes: \(value(episodes))")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "Saved only after verified create: \(value(status))")
            check(focusedIdentifier() != nil, "keyboard focus is inside the new window: \(focusedIdentifier() ?? "none")")
            try audit("T01 new show window")
        }
    }

    /// T02 (K02) undo, T03 (K03/K04) persistence after ⌘S and reopen, T15 (K15) explicit Save with autosave OFF.
    func testT02T03T15EpisodeMetadataExplicitSaveAndReopen() throws {
        let document = try makeDocument("Metadata")
        try task("T02 undo") {
            let window = try launchAndOpen(document, autosave: false)
            let episodes = element("ww.show.sidebar.episodes")
            check(episodes.waitForExistence(timeout: 5), "episode list")
            let before = value(episodes)
            window.typeKey("n", modifierFlags: [.command, .shift])
            let rename = element("ww.show.sidebar.rename")
            check(rename.waitForExistence(timeout: 5), "inline rename focused after New Episode")
            check(focusedIdentifier() == "ww.show.sidebar.rename", "focus in the rename field: \(focusedIdentifier() ?? "none")")
            app.typeKey(.escape, modifierFlags: [])
            check(value(episodes) != before, "episode added: \(value(episodes))")
            app.typeKey("z", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 3) { self.value(episodes) == before }, "⌘Z removes the new episode: \(value(episodes))")
        }
        try task("T03 + T15") {
            let window = app.windows.matching(identifier: "ww.show.window").firstMatch
            window.typeKey("i", modifierFlags: .command)
            let title = element("ww.inspector.episode.title")
            check(title.waitForExistence(timeout: 5), "⌘I shows the episode inspector")
            check(focusedIdentifier() == "ww.inspector.episode.title", "⌘I focuses Title: \(focusedIdentifier() ?? "none")")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Keyboard Title")
            app.typeKey("\t", modifierFlags: [])
            check(focusedIdentifier() == "ww.inspector.episode.number", "Tab reaches Number: \(focusedIdentifier() ?? "none")")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("7\t")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 3) { !self.value(status).hasPrefix("Saved") }, "edits never show Saved before ⌘S: \(value(status))")
            check(diskEpisode(document)?.title != "Keyboard Title", "autosave OFF: nothing written before ⌘S")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "⌘S → Saved: \(value(status))")
            check(diskEpisode(document)?.title == "Keyboard Title" && diskEpisode(document)?.number == 7, "disk has the edits: \(String(describing: diskEpisode(document)))")
            try audit("T03 episode inspector")
            app.typeKey("w", modifierFlags: .command)
            check(!app.sheets.firstMatch.waitForExistence(timeout: 1.5), "saved document closes without a prompt")
            app.open(document)
            let reopened = element("ww.inspector.episode.title")
            window.typeKey("i", modifierFlags: .command)
            check(reopened.waitForExistence(timeout: 10) && value(reopened) == "Keyboard Title", "reopen shows the saved title: \(value(reopened))")
            check(value(element("ww.inspector.episode.number")) == "7", "reopen shows the saved number")
        }
    }

    /// T16 (K16): another writer changes the file; ⌘S never overwrites it; the status reads Conflict; Close
    /// while conflicted has no plain Save.
    func testT16ConflictNeverOverwrites() throws {
        let document = try makeDocument("Conflict")
        try task("T16") {
            let window = try launchAndOpen(document, autosave: false)
            try probe(["save", "--file", document.path, "--title", "Other Writer"])
            check(diskTitle(document) == "Other Writer", "second writer published")
            try editShowTitle(window, "Mine")
            app.typeKey("s", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            // AppKit may first ask about the external change; never choose to overwrite.
            if app.sheets.firstMatch.waitForExistence(timeout: 3) {
                let sheet = app.sheets.firstMatch
                Acceptance.record(self, "T16 sheet: \(sheet.staticTexts.allElementsBoundByIndex.map(\.value)) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
                try audit("T16 conflict sheet")
                app.typeKey(.escape, modifierFlags: [])
            }
            check(diskTitle(document) == "Other Writer", "the other version is not overwritten")
            let status = element("ww.show.saveStatus")
            Acceptance.record(self, "T16 save status: \(value(status))")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix("Conflict") }, "status Conflict: \(value(status))")
            app.typeKey("w", modifierFlags: .command)
            if app.sheets.firstMatch.waitForExistence(timeout: 5) {
                let sheet = app.sheets.firstMatch
                Acceptance.record(self, "T16 close sheet buttons: \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
                check(!sheet.buttons["Save"].exists, "no plain Save while conflicted")
                app.typeKey(.escape, modifierFlags: [])
                check(window.waitForExistence(timeout: 2), "Esc keeps the window open")
            } else {
                check(false, "Close while conflicted asks how to keep the changes")
            }
            check(diskTitle(document) == "Other Writer", "other version byte-unchanged at the end")
        }
    }

    /// T17 (K17): the newest file is damaged; the app opens the last complete version from its device-local
    /// recovery store and says so in a persistent message bar.
    func testT17RecoverPriorWork() throws {
        let document = try makeDocument("Recover")
        try task("T17") {
            let window = try launchAndOpen(document, autosave: false)
            try editShowTitle(window, "Complete Version")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.diskTitle(document) == "Complete Version" }, "complete version saved (prior retained)")
            try editShowTitle(window, "Newest Version")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.diskTitle(document) == "Newest Version" }, "newest version saved")
            app.terminate()
            // Simulate an incomplete newest save: truncate the file.
            let data = try Data(contentsOf: document)
            try data.prefix(data.count / 2).write(to: document)
            let reopened = try openOptionally(document, autosave: false)
            Thread.sleep(forTimeInterval: 2)
            let texts = app.descendants(matching: .staticText).allElementsBoundByIndex.prefix(40).map { "\($0.value ?? $0.label)" }
            Acceptance.record(self, "T17 after reopen: windows \(app.windows.allElementsBoundByIndex.map(\.title)) texts \(texts)")
            let bar = element("ww.show.messageBar")
            check(bar.waitForExistence(timeout: 5) || reopened != nil, "a show window or recovery offer appears")
            if app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists {
                try audit("T17 recovery offer")
            }
            check(bar.exists, "message bar 'Opened the last complete version'")
        }
    }

    /// T20 (K19): a show written by a newer WaveWrangler is refused for editing and saving with a reason.
    func testT20UnknownNewerRefusal() throws {
        let document = try makeDocument("Newer")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: document)) as! [String: Any]
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: document)
        let bytes = try Data(contentsOf: document)
        try task("T20") {
            _ = try openOptionally(document, autosave: true)
            Thread.sleep(forTimeInterval: 2)
            let texts = app.descendants(matching: .staticText).allElementsBoundByIndex.prefix(40).map { "\($0.value ?? $0.label)" }
            Acceptance.record(self, "T20 after open: windows \(app.windows.allElementsBoundByIndex.map(\.title)) texts \(texts)")
            let reason = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS[c] 'newer WaveWrangler' OR label CONTAINS[c] 'newer WaveWrangler'")).firstMatch
            check(reason.waitForExistence(timeout: 5), "reason 'needs a newer WaveWrangler' shown")
            if app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists { try audit("T20 refusal") }
            app.typeKey(.escape, modifierFlags: [])
            check((try? Data(contentsOf: document)) == bytes, "file bytes unchanged")
        }
    }

    /// T24 (K22): two windows on one show share the document; an edit in one is undone from the other.
    func testT24TwoWindowsSharedUndo() throws {
        let document = try makeDocument("Windows")
        try task("T24") {
            let window = try launchAndOpen(document, autosave: false)
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems["New Window"].click()
            let windows = app.windows.matching(identifier: "ww.show.window")
            check(windows.element(boundBy: 1).waitForExistence(timeout: 5), "second window")
            try editShowTitle(windows.element(boundBy: 0), "Shared Edit")
            app.menuBars.menuBarItems["Edit"].click()
            let undo = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo '")).firstMatch
            check(undo.exists, "named undo: \(undo.exists ? undo.title : "missing")")
            app.typeKey(.escape, modifierFlags: [])
            windows.element(boundBy: 1).click()
            app.typeKey("z", modifierFlags: .command)
            let showInfo = window.textFields["Show title"]
            check(Acceptance.waitFor(timeout: 3) { showInfo.value as? String == Self.original }, "undo from the other window reverts the shared edit")
        }
    }

    // MARK: - Recording

    private var results: [[String: Any]] = []

    private func task(_ id: String, _ body: () throws -> Void) throws {
        findings = []
        do { try body() } catch { findings.append("threw \(error)") }
        let passed = findings.isEmpty
        Acceptance.record(self, "A11Y-001 \(id): \(passed ? "PASS" : "FAIL \(findings)")")
        results.append(["task": id, "passed": passed, "findings": findings])
        let url = Acceptance.evidenceDirectory.appending(path: "a11y001-core-tasks.jsonl")
        let line = (try? JSONSerialization.data(withJSONObject: ["task": id, "passed": passed, "findings": findings, "revision": Acceptance.revision()])) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: url)
        }
        for finding in findings { XCTFail("\(id): \(finding)") }
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { findings.append(message) }
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES"] + arguments
        app.launch()
        app.activate()
    }

    @discardableResult
    private func openOptionally(_ document: URL, autosave: Bool, expectWindow: Bool = false) throws -> XCUIElement? {
        launch(["-WWUITestAutosave", autosave ? "ON" : "OFF"])
        app.open(document)
        let name = document.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        guard window.waitForExistence(timeout: 10) else {
            if expectWindow { throw NSError(domain: "CoreTasks", code: 1, userInfo: [NSLocalizedDescriptionKey: "window did not open"]) }
            return nil
        }
        if !autosave {
            DistributedNotificationCenter.default().postNotificationName(Self.autosaveOff, object: nil, userInfo: nil, deliverImmediately: true)
            Thread.sleep(forTimeInterval: 0.3)
        }
        return window
    }

    private func launchAndOpen(_ document: URL, autosave: Bool) throws -> XCUIElement {
        guard let window = try openOptionally(document, autosave: autosave, expectWindow: true) else {
            throw NSError(domain: "CoreTasks", code: 1)
        }
        return window
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "\(element.value ?? "")" }

    private func focusedIdentifier() -> String? {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        return focused.exists ? focused.identifier : nil
    }

    private func editShowTitle(_ window: XCUIElement, _ title: String) throws {
        let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
        if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
        let field = window.textFields["Show title"]
        guard field.waitForExistence(timeout: 5) else { throw NSError(domain: "CoreTasks", code: 2) }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        field.typeKey(.return, modifierFlags: [])
    }

    private func audit(_ surface: String) throws {
        var unwaived: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]) { issue in
            let description = "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(200) ?? "no element")"
            if let rationale = AcceptanceAudit.waiver(for: issue) {
                print("AUDIT WAIVED \(description) — \(rationale)")
            } else {
                unwaived.append(description)
            }
            return true
        }
        for finding in unwaived { findings.append("AUDIT \(finding)") }
        print("AUDIT \(surface): \(unwaived.isEmpty ? "no unwaived issues" : "\(unwaived.count) unwaived issue(s)")")
    }

    @discardableResult
    private func probe(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeDocument(_ name: String) throws -> URL {
        let url = workDirectory.appending(path: "\(name).wwshow")
        guard try probe(["create", "--file", url.path, "--seed", "1"]) == 0, diskTitle(url) == Self.original else {
            throw NSError(domain: "CoreTasks", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture creation failed"])
        }
        return url
    }

    private func payload(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["payload"] as? [String: Any]
    }

    private func diskTitle(_ url: URL) -> String? {
        (payload(url)?["show"] as? [String: Any])?["title"] as? String
    }

    private func diskEpisode(_ url: URL) -> (title: String?, number: Int?)? {
        guard let first = (payload(url)?["episodes"] as? [[String: Any]])?.first else { return nil }
        return (first["title"] as? String, first["number"] as? Int)
    }
}

/// Audit waivers shared by the acceptance suites (same policy as the lane suites; see the evidence doc).
enum AcceptanceAudit {
    static func waiver(for issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else { return nil }
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) { return "system window chrome" }
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled { return "non-interactive layout container" }
        if issue.auditType == .action, element.elementType == .popUpButton { return "system pop-up button exposes AXShowMenu" }
        if element.elementType == .popUpButton, element.label == "emoji & symbols" { return "system input item, not app UI" }
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists { return "system Siri overlay, not app UI" }
        return nil
    }
}
