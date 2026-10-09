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
///
/// Keyboard only (C01), with one limit (as `LibraryLocationUITests`, #169): Tab reaches popover buttons, and buttons
/// take keyboard focus, only with the system Full Keyboard Access ("Keyboard navigation") setting on. AppKit reads it
/// only from the system (`-AppleKeyboardUIMode` has no effect), and tests never change system settings.
/// - **On** (the user's C01 run): Tab/Space reach and activate the popover buttons, and focus checks are asserted.
/// - **Off** (agent runs): only those steps use XCUITest element actions, and each is recorded as **Not run (needs
///   Full Keyboard Access)** in `offline-keyboard-navigation` evidence, so the task is reported partial. Every outcome
///   check (status, attempts, disk, window, message bar) stays a hard check either way.
@MainActor
final class OfflineSaveKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []
    /// Steps not run as key events because the system keyboard navigation setting is off.
    private var needsKeyboardNavigation: [String] = []

    /// The system Full Keyboard Access / "Keyboard navigation" setting (`AppleKeyboardUIMode` bit 2, global domain).
    private static let keyboardNavigation = UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0

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
        if app != nil {
            let run = testRun
            let outcome = run?.hasBeenSkipped == true ? "skipped" : (run?.totalFailureCount ?? 0) == 0 ? "passed" : "failed"
            Acceptance.writeEvidence("offline-keyboard-navigation-\(name.replacingOccurrences(of: " ", with: "_"))",
                                     ["outcome": outcome, "keyboardNavigation": Self.keyboardNavigation,
                                      "notRunNeedsFullKeyboardAccess": Array(Set(needsKeyboardNavigation)).sorted()], test: self)
        }
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
            if Self.keyboardNavigation {
                check(isFocused(popover.buttons["Try Again"]), "keyboard focus starts on Try Again")
            } else {
                needsKeyboardNavigation.append("T27: keyboard focus starts on Try Again")
            }
            try audit("T27 popover")
            app.typeKey(.escape, modifierFlags: [])
            recordDirtyIndicators(window, "T27 while unreachable")
            // ST-12: no automatic attempt, for several times the (shortened) retry interval.
            Thread.sleep(forTimeInterval: 7)
            check(seam()?.attempts == afterSave, "no automatic save attempt with Autosave Off: \(String(describing: seam()?.attempts)) after \(afterSave)")
            check(value(status).hasPrefix(Self.cantReach), "still Can't reach: \(value(status))")
            check(try Data(contentsOf: document) == original, "the last saved version is byte-unchanged while unreachable")
            // Reconnect, then Try Again (focused first in the popover; Space activates it with keyboard navigation).
            post(Self.reconnect)
            try openSaveStatus()
            check(app.popovers.firstMatch.waitForExistence(timeout: 5), "popover reopened")
            activatePopoverButton("Try Again", tabs: 0, task: "T27")
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
            // T26 contract: after the failed save the title still shows "— Edited" (AppKit's edit state).
            check(Acceptance.waitFor(timeout: 3) { self.editingState(window) == "Edited" },
                  "the title shows \"— Edited\" after the failed save (AX_EDITING_STATE): \(editingState(window) ?? "none")")
            recordDirtyIndicators(window, "T26 after the first failed attempt")
            // Another edit right away, then sampling until 25 s after the failure: before the popover audit, which
            // can take 20 s on a loaded host and must not use up the window between attempts.
            addEpisodeByKeyboard(window)
            let secondEdit = Date().timeIntervalSince(firstFailure)
            Acceptance.record(self, "T26 second edit at +\(String(format: "%.1f", secondEdit)) s after the failure")
            check(secondEdit < 25, "the second edit happened before the next attempt was due: +\(secondEdit) s")
            var flicker: [String] = []
            while Date().timeIntervalSince(firstFailure) < 25 {
                let current = value(status)
                if !current.hasPrefix(Self.cantReach) { flicker.append(current) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            check(flicker.isEmpty, "no flicker between attempts: \(Set(flicker))")
            check(try Data(contentsOf: document) == original, "the last saved version is byte-unchanged while unreachable")
            try openSaveStatus()
            let popover = app.popovers.firstMatch
            check(popover.waitForExistence(timeout: 5), "save-status popover opened")
            check(texts(in: popover).contains { $0.contains("WaveWrangler will try again automatically.") }, "popover text: \(texts(in: popover))")
            check(popover.buttons["Try Again"].exists && popover.buttons["Save a Copy Elsewhere…"].exists,
                  "popover buttons: \(popover.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T26 popover")
            app.typeKey(.escape, modifierFlags: [])
            // The automatic retry 30 s after the failure fails too (still unreachable). After that AppKit's own edit
            // state reads "Not Saved" (macOS 27, mini #197 round 2), which the T26 row allows; it must still show one.
            check(Acceptance.waitFor(timeout: 40) { (self.seam()?.attempts ?? 0) > attemptsAtFailure }, "the automatic retry ran (still unreachable)")
            check(value(status).hasPrefix(Self.cantReach), "still Can't reach after the failed retry: \(value(status))")
            check(unsavedIndicator(window) != nil, "the title still shows unsaved changes after the failed retry (AX_EDITING_STATE): \(editingState(window) ?? "none")")
            recordDirtyIndicators(window, "T26 after the failed automatic retry")
            check(try Data(contentsOf: document) == original, "the last saved version is still byte-unchanged")
            // Reconnect: the next automatic retry (due 30 s after the last failed attempt) saves with no user action.
            post(Self.reconnect)
            check(Acceptance.waitFor(timeout: 40) { self.value(status).hasPrefix("Saved") }, "after reconnect → Saved with no user action: \(value(status))")
            let times = seam()?.attemptTimes ?? []
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
            Acceptance.record(self, "T26 attempt times (s after the first): \(times.map { String(format: "%.2f", $0 - (times.first ?? 0)) })")
            check(times.count >= 2, "an automatic retry happened: \(times.count) attempts")
            check(gaps.allSatisfy { $0 >= 29.9 }, "automatic retries at most every 30 s, even after the edit at +\(String(format: "%.1f", secondEdit)) s: gaps \(gaps)")
            check(diskEpisodeCount(document) == 2, "both edits are on disk: \(String(describing: diskEpisodeCount(document)))")
            let clean = Acceptance.waitFor(timeout: 3) { self.unsavedIndicator(window) == nil }
            Acceptance.record(self, "T26 edited-state trace: \(seam()?.events ?? [])")
            check(clean, "no \"— Edited\" after the verified save (AX_EDITING_STATE \(editingState(window) ?? "none")): \(window.title)")
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
            let popover = app.popovers.firstMatch
            check(popover.waitForExistence(timeout: 5), "save-status popover opened")
            // Try Again is focused first; Tab reaches Save a Copy Elsewhere…; Space activates it.
            activatePopoverButton("Save a Copy Elsewhere…", tabs: 1, task: "T28")
            let copy = try saveCopyThroughPanel(named: "Offline Copy copy", into: elsewhere, surface: "T28 save panel")
            check(Acceptance.waitFor(timeout: 10) { self.diskEpisodeCount(copy) == 1 }, "the copy holds the edit: \(String(describing: diskEpisodeCount(copy)))")
            check(Acceptance.waitFor(timeout: 5) { window.title.hasPrefix("Offline Copy copy") }, "window title is the copy: \(window.title)")
            check(Acceptance.waitFor(timeout: 5) { self.value(status).hasPrefix("Saved") }, "status Saved after the copy: \(value(status))")
            let bar = window.descendants(matching: .any).matching(identifier: "ww.show.messageBar").firstMatch
            let expected = "You're now editing “Offline Copy copy” in Elsewhere. The original at Unreachable wasn't changed."
            // The bar is one accessibility group: its label carries the heading (as for the C2b offer).
            let barShown = bar.waitForExistence(timeout: 10)
            check(barShown && (bar.label == expected || texts(in: bar).contains(expected)),
                  "message bar: \(barShown ? "\(bar.label) \(texts(in: bar))" : "not shown")")
            try audit("T28 copy message bar")
            // T28: "Focus returns to the save-status item" after the save panel closes (a button takes keyboard focus
            // only with keyboard navigation on).
            if Self.keyboardNavigation {
                check(Acceptance.waitFor(timeout: 3) { self.isFocused(status) }, "focus returns to the save-status item after the copy")
            } else {
                needsKeyboardNavigation.append("T28: focus returns to the save-status item")
            }
            check(try Data(contentsOf: document) == original, "the original is byte-unchanged")
            check(diskShowID(copy) != nil && diskShowID(copy) != diskShowID(document), "the copy is a separate show (new show ID)")
            check(diskTitle(copy) == "Offline Copy copy", "the copy is titled after its name: \(String(describing: diskTitle(copy)))")
            Acceptance.record(self, "T28 library: not asserted — the F-OFFLINE seam fails publications only; the library itself still reaches the original's folder, so its \"Location unavailable\" status can't be exercised here")
        }
    }

    func testT28ChangedCopyAfterReadbackKeepsOriginalWindowDirtyAndUndoable() throws {
        let unreachable = try folder("Unreachable"), elsewhere = try folder("Elsewhere")
        let original = try makeDocument("Unverified Copy", in: unreachable)
        let originalBytes = try Data(contentsOf: original)
        try task("T28-copy-changed-after-readback") {
            let window = try launchAndOpen(original, autosave: false, retryInterval: nil,
                                           offlineFolder: unreachable, replaceVerifiedCopy: true,
                                           retainedSnapshot: originalBytes)
            let offer = element("ww.show.messageBar")
            check(offer.waitForExistence(timeout: 10) && offer.label.contains("damaged and cannot be restored"),
                  "the original's retained recovery offer is visible before Save a Copy")
            let episodes = element("ww.show.sidebar.episodes")
            let before = value(episodes)
            addEpisodeByKeyboard(window)
            let afterEdit = value(episodes)
            check(afterEdit != before, "the unsaved edit appears in the live show")
            app.typeKey("s", modifierFlags: .command)
            dismissErrorSheetIfAny("T28 before copy")
            app.typeKey("w", modifierFlags: .command)
            check(app.sheets.firstMatch.waitForExistence(timeout: 5), "failed-save close asks for a copy")
            app.typeKey(.return, modifierFlags: [])
            let destination = try saveCopyThroughPanel(named: "Unverified Copy copy", into: elsewhere,
                                                        surface: "T28 changed copy")
            check(Acceptance.waitFor(timeout: 10) {
                (try? Data(contentsOf: destination)) == Data("competing destination".utf8)
            }, "the replacement occurred after independent readback")
            dismissErrorSheetIfAny("T28 changed copy")
            check(Acceptance.waitFor(timeout: 5) {
                window.exists && window.title.hasPrefix("Unverified Copy")
                    && !window.title.hasPrefix("Unverified Copy copy")
            },
                  "a failed copy cannot switch the live window or close it")
            check(value(element("ww.show.saveStatus")).hasPrefix("Save may have completed"),
                  "the late replacement is reported as uncertainty, never Saved")
            check(unsavedIndicator(window) != nil, "the original document remains dirty")
            check(value(episodes) == afterEdit, "the live unsaved model was not replaced by the copy")
            check(!element("ww.show.messageBar").label.hasPrefix("You're now editing"),
                  "no success notice for the unverified copy")
            check(offer.exists && offer.label.contains("damaged and cannot be restored"),
                  "the original's recovery offer remains selected after the failed copy")
            check(try Data(contentsOf: original) == originalBytes, "the original on disk was not written")
            check(try Data(contentsOf: destination) == Data("competing destination".utf8),
                  "the destination was replaced after independent readback")
            app.typeKey("z", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 5) { self.value(episodes) == before },
                  "Undo still reverses the original edit after the failed copy")
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
            // AX lists NSAlert buttons in layout order; the default (Return) is checked below by pressing Return.
            check(Set(sheet.buttons.allElementsBoundByIndex.map(\.title)) == ["Save a Copy Elsewhere…", "Cancel", "Don't Save"],
                  "buttons: \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
            try audit("T23 D7 close sheet")
            app.typeKey(.escape, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists } && window.exists, "Esc = Cancel keeps the window")
            app.typeKey("w", modifierFlags: .command)
            check(app.sheets.firstMatch.waitForExistence(timeout: 5), "close sheet again")
            app.typeKey(.return, modifierFlags: [])   // the default: Save a Copy Elsewhere…
            let copy = try saveCopyThroughPanel(named: "Offline Close copy", into: elsewhere, surface: "T23 D7 save panel (Return = default)")
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

    private func launchAndOpen(_ document: URL, autosave: Bool, retryInterval: Double?, offlineFolder: URL? = nil,
                               replaceVerifiedCopy: Bool = false, retainedSnapshot: Data? = nil) throws -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestResetStorage", "YES", "-WWUITestCenterWindows", "YES",
                               "-WWUITestAutosave", autosave ? "ON" : "OFF", "-WWUITestOffline", "YES"]
            + (retryInterval.map { ["-WWUITestSaveRetryInterval", "\($0)"] } ?? [])
            + (offlineFolder.map { ["-WWUITestOfflineFolder", $0.path(percentEncoded: false)] } ?? [])
            + (replaceVerifiedCopy ? ["-WWUITestReplaceVerifiedCopy", "YES"] : [])
            + (retainedSnapshot.map { ["-WWUITestRetainDamagedEditCheckpoint", $0.base64EncodedString()] } ?? [])
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

    /// AppKit's unsaved-changes indicator beside the title: "Edited", or "Not Saved" once an automatic retry has also
    /// failed (T26 row; observed macOS 27, mini #197 round 2); nil when the window shows none. T26 requires exactly
    /// "Edited" after the first failure.
    private func unsavedIndicator(_ window: XCUIElement) -> String? {
        if let state = editingState(window), ["Edited", "Not Saved"].contains(state) { return state }
        return window.title.contains("Edited") ? window.title : nil
    }

    private func seam() -> (attempts: Int, offline: Bool, attemptTimes: [Double], events: [String])? {
        guard let text = NSPasteboard(name: Self.seamPasteboard).string(forType: .string),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let attempts = object["publicationAttempts"] as? Int, let offline = object["offline"] as? Bool else { return nil }
        return (attempts, offline, (object["attemptTimes"] as? [Double]) ?? [], (object["events"] as? [String]) ?? [])
    }

    /// With keyboard navigation: Tab `tabs` times from the first (focused) popover button, check focus, Space. Without
    /// it: the button is clicked, and the keyboard step is recorded as Not run (needs Full Keyboard Access).
    private func activatePopoverButton(_ title: String, tabs: Int, task: String) {
        let button = app.popovers.firstMatch.buttons[title]
        if Self.keyboardNavigation {
            for _ in 0..<tabs { app.typeKey("\t", modifierFlags: []) }
            check(isFocused(button), "\(task): keyboard focus reaches \(title)")
            app.typeKey(" ", modifierFlags: [])
        } else {
            needsKeyboardNavigation.append("\(task): Tab/Space to \(title) in the save-status popover")
            check(button.waitForExistence(timeout: 3), "\(task): popover button \(title)")
            button.click()
        }
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

    /// In the save panel: checks the proposed name, goes to `folder` with ⇧⌘G, and saves with Return. As in #169 and
    /// #190: a bounded wait for the panel, a 2 s settle from detection, and keys sent to the out-of-process panel
    /// service when it hosts the panel (the sandboxed app's own snapshot stalls while the panel is up).
    /// Where the native save panel is shown, or nil while it isn't (yet). The panel is drawn by the out-of-process panel
    /// service, but XCUITest doesn't always report that service as running for a cold panel (#151, #190); the app
    /// then exposes it as a sheet (or window) holding the proposed name. A closing alert sheet doesn't count.
    private func savePanelHost(_ service: XCUIApplication, name: String) -> String? {
        if service.state != .notRunning { return "panel service" }
        for window in ["save-panel", "open-panel"] where app.windows[window].exists { return "app window \(window)" }
        let sheet = app.sheets.firstMatch
        if sheet.exists, sheet.textFields.allElementsBoundByIndex.contains(where: { ($0.value as? String) == name }) { return "app sheet" }
        return nil
    }

    /// ⇧⌘G, the folder's path, Return, then Return to save (all native save-panel keys).
    private func typeFolderAndSave(_ folder: URL, into target: XCUIApplication) {
        target.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        target.typeText(folder.path(percentEncoded: false))
        Thread.sleep(forTimeInterval: 0.5)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        target.typeKey(.return, modifierFlags: [])
    }

    private func saveCopyThroughPanel(named name: String, into folder: URL, surface: String) throws -> URL {
        let service = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
        let start = Date()
        var host: String?
        _ = Acceptance.waitFor(timeout: 20) {
            host = self.savePanelHost(service, name: name)
            return host != nil
        }
        check(host != nil, "\(surface): native save panel shown with the proposed name \"\(name)\" (service \(service.state.rawValue), sheets \(app.sheets.count))")
        let detectedAt = Date()
        let names = app.sheets.firstMatch.textFields.allElementsBoundByIndex.compactMap { $0.value as? String }
        if !names.isEmpty { check(names.contains(name), "\(surface): proposed name \"\(name)\": \(names)") }
        // Keys go to the service whenever it is reported; a panel that has only just appeared gets a 2 s settle.
        if host != "panel service", Acceptance.waitFor(timeout: 3, { service.state != .notRunning }) { host = "panel service" }
        Thread.sleep(forTimeInterval: 2)
        let first: XCUIApplication = host == "panel service" ? service : app
        Acceptance.record(self, "\(surface): panel host \(host ?? "none"), detected after \(String(format: "%.1f", detectedAt.timeIntervalSince(start))) s")
        typeFolderAndSave(folder, into: first)
        let copy = folder.appending(path: "\(name).wwshow")
        var written = Acceptance.waitFor(timeout: 10) { FileManager.default.fileExists(atPath: copy.path) }
        if !written {
            recordPanelDiagnostics(service, folder: folder, surface: surface)
            // The panel may have taken the keys in the other process: one more keyboard pass there, recorded.
            if service.state != .notRunning || savePanelHost(service, name: name) != nil {
                let second: XCUIApplication = first === service ? app : service
                Acceptance.record(self, "\(surface): no copy after keys to \(first === service ? "the panel service" : "the app"); retrying the same keys to \(second === service ? "the panel service" : "the app")")
                typeFolderAndSave(folder, into: second)
                written = Acceptance.waitFor(timeout: 10) { FileManager.default.fileExists(atPath: copy.path) }
                if !written { recordPanelDiagnostics(service, folder: folder, surface: "\(surface) (second pass)") }
            }
        }
        check(written, "\(surface): copy written at the chosen folder")
        return copy
    }

    private func recordPanelDiagnostics(_ service: XCUIApplication, folder: URL, surface: String) {
        let sheets = app.sheets.allElementsBoundByIndex.map { sheet in
            "\(sheet.identifier)|fields \(sheet.textFields.allElementsBoundByIndex.compactMap { $0.value as? String })|buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))"
        }
        let windows = app.windows.allElementsBoundByIndex.map { "\($0.identifier)|\($0.title)" }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        Acceptance.record(self, "\(surface) diagnostics: service \(service.state.rawValue), app sheets \(sheets), app windows \(windows), folder \(listing)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "panel-\(surface.replacingOccurrences(of: " ", with: "_"))"
        shot.lifetime = .keepAlways
        add(shot)
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
