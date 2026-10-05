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
        // Isolated storage/preferences, a synthetic show with one episode opened directly in Setup.
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES", "-WWUITestOpenShow", "Setup Fixture", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        try openSetup()
        // A roomy window so the details panel sits beside the tables (narrow windows stack it below).
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    /// The synthetic show opens on its first episode; View › Setup (⌘1) makes sure Setup is shown.
    private func openSetup() throws {
        let sources = app.descendants(matching: .any)["ww.setup.sources"]
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(sources.waitForExistence(timeout: 10), "Setup content not reachable")
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
        XCTAssertTrue(text("Ungrouped · 9 sources").waitForExistence(timeout: 5), "import applied")
        XCTAssertTrue(waitForOutline("9 selected"), "imported rows are selected (IA-16)")
    }

    /// Any element whose value or label is exactly `string` (SwiftUI Text exposes its text as the value).
    private func text(_ string: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }

    private func value(_ identifier: String) -> String? {
        element(identifier).value as? String
    }

    private func waitForValue(_ identifier: String, beginsWith prefix: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value BEGINSWITH %@", identifier, prefix)).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Audit waiver rules. System/framework rules cover controls app code can't change; app-specific
    /// rules are scoped by identifier and pinned per surface so new findings can't hide behind them.
    enum WaiverRule: String, CaseIterable {
        case layoutContainer = "non-interactive layout container"
        case popUpShowMenu = "system pop-up button exposes AXShowMenu"
        case windowChrome = "system window chrome"
        case siriOverlay = "system Siri overlay, not app UI"
        case behindSheet = "window content behind a modal sheet (dimmed by AppKit); audited undimmed in T13"
        case tableText = "issue #59: system table/sidebar text contrast (tracked)"
        case windowTitle = "window title/subtitle drawn by AppKit"
    }

    /// Maximum waivers per rule for each audited surface (observed on the claimed host, fixture-sized).
    static let pinned: [String: [WaiverRule: Int]] = [
        "import-review": [.layoutContainer: 39, .popUpShowMenu: 10, .windowChrome: 1, .siriOverlay: 1, .behindSheet: 17, .tableText: 1],
        "setup": [.layoutContainer: 67, .popUpShowMenu: 2, .windowChrome: 1, .siriOverlay: 1, .tableText: 4, .windowTitle: 3],
    ]

    /// Identifier prefixes of the #59 surfaces: Setup outline/table cells, Import Review rows and the
    /// show sidebar rows (system table text with no custom styling).
    static let tableTextIdentifiers = ["ww.setup.source.", "ww.setup.speaker.", "ww.setup.group.", "ww.import.row.", "ww.show.sidebar.episode.", "ww.show.sidebar.showInfo"]

    /// macOS audit types (acceptance §4.2). Every finding is either waived by a rule (printed, counted
    /// and checked against the surface's pin) or fails the test.
    private func audit(_ surface: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var findings: [String] = []
        var counts: [WaiverRule: Int] = [:]
        let titlebarBottom = app.windows["ww.show.window"].frame.minY + 56
        let sheet = app.sheets.firstMatch.exists ? app.sheets.firstMatch.frame : nil
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]) { issue in
            let description = "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(240) ?? "no element")"
            if let rule = Self.waiver(for: issue, titlebarBottom: titlebarBottom, sheet: sheet) {
                counts[rule, default: 0] += 1
                print("AUDIT WAIVED [\(rule)] \(description)")
            } else {
                findings.append(description)
            }
            return true
        }
        for finding in findings { XCTFail("AUDIT \(finding)", file: file, line: line) }
        let pins = Self.pinned[surface] ?? [:]
        for rule in WaiverRule.allCases {
            let count = counts[rule, default: 0]
            print("AUDIT \(surface) rule \(rule): \(count) (pinned ≤ \(pins[rule, default: 0])) — \(rule.rawValue)")
            XCTAssertLessThanOrEqual(count, pins[rule, default: 0], "AUDIT \(surface): waiver rule \(rule) exceeded its pinned count", file: file, line: line)
        }
        print("AUDIT \(surface): \(findings.isEmpty ? "no unwaived issues" : "\(findings.count) unwaived issue(s)")")
    }

    private static func waiver(for issue: XCUIAccessibilityAuditIssue, titlebarBottom: CGFloat, sheet: CGRect?) -> WaiverRule? {
        guard let element = issue.element else { return nil }
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) { return .windowChrome }
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled { return .layoutContainer }
        if issue.auditType == .action, element.elementType == .popUpButton { return .popUpShowMenu }
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists { return .siriOverlay }
        if issue.auditType == .contrast {
            let frame = element.frame
            if let sheet, !sheet.contains(CGPoint(x: frame.midX, y: frame.midY)) { return .behindSheet }
            if element.elementType == .staticText, tableTextIdentifiers.contains(where: element.identifier.hasPrefix) { return .tableText }
            if element.elementType == .staticText, frame.maxY <= titlebarBottom { return .windowTitle }
        }
        return nil
    }

    /// Clicks the Sources outline row whose name is `name` (at the row's leading edge).
    private func select(_ name: String) {
        let row = app.outlines["ww.setup.sources"].outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND value == %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "row \(name)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).click()
        if !waitForOutline("1 selected") {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).click()
        }
        XCTAssertTrue(waitForOutline("1 selected"), "selected \(name), outline value \(app.outlines["ww.setup.sources"].value ?? "nil")")
    }

    private func waitForOutline(_ value: String) -> Bool {
        app.outlines.matching(NSPredicate(format: "identifier == 'ww.setup.sources' AND value == %@", value)).firstMatch.waitForExistence(timeout: 3)
    }

    // MARK: T07 — Import a messy folder

    func testT07ImportReviewKeyboard() throws {
        app.typeKey("i", modifierFlags: [.command, .shift])
        let review = element("ww.import.review")
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let confirm = element("ww.import.confirm")
        XCTAssertEqual(confirm.label, "Import 9")
        XCTAssertTrue(text("Suggestions are based only on folder and file names. Review them before importing.").exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'not recordings'")).firstMatch.exists)

        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        XCTAssertEqual(confirm.label, "Import 8", "Space toggles Include")
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        XCTAssertEqual(confirm.label, "Import 9")

        let unapplied = element("ww.import.unapplied")
        XCTAssertTrue(unapplied.exists, "unconfirmed suggestions are announced as not applied")
        try audit("import-review")

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(element("ww.setup.sources").waitForExistence(timeout: 3))
        XCTAssertTrue(text("Ungrouped · 9 sources").waitForExistence(timeout: 3), "unconfirmed suggestions were not applied")
        XCTAssertTrue(app.menuBars.menuBarItems["Edit"].exists)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Import 9 Sources"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testT07CancelChangesNothing() {
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("ww.import.review").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(text("Ungrouped · 0 sources").waitForExistence(timeout: 3))
    }

    // MARK: T08/T09 — grouping and numeric epoch/channel

    func testT08GroupingAndT09EpochFromMenus() {
        importFixture()
        select("tr1.wav")
        menu("Source", "Assign to Recorder Group", "New Recorder Group…")
        let name = element("ww.setup.nameField")
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click()
        name.typeText("Zoom H6")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(text("Zoom H6 — recorder group · 1 source").waitForExistence(timeout: 3))

        menu("Source", "Set Epoch…")
        let field = element("ww.setup.numberField")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("2")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let epoch = element("ww.inspector.source.epoch")
        XCTAssertTrue(epoch.waitForExistence(timeout: 2))
        XCTAssertEqual(epoch.value as? String, "2")

        menu("Source", "Set Channel…")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertFalse(field.isEnabled, "channel starts Unknown")
        element("ww.setup.numberUnknown").click()
        field.click()
        field.typeText("0")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(text("Enter a whole number").waitForExistence(timeout: 2), "invalid input explains itself")
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
        name.click()
        name.typeText("Ana")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(text("Choose primary").waitForExistence(timeout: 3))

        select("tr1.wav")
        menu("Source", "Use as Primary")
        XCTAssertTrue(text("Primary chosen").waitForExistence(timeout: 3))

        select("tr2.wav")
        menu("Source", "Assign Speaker", "Ana")
        select("tr2.wav")
        menu("Source", "Use as Primary")
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Undo Change Primary for “Ana”"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.speaker.' AND value CONTAINS '1 backup,'")).firstMatch.waitForExistence(timeout: 3), "previous primary stays as one backup")
    }

    // MARK: T11/T12/T13 — relink, regrant and the five dimensions

    func testT13InspectorShowsAllFiveDimensions() throws {
        importFixture()
        select("tr3.wav")
        for dimension in ["location", "access", "residency", "transfer", "identity"] {
            XCTAssertTrue(element("ww.inspector.\(dimension)").waitForExistence(timeout: 2), dimension)
        }
        XCTAssertEqual(value("ww.inspector.access"), "WaveWrangler needs your permission again. Checked \(checkedTime())")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "(identifier ENDSWITH '.status' OR identifier BEGINSWITH 'ww.inspector.') AND value CONTAINS[c] 'offline'")).firstMatch.exists)
        try audit("setup")
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
        XCTAssertEqual(confirm.label, "Use This File Anyway")
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
        XCTAssertEqual(value("ww.inspector.transfer"), "Downloading — 42%. Checked \(checkedTime())")
        menu("Source", "Cancel Download")
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.buttons["Keep Downloading"].waitForExistence(timeout: 2), "cancel asks when progress may be lost")
        confirmation.buttons["Cancel Download"].click()
        XCTAssertTrue(waitForValue("ww.inspector.transfer", beginsWith: "Download cancelled"))

        select("offline.wav")
        XCTAssertEqual(value("ww.inspector.transfer"), "Can't download — no network connection. Checked \(checkedTime())")
        menu("Source", "Retry Download")
        XCTAssertTrue(waitForValue("ww.inspector.transfer", beginsWith: "Waiting to download"))
    }
}
