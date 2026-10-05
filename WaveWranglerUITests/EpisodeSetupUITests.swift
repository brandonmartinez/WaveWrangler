import XCTest

/// Setup destination keyboard/VoiceOver-structure tasks (accessibility-acceptance T07–T13, T18, T29) run
/// against the scripted fixture engine (`WW_SETUP_ENGINE=fixture-states`). Every provider state here is a
/// **simulated provider state**; no user media, folders or network are touched.
///
/// Keys are driven with `typeKey`; menu-bar commands use XCUITest's menu API (the keyboard-only menu
/// path ⌃F2 is a manual Full Keyboard Access exit item, accessibility-acceptance §6).
@MainActor
final class EpisodeSetupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["WW_SETUP_ENGINE"] = "fixture-states"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        try openSetup()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    /// Reaches an episode's Setup destination: directly when the window already shows it, otherwise via
    /// File › New Episode (⇧⌘N) and View › Setup (⌘1).
    private func openSetup() throws {
        let sources = app.descendants(matching: .any)["ww.setup.sources"]
        if sources.waitForExistence(timeout: 5) { return }
        app.typeKey("n", modifierFlags: [.command, .shift])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(sources.waitForExistence(timeout: 5), "Setup content not reachable")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func menu(_ path: String...) {
        var item = app.menuBars.menuBarItems[path[0]]
        item.click()
        for title in path.dropFirst() {
            item = item.menuItems[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 2), "menu item \(title)")
            item.click()
        }
    }

    private func importFixture() {
        app.typeKey("i", modifierFlags: [.command, .shift])
        let review = element("ww.import.review")
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertFalse(review.waitForExistence(timeout: 1) && review.isHittable)
    }

    private func select(_ name: String) {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 3), "row \(name)")
        cell.click()
    }

    // MARK: T07 — Import a messy folder

    func testT07ImportReviewKeyboard() throws {
        app.typeKey("i", modifierFlags: [.command, .shift])
        let review = element("ww.import.review")
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let confirm = element("ww.import.confirm")
        XCTAssertEqual(confirm.title, "Import 9")
        XCTAssertTrue(app.staticTexts["Suggestions are based only on folder and file names. Review them before importing."].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not recordings'")).firstMatch.exists)

        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        XCTAssertEqual(confirm.title, "Import 8", "Space toggles Include")
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        XCTAssertEqual(confirm.title, "Import 9")

        let unapplied = element("ww.import.unapplied")
        XCTAssertTrue(unapplied.exists, "unconfirmed suggestions are announced as not applied")
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild])

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(element("ww.setup.sources").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ungrouped · 9 sources"].waitForExistence(timeout: 3), "unconfirmed suggestions were not applied")
        XCTAssertTrue(app.menuBars.menuBarItems["Edit"].exists)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Import 9 Sources"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testT07CancelChangesNothing() {
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("ww.import.review").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Ungrouped · 0 sources"].waitForExistence(timeout: 3))
    }

    // MARK: T08/T09 — grouping and numeric epoch/channel

    func testT08GroupingAndT09EpochFromMenus() {
        importFixture()
        select("tr1.wav")
        menu("Source", "Assign to Recorder Group", "New Recorder Group…")
        let name = element("ww.setup.nameField")
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.typeText("Zoom H6")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Zoom H6 — recorder group · 1 source"].waitForExistence(timeout: 3))

        menu("Source", "Set Epoch…")
        let field = element("ww.setup.numberField")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("2")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let epoch = element("ww.inspector.source.epoch")
        XCTAssertTrue(epoch.waitForExistence(timeout: 2))
        XCTAssertEqual(epoch.value as? String, "2")

        menu("Source", "Set Channel…")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("0")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Enter a whole number"].waitForExistence(timeout: 2), "invalid input explains itself")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Set Epoch"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    // MARK: T10 — speaker, primary and backup

    func testT10SpeakerPrimaryBackup() {
        importFixture()
        select("tr1.wav")
        menu("Source", "Assign Speaker", "New Speaker…")
        let name = element("ww.setup.nameField")
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.typeText("Ana")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Choose primary"].waitForExistence(timeout: 3))

        select("tr1.wav")
        menu("Source", "Use as Primary")
        XCTAssertTrue(app.staticTexts["Primary chosen"].waitForExistence(timeout: 3))

        select("tr2.wav")
        menu("Source", "Assign Speaker", "Ana")
        select("tr2.wav")
        menu("Source", "Use as Primary")
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Change Primary for “Ana”"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["1"].exists, "previous primary stays as one backup")
    }

    // MARK: T11/T12/T13 — relink, regrant and the five dimensions

    func testT13InspectorShowsAllFiveDimensions() throws {
        importFixture()
        select("tr3.wav")
        for dimension in ["location", "access", "residency", "transfer", "identity"] {
            XCTAssertTrue(element("ww.inspector.\(dimension)").waitForExistence(timeout: 2), dimension)
        }
        XCTAssertEqual(element("ww.inspector.access").value as? String, "WaveWrangler needs your permission again. Checked \(checkedTime())")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'offline'")).firstMatch.exists)
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild])
    }

    private func checkedTime() -> String {
        Date(timeIntervalSince1970: 1_790_000_000).formatted(date: .omitted, time: .shortened)
    }

    func testT11RelinkRequiresAcknowledgementWhenDetailsDiffer() {
        importFixture()
        select("intro.wav")
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.status' AND value BEGINSWITH 'Not found'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 2), "decoy at the old path is not auto-linked")
        menu("Source", "Relink Source…")
        let sheet = element("ww.relink.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        let confirm = element("ww.relink.confirm")
        XCTAssertEqual(confirm.title, "Use This File Anyway")
        XCTAssertFalse(confirm.isEnabled, "needs the acknowledgement checkbox")
        element("ww.relink.acknowledge").click()
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Relink “intro.wav”"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testT12DeniedAndNeedsPermissionAreDistinct() {
        importFixture()
        let denied = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.status' AND value BEGINSWITH 'Access denied'")).firstMatch
        let needs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '.status' AND value BEGINSWITH 'Needs permission'")).firstMatch
        XCTAssertTrue(denied.waitForExistence(timeout: 3))
        XCTAssertTrue(needs.exists)
        select("tr3.wav")
        menu("Source", "Grant Access…")
        XCTAssertTrue(element("ww.relink.sheet").waitForExistence(timeout: 3), "regrant still runs the identity comparison")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    // MARK: T18/T29 — cancel and retry downloads (simulated provider state)

    func testT18CancelDownloadConfirmsAndT29Retry() {
        importFixture()
        select("tr2.wav")
        XCTAssertEqual(element("ww.inspector.transfer").value as? String, "Downloading — 42%. Checked \(checkedTime())")
        menu("Source", "Cancel Download")
        let keep = app.buttons["Keep Downloading"]
        XCTAssertTrue(keep.waitForExistence(timeout: 2), "cancel asks when progress may be lost")
        app.buttons["Cancel Download"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'ww.inspector.transfer' AND value BEGINSWITH 'Download cancelled'")).firstMatch.waitForExistence(timeout: 3))

        select("offline.wav")
        XCTAssertEqual(element("ww.inspector.transfer").value as? String, "Can't download — no network connection. Checked \(checkedTime())")
        menu("Source", "Retry Download")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'ww.inspector.transfer' AND value BEGINSWITH 'Waiting to download'")).firstMatch.waitForExistence(timeout: 3))
    }
}
