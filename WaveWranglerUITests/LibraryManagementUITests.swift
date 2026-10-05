import XCTest

/// WW-013 / WW-011 library management on the real (persistent) library store in isolated UI-test storage:
/// collections create / rename / move / delete, File › Library › Rebuild Library Index… with zero semantic
/// loss, and Settings › Library location: move to a local temporary folder (sandboxed panel) and back.
/// "Semantic state" = every sidebar row's label and value plus the Shows entry count, compared before and
/// after each operation. Synthetic show documents only.
@MainActor
final class LibraryManagementUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []
    private let suffix = String(UUID().uuidString.prefix(4))

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else { throw XCTSkip("WW_PROBE is not set") }
        workDirectory = FileManager.default.temporaryDirectory.appending(path: "WW013-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testCollectionsRebuildIndexAndLibraryLocation() throws {
        let show = workDirectory.appending(path: "WW013 Show \(suffix).wwshow")
        try probe(["create", "--file", show.path, "--seed", "13"])
        launch()
        app.open(show)
        _ = app.windows.matching(identifier: "ww.show.window").firstMatch.waitForExistence(timeout: 10)
        app.typeKey("w", modifierFlags: .command)
        showLibrary()

        // Collections: create two, rename one, move, add the show, delete one.
        step("collections") {
            for name in ["WW013 A \(suffix)", "WW013 B \(suffix)"] {
                menu("File", "Library", "New Collection…")
                let field = element("ww.dialog.name")
                check(field.waitForExistence(timeout: 5), "name dialog")
                field.typeText(name + "\r")
                check(collection(name).waitForExistence(timeout: 5), "created \(name)")
            }
            collection("WW013 A \(suffix)").click()
            menu("File", "Library", "Rename Collection…")
            let field = element("ww.dialog.name")
            check(field.waitForExistence(timeout: 5), "rename dialog")
            field.typeKey("a", modifierFlags: .command)
            field.typeText("WW013 Renamed \(suffix)\r")
            check(collection("WW013 Renamed \(suffix)").waitForExistence(timeout: 5), "renamed")
            let before = collectionOrder()
            app.typeKey(.downArrow, modifierFlags: [.command, .option])
            check(Acceptance.waitFor(timeout: 3) { self.collectionOrder() != before }, "Move Collection Down reorders: \(collectionOrder())")
            // Add the show (Shows › first row) to the renamed collection via File › Library › Add to Collection ▸.
            element("ww.library.sidebar.shows").click()
            app.typeKey("\t", modifierFlags: [])
            app.typeKey(.downArrow, modifierFlags: [])
            menu("File", "Library", "Add to Collection", "WW013 Renamed \(suffix)")
            check(Acceptance.waitFor(timeout: 3) { (self.collection("WW013 Renamed \(suffix)").value as? String) == "1 item" }, "show added: \(collection("WW013 Renamed \(suffix)").value ?? "nil")")
            collection("WW013 B \(suffix)").click()
            app.typeKey(.delete, modifierFlags: [])
            let sheet = app.sheets.firstMatch
            check(sheet.waitForExistence(timeout: 5), "delete confirmation")
            if sheet.exists { sheet.buttons["Delete"].click() }
            check(!collection("WW013 B \(suffix)").waitForExistence(timeout: 2), "deleted")
            check(element("ww.library.sidebar.shows").value as? String != "0 shows", "deleting a collection keeps shows")
        }

        // Rebuild Library Index: zero semantic loss.
        step("rebuild index") {
            let before = semanticState()
            menu("File", "Library", "Rebuild Library Index…")
            if app.sheets.firstMatch.waitForExistence(timeout: 3) {
                let sheet = app.sheets.firstMatch
                Acceptance.record(self, "rebuild sheet: \(sheet.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
                let confirm = sheet.buttons.matching(NSPredicate(format: "title BEGINSWITH 'Rebuild'")).firstMatch
                if confirm.exists { confirm.click() } else { app.typeKey(.return, modifierFlags: []) }
            }
            Thread.sleep(forTimeInterval: 3)
            let after = semanticState()
            Acceptance.record(self, "rebuild before \(before) after \(after)")
            check(before == after, "rebuild index keeps every collection, member count, recent and entry")
        }

        // Relaunch: the library (collections, membership) persists.
        step("relaunch persistence") {
            let before = semanticState()
            app.typeKey("q", modifierFlags: .command)
            _ = app.wait(for: .notRunning, timeout: 10)
            launch()
            showLibrary()
            Thread.sleep(forTimeInterval: 2)
            let after = semanticState()
            Acceptance.record(self, "relaunch before \(before) after \(after)")
            check(before == after, "library state after relaunch equals before (#88)")
        }

        // Library location: to a local temporary folder and back.
        let folder = workDirectory.appending(path: "Library Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        step("location to folder") {
            let before = semanticState()
            choose(location: "Choose Folder…")
            choosePanelFolder(folder.path)
            confirmMove()
            let popup = app.popUpButtons["ww.settings.libraryLocation"]
            check(Acceptance.waitFor(timeout: 20) { (popup.value as? String) == "Library Folder" }, "location shows the folder: \(popup.value ?? "nil")")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            Acceptance.record(self, "library folder contents after move: \(files.count) item(s)")
            check(!files.isEmpty, "library written into the chosen folder")
            app.typeKey("w", modifierFlags: .command)
            showLibrary()
            check(semanticState() == before, "nothing lost moving the library: \(semanticState())")
        }
        step("location back") {
            let before = semanticState()
            choose(location: "In WaveWrangler")
            confirmMove()
            let popup = app.popUpButtons["ww.settings.libraryLocation"]
            check(Acceptance.waitFor(timeout: 20) { (popup.value as? String) == "In WaveWrangler" }, "location back in WaveWrangler: \(popup.value ?? "nil")")
            app.typeKey("w", modifierFlags: .command)
            showLibrary()
            check(semanticState() == before, "nothing lost moving back: \(semanticState())")
        }
    }

    // MARK: - Helpers

    private func step(_ name: String, _ body: () throws -> Void) {
        findings = []
        do { try body() } catch { findings.append("threw \(error)") }
        Acceptance.record(self, "WW-013 \(name): \(findings.isEmpty ? "PASS" : "FAIL \(findings)")")
        Acceptance.writeEvidence("ww013-\(name.replacingOccurrences(of: " ", with: "-"))", ["step": name, "passed": findings.isEmpty, "findings": findings, "revision": Acceptance.revision()], test: self)
        for finding in findings { XCTFail("\(name): \(finding)") }
    }

    private func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { findings.append(message()) }
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestCenterWindows", "YES"]
        app.launch()
        app.activate()
    }

    private func showLibrary() {
        app.typeKey("l", modifierFlags: [.command, .shift])
        _ = element("ww.library.sidebar").waitForExistence(timeout: 10)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func collection(_ name: String) -> XCUIElement {
        app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.' AND label == %@", "\(name), collection")).firstMatch
    }

    private func collectionOrder() -> [String] {
        app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.'")).allElementsBoundByIndex.map(\.label)
    }

    /// Sidebar rows (label: value) in order, plus the Shows count.
    private func semanticState() -> [String] {
        app.outlines["ww.library.sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.' AND identifier != 'ww.library.sidebar.newCollection'"))
            .allElementsBoundByIndex.map { "\($0.label): \($0.value as? String ?? "")" }
    }

    private func menu(_ path: String...) {
        var item = app.menuBars.menuBarItems[path[0]]
        item.click()
        for (index, title) in path.dropFirst().enumerated() {
            item = item.menuItems[title].firstMatch
            guard item.waitForExistence(timeout: 3) else {
                findings.append("menu \(path.joined(separator: " › ")) (missing \(title))")
                app.typeKey(.escape, modifierFlags: [])
                return
            }
            if index == path.count - 2 { item.click() } else { item.hover() }
        }
    }

    private func choose(location title: String) {
        app.typeKey(",", modifierFlags: .command)
        if app.toolbars.buttons["General"].waitForExistence(timeout: 3) { app.toolbars.buttons["General"].click() }
        let popup = app.popUpButtons["ww.settings.libraryLocation"]
        guard popup.waitForExistence(timeout: 5) else { findings.append("library location pop-up"); return }
        popup.click()
        let item = popup.menuItems[title]
        guard item.waitForExistence(timeout: 3) else { findings.append("location item \(title)"); return }
        item.click()
    }

    private func choosePanelFolder(_ path: String) {
        let service = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
        Thread.sleep(forTimeInterval: 2)
        let target = service.state == .notRunning ? app! : service
        target.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        target.typeText(path)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func confirmMove() {
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 10) else {
            let dialog = app.dialogs.firstMatch
            if dialog.exists, dialog.buttons["Move Library"].exists { dialog.buttons["Move Library"].click(); return }
            findings.append("move confirmation")
            return
        }
        Acceptance.record(self, "move sheet: \(sheet.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
        if sheet.buttons["Move Library"].exists { sheet.buttons["Move Library"].click() } else { findings.append("Move Library button") }
    }

    private func probe(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
