import AppKit
import XCTest

/// M1-DUR-026 native lifecycle holdout (grant A): every Close/Quit route with dirty documents, AS01, AS05,
/// Save As cancel, Revert and relaunch with an edit checkpoint present. Disk truth is read independently
/// from the synthetic `.wwshow` file (created with `wwpersist-probe`, `WW_PROBE`).
///
/// Scenarios rotate through the routes; `TEST_RUNNER_WW_HOLDOUT_SCENARIOS` sets how many run (default: one
/// per route = calibration; 20 = frozen holdout). Each scenario is a fresh app launch on a fresh document.
/// Outcomes are recorded per scenario (JSON evidence) and any failed scenario fails the test at the end.
@MainActor
final class LifecycleHoldoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var failures: [String] = []
    private var notRun: String?

    private static let autosaveOn = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.on")
    private static let autosaveOff = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")
    private static let original = "Synthetic Trial Show 1"

    enum Route: String, CaseIterable {
        case closeOffCancelThenSave = "Close (⌘W), OFF dirty: Cancel keeps work, then Save writes"
        case commandQuitOffCancelThenDontSave = "⌘Q, OFF dirty: Cancel keeps app, then Don't Save quits without writing"
        case appMenuQuitOffSave = "App menu › Quit WaveWrangler, OFF dirty: Save writes and quits"
        case dockQuitOffDontSave = "Dock › Quit, OFF dirty: review shown, Don't Save quits without writing"
        case as01EditThenOffWithinDelay = "AS01: edit while ON, turn OFF within the delay: nothing written, Close prompts"
        case as05CloseDontSave = "AS05: OFF dirty Close › Don't Save: closes, disk unchanged"
        case saveAsCancel = "Save As… panel cancelled: nothing written, document unchanged and still dirty"
        case revertToSaved = "Revert To › Last Saved Version: edits discarded, disk title shown"
        case relaunchWithEditCheckpoint = "Relaunch with an edit checkpoint present: 'Restore unsaved changes' offered"
    }

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerDUR026-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testLifecycleRoutes() throws {
        let count = Acceptance.count("WW_HOLDOUT_SCENARIOS", default: Route.allCases.count)
        var records: [[String: Any]] = []
        for index in 0..<count {
            let route = Route.allCases[index % Route.allCases.count]
            // `WW_ROUTES` (comma-separated route numbers, 1-based) limits a calibration run to some routes.
            if let only = Acceptance.environment["WW_ROUTES"]?.split(separator: ",").compactMap({ Int($0) }),
               !only.contains(index % Route.allCases.count + 1) { continue }
            failures = []
            notRun = nil
            let started = Date()
            do {
                try run(route, index: index)
            } catch {
                failures.append("threw \(error)")
            }
            if let app, app.state != .notRunning { app.terminate() }
            let record: [String: Any] = [
                "scenario": index + 1, "route": route.rawValue, "passed": failures.isEmpty && notRun == nil, "failures": failures,
                "notRun": notRun ?? "",
                "seconds": Date().timeIntervalSince(started),
            ]
            records.append(record)
            Acceptance.record(self, "DUR-026 #\(index + 1) \(route.rawValue): \(notRun.map { "NOT RUN \($0)" } ?? (failures.isEmpty ? "PASS" : "FAIL \(failures)"))")
        }
        let passed = records.filter { $0["passed"] as? Bool == true }.count
        Acceptance.writeEvidence("dur026-native-lifecycle", [
            "revision": Acceptance.revision(), "scenarios": records, "executed": records.count, "passed": passed,
        ], test: self)
        for record in records where record["passed"] as? Bool != true && (record["notRun"] as? String ?? "").isEmpty {
            XCTFail("DUR-026 scenario \(record["scenario"] ?? "?") \(record["route"] ?? ""): \(record["failures"] ?? "")")
        }
    }

    // MARK: - Routes

    private func run(_ route: Route, index: Int) throws {
        let document = try makeDocument("Lifecycle \(index + 1)")
        switch route {
        case .closeOffCancelThenSave:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Edited \(index)")
            check(diskStays(document, Self.original, for: 2), "OFF must not write")
            app.typeKey("w", modifierFlags: .command)
            guard let sheet = closeSheet() else { return }
            check(hasDecisionButtons(sheet), "Save / Don't Save / Cancel")
            sheet.buttons["Cancel"].click()
            check(window.waitForExistence(timeout: 2), "Cancel keeps the window")
            check(diskTitle(document) == Self.original, "Cancel writes nothing")
            app.typeKey("w", modifierFlags: .command)
            closeSheet()?.buttons["Save"].click()
            check(Acceptance.waitFor(timeout: 5) { self.diskTitle(document) == "Edited \(index)" }, "Save writes the edit")
            check(Acceptance.waitFor(timeout: 5) { !window.exists }, "window closes after Save")

        case .commandQuitOffCancelThenDontSave:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Unsaved \(index)")
            app.typeKey("q", modifierFlags: .command)
            guard let sheet = closeSheet() else { return }
            check(hasDecisionButtons(sheet), "Save / Don't Save / Cancel")
            sheet.buttons["Cancel"].click()
            check(window.waitForExistence(timeout: 2) && app.state != .notRunning, "Cancel keeps the app and window")
            app.typeKey("q", modifierFlags: .command)
            if let sheet = closeSheet() { dontSave(in: sheet).click() }
            check(app.wait(for: .notRunning, timeout: 10), "Don't Save quits")
            check(diskTitle(document) == Self.original, "nothing written")

        case .appMenuQuitOffSave:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Saved at app-menu Quit \(index)")
            app.menuBars.menuBarItems["WaveWrangler"].click()
            app.menuBars.menuItems["Quit WaveWrangler"].click()
            guard let sheet = closeSheet() else { return }
            check(hasDecisionButtons(sheet), "Save / Don't Save / Cancel")
            sheet.buttons["Save"].click()
            check(app.wait(for: .notRunning, timeout: 10), "Save then quits")
            check(diskTitle(document) == "Saved at app-menu Quit \(index)", "Save wrote the edit")

        case .dockQuitOffDontSave:
            // Not runnable here: the sandboxed XCUITest runner can neither read the Dock's AX tree nor send Apple
            // events, and background computer-use can't open the Dock's menu. Recorded as not run, never passed.
            notRun = "Dock › Quit can't be driven by the sandboxed runner or background computer-use (user-manual item)"
            _ = document
        case .as01EditThenOffWithinDelay:
            let window = try launchAndOpen(document, autosave: true)
            try edit(window, title: "Queued \(index)")
            post(Self.autosaveOff)
            check(diskStays(document, Self.original, for: 3), "work queued before OFF is skipped")
            app.typeKey("w", modifierFlags: .command)
            guard let sheet = closeSheet() else { return }
            check(hasDecisionButtons(sheet), "OFF dirty Close prompts")
            sheet.buttons["Cancel"].click()
            check(window.waitForExistence(timeout: 2), "Cancel keeps the window")

        case .as05CloseDontSave:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Discarded \(index)")
            app.typeKey("w", modifierFlags: .command)
            guard let sheet = closeSheet() else { return }
            check(hasDecisionButtons(sheet), "Save / Don't Save / Cancel")
            dontSave(in: sheet).click()
            check(Acceptance.waitFor(timeout: 5) { !window.exists }, "Don't Save closes")
            check(diskTitle(document) == Self.original, "nothing written")

        case .saveAsCancel:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Save As cancelled \(index)")
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? [])
            let titleBefore = window.title
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems["Save As…"].click()
            let panel = app.sheets.firstMatch
            check(panel.waitForExistence(timeout: 5), "Save As panel shown")
            app.typeKey(.escape, modifierFlags: [])
            check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists }, "panel dismissed")
            check(diskTitle(document) == Self.original, "nothing written")
            check(window.title == titleBefore, "still the same document: \(titleBefore) → \(window.title)")
            check(window.textFields["Show title"].value as? String == "Save As cancelled \(index)", "edit kept")
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? [])
            check(after == before, "no copy created: \(after.subtracting(before))")
            app.typeKey("w", modifierFlags: .command)
            check(closeSheet() != nil, "still dirty after cancelled Save As")

        case .revertToSaved:
            let window = try launchAndOpen(document, autosave: false)
            try edit(window, title: "Reverted \(index)")
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems["Revert To"].hover()
            let item = app.menuBars.menuItems["Last Saved Version"]
            guard item.waitForExistence(timeout: 3) else { failures.append("Revert To › Last Saved Version missing"); return }
            item.click()
            let alert = app.sheets.firstMatch
            if alert.waitForExistence(timeout: 3) {
                Acceptance.record(self, "Revert sheet: \(alert.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) buttons \(alert.buttons.allElementsBoundByIndex.map(\.title))")
                let revert = alert.buttons.matching(NSPredicate(format: "title BEGINSWITH 'Revert'")).firstMatch
                if revert.exists { revert.click() } else { failures.append("Revert confirmation button") }
            } else {
                Acceptance.record(self, "Revert: no confirmation sheet")
            }
            Thread.sleep(forTimeInterval: 1)
            // The title field still has keyboard focus here: it must show the reverted value, not the stale draft.
            Acceptance.record(self, "Revert: field \(window.textFields["Show title"].value ?? "nil"), window title \(window.title), disk \(diskTitle(document) ?? "nil")")
            check(Acceptance.waitFor(timeout: 5) { window.textFields["Show title"].value as? String == Self.original },
                  "reverted to the disk title: \(window.textFields["Show title"].value ?? "nil")")
            check(diskTitle(document) == Self.original, "disk unchanged")
            app.typeKey("w", modifierFlags: .command)
            check(!app.sheets.firstMatch.waitForExistence(timeout: 1.5), "clean after revert: no prompt")

        case .relaunchWithEditCheckpoint:
            // ON with a 30 s delay: no verified publication is expected within 1.5 s, so a C2b edit checkpoint is
            // written at quiescence. Then the process is killed (no Quit) and the show reopened.
            let window = try launchAndOpen(document, autosave: true, extra: ["-WWUITestAutosaveDelaySeconds", "30"])
            try edit(window, title: "Checkpointed \(index)")
            Thread.sleep(forTimeInterval: 3)
            app.terminate()
            check(diskTitle(document) == Self.original, "no publication before the kill")
            let reopened = try launchAndOpen(document, autosave: true, extra: ["-WWUITestAutosaveDelaySeconds", "30"])
            let offer = reopened.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Restore' OR value CONTAINS[c] 'Restore' OR title CONTAINS[c] 'Restore'")).firstMatch
            check(offer.waitForExistence(timeout: 5), "'Restore unsaved changes' offered on reopen (issue #84)")
            let restore = reopened.buttons["Restore Unsaved Changes"]
            if restore.waitForExistence(timeout: 3) {
                restore.click()
                let showInfo = reopened.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
                if showInfo.exists { showInfo.click() }
                check(Acceptance.waitFor(timeout: 5) { reopened.textFields["Show title"].value as? String == "Checkpointed \(index)" },
                      "restored the unsaved title: \(reopened.textFields["Show title"].value ?? "nil")")
                let status = reopened.descendants(matching: .any).matching(identifier: "ww.show.saveStatus").firstMatch
                Acceptance.record(self, "after restore: status \(status.value ?? "nil"), disk \(diskTitle(document) ?? "nil")")
                check(!((status.value as? String) ?? "").hasPrefix("Saved") || diskTitle(document) == "Checkpointed \(index)",
                      "restore never claims Saved before a verified save")
            } else {
                check(false, "Restore Unsaved Changes button")
            }
        }
    }

    // MARK: - Helpers

    private func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    private func makeDocument(_ name: String) throws -> URL {
        let url = workDirectory.appending(path: "\(name).wwshow")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        probe.arguments = ["create", "--file", url.path, "--seed", "1"]
        probe.standardOutput = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0, diskTitle(url) == Self.original else {
            throw NSError(domain: "DUR026", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture creation failed"])
        }
        return url
    }

    private func launchAndOpen(_ document: URL, autosave: Bool, extra: [String] = []) throws -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = [
            "-WWUITestHooks", "YES", "-WWUITestAutosave", autosave ? "ON" : "OFF", "-ApplePersistenceIgnoreState", "YES",
        ] + extra
        // One launch only (see SourceGrantHoldoutUITests.launchAndOpen): `open(_:)` applies the launch arguments.
        app.open(document)
        let untitled = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Untitled'")).firstMatch
        if untitled.waitForExistence(timeout: 1) {
            untitled.click()
            app.typeKey("w", modifierFlags: .command)
            _ = Acceptance.waitFor(timeout: 3) { !untitled.exists }
        }
        let name = document.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        guard window.waitForExistence(timeout: 10) else {
            throw NSError(domain: "DUR026", code: 2, userInfo: [NSLocalizedDescriptionKey: "document window did not open"])
        }
        post(autosave ? Self.autosaveOn : Self.autosaveOff)
        Thread.sleep(forTimeInterval: 0.3)
        // Address the window by identifier from here on: its title follows the show title and edit state.
        return app.windows.matching(identifier: "ww.show.window").firstMatch
    }

    private func edit(_ window: XCUIElement, title: String) throws {
        let showInfo = window.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
        if showInfo.waitForExistence(timeout: 5) { showInfo.click() }
        let field = window.textFields["Show title"]
        guard field.waitForExistence(timeout: 5) else {
            throw NSError(domain: "DUR026", code: 3, userInfo: [NSLocalizedDescriptionKey: "Show title field missing"])
        }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        field.typeKey(.return, modifierFlags: [])
    }

    @discardableResult
    private func closeSheet() -> XCUIElement? {
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 5) else {
            failures.append("no Save / Don't Save / Cancel decision shown")
            return nil
        }
        return sheet
    }

    private func hasDecisionButtons(_ sheet: XCUIElement) -> Bool {
        sheet.buttons["Save"].exists && dontSave(in: sheet).exists && sheet.buttons["Cancel"].exists
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

    private func diskStays(_ url: URL, _ title: String, for seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if diskTitle(url) != title { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
