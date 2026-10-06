import AppKit
import CryptoKit
import XCTest

/// T25 / K26 (accessibility-acceptance): change the library location, keyboard only, and the library-level states
/// L1–L5 (states-and-recovery §5.1). The app's real persistent library is seeded with F-LIBLOC (12 shows,
/// 5 collections, 8 recent items, 3 unavailable entries) by `-WWUITestLibraryLocation`; target folders are made
/// here, in the runner's temporary directory, with the persistence probe (`WW_PROBE`), and chosen in the real open
/// panel by keyboard (⇧⌘G, path, Return). Each target folder is checksummed before and after where nothing may be
/// written. Synthetic data only.
///
/// Keyboard only (C01), with one limit. macOS Tab reaches pop-ups and buttons, and ⌃F2 reaches the menu bar, only
/// with the system Full Keyboard Access ("Keyboard navigation") setting on. AppKit reads it only from the system: a
/// launch argument or an app default doesn't turn it on (`-AppleKeyboardUIMode 2` was tried in #161 and had no
/// effect). That setting isn't in the agent grant, so it is never changed here.
/// - **Keyboard navigation on** (the user's C01 run): every step is a key event, and Tab-reachability and focus
///   return are asserted.
/// - **Off** (agent runs): only the steps that need it use XCUITest element/menu actions: Tab to the Library
///   location pop-up, Tab to message bar and sheet buttons, ⌃F2 menus, and focus return. Each is recorded as
///   **Not run (needs Full Keyboard Access)** in `t25-keyboard-navigation` evidence, so T25 is reported partial.
///   Everything else stays keys: ⌘, ⇧⌘L, Space and type-select in the pop-up menu, ⇧⌘G and Return in the open
///   panel, Return and Esc in sheets, and typing names.
/// The XCUITest result never stands in for the user's FKA run; that C01 cell stays **Not run** until the user
/// records it (accessibility-acceptance §6 item 3).
@MainActor
final class LibraryLocationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var work: URL!
    /// Steps not run as key events because the system keyboard navigation setting is off.
    private var needsKeyboardNavigation: [String] = []

    /// The system Full Keyboard Access / "Keyboard navigation" setting (`AppleKeyboardUIMode` bit 2, global domain).
    private static let keyboardNavigation = UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else { throw XCTSkip("WW_PROBE is not set") }
        work = FileManager.default.temporaryDirectory.appending(path: "T25-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Acceptance.writeEvidence("t25-keyboard-navigation-\(name.replacingOccurrences(of: " ", with: "_"))",
                                 ["keyboardNavigation": Self.keyboardNavigation,
                                  "notRunNeedsFullKeyboardAccess": Array(Set(needsKeyboardNavigation)).sorted()], test: self)
        if let app, app.state != .notRunning { app.terminate() }
        // Leave no library location or library behind for later suites: they share the isolated UI-test
        // preferences and storage, and the folders chosen here are deleted below. One launch with storage reset
        // clears the location setting and the UI-test library.
        if app != nil {
            let reset = XCUIApplication()
            reset.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetStorage", "YES",
                                     "-WWUITestResetPreferences", "YES", "-WWUITestLibraryFixture", "empty"]
            reset.launch()
            reset.terminate()
        }
        if let work {
            // Restore permissions changed by a test so the folder can be removed.
            for item in (try? FileManager.default.subpathsOfDirectory(atPath: work.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appending(path: item).path)
            }
            try? FileManager.default.removeItem(at: work)
        }
    }

    // MARK: - T25: move, cancel, failure

    /// K26 keyboard path: ⌘, → Tab to Library location → Space → Choose Folder… → Return → folder in the panel →
    /// sheet: Return = Move Library. Everything is kept; focus returns to the pop-up; the old copy is no longer
    /// written; and back into WaveWrangler.
    func testMoveToAFolderAndBackKeepsEverythingKeyboardOnly() throws {
        launch(state: "ready")
        let before = libraryState()
        XCTAssertEqual(before.shows, "12 shows")
        XCTAssertEqual(before.recent, "8 items")
        XCTAssertEqual(before.unavailable, "3 items need attention")
        XCTAssertEqual(before.collections.count, 5, "F-LIBLOC collections: \(before.collections)")

        let popup = openLibraryLocation()
        XCTAssertEqual(popup.value as? String, "In WaveWrangler", "fresh install location")
        let first = folder("First Library Folder")
        chooseFolder(first, from: popup)
        confirmMove(to: "First Library Folder")
        // Progress is read in Settings (ST-33 step 3).
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Moving library — checking copy…' OR value CONTAINS 'Moving library — checking copy…'")).firstMatch.waitForExistence(timeout: 10),
                      "progress: \(texts(app.windows.firstMatch))")
        waitForValue(popup, "First Library Folder", timeout: 20)
        assertFocusReturns(to: popup, "focus returns to the pop-up after the sheet")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Your library is now stored in “First Library Folder”' OR value BEGINSWITH 'Your library is now stored in “First Library Folder”'")).firstMatch.waitForExistence(timeout: 5),
                      "outcome stated in Settings")
        let firstFile = first.appending(path: "Library.wwlibrary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path), "library written into the chosen folder")
        XCTAssertEqual(libraryState(), before, "nothing lost moving the library")

        // A second move: the first copy is retired — kept, never written again.
        let second = folder("Second Library Folder")
        let popup2 = openLibraryLocation()
        chooseFolder(second, from: popup2)
        confirmMove(to: "Second Library Folder")
        waitForValue(popup2, "Second Library Folder", timeout: 20)
        let retired = try digest(first)
        addCollection("After The Move")
        var after = before
        after.collections.append("After The Move: 0 items")
        XCTAssertEqual(libraryState().collectionNames.sorted(), after.collectionNames.sorted(), "the edit is in the library in use")
        XCTAssertEqual(try digest(first), retired, "the retired copy isn't written")

        // Back into WaveWrangler (same sheet, "Move your library back into WaveWrangler?").
        let popup3 = openLibraryLocation()
        select("In WaveWrangler", in: popup3)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Move your library back into WaveWrangler?"].exists, texts(sheet).description)
        app.typeKey(.return, modifierFlags: [])
        waitForValue(popup3, "In WaveWrangler", timeout: 20)
        XCTAssertEqual(libraryState().collectionNames.sorted(), after.collectionNames.sorted(), "nothing lost moving back")
    }

    /// Cancel and failure leave the old location in use, and nothing is written to the chosen folder.
    func testCancelAndFailureLeaveTheLibraryWhereItIs() throws {
        launch(state: "ready")
        let before = libraryState()

        let empty = folder("Cancelled Folder")
        let popup = openLibraryLocation()
        chooseFolder(empty, from: popup)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["Move your library to “Cancelled Folder”?"].exists, texts(sheet).description)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(popup.value as? String, "In WaveWrangler", "Cancel keeps the location")
        assertFocusReturns(to: popup, "focus returns to the pop-up after Cancel")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [], "nothing written on Cancel")

        let readOnly = folder("Read-Only Folder")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        chooseFolder(readOnly, from: popup)
        confirmMove(to: "Read-Only Folder")
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Couldn’t move your library' OR label BEGINSWITH 'Couldn\\'t move your library' OR value BEGINSWITH 'Couldn\\'t move your library'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "failure stated: \(texts(app.windows.firstMatch))")
        XCTAssertTrue(failure.label.contains("nothing was changed") || ((failure.value as? String) ?? "").contains("nothing was changed"))
        XCTAssertEqual(popup.value as? String, "In WaveWrangler", "failure keeps the location")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: readOnly.path), [], "nothing written on failure")
        XCTAssertEqual(libraryState(), before)
    }

    // MARK: - T25: a folder that already has a library (§5.1 step 6)

    /// L1: the sheet says everything is kept; Use That Library combines (ST-36): differing same-named collections
    /// survive with the first free "(from this Mac n)" suffix; every entry, unavailable entry and recent is kept.
    func testFolderWithAReadyLibraryCombinesKeepingEverything() throws {
        launch(state: "ready")
        let target = folder("Shared Library")
        // The folder's library: 4 shows, Alpha [0,1,2], Beta [1,2,3], 1 recent, plus "Alpha (from this Mac)".
        try probeLibrary(target, ["--seed-fixture", "1"])
        try probeLibrary(target, ["--add-collection", "Alpha (from this Mac)"])

        let popup = openLibraryLocation()
        chooseFolder(target, from: popup)
        confirmMove(to: "Shared Library")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["“Shared Library” already has a WaveWrangler library"].waitForExistence(timeout: 10), texts(sheet).description)
        XCTAssertTrue(texts(sheet).contains { $0.contains("All collections, recent items and library entries from both are kept, including unavailable shows.") })
        let use = sheet.buttons["Use That Library"]
        XCTAssertTrue(use.isEnabled)
        XCTAssertTrue(sheet.buttons["Choose Another Folder…"].exists)
        XCTAssertTrue(sheet.buttons["Cancel"].exists)
        // Keyboard: Tab to Use That Library (no default button), Space.
        press(use, step: "Tab to Use That Library")
        waitForValue(popup, "Shared Library", timeout: 20)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Combined libraries' OR value BEGINSWITH 'Combined libraries'")).firstMatch.waitForExistence(timeout: 5),
                      "ST-36 summary stated")

        let combined = libraryState()
        XCTAssertEqual(combined.shows, "16 shows", "every entry from both libraries")
        // The 3 unavailable entries, plus the folder library's 4 shows, which this Mac has never opened (Location
        // unknown).
        XCTAssertEqual(combined.unavailable, "7 items need attention", "unavailable entries kept")
        XCTAssertEqual(combined.recent, "9 items", "recent items from both")
        for name in ["Alpha", "Alpha (from this Mac)", "Alpha (from this Mac 2)", "Beta", "Season 1", "Season 2", "Specials", "Archive"] {
            XCTAssertTrue(combined.collectionNames.contains(name), "collection \(name) in \(combined.collectionNames)")
        }
        XCTAssertEqual(combined.collectionNames.count, 8, "\(combined.collectionNames)")
    }

    /// L5 (newer format) and L3 (no permission to read it) libraries in the folder: Use That Library is disabled, the
    /// reason is the §5.1 step 6 sentence, nothing is written (checksums unchanged), and the current library stays in
    /// use.
    func testFolderWithANewerOrPermissionDeniedLibraryIsNeverUsedOrWritten() throws {
        launch(state: "ready")
        let before = libraryState()

        let newer = folder("Newer Library")
        try probeLibrary(newer, ["--seed-fixture", "1"])
        let newerFile = newer.appending(path: "Library.wwlibrary")
        let text = try String(contentsOf: newerFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\":2"), "probe wrote the current library schema")
        try text.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":99").write(to: newerFile, atomically: true, encoding: .utf8)
        let newerDigest = try digest(newer)

        let popup = openLibraryLocation()
        chooseFolder(newer, from: popup)
        confirmMove(to: "Newer Library")
        assertBlocked("Newer Library", reason: "The library in this folder was saved by a newer version of WaveWrangler, so this version can't add to it.")
        XCTAssertEqual(try digest(newer), newerDigest, "nothing written to the newer library")
        XCTAssertEqual(popup.value as? String, "In WaveWrangler")

        let unreadable = folder("Locked Library")
        try probeLibrary(unreadable, ["--seed-fixture", "1"])
        let unreadableFile = unreadable.appending(path: "Library.wwlibrary")
        let unreadableDigest = try digest(unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFile.path)
        chooseFolder(unreadable, from: popup)
        confirmMove(to: "Locked Library")
        assertBlocked("Locked Library", reason: "WaveWrangler needs permission to use the library in this folder.")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableFile.path)
        XCTAssertEqual(try digest(unreadable), unreadableDigest, "nothing written to the locked library")
        XCTAssertEqual(popup.value as? String, "In WaveWrangler")
        XCTAssertEqual(libraryState(), before, "the current library stays in use, unchanged")
    }

    // MARK: - T25: library-level states of the current library (Library window message bar)

    /// L2: heading and actions; ⇧⌘L → Tab reaches the message bar buttons first (K26); an edit is queued as
    /// "1 library change not saved yet"; when the folder is back, Try Again saves it.
    func testUnreachableLibraryQueuesEditsAndTryAgainSavesThem() throws {
        launch(state: "unreachable")
        let bar = messageBar(heading: "Can't reach your library")
        XCTAssertTrue(bar.buttons["Try Again"].exists)
        XCTAssertTrue(bar.buttons["Library Settings…"].exists)
        assertTabReachesMessageBarFirst(bar.buttons["Try Again"])
        addCollection("Queued While Away")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 library change not saved yet' OR value CONTAINS '1 library change not saved yet'")).firstMatch.waitForExistence(timeout: 5),
                      "queued edit stated: \(texts(bar))")
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.brandonmartinez.wavewrangler.uitest.libraryFolder.restore"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.5)
        press(bar.buttons["Try Again"], step: "Tab to Try Again")
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "library reachable again: \(texts(app.windows["Library"]))")
        XCTAssertTrue(libraryState().collectionNames.contains("Queued While Away"), "the queued edit was saved")
    }

    /// L3: heading and Grant Access… (open panel pre-pointed at the folder; Return chooses it) → back to L1.
    func testNeedsPermissionGrantAccessRestoresTheLibrary() throws {
        launch(state: "permission")
        let bar = messageBar(heading: "WaveWrangler needs permission to use your library folder")
        let grant = bar.buttons["Grant Access…"]
        XCTAssertTrue(grant.exists)
        assertTabReachesMessageBarFirst(grant)
        press(grant, step: "Tab to Grant Access…", alreadyFocused: true)
        // The panel opens at the library's folder: choose it.
        let service = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
        Thread.sleep(forTimeInterval: 2)
        (service.state == .notRunning ? app! : service).typeKey(.return, modifierFlags: [])
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "access granted: \(texts(app.windows["Library"]))")
        XCTAssertEqual(libraryState().shows, "12 shows")
    }

    /// L4: another writer changed the library; this Mac's next edit meets it. Combine (Keep Everything) keeps both.
    func testChangedOnAnotherMacCombinesKeepingBothChanges() throws {
        launch(state: "conflict")
        _ = libraryState()
        Thread.sleep(forTimeInterval: 2)  // the fixture's external change is published after load
        addCollection("Made On This Mac")
        let bar = messageBar(heading: "Your library was changed on another Mac")
        let combine = bar.buttons["Combine (Keep Everything)"]
        XCTAssertTrue(combine.exists)
        XCTAssertTrue(bar.buttons["Use Other Mac's Version"].exists)
        assertTabReachesMessageBarFirst(combine)
        press(combine, step: "Tab to Combine (Keep Everything)", alreadyFocused: true)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "resolved: \(texts(app.windows["Library"]))")
        let names = libraryState().collectionNames
        XCTAssertTrue(names.contains("From Another Mac"), "the other Mac's change is kept: \(names)")
        XCTAssertTrue(names.contains("Made On This Mac"), "this Mac's change is kept: \(names)")
    }

    /// L5: read-only; heading and Library Settings…; New Collection… is unavailable; shows still open with File › Open.
    func testNewerFormatLibraryIsReadOnly() throws {
        launch(state: "newer")
        let bar = messageBar(heading: "Your library needs a newer WaveWrangler")
        XCTAssertTrue(bar.buttons["Library Settings…"].exists)
        assertTabReachesMessageBarFirst(bar.buttons["Library Settings…"])
        let file = app.menuBars.menuBarItems["File"]
        openMenu("File", path: ["Library"])
        XCTAssertFalse(file.menuItems["Library"].menuItems["New Collection…"].isEnabled, "no library edits in L5")
        closeMenus()
        openMenu("File", path: [])
        XCTAssertTrue(file.menuItems["Open…"].isEnabled, "shows still open with File › Open")
        closeMenus()
        press(bar.buttons["Library Settings…"], step: "Tab to Library Settings…")
        XCTAssertTrue(app.popUpButtons["ww.settings.libraryLocation"].waitForExistence(timeout: 5), "Library Settings… opens Settings")
    }

    // MARK: - Helpers

    private func launch(state: String) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetStorage", "YES",
                               "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES", "-WWUITestLibraryLocation", state, "-WWUITestHoldMoveSteps", "YES"]
        app.launch()
        app.activate()
    }

    private func folder(_ name: String) -> URL {
        let url = work.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A library in `folder` made by the persistence probe (its own settings, recovery and index outside it).
    private func probeLibrary(_ folder: URL, _ extra: [String]) throws {
        let support = work.appending(path: ".probe-\(folder.lastPathComponent)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        process.arguments = ["lib", "--file", support.appending(path: "settings.json").path, "--container", folder.path,
                             "--recovery", support.appending(path: "Recovery").path, "--cache", support.appending(path: "index.json").path] + extra
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "probe lib \(extra)")
    }

    /// SHA-256 of every file in `folder` (names and bytes).
    private func digest(_ folder: URL) throws -> String {
        var hasher = SHA256()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            hasher.update(data: Data(name.utf8))
            if let data = FileManager.default.contents(atPath: folder.appending(path: name).path) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// Tab (forward) until `element` has keyboard focus. Needs the system keyboard navigation setting for pop-ups and
    /// buttons; without it the step is recorded as not run (see the type's note).
    private func focus(_ element: XCUIElement, step: String, file: StaticString = #filePath, line: UInt = #line) {
        guard Self.keyboardNavigation else { needsKeyboardNavigation.append(step); return }
        for _ in 0..<25 where !hasFocus(element) { app.typeKey("\t", modifierFlags: []) }
        XCTAssertTrue(hasFocus(element), "Tab reaches \(element)", file: file, line: line)
    }

    /// Tab to `button` and press Space. Without system keyboard navigation, Tab can't reach a button: the step is
    /// recorded as not run and the button is pressed through XCUITest instead.
    private func press(_ button: XCUIElement, step: String, alreadyFocused: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.isEnabled, "\(button.label) enabled", file: file, line: line)
        guard Self.keyboardNavigation else {
            needsKeyboardNavigation.append(step)
            button.click()
            return
        }
        if !alreadyFocused { focus(button, step: step, file: file, line: line) }
        app.typeKey(" ", modifierFlags: [])
    }

    /// Focus return after a sheet: asserted with system keyboard navigation (a pop-up can't hold focus without it).
    private func assertFocusReturns(to element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard Self.keyboardNavigation else { needsKeyboardNavigation.append(message); return }
        XCTAssertTrue(hasFocus(element), message, file: file, line: line)
    }

    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (element.value as? String) == expected }, object: nil)], timeout: timeout)
        XCTAssertEqual(done, .completed, "\(element.identifier) value \(element.value ?? "nil"), expected \(expected)", file: file, line: line)
    }

    private func texts(_ element: XCUIElement) -> [String] {
        element.staticTexts.allElementsBoundByIndex.map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
    }

    /// ⌘, (Settings opens on General: preferences are reset at launch) → Tab to Library location.
    private func openLibraryLocation() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let popup = app.popUpButtons["ww.settings.libraryLocation"]
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Library location pop-up")
        XCTAssertEqual(popup.label, "Library location")
        focus(popup, step: "Tab to Library location")
        return popup
    }

    /// Space opens the pop-up (XCUITest opens it without system keyboard navigation); type-select the item; Return.
    private func select(_ title: String, in popup: XCUIElement) {
        if Self.keyboardNavigation {
            app.typeKey(" ", modifierFlags: [])
        } else {
            needsKeyboardNavigation.append("Space opens the Library location pop-up")
            popup.click()
        }
        XCTAssertTrue(popup.menuItems[title].waitForExistence(timeout: 3), "pop-up item \(title)")
        app.typeText(String(title.prefix(6)))
        app.typeKey(.return, modifierFlags: [])
    }

    /// Choose Folder… → the open panel → ⇧⌘G, path, Return, Return.
    private func chooseFolder(_ folder: URL, from popup: XCUIElement) {
        select("Choose Folder…", in: popup)
        let service = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
        Thread.sleep(forTimeInterval: 2)
        let target = service.state == .notRunning ? app! : service
        target.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        target.typeText(folder.path)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        target.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The move sheet: "Move your library to “<folder>”?" — Return = Move Library (default).
    private func confirmMove(to name: String, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "move confirmation", file: file, line: line)
        XCTAssertTrue(sheet.staticTexts["Move your library to “\(name)”?"].exists, "\(texts(sheet))", file: file, line: line)
        XCTAssertTrue(sheet.buttons["Move Library"].exists && sheet.buttons["Cancel"].exists, file: file, line: line)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.staticTexts["Move your library to “\(name)”?"].waitForNonExistence(timeout: 10), file: file, line: line)
    }

    private func assertBlocked(_ name: String, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["“\(name)” already has a WaveWrangler library"].waitForExistence(timeout: 10), "\(texts(sheet))", file: file, line: line)
        XCTAssertTrue(texts(sheet).contains { $0.hasPrefix(reason) }, "reason “\(reason)” in \(texts(sheet))", file: file, line: line)
        XCTAssertFalse(sheet.buttons["Use That Library"].isEnabled, "Use That Library disabled", file: file, line: line)
        XCTAssertTrue(sheet.buttons["Choose Another Folder…"].exists && sheet.buttons["Cancel"].exists, file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    /// ⇧⌘L, then the message bar with `heading`.
    private func messageBar(heading: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.typeKey("l", modifierFlags: [.command, .shift])
        let bar = element("ww.library.messageBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "library message bar", file: file, line: line)
        XCTAssertEqual(bar.label, heading, file: file, line: line)
        return bar
    }

    /// K26: in the Library window, Tab reaches the message bar's buttons first. Without system keyboard navigation the
    /// Tab step is recorded as not run, and the order is checked in the accessibility tree instead: the message bar
    /// comes before the entry list (commands-keyboard: "The message bar is announced before the tables").
    private func assertTabReachesMessageBarFirst(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("l", modifierFlags: [.command, .shift])
        guard Self.keyboardNavigation else {
            needsKeyboardNavigation.append("Tab reaches the message bar buttons first (\(button.label))")
            let order = app.windows["Library"].descendants(matching: .any)
                .matching(NSPredicate(format: "identifier IN %@", ["ww.library.messageBar", "ww.library.entries"])).allElementsBoundByIndex
                .map(\.identifier)
            XCTAssertEqual(order.first, "ww.library.messageBar", "message bar before the entry list in AX order: \(order)", file: file, line: line)
            XCTAssertTrue(order.contains("ww.library.entries"), "entry list present: \(order)", file: file, line: line)
            return
        }
        var reached = false
        for _ in 0..<4 {
            app.typeKey("\t", modifierFlags: [])
            if hasFocus(button) { reached = true; break }
        }
        XCTAssertTrue(reached, "Tab reaches \(button.label) first", file: file, line: line)
    }

    /// ⌃F2 to the menu bar, type-select `menu` and open it with ↓, then type-select each submenu item along `path`
    /// and enter it with →. Leaves the last menu open with its item selected. Without system keyboard navigation
    /// (⌃F2 needs it) the menus are opened through XCUITest's menu API instead, as in CoreTasksKeyboardUITests.
    private func openMenu(_ menu: String, path: [String]) {
        guard Self.keyboardNavigation else {
            needsKeyboardNavigation.append("⌃F2 to the menu bar (\(([menu] + path).joined(separator: " › ")))")
            app.menuBars.menuBarItems[menu].click()
            var parent = app.menuBars.menuBarItems[menu]
            for item in path {
                let next = parent.menuItems[item]
                XCTAssertTrue(next.waitForExistence(timeout: 3), "menu item \(item)")
                next.hover()
                parent = next
            }
            return
        }
        app.typeKey(XCUIKeyboardKey.F2.rawValue, modifierFlags: .control)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText(menu)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        for item in path {
            app.typeText(item)
            app.typeKey(.rightArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Esc until no menu is open.
    private func closeMenus() {
        for _ in 0..<4 { app.typeKey(.escape, modifierFlags: []) }
    }

    /// ⌃F2 → File › Library › New Collection… (Return) → name → Return.
    private func addCollection(_ name: String) {
        app.typeKey("l", modifierFlags: [.command, .shift])
        openMenu("File", path: ["Library"])
        if Self.keyboardNavigation {
            app.typeText("New Collection")
            app.typeKey(.return, modifierFlags: [])
        } else {
            app.menuBars.menuBarItems["File"].menuItems["Library"].menuItems["New Collection…"].click()
        }
        let field = element("ww.dialog.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name + "\r")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    struct LibraryState: Equatable {
        var shows: String
        var recent: String
        var unavailable: String
        var collections: [String]
        var collectionNames: [String] { collections.map { String($0.split(separator: ":").first ?? "") } }
    }

    /// The Library window's sidebar: Shows, Recent, Unavailable values and every collection "name: value".
    private func libraryState() -> LibraryState {
        app.typeKey("l", modifierFlags: [.command, .shift])
        let sidebar = app.outlines["ww.library.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        func value(_ id: String) -> String { (element(id).value as? String) ?? "" }
        let collections = sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.library.sidebar.collection.'")).allElementsBoundByIndex
            .map { "\($0.label.replacingOccurrences(of: ", collection", with: "")): \(($0.value as? String) ?? "")" }
        return LibraryState(shows: value("ww.library.sidebar.shows"), recent: value("ww.library.sidebar.recent"),
                            unavailable: value("ww.library.sidebar.unavailable"), collections: collections)
    }
}
