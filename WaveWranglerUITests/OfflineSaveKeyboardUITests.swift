import AppKit
import XCTest

/// Show folder unreachable (accessibility-acceptance T26, T27; states-and-recovery D7, ST-11, ST-12), driven by
/// keyboard. The app runs with the F-OFFLINE seam (`-WWUITestOffline YES`, Debug only): every publication fails
/// before anything is written, as for an unreachable folder, until the test "reconnects" with a distributed
/// notification. The seam counts publication attempts on a named pasteboard. Synthetic documents only
/// (`wwpersist-probe`, `WW_PROBE`).
///
/// Menu commands without a shortcut (View › Show Save Status) use XCUITest's menu API, as in
/// `CoreTasksKeyboardUITests`; everything else is key events. Each task records Pass/Fail with its findings.
@MainActor
final class OfflineSaveKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []

    private static let autosaveOff = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")
    private static let autosaveOn = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.on")
    private static let reconnect = Notification.Name("com.brandonmartinez.wavewrangler.uitest.offline.off")
    private static let seamPasteboard = NSPasteboard.Name("com.brandonmartinez.wavewrangler.uitest")
    private static let cantReach = "Can't reach. WaveWrangler can't reach the folder where this show is saved."

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerOffline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tasks

    /// T27 (K15, K27), Autosave Off: ⌘S fails → "Can't reach", popover says "Choose Try Again…"; no automatic
    /// attempt follows (seam count stays at the one ⌘S); dirty throughout; after reconnect, Try Again → "Saved".
    func testT27UnreachableAutosaveOff() throws {
        let document = try makeDocument("Offline Off")
        let original = try Data(contentsOf: document)
        try task("T27") {
            let window = try launchAndOpen(document, autosave: false, retryInterval: 2)
            check(seam()?.attempts == 0, "no publication attempt before ⌘S: \(String(describing: seam()))")
            addEpisodeByKeyboard(window)
            let status = element("ww.show.saveStatus")
            app.typeKey("s", modifierFlags: .command)
            dismissErrorSheetIfAny("T27 after ⌘S")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix(Self.cantReach) }, "status value after failed ⌘S: \(value(status))")
            let afterSave = seam()?.attempts ?? -1
            check(afterSave == 1, "the ⌘S made exactly one publication attempt: \(afterSave)")
            try openSaveStatus()
            let popover = app.popovers.firstMatch
            check(popover.waitForExistence(timeout: 5), "save-status popover opened (View › Show Save Status)")
            check(texts(in: popover).contains { $0.contains("Choose Try Again when the folder is available.") }, "popover text: \(texts(in: popover))")
            check(popover.buttons["Try Again"].exists && popover.buttons["Save a Copy Elsewhere…"].exists,
                  "popover buttons: \(popover.buttons.allElementsBoundByIndex.map(\.title))")
            check(isFocused(popover.buttons["Try Again"]), "keyboard focus starts on Try Again")
            try audit("T27 popover")
            app.typeKey(.escape, modifierFlags: [])
            recordDirtyIndicators(window, "T27 while unreachable")
            // ST-12: no automatic attempt, for several times the (shortened) retry interval.
            Thread.sleep(forTimeInterval: 7)
            check(seam()?.attempts == afterSave, "no automatic save attempt with Autosave Off: \(String(describing: seam()?.attempts)) after \(afterSave)")
            check(value(status).hasPrefix(Self.cantReach), "still Can't reach: \(value(status))")
            check(try Data(contentsOf: document) == original, "the last saved version is byte-unchanged while unreachable")
            // Reconnect, then Try Again by keyboard (focused first in the popover; Space activates).
            post(Self.reconnect)
            try openSaveStatus()
            check(app.popovers.firstMatch.waitForExistence(timeout: 5), "popover reopened")
            app.typeKey(" ", modifierFlags: [])
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "Try Again after reconnect → Saved: \(value(status))")
            check(diskEpisodeCount(document) == 1, "the edit is on disk after Try Again: \(String(describing: diskEpisodeCount(document)))")
            check(seam()?.attempts == afterSave + 1, "Try Again made one attempt: \(String(describing: seam()?.attempts))")
        }
    }

    /// T26 (K27), Autosave On: an automatic save fails → "Can't reach" with "will try again automatically";
    /// retries at most every 30 s (production interval); no flicker back to "Edited" between attempts, even after
    /// another edit; the last saved version is unchanged until reconnect; then "Saved" with no user action.
    func testT26UnreachableAutosaveOnRetriesAutomatically() throws {
        let document = try makeDocument("Offline On")
        let original = try Data(contentsOf: document)
        try task("T26") {
            let window = try launchAndOpen(document, autosave: true, retryInterval: nil)
            addEpisodeByKeyboard(window)
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 8) { self.value(status).hasPrefix(Self.cantReach) }, "autosave failure shows Can't reach: \(value(status))")
            // The baseline is the first attempt's own time (seam), not when the test noticed it.
            let firstFailure = seam()?.attemptTimes.first.map { Date(timeIntervalSince1970: $0) } ?? Date()
            dismissErrorSheetIfAny("T26 after the failed autosave")
            let attemptsAtFailure = seam()?.attempts ?? -1
            check(attemptsAtFailure >= 1, "an automatic attempt was made: \(attemptsAtFailure)")
            try openSaveStatus()
            let popover = app.popovers.firstMatch
            check(popover.waitForExistence(timeout: 5), "save-status popover opened")
            check(texts(in: popover).contains { $0.contains("WaveWrangler will try again automatically.") }, "popover text: \(texts(in: popover))")
            check(popover.buttons["Try Again"].exists && popover.buttons["Save a Copy Elsewhere…"].exists,
                  "popover buttons: \(popover.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T26 popover")
            app.typeKey(.escape, modifierFlags: [])
            check(windowSaysEdited(window), "the window says Edited while unreachable (AX_EDITING_STATE): \(editingState(window) ?? "none")")
            recordDirtyIndicators(window, "T26 while unreachable")
            // Between attempts the value stays Can't reach (sampled), including after another edit.
            var flicker: [String] = []
            var edited = false
            while Date().timeIntervalSince(firstFailure) < 25 {
                let current = value(status)
                if !current.hasPrefix(Self.cantReach) { flicker.append(current) }
                if !edited, Date().timeIntervalSince(firstFailure) > 8 {
                    addEpisodeByKeyboard(window)
                    edited = true
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            check(flicker.isEmpty, "no flicker between attempts: \(Set(flicker))")
            check(seam()?.attempts == attemptsAtFailure, "no further attempt within 25 s (at most every 30 s), even after an edit: \(String(describing: seam()?.attempts)) vs \(attemptsAtFailure)")
            check(try Data(contentsOf: document) == original, "the last saved version is byte-unchanged while unreachable")
            // Reconnect: the next automatic retry (due ~30 s after the failure) saves with no user action.
            post(Self.reconnect)
            check(Acceptance.waitFor(timeout: 20) { self.value(status).hasPrefix("Saved") }, "after reconnect → Saved with no user action: \(value(status))")
            let times = seam()?.attemptTimes ?? []
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
            Acceptance.record(self, "T26 attempt times (s after the first): \(times.map { String(format: "%.2f", $0 - (times.first ?? 0)) })")
            check(times.count >= 2, "an automatic retry happened: \(times.count) attempts")
            check(gaps.allSatisfy { $0 >= 29.9 }, "automatic retries at most every 30 s: gaps \(gaps)")
            check(diskEpisodeCount(document) == 2, "both edits are on disk: \(String(describing: diskEpisodeCount(document)))")
            check(Acceptance.waitFor(timeout: 3) { !self.windowSaysEdited(window) }, "no \"— Edited\" after the verified save: \(window.title)")
        }
    }

    /// T28 (K27), ST-16: from the unreachable state, Save a Copy Elsewhere… (popover, keyboard) → native save panel
    /// named "<Show> copy" → a writable folder. The window then edits the copy (title, Saved), the message bar says
    /// so, the copy is a complete separate show, and the original file is byte-unchanged.
    func testT28SaveACopyElsewhere() throws {
        let unreachable = try folder("Unreachable"), elsewhere = try folder("Elsewhere")
        let document = try makeDocument("Offline Copy", in: unreachable)
        let original = try Data(contentsOf: document)
        try task("T28") {
            let window = try launchAndOpen(document, autosave: false, retryInterval: 2, offlineFolder: unreachable)
            addEpisodeByKeyboard(window)
            let status = element("ww.show.saveStatus")
            app.typeKey("s", modifierFlags: .command)
            dismissErrorSheetIfAny("T28 after ⌘S")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix(Self.cantReach) }, "Can't reach before the copy: \(value(status))")
            try openSaveStatus()
            let popover = element("ww.show.saveStatus.popover")
            check(popover.waitForExistence(timeout: 5), "save-status popover opened")
            // Try Again is focused first; Tab reaches Save a Copy Elsewhere…; Space activates it.
            app.typeKey("\t", modifierFlags: [])
            check(isFocused(popover.buttons["Save a Copy Elsewhere…"]), "Tab reaches Save a Copy Elsewhere…")
            app.typeKey(" ", modifierFlags: [])
            let copy = try saveCopyThroughPanel(named: "Offline Copy copy", into: elsewhere, surface: "T28 save panel")
            check(Acceptance.waitFor(timeout: 10) { self.diskEpisodeCount(copy) == 1 }, "the copy holds the edit: \(String(describing: diskEpisodeCount(copy)))")
            check(Acceptance.waitFor(timeout: 5) { window.title.hasPrefix("Offline Copy copy") }, "window title is the copy: \(window.title)")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix("Saved") }, "status Saved after the copy: \(value(status))")
            let bar = window.descendants(matching: .any).matching(identifier: "ww.show.messageBar").firstMatch
            let expected = "You're now editing “Offline Copy copy” in Elsewhere. The original at Unreachable wasn't changed."
            check(bar.waitForExistence(timeout: 5) && texts(in: bar).contains(expected), "message bar: \(texts(in: bar))")
            try audit("T28 copy message bar")
            // T28: "Focus returns to the save-status item" after the save panel closes.
            check(Acceptance.waitFor(timeout: 3) { self.isFocused(status) }, "focus returns to the save-status item after the copy")
            check(try Data(contentsOf: document) == original, "the original is byte-unchanged")
            check(diskShowID(copy) != nil && diskShowID(copy) != diskShowID(document), "the copy is a separate show (new show ID)")
            check(diskTitle(copy) == "Offline Copy copy", "the copy is titled after its name: \(String(describing: diskTitle(copy)))")
            Acceptance.record(self, "T28 library: not asserted — the F-OFFLINE seam fails publications only; the library itself still reaches the original's folder, so its \"Location unavailable\" status can't be exercised here")
        }
    }

    /// T23 D7 (K20): closing while the folder can't be reached asks "“…” couldn't be saved: …" with Save a Copy
    /// Elsewhere… (default, Return), Cancel (Esc) and Don't Save (⌘⌫). Esc keeps the window; Return saves a copy and
    /// then closes; the original is byte-unchanged.
    func testT23D7CloseWhileUnreachableSavesACopy() throws {
        let unreachable = try folder("Unreachable"), elsewhere = try folder("Elsewhere")
        let document = try makeDocument("Offline Close", in: unreachable)
        let original = try Data(contentsOf: document)
        try task("T23-D7") {
            let window = try launchAndOpen(document, autosave: true, retryInterval: nil, offlineFolder: unreachable)
            addEpisodeByKeyboard(window)
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 8) { self.value(status).hasPrefix(Self.cantReach) }, "Can't reach: \(value(status))")
            dismissErrorSheetIfAny("T23 D7 after the failed autosave")
            app.typeKey("w", modifierFlags: .command)
            let sheet = app.sheets.firstMatch
            check(sheet.waitForExistence(timeout: 5), "close asks how to keep the changes")
            Acceptance.record(self, "T23 D7 sheet: \(texts(in: sheet)) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
            check(texts(in: sheet).contains("“Offline Close” couldn't be saved: the folder can't be reached."), "sheet message: \(texts(in: sheet))")
            check(sheet.buttons.allElementsBoundByIndex.map(\.title) == ["Save a Copy Elsewhere…", "Cancel", "Don't Save"],
                  "buttons, default first: \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T23 D7 close sheet")
            app.typeKey(.escape, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists } && window.exists, "Esc = Cancel keeps the window")
            app.typeKey("w", modifierFlags: .command)
            check(app.sheets.firstMatch.waitForExistence(timeout: 5), "close sheet again")
            app.typeKey(.return, modifierFlags: [])
            let copy = try saveCopyThroughPanel(named: "Offline Close copy", into: elsewhere, surface: "T23 D7 save panel")
            check(Acceptance.waitFor(timeout: 10) { !window.exists }, "the window closes once the copy is saved")
            check(diskEpisodeCount(copy) == 1, "the copy holds the edit: \(String(describing: diskEpisodeCount(copy)))")
            check(try Data(contentsOf: document) == original, "the original is byte-unchanged")
        }
    }

    /// T23 D7: Don't Save (⌘⌫) closes without writing anything; the original is byte-unchanged.
    func testT23D7CloseWhileUnreachableDontSave() throws {
        let unreachable = try folder("Unreachable")
        let document = try makeDocument("Offline Discard", in: unreachable)
        let original = try Data(contentsOf: document)
        try task("T23-D7-dont-save") {
            let window = try launchAndOpen(document, autosave: false, retryInterval: 2, offlineFolder: unreachable)
            addEpisodeByKeyboard(window)
            app.typeKey("s", modifierFlags: .command)
            dismissErrorSheetIfAny("T23 D7 after ⌘S")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix(Self.cantReach) }, "Can't reach: \(value(status))")
            app.typeKey("w", modifierFlags: .command)
            check(app.sheets.firstMatch.waitForExistence(timeout: 5), "close sheet")
            app.typeKey(.delete, modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 5) { !window.exists }, "⌘⌫ = Don't Save closes the window")
            check(try Data(contentsOf: document) == original, "nothing was written")
        }
    }

    // MARK: - Recording

    private func task(_ id: String, _ body: () throws -> Void) throws {
        findings = []
        do { try body() } catch { findings.append("threw \(error)") }
        let passed = findings.isEmpty
        Acceptance.record(self, "A11Y-001 \(id): \(passed ? "PASS" : "FAIL \(findings)")")
        Acceptance.writeEvidence("a11y001-\(id)", ["task": id, "passed": passed, "findings": findings, "revision": Acceptance.revision()], test: self)
        for finding in findings { XCTFail("\(id): \(finding)") }
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { findings.append(message) }
    }

    // MARK: - Helpers

    private func launchAndOpen(_ document: URL, autosave: Bool, retryInterval: Double?, offlineFolder: URL? = nil) throws -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestResetStorage", "YES", "-WWUITestCenterWindows", "YES",
                               "-WWUITestAutosave", autosave ? "ON" : "OFF", "-WWUITestOffline", "YES",
                               // Keyboard navigation (Tab reaches buttons) for this app only, via its argument domain: the
                               // GUI host doesn't have Full Keyboard Access on, and tests never change system settings.
                               "-AppleKeyboardUIMode", "2"]
            + (retryInterval.map { ["-WWUITestSaveRetryInterval", "\($0)"] } ?? [])
            + (offlineFolder.map { ["-WWUITestOfflineFolder", $0.path(percentEncoded: false)] } ?? [])
        // One launch only: see `XCUIApplication.launchOnce(opening:)`.
        app.launchOnce(opening: document)
        let name = document.deletingPathExtension().lastPathComponent
        guard app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch.waitForExistence(timeout: 10) else {
            throw NSError(domain: "OfflineSave", code: 1, userInfo: [NSLocalizedDescriptionKey: "window did not open"])
        }
        post(autosave ? Self.autosaveOn : Self.autosaveOff)
        Thread.sleep(forTimeInterval: 0.3)
        return app.windows.matching(identifier: "ww.show.window").firstMatch
    }

    /// A keyboard edit that marks the document dirty: New Episode (⇧⌘N), then Esc to leave the name as is.
    private func addEpisodeByKeyboard(_ window: XCUIElement) {
        window.typeKey("n", modifierFlags: [.command, .shift])
        check(element("ww.show.sidebar.rename").waitForExistence(timeout: 5), "New Episode by keyboard")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// View › Show Save Status (no shortcut; see the type comment).
    private func openSaveStatus() throws {
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuBars.menuItems["Show Save Status"]
        guard item.waitForExistence(timeout: 3) else { throw NSError(domain: "OfflineSave", code: 2) }
        item.click()
    }

    /// AppKit may present the failed save as an error sheet. Recorded (text and buttons) and dismissed with Return.
    private func dismissErrorSheetIfAny(_ context: String) {
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 2) else {
            Acceptance.record(self, "\(context): no error sheet")
            return
        }
        Acceptance.record(self, "\(context): sheet \(texts(in: sheet)) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
        app.typeKey(.return, modifierFlags: [])
        check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }, "\(context): sheet dismissed with Return")
    }

    /// The close-button dot and the Window-menu dot (Autosave Off) aren't exposed as XCUITest attributes we can
    /// assert on reliably, so their AX values are recorded for the evidence.
    private func recordDirtyIndicators(_ window: XCUIElement, _ context: String) {
        let close = window.buttons[XCUIIdentifierCloseWindow]
        Acceptance.record(self, "\(context): title \(window.title) | AX_EDITING_STATE \(editingState(window) ?? "none") | close button value \(String(describing: close.value))")
    }

    /// AppKit's document edit state ("— Edited" beside the title) is the `AX_EDITING_STATE` element, label "Document
    /// status", value "Edited" (mini audit records 479eb9e); it isn't part of the AX window title on macOS 27.
    private func editingState(_ window: XCUIElement) -> String? {
        let element = window.descendants(matching: .any).matching(identifier: "AX_EDITING_STATE").firstMatch
        guard element.exists else { return nil }
        return element.value as? String ?? element.label
    }

    private func windowSaysEdited(_ window: XCUIElement) -> Bool {
        editingState(window) == "Edited" || window.title.contains("Edited")
    }

    private func seam() -> (attempts: Int, offline: Bool, attemptTimes: [Double])? {
        guard let text = NSPasteboard(name: Self.seamPasteboard).string(forType: .string),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let attempts = object["publicationAttempts"] as? Int, let offline = object["offline"] as? Bool else { return nil }
        return (attempts, offline, (object["attemptTimes"] as? [Double]) ?? [])
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

    private func audit(_ surface: String) throws {
        let unwaived = try AcceptanceAudit.run(app, surface: surface, test: self)
        for finding in unwaived { findings.append("AUDIT \(finding)") }
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func folder(_ name: String) throws -> URL {
        let url = workDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// In the open save panel (sheet): checks the proposed name, goes to `folder` with ⇧⌘G, and saves with Return.
    private func saveCopyThroughPanel(named name: String, into folder: URL, surface: String) throws -> URL {
        let panel = app.sheets.firstMatch
        check(panel.waitForExistence(timeout: 5), "\(surface): native save panel shown")
        let names = panel.textFields.allElementsBoundByIndex.compactMap { $0.value as? String }
        check(names.contains(name), "\(surface): proposed name \"\(name)\": \(names)")
        app.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeText(folder.path(percentEncoded: false) + "\r")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.return, modifierFlags: [])
        let copy = folder.appending(path: "\(name).wwshow")
        check(Acceptance.waitFor(timeout: 10) { FileManager.default.fileExists(atPath: copy.path) }, "\(surface): copy written at the chosen folder")
        return copy
    }

    private func diskPayload(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["payload"] as? [String: Any]
    }

    private func diskShowID(_ url: URL) -> String? { (diskPayload(url)?["show"] as? [String: Any])?["id"] as? String }

    private func diskTitle(_ url: URL) -> String? { (diskPayload(url)?["show"] as? [String: Any])?["title"] as? String }

    private func makeDocument(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? workDirectory).appending(path: "\(name).wwshow")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        process.arguments = ["create", "--file", url.path, "--seed", "1"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, diskEpisodeCount(url) != nil else {
            throw NSError(domain: "OfflineSave", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture creation failed"])
        }
        return url
    }

    /// Episodes in the synthetic fixture beyond the probe's seed episodes, as written on disk.
    private func diskEpisodeCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any], let episodes = payload["episodes"] as? [Any] else { return nil }
        return episodes.count - Self.seedEpisodes
    }

    /// `wwpersist-probe create` writes three synthetic episodes.
    private static let seedEpisodes = 3
}
