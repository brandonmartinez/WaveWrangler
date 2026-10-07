import AppKit
import XCTest

/// #159 (accessibility-acceptance T21; states-and-recovery D14/D15): opening a show written by the M1 (schema 1)
/// build asks "Update “…” to the current format?" with Update (default, Return), Open Read-Only (⌘R) and Cancel (Esc),
/// keyboard only. F-OLDER is the frozen M1 golden bytes (`ShowSchema1Fixtures`, shared with the package tests);
/// F-OLDER-BAD is the same bytes with the payload changed under its checksum. The D15 case forces the migration to fail
/// after its backup is kept (`-WWUITestFailFormatUpdate YES`, Debug only). Every case checks the file's bytes.
///
/// Keyboard only (C01), with one limit (as `LibraryLocationUITests` and `OfflineSaveKeyboardUITests`): Tab reaches
/// message-bar and popover buttons, and buttons take keyboard focus, only with the system Full Keyboard Access
/// ("Keyboard navigation") setting on, which tests never change.
/// - **On** (the user's C01 run): Tab/Space reach and activate those buttons, and focus is asserted.
/// - **Off** (agent and Mac mini runs): only those steps use XCUITest element actions, each recorded as **Not run
///   (needs Full Keyboard Access)** in `format-update-keyboard-navigation` evidence. Return, Esc, ⌘R and ⌃Tab stay key
///   events, and every outcome check (prompt, disk bytes, schema, status, bar) stays a hard check either way.
///
/// Audits follow the M2 baseline (docs/m2/evidence/m2-gui-baseline.md): `.contrast` is enforced on the blocked and
/// recovery surfaces (the prompt, read-only window, failure bar and details, status popover, damaged-file refusal);
/// the updated, editable show window gets the essential set.
@MainActor
final class FormatUpdateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []
    /// Steps not run as key events because the system keyboard navigation setting is off.
    private var needsKeyboardNavigation: [String] = []

    /// The system Full Keyboard Access / "Keyboard navigation" setting (`AppleKeyboardUIMode` bit 2, global domain).
    private static let keyboardNavigation = UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0
    private static let bundleIdentifier = "com.brandonmartinez.wavewrangler"

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerFormatUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if app != nil {
            let run = testRun
            let outcome = run?.hasBeenSkipped == true ? "skipped" : (run?.totalFailureCount ?? 0) == 0 ? "passed" : "failed"
            Acceptance.writeEvidence("format-update-keyboard-navigation-\(name.replacingOccurrences(of: " ", with: "_"))",
                                     ["outcome": outcome, "keyboardNavigation": Self.keyboardNavigation,
                                      "notRunNeedsFullKeyboardAccess": Array(Set(needsKeyboardNavigation)).sorted()], test: self)
        }
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tasks

    /// T21: the prompt appears before anything can be edited; Return = Update rewrites the show in the current format
    /// (stated channels kept, the index-0 placeholder now Unknown) and the window becomes editable and Saved.
    func testT21UpdateWithReturn() throws {
        let document = try writeOlder("Older Show", ShowSchema1Fixtures.statedChannels)
        let original = try Data(contentsOf: document)
        try task("T21-update") {
            let window = try openAndExpectPrompt(document, name: "Older Show", original: original)
            app.typeKey(.return, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 10) { self.diskSchemaVersion(document) == 2 }, "Return updates the file to schema 2: \(String(describing: diskSchemaVersion(document)))")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "status Saved after the update: \(value(status))")
            check(diskShowTitle(document) == "Stated Show", "content kept: \(String(describing: diskShowTitle(document)))")
            check(diskPrimaryChannels(document) == ["known:1", "known:0"], "user-stated channels kept: \(diskPrimaryChannels(document))")
            check(!app.sheets.firstMatch.exists, "no sheet left over")
            let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
            if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
            let title = window.textFields["Show title"]
            check(title.waitForExistence(timeout: 5) && title.isEnabled, "the updated show is editable")
            try audit("T21 updated show window", types: AcceptanceAudit.essentialTypes)   // editable: not a blocked surface
        }
    }

    /// T21 placeholder: a show whose channels were never stated reads "Unknown channel" after the update, never 0.
    func testT21UpdatePlaceholderBecomesUnknown() throws {
        let document = try writeOlder("Placeholder", ShowSchema1Fixtures.placeholderOnly)
        let original = try Data(contentsOf: document)
        try task("T21-placeholder") {
            _ = try openAndExpectPrompt(document, name: "Placeholder", original: original)
            app.typeKey(.return, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 10) { self.diskSchemaVersion(document) == 2 }, "updated to schema 2")
            check(diskPrimaryChannels(document) == ["unknown"], "the index-0 placeholder became Unknown: \(diskPrimaryChannels(document))")
        }
    }

    /// T21 Open Read-Only (⌘R): the show is shown upgraded in memory, editing and saving are unavailable, and nothing is
    /// ever written (autosave is on).
    func testT21OpenReadOnlyWithCommandR() throws {
        let document = try writeOlder("Read Only", ShowSchema1Fixtures.mixed)
        let original = try Data(contentsOf: document)
        try task("T21-readonly") {
            let window = try openAndExpectPrompt(document, name: "Read Only", original: original)
            app.typeKey("r", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }, "⌘R dismisses the prompt")
            check(window.exists, "the window stays open")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix("Read-only") }, "status Read-only: \(value(status))")
            try audit("T21 read-only window")
            let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
            if showInfo.waitForExistence(timeout: 5) {
                showInfo.click()
                try audit("T21 read-only Show Info")
            }
            let title = window.textFields["Show title"]
            check(title.waitForExistence(timeout: 5) && title.value as? String == "Mixed Show", "the older content is shown: \(title.value ?? "nil")")
            check(!title.isEnabled, "the title can't be edited")
            app.menuBars.menuBarItems["File"].click()
            let save = app.menuBars.menuItems["Save"]
            check(save.exists && !save.isEnabled, "File › Save is unavailable")
            let saveAs = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Save As'")).firstMatch
            check(!saveAs.exists || !saveAs.isEnabled, "File › Save As… is unavailable")
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey("s", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 3)   // past the autosave delay
            check((try? Data(contentsOf: document)) == original, "nothing is written: the file is byte-unchanged")
        }
    }

    /// T21 Cancel (Esc): the show closes and the file is untouched.
    func testT21CancelWithEscape() throws {
        let document = try writeOlder("Cancelled", ShowSchema1Fixtures.placeholderOnly)
        let original = try Data(contentsOf: document)
        try task("T21-cancel") {
            let window = try openAndExpectPrompt(document, name: "Cancelled", original: original)
            app.typeKey(.escape, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 5) { !window.exists }, "Esc closes the show")
            check(app.windows.matching(identifier: "ww.show.window").count == 0, "no show window remains")
            check((try? Data(contentsOf: document)) == original, "the file is byte-unchanged")
        }
    }

    /// D15: the update fails after the backup is kept; "Couldn't update this show" says the original is unchanged, the
    /// read-only view stays open, Try Again and Show Details are reachable by keyboard, and the file is byte-unchanged.
    func testD15UpdateFailureKeepsOriginalAndReadOnlyView() throws {
        let document = try writeOlder("Failing", ShowSchema1Fixtures.mixed)
        let original = try Data(contentsOf: document)
        try task("T21-D15") {
            let window = try openAndExpectPrompt(document, name: "Failing", original: original, extra: ["-WWUITestFailFormatUpdate", "YES"])
            app.typeKey(.return, modifierFlags: [])
            let bar = window.descendants(matching: .any).matching(identifier: "ww.show.messageBar").firstMatch
            check(bar.waitForExistence(timeout: 10), "the failure message bar appears")
            let barTexts = texts(in: bar) + [bar.label]
            check(barTexts.contains("Couldn't update this show"), "heading: \(barTexts)")
            check(barTexts.contains { $0.contains("The original is unchanged") }, "says the original is unchanged: \(barTexts)")
            let status = element("ww.show.saveStatus")
            check(value(status).hasPrefix("Read-only"), "still read-only (not colour alone): \(value(status))")
            check(window.exists, "the read-only view stays open")
            check((try? Data(contentsOf: document)) == original, "the original file is byte-unchanged")
            let tryAgain = bar.buttons["Try Again"], details = bar.buttons["Show Details"]
            check(tryAgain.exists && details.exists, "Try Again and Show Details: \(bar.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T21 D15 failure bar")
            // Keyboard: Tab to Try Again and press Space; the forced failure repeats and nothing changes.
            activate(tryAgain, "Try Again in the failure bar", task: "T21-D15")
            Thread.sleep(forTimeInterval: 2)
            check(bar.exists && (try? Data(contentsOf: document)) == original, "Try Again fails again, original unchanged")
            check((texts(in: bar) + [bar.label]).contains("Couldn't update this show") && value(status).hasPrefix("Read-only"),
                  "still the failure bar and read-only: \(value(status))")
            activate(details, "Show Details in the failure bar", task: "T21-D15")
            let detailsSheet = app.sheets.firstMatch
            check(detailsSheet.waitForExistence(timeout: 5), "Show Details explains the failure")
            check(texts(in: detailsSheet).contains { $0.contains("simulated failure") && $0.contains("The original file is unchanged.") },
                  "details text: \(texts(in: detailsSheet))")
            try audit("T21 D15 details")
            app.typeKey(.return, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }, "Return dismisses the details")
        }
    }

    /// D14 fallback (#175 review): after Open Read-Only, Update… in the save-status popover asks again (focused first,
    /// Space activates) and Return updates the show.
    func testT21UpdateFromStatusItemAfterOpenReadOnly() throws {
        let document = try writeOlder("Later", ShowSchema1Fixtures.statedChannels)
        let original = try Data(contentsOf: document)
        try task("T21-update-later") {
            _ = try openAndExpectPrompt(document, name: "Later", original: original)
            app.typeKey("r", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }, "⌘R dismisses the prompt")
            let status = element("ww.show.saveStatus")
            // View › Show Save Status (as T27); keyboard focus starts on the popover's first action.
            app.menuBars.menuBarItems["View"].click()
            let showStatus = app.menuBars.menuItems["Show Save Status"]
            check(showStatus.waitForExistence(timeout: 3), "View › Show Save Status exists")
            showStatus.click()
            let popover = app.popovers.firstMatch
            check(popover.waitForExistence(timeout: 5), "the status popover opens")
            let update = popover.buttons["Update…"]
            check(update.exists, "Update… is offered: \(popover.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T21 status popover Update…")
            // Focus starts on the popover's first action (Update…), so Space activates it with keyboard navigation.
            activate(update, "Update… in the save-status popover", task: "T21-update-later", tabs: 0)
            let sheet = app.sheets.firstMatch
            check(sheet.waitForExistence(timeout: 5), "Update… asks again")
            check(texts(in: sheet).contains("Update “Later” to the current format?"), "prompt title: \(texts(in: sheet))")
            check((try? Data(contentsOf: document)) == original, "nothing is written before Update")
            app.typeKey(.return, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 10) { self.diskSchemaVersion(document) == 2 }, "Return updates the file to schema 2")
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "status Saved after the update: \(value(status))")
        }
    }

    /// Several older shows opened as tabs (#175 review; the M1→M2 upgrade path, as at a state-restored launch): each
    /// show asks once, on its own tab, when that tab is selected; none is lost for being a background tab.
    func testT21EachTabbedOlderShowAsksWhenSelected() throws {
        let first = try writeOlder("First Tab", ShowSchema1Fixtures.statedChannels)
        let second = try writeOlder("Second Tab", ShowSchema1Fixtures.mixed)
        let originals = [first: try Data(contentsOf: first), second: try Data(contentsOf: second)]
        try task("T21-tabs") {
            launch(["-WWUITestAutosave", "ON", "-WWUITestResetStorage", "YES"], opening: first)
            check(app.windows.matching(identifier: "ww.show.window").firstMatch.waitForExistence(timeout: 10), "the first show opens")
            // Open the second before answering the first: it opens as the selected tab, the first goes to the background.
            // Delivered to the running app as Finder does; `XCUIApplication.open` would start a second instance (GUI round 1).
            try openInRunningApp(second)
            // Background tabs may be absent from the AX window list, so wait for the second (selected) tab only.
            check(Acceptance.waitFor(timeout: 10) { self.app.windows.allElementsBoundByIndex.contains { $0.title.contains("Second Tab") } },
                  "the second show opens in the app under test: \(app.windows.allElementsBoundByIndex.map(\.title))")
            check(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).count == 1,
                  "one app process: \(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).map(\.processIdentifier))")
            var asked: [String] = []
            for _ in 0..<6 where asked.count < 2 {
                let sheet = app.sheets.firstMatch
                if sheet.waitForExistence(timeout: 5) {
                    let title = texts(in: sheet).first { $0.hasPrefix("Update “") } ?? "?"
                    asked.append(title)
                    app.typeKey("r", modifierFlags: .command)   // Open Read-Only: nothing is written
                    _ = Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }
                } else {
                    app.typeKey("\t", modifierFlags: .control)   // Window › Show Next Tab
                }
            }
            Acceptance.record(self, "T21 tabs asked: \(asked)")
            check(Set(asked) == ["Update “First Tab” to the current format?", "Update “Second Tab” to the current format?"]
                  && asked.count == 2, "each tabbed show asks exactly once: \(asked)")
            // Selecting each tab again never asks a second time.
            app.typeKey("\t", modifierFlags: .control)
            check(!app.sheets.firstMatch.waitForExistence(timeout: 3), "no second prompt after Open Read-Only")
            for (url, original) in originals {
                check((try? Data(contentsOf: url)) == original, "\(url.lastPathComponent) is byte-unchanged")
            }
        }
    }

    /// F-OLDER-BAD: an older file whose payload doesn't match its checksum is refused as damaged, without the update
    /// prompt, and left unchanged. Its M1-era retained checkpoint is still offered (M1 "Open Recovered Copy", #175
    /// review): choosing it opens the last complete version, upgraded in memory, as a new unsaved copy.
    func testOlderDamagedFileIsRefusedUnchanged() throws {
        var bytes = ShowSchema1Fixtures.placeholderOnly
        let range = try XCTUnwrap(bytes.range(of: Data("Placeholder Show".utf8)))
        bytes.replaceSubrange(range, with: Data("Placeholder Shoe".utf8))
        let document = try writeOlder("Older Bad", bytes)
        try task("F-OLDER-BAD") {
            launch(["-WWUITestAutosave", "ON", "-WWUITestResetStorage", "YES",
                    "-WWUITestRetainOlderCheckpoint", ShowSchema1Fixtures.placeholderOnly.base64EncodedString()], opening: document)
            check(Acceptance.waitFor(timeout: 10) { self.app.dialogs.firstMatch.exists || self.app.sheets.firstMatch.exists },
                  "a damaged-file refusal appears")
            check(!app.buttons["Update"].exists, "no update prompt for a damaged file")
            check(app.windows.matching(identifier: "ww.show.window").count == 0, "no window opens the damaged file")
            Acceptance.record(self, "F-OLDER-BAD after open: windows \(app.windows.allElementsBoundByIndex.map(\.title)) texts \(app.staticTexts.allElementsBoundByIndex.prefix(20).map { "\($0.value ?? $0.label)" })")
            let refusal = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
            if refusal.exists {
                try audit("F-OLDER-BAD refusal")
                Acceptance.record(self, "F-OLDER-BAD offer buttons: \(refusal.buttons.allElementsBoundByIndex.map(\.title))")
                let recovered = refusal.buttons["Open Recovered Copy"]
                check(recovered.exists, "the retained checkpoint is offered as a recovered copy")
                if recovered.exists {
                    // Keyboard only: the recovered copy is the default action.
                    app.typeKey(.return, modifierFlags: [])
                    let copy = app.windows.matching(identifier: "ww.show.window").firstMatch
                    check(copy.waitForExistence(timeout: 10), "the recovered copy opens")
                    let showInfo = copy.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
                    if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
                    let title = copy.textFields["Show title"]
                    check(title.waitForExistence(timeout: 5) && title.value as? String == "Placeholder Show",
                          "the last complete version opens: \(title.value ?? "nil")")
                    check(!app.buttons["ww.formatUpdate.update"].exists, "a recovered copy is a new current-format show: no update prompt")
                } else {
                    app.typeKey(.escape, modifierFlags: [])
                }
            }
            check((try? Data(contentsOf: document)) == bytes, "the damaged file is byte-unchanged")
        }
    }

    // MARK: - Recording

    private func task(_ id: String, _ body: () throws -> Void) throws {
        findings = []
        do { try body() } catch { findings.append("threw \(error)") }
        let passed = findings.isEmpty
        Acceptance.record(self, "FORMAT-UPDATE \(id): \(passed ? "PASS" : "FAIL \(findings)")")
        Acceptance.writeEvidence("format-update-\(id)", ["task": id, "passed": passed, "findings": findings, "revision": Acceptance.revision()], test: self)
        for finding in findings { XCTFail("\(id): \(finding)") }
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { findings.append(message) }
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String], opening document: URL) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES"] + arguments
        // One launch only: see `XCUIApplication.launchOnce(opening:)`.
        app.launchOnce(opening: document)
    }

    /// Opens an older show (autosave on, fresh storage) and checks the D14 prompt: wording, buttons, AX identifiers and
    /// an accessibility audit, with the file still byte-unchanged while it waits.
    private func openAndExpectPrompt(_ document: URL, name: String, original: Data, extra: [String] = []) throws -> XCUIElement {
        launch(["-WWUITestAutosave", "ON", "-WWUITestResetStorage", "YES"] + extra, opening: document)
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        guard window.waitForExistence(timeout: 10) else {
            throw NSError(domain: "FormatUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "show window did not open"])
        }
        let sheet = app.sheets.firstMatch
        check(sheet.waitForExistence(timeout: 5), "the update prompt appears")
        Acceptance.record(self, "D14 sheet: \(texts(in: sheet)) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
        check(texts(in: sheet).contains("Update “\(name)” to the current format?"), "prompt title: \(texts(in: sheet))")
        check(texts(in: sheet).contains { $0.contains("The original is kept unchanged as a backup") }, "prompt body: \(texts(in: sheet))")
        // AX lists NSAlert buttons in layout order; the default (Return) is proven by pressing Return.
        check(Set(sheet.buttons.allElementsBoundByIndex.map(\.title)) == ["Update", "Open Read-Only", "Cancel"],
              "buttons: \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
        for id in ["ww.formatUpdate.update", "ww.formatUpdate.openReadOnly", "ww.formatUpdate.cancel"] {
            check(sheet.buttons.matching(identifier: id).firstMatch.exists, "button identifier \(id)")
        }
        try audit("T21 update prompt")
        Thread.sleep(forTimeInterval: 2)   // past the autosave delay: waiting writes nothing
        check((try? Data(contentsOf: document)) == original, "nothing is written while the prompt waits")
        return window
    }

    private func writeOlder(_ name: String, _ bytes: Data) throws -> URL {
        let url = workDirectory.appending(path: "\(name).wwshow")
        try bytes.write(to: url)
        return url
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "\(element.value ?? "")" }

    private func texts(in element: XCUIElement) -> [String] {
        element.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        element.exists && (element.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
    }

    /// Activates `button` by keyboard (Tab until focused, or `tabs` presses, then Space) with keyboard navigation on;
    /// otherwise with an element action, recorded as needing Full Keyboard Access (see the type comment).
    private func activate(_ button: XCUIElement, _ step: String, task: String, tabs: Int? = nil) {
        check(button.waitForExistence(timeout: 3), "\(task): \(step) exists")
        if Self.keyboardNavigation {
            if let tabs {
                for _ in 0..<tabs { app.typeKey("\t", modifierFlags: []) }
            } else {
                for _ in 0..<40 where !isFocused(button) { app.typeKey("\t", modifierFlags: []) }
            }
            check(isFocused(button), "\(task): keyboard focus reaches \(step)")
            app.typeKey(" ", modifierFlags: [])
        } else {
            needsKeyboardNavigation.append("\(task): Tab/Space to \(step)")
            button.click()
        }
    }

    /// Opens `url` in the app instance under test, as Finder does: LaunchServices delivers it to the running
    /// instance. `XCUIApplication.open(_:)` on a running app starts a second instance instead.
    private func openInRunningApp(_ url: URL) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard let target = running.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }),
              let bundleURL = target.bundleURL else {
            throw NSError(domain: "FormatUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "the app under test isn't running"])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "open \(url.lastPathComponent)")
        let outcome = OpenOutcome()
        NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: configuration) { _, error in
            outcome.error = error.map { "\($0)" }
            opened.fulfill()
        }
        wait(for: [opened], timeout: 15)
        if let error = outcome.error { throw NSError(domain: "FormatUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
        app.activate()
    }

    /// Audits, then brings the app back to the front: an audit can take minutes, and on the Mac mini (GUI round 1) the
    /// app was no longer frontmost for the next key event.
    private func audit(_ surface: String, types: XCUIAccessibilityAuditType = AcceptanceAudit.types) throws {
        let unwaived = try AcceptanceAudit.run(app, surface: surface, test: self, types: types)
        for finding in unwaived { findings.append("AUDIT \(finding)") }
        app.activate()
    }

    private func envelope(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func diskSchemaVersion(_ url: URL) -> Int? { envelope(url)?["schemaVersion"] as? Int }

    private func diskShowTitle(_ url: URL) -> String? {
        ((envelope(url)?["payload"] as? [String: Any])?["show"] as? [String: Any])?["title"] as? String
    }

    /// Each assignment's primary channel in the first episode, as "known:n" or "unknown" (schema 2 only).
    private func diskPrimaryChannels(_ url: URL) -> [String] {
        guard let payload = envelope(url)?["payload"] as? [String: Any],
              let episode = (payload["episodes"] as? [[String: Any]])?.first,
              let assignments = episode["speakerAssignments"] as? [[String: Any]] else { return [] }
        return assignments.compactMap { assignment in
            guard let channel = (assignment["primary"] as? [String: Any])?["channel"] as? [String: Any] else { return nil }
            return channel["state"] as? String == "known" ? "known:\(channel["value"] as? Int ?? -1)" : "\(channel["state"] ?? "?")"
        }
    }
}

/// The open's result, written once by NSWorkspace's completion handler before the expectation it waits on is fulfilled.
private final class OpenOutcome: @unchecked Sendable {
    var error: String?
}
