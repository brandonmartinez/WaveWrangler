import XCTest

@MainActor
final class AlignmentInspectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES",
            "-WWUITestCenterWindows", "YES",
            "-WWUITestOpenShow", "Alignment Fixture",
            "-WWUITestShowEpisodes", "1",
            "-WWUITestAlignmentFixture", "YES",
            "-WWUITestMinimumShowWindow", "YES",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        showSidebar("alignment")
        let expanded = app.outlines["ww.alignment.groups"].waitForExistence(timeout: 5)
        if !expanded {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Detailed inspection after Alignment sidebar activation"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Alignment sidebar activation"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(expanded)
    }

    func testTM201ReachEveryAlignmentControl() {
        let window = app.windows["ww.show.window"]
        XCTAssertEqual(window.frame.width, 760, accuracy: 2)
        XCTAssertEqual(window.frame.height, 492, accuracy: 2)
        let group = app.outlines["ww.alignment.groups"].staticTexts["Studio recorder"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        scrollIntoWindow(group)
        group.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(stateHeading("Reference").waitForExistence(timeout: 2))
        selectTargetEpoch()
        showTimingEvidence()
        XCTAssertTrue(app.staticTexts["ww.inspector.alignment.evidence"].waitForExistence(timeout: 2))
        showSidebar("alignment")
        for identifier in [
            "alignment.waveforms.load", "alignment.acceptProposal", "alignment.rejectProposal",
            "alignment.editNumeric", "alignment.placeAnchors", "alignment.placeAnchorAtPlayhead",
            "alignment.deleteAnchor", "alignment.editAnchor", "alignment.startNewEpoch",
            "ww.alignment.audition.play",
            "ww.alignment.audition.range.start", "ww.alignment.audition.range.duration",
        ] {
            assertReachable(identifier, in: window)
        }
    }

    func testTM202PlaceAnchorFromMenu() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        let anchorsBefore = Set(anchorAlignedCells().allElementsBoundByIndex.map(\.identifier))
        replace(app.textFields["ww.alignment.audition.range.start"], with: "0.5")
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "2")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForText("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForText("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
        chooseEpisodeMenu("Place Anchor at Playhead")

        // The new anchor is selected and its focused editor opens with "Aligned time" holding keyboard focus.
        let editor = app.textFields["alignment.anchor.alignedTime"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "The Edit Anchor sheet must open for the new anchor")
        XCTAssertTrue(waitForKeyboardFocus(editor), "The Aligned time field must own keyboard focus")
        guard let initial = Double(editor.value as? String ?? "") else {
            return XCTFail("Expected a numeric aligned time, got \(String(describing: editor.value))")
        }
        // Anchor rows are identified by position, so placing an interior anchor renumbers the rows after
        // it. The placed anchor is tracked by the source time the sheet reports instead.
        guard let placedSource = app.staticTexts["alignment.anchor.sourceTime"].value as? String else {
            return XCTFail("Expected the sheet to report the placed anchor's source time")
        }
        let replacement = initial + 0.001
        app.typeKey("a", modifierFlags: .command)
        app.typeText(String(format: "%.3f", replacement))
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitForAnchorCellCount(anchorsBefore.count + 1, timeout: 15))
        guard let placedRow = anchorRow(withSourceTime: placedSource) else {
            return XCTFail("Expected an anchor row at source time \(placedSource)")
        }
        let placed = app.staticTexts["ww.alignment.anchor.\(placedRow).alignedTime"]
        XCTAssertTrue(
            waitForValue(Self.formatTime(replacement), in: placed),
            "The committed row must show the typed aligned time"
        )
        scrollIntoWindow(placed)
        XCTAssertTrue(
            waitForAnchorRowSelected(placedRow, timeout: 15),
            "The placed anchor's row must stay selected once the sheet is dismissed"
        )
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            waitForValue(Self.formatTime(initial), in: placed, timeout: 15),
            "Undo must restore the anchor's previous aligned time"
        )
    }

    func testTM203EditAnchorTimeNumerically() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        let cell = app.staticTexts["ww.alignment.anchor.0.alignedTime"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        guard let originalValue = cell.value as? String else {
            return XCTFail("Expected the aligned-time cell's original value")
        }
        selectAnchorRow(0)
        app.typeKey(.return, modifierFlags: [])

        let editor = app.textFields["alignment.anchor.alignedTime"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Return on the selected row must open the Edit Anchor sheet")
        XCTAssertTrue(waitForKeyboardFocus(editor), "The Aligned time field must own keyboard focus")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("0.125")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitForValue(Self.formatTime(0.125), in: app.staticTexts["ww.alignment.anchor.0.alignedTime"]))
        // Escape leaves the row selected, so the undo below acts on the same anchor.
        XCTAssertTrue(waitForAnchorRowSelected(0, timeout: 15), "Focus must return to the edited anchor's row")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForValue(originalValue, in: app.staticTexts["ww.alignment.anchor.0.alignedTime"], timeout: 15))
    }

    func testTM204DeleteAnchorCommandIsKeyboardReachable() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        selectAnchorRow(1)
        app.typeKey(.delete, modifierFlags: [])
        let confirmation = app.sheets.buttons["Delete Anchor"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        let anchors = app.outlines["ww.alignment.anchors"]
        XCTAssertTrue(waitForRowCount(0, in: anchors, timeout: 15))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForRowCount(2, in: anchors, timeout: 15))
    }

    func testTM205CorrectEpochNumericallyReturnAndEscape() {
        selectTargetEpoch()
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let rate = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 2))
        rate.typeKey("a", modifierFlags: .command)
        rate.typeText("12.5")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        chooseEpisodeMenu("Edit Epoch Timing Numerically…")
        let preserved = app.textFields["alignment.numeric.rate"]
        XCTAssertTrue(preserved.waitForExistence(timeout: 2))
        XCTAssertEqual(preserved.value as? String, "12.500")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTM206AcceptProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(
            waitForText("Set by you", in: epochState("Guest take")),
            "The selected saved proposal must become manual. \(alignmentCorrectionDiagnostics)"
        )
    }

    func testTM207RejectProposalCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Reject Proposal")
        XCTAssertTrue(
            waitForText("Timing not set — not attempted", in: epochState("Guest take")),
            "Reject must change Guest take, not match the already-unmapped restart epoch. \(alignmentCorrectionDiagnostics)"
        )
    }

    func testTM208StartNewEpochCommandExists() {
        selectTargetEpoch()
        chooseEpisodeMenu("Place Anchors…")
        replaceSheetValue("alignment.anchors.second.source", with: "0.5")
        replaceSheetValue("alignment.anchors.second.aligned", with: "0.5")
        app.buttons["alignment.anchors.apply"].click()
        XCTAssertTrue(stateHeading("Set by you").waitForExistence(timeout: 5))
        selectAnchorRow(1)
        // The split must run on the interior anchor, never on the span's 0.000 endpoint.
        XCTAssertEqual(
            app.staticTexts["ww.alignment.anchor.1.sourceTime"].value as? String,
            Self.formatTime(0.5),
            "Anchor 1 must be the interior 0.500 anchor before Start New Epoch at Anchor"
        )
        chooseEpisodeMenu("Start New Epoch at Anchor")
        XCTAssertTrue(
            waitForText("Started Epoch 3", in: app.staticTexts["alignment.status"], timeout: 15),
            "Split error: \(app.descendants(matching: .any)["alignment.error"].debugDescription)"
        )
        let epoch = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Epoch 3", "Epoch 3"
        )).firstMatch
        XCTAssertTrue(epoch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForSelectedEpoch("Epoch 3"))
        XCTAssertTrue(waitForKeyboardFocus(app.outlines["ww.alignment.groups"]))
    }

    func testTM209AuditionAndStopShortcuts() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.duration"], with: "2")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForText("Auditioning", in: app.staticTexts["alignment.auditionStatus"]))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForText("Audition stopped at", in: app.staticTexts["alignment.auditionStatus"]))
    }

    func testTM210BlockedStateAndRemedyAreLabeled() {
        selectTargetEpoch()
        replace(app.textFields["ww.alignment.audition.range.start"], with: "2.5")
        let heading = app.staticTexts["ww.alignment.region.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 2))
        XCTAssertEqual(heading.value as? String, "Gap — clock restarted")
        XCTAssertTrue(app.buttons["Go to Epoch After"].exists)
    }

    func testTM211DependentsNoticeIsReadableWithoutFocusMove() {
        selectTargetEpoch()
        let notice = app.staticTexts["ww.alignment.dependents"]
        makeReachable(notice)
        guard let total = dependentTotal(from: notice) else {
            return XCTFail("Expected current dependent count, got \(text(of: notice))")
        }
        chooseEpisodeMenu("Accept Proposal as Manual")
        XCTAssertTrue(
            waitForStaleDependents(in: notice, previousTotal: total, timeout: 15),
            "Expected an affected dependent to become stale, got \(text(of: notice)). \(alignmentCorrectionDiagnostics)"
        )
        XCTAssertTrue(waitForText("Set by you", in: epochState("Guest take")))
        XCTAssertTrue(waitForSelectedEpoch("Guest take"), "Reading the dependent notice must not change epoch selection")
    }

    func testEmptyWorkspaceCanAddRecordings() {
        let addRecordings = openEmptyWorkspace()
        addRecordings.click()
        assertRecordingManagementIsOpen()
    }

    func testBlockedRecoveryIsKeyboardReachable() throws {
        guard UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 != 0 else {
            throw XCTSkip("Tab-only recovery requires system Full Keyboard Access")
        }
        let addRecordings = openEmptyWorkspace()
        XCTAssertTrue(tabToFocus(addRecordings))
        app.typeKey(.space, modifierFlags: [])
        assertRecordingManagementIsOpen()
    }

    private func openEmptyWorkspace() -> XCUIElement {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenShow", "Empty Alignment", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Add recordings to begin"].waitForExistence(timeout: 5))
        let addRecordings = app.windows["ww.show.window"].buttons["Add recordings…"]
        XCTAssertTrue(addRecordings.exists)
        return addRecordings
    }

    private func assertRecordingManagementIsOpen() {
        let recordings = app.sheets.firstMatch
        XCTAssertTrue(recordings.waitForExistence(timeout: 5), "Blocked recovery must open Recordings & Speakers")
        XCTAssertTrue(recordings.staticTexts["Recordings & Speakers"].exists)
        XCTAssertTrue(recordings.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    func testAlignmentWindowSmokeAndResize() throws {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.exists)
        window.doubleClick()
        let contentInspector = app.descendants(matching: .any)["ww.show.contentInspector"]
        XCTAssertTrue(contentInspector.waitForExistence(timeout: 2))
        XCTAssertFalse(window.descendants(matching: .any)["ww.show.sidebar.episodes"].exists)
        XCTAssertTrue(app.buttons["ww.show.library"].exists)
        let workspaceRoot = app.descendants(matching: .any)["ww.alignment.workspaceRoot"]
        XCTAssertTrue(workspaceRoot.waitForExistence(timeout: 2))
        XCTAssertEqual(workspaceRoot.label, "Alignment workspace")
        for identifier in ["ww.alignment.workspace", "alignment.waveforms.load"] {
            scrollIntoWindow(workspaceRoot.descendants(matching: .any)[identifier])
            XCTAssertTrue(
                workspaceRoot.descendants(matching: .any)[identifier].exists,
                "\(identifier) must stay exposed inside the Alignment workspace group"
            )
        }
        showSidebar("alignment")
        let inspector = app.scrollViews["ww.inspector.alignment.details"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertEqual(inspector.label, "Alignment inspector")
        for identifier in [
            "ww.alignment.groups", "ww.alignment.anchors", "alignment.editAnchor", "alignment.startNewEpoch",
        ] {
            let element = inspector.descendants(matching: .any)[identifier]
            scrollIntoWindow(element, named: identifier)
            XCTAssertTrue(element.exists, "\(identifier) must stay exposed inside the Alignment sidebar")
            XCTAssertFalse(workspaceRoot.descendants(matching: .any)[identifier].exists,
                           "Detailed inspection must not be duplicated on the track canvas")
        }
        guard AcceptanceAudit.shouldRun(named: "Alignment workspace") else { return }
        // Resolve every container the audit may waive *before* the audit runs, so each waiver is pinned to
        // one element's exact frame and to the identified children it exposes, rather than to any group of
        // roughly the right shape (#219 review).
        let inspectorColumn = resolveInspectorColumn(
            around: inspector, excluding: [contentInspector.frame]
        )
        let actionRows = resolveActionRows(in: inspector)
        let touchBar = app.descendants(matching: .touchBar).firstMatch
        let inactiveTouchBarFrame: CGRect? = touchBar.exists && !touchBar.isEnabled
            && touchBar.descendants(matching: .any).count == 0 ? touchBar.frame : nil
        XCTAssertLessThanOrEqual(
            actionRows.count, 2,
            "Only the alignment action grid's own rows may be waived"
        )
        // Cell containers are matched by their place in an outline's subtree rather than by geometry: a
        // row scrolled under the table's edge reaches outside the outline's own frame. The identified
        // elements above are the scroll views; rows hang off their enclosing outlines.
        let outlines: [XCUIElement] = app.descendants(matching: .outline).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(outlines.count, 2, "Both alignment outlines must be exposed")
        var outlineCellFrames: [CGRect] = []
        for outline in outlines {
            let descendants: [XCUIElement] = outline.descendants(matching: .any).allElementsBoundByIndex
            for descendant in descendants {
                let type: XCUIElement.ElementType = descendant.elementType
                guard type == .group || type == .other else { continue }
                let frame: CGRect = descendant.frame
                guard frame.height <= 32 else { continue }
                outlineCellFrames.append(frame)
            }
        }
        // Audit the workspace, not a native tooltip left open by the scrolling setup.
        app.menuBars.firstMatch.hover()
        let helpTag = app.descendants(matching: .helpTag).firstMatch
        XCTAssertEqual(
            XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: helpTag),
            ], timeout: 5),
            .completed,
            "The workspace audit must start without a transient hover tooltip"
        )
        var layoutContainerFindings = 0
        var inspectorColumnFindings = 0
        var actionRowFindings = 0
        var outlineCellFindings = 0
        try app.performAccessibilityAudit(
            for: [.elementDetection, .sufficientElementDescription, .hitRegion, .action]
        ) { issue in
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element, element.elementType == .touchBar,
               !element.isEnabled, element.descendants(matching: .any).count == 0,
               element.frame == inactiveTouchBarFrame {
                print("AUDIT WAIVED [inactive-native-touch-bar] \(issue.compactDescription)")
                return true
            }
            guard issue.auditType == .sufficientElementDescription,
                  let element = issue.element,
                  element.elementType == .group || element.elementType == .other
            else { return self.reportUnwaived(issue) }
            let isContent = self.approximatelyEqual(element.frame, contentInspector.frame)
            // SwiftUI owns the inspector column's chrome around our labeled Inspector scroll area, so no
            // modifier reaches it. Match the exact frame and the active activity's labeled scroll area.
            let exposedInspector = element.descendants(matching: .any)[inspector.identifier].exists
                ? [inspector.identifier] : []
            let isInspectorColumn = inspector.exists
                && inspectorColumn?.matches(element, exposing: exposedInspector) == true
            // AppKit builds the container around an outline's disclosure-column cell itself, and no
            // SwiftUI description reaches it: labeling the cell content, combining its children and
            // the value-keypath shorthand all leave this one container undescribed (#219). It is waived
            // only while its own labeled text child is still exposed to assistive technology.
            // The action buttons' own grid rows are undescribed layout containers: declaring one a
            // containing element drops its buttons from the tree in a narrow window (#219). Each is waived
            // only as a row resolved above: the same exact frame, exposing exactly the same alignment
            // action buttons by identifier.
            let exposedActionButtons = element.descendants(matching: .button)
                .allElementsBoundByIndex.map(\.identifier)
            let isActionRow = actionRows.contains {
                $0.matches(element, exposing: exposedActionButtons)
            }
            let isOutlineCell = outlineCellFrames.contains(element.frame)
                && element.descendants(matching: .any).allElementsBoundByIndex
                    .contains { !$0.label.isEmpty || !(($0.value as? String) ?? "").isEmpty }
            guard isContent || isOutlineCell || isInspectorColumn
                    || isActionRow
            else {
                return self.reportUnwaived(issue)
            }
            if isActionRow {
                actionRowFindings += 1
                print(
                    "AUDIT WAIVED [alignment-action-row] \(issue.compactDescription) \(element.frame) — " +
                    "layout row holding only labeled alignment buttons"
                )
            } else if isOutlineCell {
                outlineCellFindings += 1
                print(
                    "AUDIT WAIVED [alignment-outline-cell] \(issue.compactDescription) — " +
                    "AppKit-owned outline cell container; its labeled text child remains exposed"
                )
            } else if isInspectorColumn && !isContent {
                inspectorColumnFindings += 1
                print(
                    "AUDIT WAIVED [show-inspector-column] \(issue.compactDescription) \(element.frame) — " +
                    "SwiftUI-owned inspector column; the labeled Inspector scroll area remains exposed"
                )
            } else {
                layoutContainerFindings += 1
                print(
                    "AUDIT WAIVED [show-layout-container] \(issue.compactDescription) \(element.frame) — " +
                    "noninteractive container whose labeled children remain exposed"
                )
            }
            return true
        }
        // The show's split layout nests two containers over the whole content area, and the episode
        // sidebar adds a third; each is waived only by matching one of those labeled frames exactly.
        XCTAssertLessThanOrEqual(layoutContainerFindings, 3)
        XCTAssertLessThanOrEqual(inspectorColumnFindings, 1)
        XCTAssertLessThanOrEqual(actionRowFindings, 2)
        // At most one finding per cell: each is the container AppKit builds around that cell.
        XCTAssertGreaterThan(outlineCellFrames.count, 0, "The alignment outlines must expose their cells")
        XCTAssertLessThanOrEqual(outlineCellFindings, outlineCellFrames.count)
    }

    func testBlockedRecoveryContrastAudit() throws {
        try AcceptanceAudit.requireQualification()
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestOpenShow", "Empty Alignment", "-WWUITestShowEpisodes", "1",
        ]
        app.launch()
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Add recordings to begin"].waitForExistence(timeout: 5))
        let window = app.windows["ww.show.window"]
        let titlebarBottom = window.frame.minY + 56
        var titlebarFindings = 0
        try app.performAccessibilityAudit(for: [.contrast]) { issue in
            guard issue.auditType == .contrast, let element = issue.element,
                  element.elementType == .staticText
            else { return self.reportUnwaived(issue) }
            let title = element.value as? String ?? element.label
            let isTitle = (title == "Empty Alignment" || title == window.title)
                && element.frame.maxY <= titlebarBottom
            guard isTitle else { return self.reportUnwaived(issue) }
            titlebarFindings += 1
            print("AUDIT WAIVED [blocked-titlebar] \(issue.compactDescription) — AppKit window title outside the blocked content")
            return true
        }
        XCTAssertLessThanOrEqual(titlebarFindings, 1)
    }

    private func chooseEpisodeMenu(_ item: String) {
        app.menuBars.menuBarItems["Episode"].click()
        let command = app.menuItems[item]
        XCTAssertTrue(command.isEnabled, "\(item) must be available for the selected epoch")
        command.click()
    }

    /// Selects an anchor row by clicking inside the row itself. An identifier-targeted `.click()` on a
    /// cell cannot resolve a hit point inside the clipped native ScrollView (#219), so the row's own
    /// visible intersection is used and the selection is asserted before any command runs.
    private func selectAnchorRow(
        _ index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let table = app.outlines["ww.alignment.anchors"]
        scrollIntoWindow(table, file: file, line: line)
        let rows = table.descendants(matching: .outlineRow)
        XCTAssertGreaterThan(rows.count, index, file: file, line: line)
        let row = rows.element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 2), file: file, line: line)
        scrollIntoWindow(row, file: file, line: line)
        XCTAssertGreaterThan(row.frame.width, 0, file: file, line: line)
        let visible = row.frame.intersection(table.frame)
            .intersection(app.scrollViews["ww.inspector.alignment.details"].frame)
        XCTAssertFalse(visible.isEmpty, "The selected row must intersect the sidebar viewport", file: file, line: line)
        row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - row.frame.minX, dy: visible.midY - row.frame.minY)).click()
        XCTAssertTrue(
            waitForAnchorRowSelected(index),
            "Anchor \(index) must be selected before the command",
            file: file,
            line: line
        )
    }

    /// Scrolls the owning activity, including the nested horizontal table viewport.
    private func scrollIntoWindow(
        _ element: XCUIElement,
        named name: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scroll = scrollRoot(for: element, named: name)
        let window = app.windows["ww.show.window"]
        if !element.exists { scrollWorkspaceToTop(in: scroll) }
        for _ in 0..<40 {
            guard element.exists else {
                scroll.scroll(byDeltaX: 0, deltaY: -80)
                continue
            }
            let viewport = scroll.frame.intersection(window.frame.insetBy(dx: 0, dy: 24))
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            let wideContainer = [.outline, .outlineRow, .table, .scrollView].contains(element.elementType)
            if viewport.contains(center) || (wideContainer && viewport.intersects(element.frame)) { return }
            if viewport.minY <= center.y, center.y <= viewport.maxY {
                horizontalScroll(for: element, in: scroll)
                    .scroll(byDeltaX: center.x > viewport.midX ? -80 : 80, deltaY: 0)
                continue
            }
            scroll.scroll(byDeltaX: 0, deltaY: center.y > viewport.midY ? -60 : 60)
        }
        XCTAssertTrue(element.exists, "\(name ?? "Alignment control") exists after scrolling", file: file, line: line)
        guard element.exists else { return }
        XCTAssertTrue(
            scroll.frame.intersection(window.frame).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)),
            "\(name ?? element.identifier) is inside its owning viewport after scrolling",
            file: file,
            line: line
        )
    }

    private func horizontalScroll(for element: XCUIElement, in root: XCUIElement) -> XCUIElement {
        let key = element.identifier.isEmpty ? element.label : element.identifier
        return root.descendants(matching: .scrollView).allElementsBoundByIndex
            .filter { $0.descendants(matching: .any).matching(identifier: key).firstMatch.exists }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? root
    }

    private func scrollRoot(for element: XCUIElement, named name: String? = nil) -> XCUIElement {
        let identifier = name ?? (element.exists ? element.identifier : "")
        if identifier.hasPrefix("alignment.waveforms.") || identifier == "ww.alignment.workspace"
            || (element.exists && element.label == "Lock position") {
            return app.scrollViews["ww.alignment.workspace"]
        }
        if identifier == "Timing evidence"
            || (identifier.hasPrefix("ww.inspector.alignment.") && identifier != "ww.inspector.alignment.details") {
            showSidebar("recording")
            return app.scrollViews["ww.inspector"]
        }
        showSidebar("alignment")
        return app.scrollViews["ww.inspector.alignment.details"]
    }

    private func showSidebar(_ activity: String) {
        let toggle = app.buttons["ww.sidebar.\(activity)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The \(activity) activity toggle must be exposed")
        if toggle.value as? String != "Shown" { toggle.click() }
        XCTAssertTrue(waitForValue("Shown", in: toggle), "The \(activity) sidebar must be active")
        let root = activity == "alignment" ? "ww.inspector.alignment.details" : "ww.inspector"
        XCTAssertTrue(app.scrollViews[root].waitForExistence(timeout: 5))
    }

    private func showTimingEvidence() {
        showSidebar("recording")
        let evidence = app.disclosureTriangles["Timing evidence"]
        scrollIntoWindow(evidence, named: "Timing evidence")
        if String(describing: evidence.value ?? "") == "0" {
            evidence.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 27, dy: 0)).click()
        }
        makeReachable(app.staticTexts["ww.inspector.alignment.evidence"])
    }

    /// Anchor rows are numbered by position, so a row is located by the source time it reports.
    private func anchorRow(withSourceTime time: String) -> Int? {
        anchorAlignedCells().allElementsBoundByIndex
            .compactMap { Int($0.identifier.split(separator: ".").dropLast().last ?? "") }
            .first { app.staticTexts["ww.alignment.anchor.\($0).sourceTime"].value as? String == time }
    }

    private func waitForAnchorRowSelected(_ index: Int, timeout: TimeInterval = 5) -> Bool {
        let rows = app.outlines["ww.alignment.anchors"].descendants(matching: .outlineRow)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if rows.count > index, rows.element(boundBy: index).isSelected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return rows.count > index && rows.element(boundBy: index).isSelected
    }

    /// Mirrors `AlignmentPresentation.formatTime` so committed row values are asserted exactly.
    private static func formatTime(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "\u{2212}" : ""
        let value = abs(seconds)
        let hours = Int(value / 3600)
        let minutes = Int(value / 60) % 60
        let whole = Int(value) % 60
        let milliseconds = Int((value * 1000).rounded()) % 1000
        return String(format: "%@%02d:%02d:%02d.%03d", sign, hours, minutes, whole, milliseconds)
    }

    private func selectTargetEpoch() {
        let lock = app.buttons.matching(NSPredicate(format: "label == 'Lock position' AND value == 'Locked'")).firstMatch
        if lock.exists {
            scrollIntoWindow(lock)
            lock.click()
        }
        showSidebar("alignment")
        let state = stateHeading("Proposed — not confirmed")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let epochName = app.outlines["ww.alignment.groups"].staticTexts["Guest take"]
        scrollIntoWindow(epochName)
        epochName.click()
        XCTAssertTrue(waitForSelectedEpoch("Guest take"))
        showTimingEvidence()
        XCTAssertTrue(app.staticTexts["ww.inspector.alignment.evidence"].waitForExistence(timeout: 2))
        showSidebar("alignment")
    }

    private func stateHeading(_ heading: String) -> XCUIElement {
        app.outlines["ww.alignment.groups"].staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", heading, heading
        )).firstMatch
    }

    private func epochState(_ name: String) -> XCUIElement {
        app.outlines["ww.alignment.groups"].descendants(matching: .outlineRow)
            .containing(.staticText, identifier: name).firstMatch.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "ww.alignment.epoch.", ".state"
            )).firstMatch
    }

    private var alignmentCorrectionDiagnostics: String {
        let error = app.descendants(matching: .any)["alignment.error"]
        return "State: \(text(of: epochState("Guest take"))); "
            + "status: \(text(of: app.staticTexts["alignment.status"])); "
            + "error: \(error.exists ? text(of: error) : "none")."
    }

    private func replace(_ field: XCUIElement, with text: String) {
        makeReachable(field)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        field.typeKey(.return, modifierFlags: [])
    }

    private func replaceSheetValue(_ identifier: String, with text: String) {
        let field = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func waitForText(
        _ prefix: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func dependentTotal(from element: XCUIElement) -> Int? {
        let value = text(of: element)
        guard value.contains(" dependent job"), value.hasSuffix(" current; none stale."),
              let first = value.split(separator: " ").first
        else { return nil }
        return Int(first)
    }

    private func waitForStaleDependents(
        in element: XCUIElement,
        previousTotal: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let parts = text(of: element).split(separator: " ")
            if parts.count >= 4, let stale = Int(parts[0]), parts[1] == "of",
               let total = Int(parts[2]), stale > 0, total >= previousTotal, total >= stale,
               text(of: element).hasSuffix("stale.") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    /// Disabled controls must be visible; enabled controls must also remain hittable.
    private func makeReachable(
        _ element: XCUIElement,
        named name: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = name ?? (element.exists ? element.identifier : "control")
        scrollIntoWindow(element, named: name, file: file, line: line)
        XCTAssertTrue(element.exists, "\(identifier) exists after scrolling", file: file, line: line)
        if element.isEnabled {
            XCTAssertTrue(
                element.isHittable,
                "\(identifier) is hittable after scrolling",
                file: file,
                line: line
            )
        }
    }

    /// Describes a finding the audit does not waive, so a failing run names the element it found.
    private func reportUnwaived(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let element = issue.element
        print(
            "AUDIT UNWAIVED \(issue.compactDescription) " +
            "auditType=\(issue.auditType) type=\(element?.elementType.rawValue ?? 0) " +
            "frame=\(String(describing: element?.frame)) id=\(element?.identifier ?? "-") " +
            "label=\(element?.label ?? "-") value=\(String(describing: element?.value))"
        )
        if let element {
            print("WW-AXTREE-BEGIN\n\(element.debugDescription)\nWW-AXTREE-END")
        }
        return false
    }

    /// One container the audit may waive. It is resolved from the tree *before* the audit runs, so the
    /// waiver is bound to that element's own identity — its exact frame (width and height) and the exact
    /// set of identified children it exposes — instead of to any element of a similar shape (#219 review).
    private struct WaivableContainer {
        let frame: CGRect
        let exposedIdentifiers: [String]

        func matches(_ element: XCUIElement, exposing identifiers: [String]) -> Bool {
            element.frame == frame && identifiers == exposedIdentifiers
        }
    }

    /// The alignment action grid's buttons. A grid row is waivable only while every button it exposes is
    /// one of these, by identifier.
    private static let actionButtonIdentifiers: Set<String> = [
        "alignment.acceptProposal", "alignment.rejectProposal", "alignment.editNumeric",
        "alignment.placeAnchors", "alignment.placeAnchorAtPlayhead", "alignment.deleteAnchor",
        "alignment.editAnchor", "alignment.startNewEpoch",
    ]

    /// The undescribed layout rows the action grid builds, pinned by frame and by the buttons they expose.
    private func resolveActionRows(in root: XCUIElement) -> [WaivableContainer] {
        var rows: [WaivableContainer] = []
        for element in root.descendants(matching: .any).allElementsBoundByIndex {
            let type: XCUIElement.ElementType = element.elementType
            guard type == .group || type == .other, element.frame.height <= 40 else { continue }
            let identifiers = element.descendants(matching: .button).allElementsBoundByIndex.map(\.identifier)
            guard identifiers.count >= 4,
                  identifiers.allSatisfy({ Self.actionButtonIdentifiers.contains($0) })
            else { continue }
            rows.append(WaivableContainer(frame: element.frame, exposedIdentifiers: identifiers))
        }
        return rows
    }

    /// SwiftUI's own inspector column: the smallest container that wraps the active activity's scroll
    /// area without being the content or sidebar region. Resolved to exactly one element, or none.
    private func resolveInspectorColumn(
        around inspector: XCUIElement,
        excluding excluded: [CGRect]
    ) -> WaivableContainer? {
        guard inspector.exists else { return nil }
        let target = inspector.frame
        var best: CGRect?
        let window = app.windows["ww.show.window"]
        let containers = window.groups.allElementsBoundByAccessibilityElement
            + window.otherElements.allElementsBoundByAccessibilityElement
        for element in containers {
            guard element.exists else { continue }
            let frame: CGRect = element.frame
            guard frame.contains(target), frame.width - target.width <= 16 else { continue }
            guard !excluded.contains(where: { self.approximatelyEqual(frame, $0) }) else { continue }
            if let current = best, current.width * current.height <= frame.width * frame.height { continue }
            best = frame
        }
        return best.map { WaivableContainer(frame: $0, exposedIdentifiers: [inspector.identifier]) }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    /// Starts the owning scroll area at its own header, not at the canvas transport.
    private func scrollWorkspaceToTop(in scroll: XCUIElement) {
        let identifier = scroll.identifier
        let top = identifier == "ww.alignment.workspace"
            ? scroll.descendants(matching: .any)["alignment.waveforms.transport.back"]
            : scroll.staticTexts[identifier == "ww.inspector.alignment.details" ? "Alignment" : "Recording"].firstMatch
        for _ in 0..<20 {
            if top.exists, scroll.frame.contains(CGPoint(x: top.frame.midX, y: top.frame.midY)) { return }
            scroll.scroll(byDeltaX: 0, deltaY: 200)
        }
    }

    private func assertReachable(
        _ identifier: String,
        in window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.descendants(matching: .any)[identifier]
        makeReachable(element, named: identifier, file: file, line: line)
        XCTAssertTrue(
            window.frame.intersects(element.frame),
            "\(identifier) is reachable by scrolling",
            file: file,
            line: line
        )
        if element.isEnabled {
            XCTAssertTrue(element.isHittable, "\(identifier) is hittable", file: file, line: line)
        }
    }

    private func tabToFocus(_ element: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if element.value(forKey: "hasKeyboardFocus") as? Bool == true { return true }
            app.typeKey(.tab, modifierFlags: [])
        }
        return element.value(forKey: "hasKeyboardFocus") as? Bool == true
    }

    private func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: 5
        ) == .completed
    }

    private func waitForValue(
        _ value: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitForAnyValue([value], in: element, timeout: timeout)
    }

    private func waitForAnyValue(
        _ values: [String],
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "value IN %@", values)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForRowCount(
        _ count: Int,
        in table: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if table.descendants(matching: .outlineRow).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return table.descendants(matching: .outlineRow).count == count
    }

    private func anchorAlignedCells() -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "ww.alignment.anchor.", ".alignedTime"
        ))
    }

    private func waitForAnchorCellCount(
        _ count: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if anchorAlignedCells().count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return anchorAlignedCells().count == count
    }

    private func waitForSelectedEpoch(
        _ label: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let table = app.outlines["ww.alignment.groups"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let rows = table.descendants(matching: .outlineRow)
            for index in 0..<rows.count {
                let row = rows.element(boundBy: index)
                guard row.isSelected else { continue }
                let epoch = row.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH %@ OR value BEGINSWITH %@", label, label
                )).firstMatch
                if epoch.exists { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

}
