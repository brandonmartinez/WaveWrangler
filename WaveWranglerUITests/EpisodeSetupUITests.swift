import AppKit
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

    /// Keeps the app's accessibility tree with the result bundle when a step misbehaves.
    private func attachState(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        add(XCTAttachment(screenshot: app.screenshot()))
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
        "import-review": [.layoutContainer: 39, .popUpShowMenu: 10, .windowChrome: 1, .siriOverlay: 1, .behindSheet: 18, .tableText: 1],
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
        let sheetTexts: Set<String> = sheet == nil ? [] : Set(app.sheets.firstMatch.staticTexts.allElementsBoundByIndex.flatMap { [$0.value as? String, $0.label].compactMap { $0 } })
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]) { issue in
            let description = "\(surface): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(240) ?? "no element")"
            if let rule = Self.waiver(for: issue, titlebarBottom: titlebarBottom, sheet: sheet, sheetTexts: sheetTexts) {
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

    private static func waiver(for issue: XCUIAccessibilityAuditIssue, titlebarBottom: CGFloat, sheet: CGRect?, sheetTexts: Set<String>) -> WaiverRule? {
        guard let element = issue.element else { return nil }
        if [.window, .toolbar, .splitter, .menuBar, .menuBarItem, .touchBar].contains(element.elementType) { return .windowChrome }
        if issue.auditType == .sufficientElementDescription, element.elementType == .group, !element.isEnabled { return .layoutContainer }
        if issue.auditType == .action, element.elementType == .popUpButton { return .popUpShowMenu }
        if element.elementType == .dialog, element.title.isEmpty, element.buttons["siri"].exists { return .siriOverlay }
        if issue.auditType == .contrast {
            let frame = element.frame
            if let sheet {
                // Window content outside the sheet, or occluded by it (not one of the sheet's own texts),
                // is dimmed by AppKit while the modal sheet is up.
                if !sheet.contains(CGPoint(x: frame.midX, y: frame.midY)) { return .behindSheet }
                if element.elementType == .staticText, !sheetTexts.contains(element.value as? String ?? element.label) { return .behindSheet }
            }
            if element.elementType == .staticText, tableTextIdentifiers.contains(where: element.identifier.hasPrefix) { return .tableText }
            if element.elementType == .staticText, frame.maxY <= titlebarBottom { return .windowTitle }
        }
        return nil
    }

    /// Clicks the Sources outline row whose name is `name` (at the row's leading edge).
    private func select(_ name: String) {
        // The Name cell's label is the file name (its value carries hidden column values for VoiceOver).
        let row = app.outlines["ww.setup.sources"].outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND (label == %@ OR value == %@)", name, name)).firstMatch
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
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "identifier == 'ww.setup.numberField' AND enabled == true")).firstMatch.waitForExistence(timeout: 3), "field enabled after turning off Unknown")
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
        // Audit the Setup surface itself: hide the workspace's Episode inspector (library lane; audited by
        // LibraryWorkspaceUITests) for this audit and restore it afterwards.
        menu("View", "Hide Inspector")
        try audit("setup")
        menu("View", "Show Inspector")
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
        let acknowledge = element("ww.relink.acknowledge")
        acknowledge.click()
        if !confirm.isEnabled { attachState("relink after acknowledge") }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'ww.relink.confirm' AND enabled == true")).firstMatch.waitForExistence(timeout: 3), "acknowledgement enables Use This File Anyway (checkbox value \(acknowledge.value ?? "nil"))")
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

    // MARK: #89 — Speakers table height

    /// Speakers shows several rows at the default (unzoomed) size, grows with the window and stays usable
    /// at 200% text size; the resize handle is present and adjustable.
    func testSpeakersTableIsUsableAndGrowsWithTheWindow() {
        let speakers = app.outlines["ww.setup.speakers"]
        XCTAssertTrue(speakers.waitForExistence(timeout: 5))
        let rowsAt100 = 28.0 + 3 * 22.0  // column header + three rows (Sources has priority when short, #104)
        let zoomed = speakers.frame.height
        XCTAssertGreaterThanOrEqual(zoomed, rowsAt100, "zoomed window: \(zoomed) pt")

        menu("Window", "Zoom")  // back to the default window size
        let unzoomedExpectation = expectation(for: NSPredicate { _, _ in speakers.frame.height < zoomed }, evaluatedWith: nil)
        wait(for: [unzoomedExpectation], timeout: 3)
        let small = speakers.frame.height
        XCTAssertGreaterThanOrEqual(small, rowsAt100, "default window: \(small) pt")
        XCTAssertGreaterThan(zoomed, small, "grows with the window")

        let split = app.sliders["ww.setup.split"].exists ? app.sliders["ww.setup.split"] : app.sliders["Speakers table height"]
        XCTAssertTrue(split.exists, "resize handle is a slider")
        let splitValue = split.value.map { "\($0)" } ?? ""
        XCTAssertTrue(splitValue == "35 percent" || splitValue == "0.35", "handle value \(splitValue)")

        menu("Window", "Zoom")
        for _ in 0..<4 { menu("View", "Text Size", "Bigger") }
        let large = expectation(for: NSPredicate { _, _ in speakers.frame.height >= 2 * rowsAt100 }, evaluatedWith: nil)
        wait(for: [large], timeout: 5)
        XCTAssertGreaterThanOrEqual(speakers.frame.height, 2 * rowsAt100, "200% text: \(speakers.frame.height) pt")
        for _ in 0..<4 { menu("View", "Text Size", "Smaller") }
    }

    // MARK: #104 — default window layout

    /// Source rows (name cells) fully inside the Sources outline's visible frame.
    private func visibleSourceRows(_ outline: XCUIElement) -> [XCUIElement] {
        let frame = outline.frame
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND NOT (identifier CONTAINS '.status') AND NOT (identifier ENDSWITH '.epoch') AND NOT (identifier ENDSWITH '.channel') AND NOT (identifier ENDSWITH '.speaker') AND NOT (identifier ENDSWITH '.role')"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY >= frame.minY - 1 && $0.frame.maxY <= frame.maxY + 1 && $0.frame.height > 0 }
    }

    private func assertStatusVisible(_ outline: XCUIElement, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND identifier ENDSWITH '.status'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3), "\(context): status cell exists", file: file, line: line)
        let frame = outline.frame
        XCTAssertGreaterThanOrEqual(status.frame.minX, frame.minX - 1, "\(context): status inside the table", file: file, line: line)
        XCTAssertLessThanOrEqual(status.frame.maxX, frame.maxX + 1, "\(context): status not clipped (\(status.frame) vs \(frame))", file: file, line: line)
        XCTAssertGreaterThan(status.frame.width, 20, "\(context): status has width", file: file, line: line)
    }

    /// #129: repeated Window › Zoom out/in must not grow the columns (a width-derived Name ideal used to
    /// compound with column autoresizing until Status scrolled off and the frame width became NaN).
    func testColumnsStayStableAcrossRepeatedZoom() {
        importFixture()
        let outline = app.outlines["ww.setup.sources"]
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND identifier ENDSWITH '.status'")).firstMatch
        // AppKit's column autoresizing may re-spread width a little between cycles; what must hold is that
        // the columns never outgrow the table: Status stays fully inside it, at least its minimum width.
        func assertFits(_ context: String) {
            assertStatusVisible(outline, context)
            XCTAssertGreaterThanOrEqual(status.frame.width, 95, "\(context): Status keeps its minimum width (\(status.frame.width))")
            XCTAssertLessThanOrEqual(status.frame.maxX, outline.frame.maxX + 1, "\(context): no horizontal overflow")
        }
        for cycle in 1...3 {
            menu("Window", "Zoom")  // default size
            assertFits("zoom cycle \(cycle), default size")
            menu("Window", "Zoom")  // zoomed
            assertFits("zoom cycle \(cycle), zoomed")
        }
        select("tr2.wav")

        // #104: columns follow the width plan only; the header offers no show/hide/reorder menu.
        outline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: -10)).rightClick()
        // Only on-screen menu items count: the menu bar's View › Sort By also has Name/Epoch/Speaker/Status
        // items, with zero-size frames while closed.
        Thread.sleep(forTimeInterval: 1)
        let shown = app.menuItems.allElementsBoundByIndex.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        let columnItems = shown.filter { ["Epoch", "Ch", "Speaker", "Role", "Status", "Name"].contains($0.title) }
        XCTAssertTrue(columnItems.isEmpty, "no header menu to show/hide columns: \(columnItems.map(\.title))")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// At the default show-window size Sources shows several rows with Status readable (no horizontal
    /// scrolling), Speakers stays usable, details collapse to a bar, and 200% text still shows Status.
    func testDefaultWindowShowsSeveralSourceRowsWithStatus() {
        importFixture()
        menu("Window", "Zoom")  // back to the default window size
        let outline = app.outlines["ww.setup.sources"]
        let shrunk = expectation(for: NSPredicate { _, _ in outline.frame.width < 900 }, evaluatedWith: nil)
        wait(for: [shrunk], timeout: 3)

        XCTAssertGreaterThanOrEqual(visibleSourceRows(outline).count, 4, "several source rows at the default size (\(outline.frame))")
        assertStatusVisible(outline, "default window")
        // Sources has priority in a short window; Speakers keeps its column header plus three rows.
        XCTAssertGreaterThanOrEqual(app.outlines["ww.setup.speakers"].frame.height, 28 + 3 * 22, "Speakers stays usable")

        let toggle = element("ww.setup.detailsToggle")
        XCTAssertTrue(toggle.exists, "details collapse to a bar in a short, narrow window")
        XCTAssertEqual(toggle.label, "Show Details")
        XCTAssertFalse(element("ww.setup.inspector").exists)

        // Keyboard path 1: Return in the Sources table opens the details on the selected row.
        select("tr2.wav")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(element("ww.setup.inspector").waitForExistence(timeout: 2), "Return opens the details")
        // K08/K09: Return also moves focus to the details' first editable field. Pop-ups take focus only
        // with Full Keyboard Access; without it this ungrouped, channel-Unknown row has no focusable
        // field, so focus stays in the Sources table (the Source menu edits it).
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true AND identifier BEGINSWITH 'ww.inspector.'")).firstMatch
        if NSApplication.shared.isFullKeyboardAccessEnabled {
            XCTAssertTrue(focused.waitForExistence(timeout: 2), "focus moved into the details after Return")
            XCTAssertEqual(focused.identifier, "ww.inspector.source.group", "first editable field (Recorder group)")
        } else {
            XCTAssertFalse(focused.waitForExistence(timeout: 1), "no focusable field: focus stays in the table")
            // Behavioural check (AX focus flags on outlines are unreliable): ↓ still moves the Sources
            // selection, so the details follow the next row.
            let name = element("ww.inspector.source.name")
            func shown() -> String { "\(name.label)|\(name.value as? String ?? "")" }
            let before = shown()
            app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
            let moved = expectation(for: NSPredicate { _, _ in name.exists && shown() != before }, evaluatedWith: nil)
            wait(for: [moved], timeout: 3)
            XCTAssertTrue(waitForOutline("1 selected"), "focus stays in ww.setup.sources")
        }
        XCTAssertTrue(element("ww.inspector.source.speaker").exists, "speaker editable in the details")
        XCTAssertTrue(element("ww.inspector.source.role").exists, "role shown in the details")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        menu("View", "Hide Setup Details")
        XCTAssertFalse(element("ww.setup.inspector").waitForExistence(timeout: 1))

        // Keyboard path 2: the menu bar (View › Show Setup Details).
        menu("View", "Show Setup Details")
        XCTAssertTrue(element("ww.setup.inspector").waitForExistence(timeout: 2), "menu opens the details")
        menu("View", "Hide Setup Details")

        // Return on a multi-row selection must not leave a focus request behind: a later ↓ to one row keeps
        // keyboard focus in the Sources table.
        select("tr1.wav")
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .shift)
        XCTAssertTrue(waitForOutline("2 selected"))
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForOutline("1 selected"))
        let stolen = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true AND identifier BEGINSWITH 'ww.inspector.'")).firstMatch
        XCTAssertFalse(stolen.waitForExistence(timeout: 1.5), "focus stays in ww.setup.sources")
        if element("ww.setup.inspector").exists { menu("View", "Hide Setup Details") }

        for _ in 0..<4 { menu("View", "Text Size", "Bigger") }
        let grown = expectation(for: NSPredicate { _, _ in self.visibleSourceRows(outline).allSatisfy { $0.frame.height >= 30 } }, evaluatedWith: nil)
        wait(for: [grown], timeout: 5)
        assertStatusVisible(outline, "200% text")
        XCTAssertGreaterThanOrEqual(visibleSourceRows(outline).count, 1, "rows visible at 200% text")

        // Speaker and Role columns are hidden at this width: the row's VoiceOver value still carries them,
        // and the Source menu still edits them for the selected row.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND value CONTAINS 'speaker' AND value CONTAINS 'role'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2), "hidden column values are in the Name cell's VoiceOver value")
        select("tr2.wav")
        menu("Source", "Assign Speaker", "New Speaker…")
        let name = element("ww.setup.nameField")
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click()
        name.typeText("Ben")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        select("tr2.wav")
        menu("Source", "Use as Primary")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ww.setup.source.' AND value CONTAINS 'speaker Ben' AND value CONTAINS 'role Primary'")).firstMatch.waitForExistence(timeout: 3), "speaker and role edited via the Source menu with the columns hidden")
        for _ in 0..<4 { menu("View", "Text Size", "Smaller") }
        menu("Window", "Zoom")
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
        if !waitForValue("ww.inspector.transfer", beginsWith: "Download cancelled") {
            attachState("after Cancel Download")
            XCTFail("transfer reads \(value("ww.inspector.transfer") ?? "nil")")
        }

        select("offline.wav")
        XCTAssertEqual(value("ww.inspector.transfer"), "Can't download — no network connection. Checked \(checkedTime())")
        menu("Source", "Retry Download")
        XCTAssertTrue(waitForValue("ww.inspector.transfer", beginsWith: "Waiting to download"))
    }
}
