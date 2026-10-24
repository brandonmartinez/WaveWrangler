import XCTest

@MainActor
final class EpisodeLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestOpenShow", "Episode Library",
            "-WWUITestShowEpisodes", "2", "-WWUITestAlignmentFixture", "YES",
            "-WWUITestVisualAlignmentFixture", "YES", "-WWUITestMinimumShowWindow", "YES",
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testLibraryManagesEpisodesWhileEditorsKeepIndependentIdentities() {
        let editors = app.windows.matching(identifier: "ww.show.window")
        XCTAssertTrue(editors.firstMatch.waitForExistence(timeout: 15))
        let first = editors.matching(NSPredicate(format: "title CONTAINS %@", "Synthetic Episode 1")).firstMatch
        XCTAssertTrue(first.exists)
        EpisodeLibraryNavigation.openEpisode(
            containing: "Synthetic Episode 2", in: app, destination: "1", closePrevious: false
        )
        XCTAssertEqual(editors.count, 2)
        XCTAssertTrue(first.title.contains("Synthetic Episode 1"))
        for editor in editors.allElementsBoundByIndex {
            XCTAssertFalse(editor.descendants(matching: .any)["ww.show.sidebar.episodes"].exists)
        }

        EpisodeLibraryNavigation.browseCurrentShow(in: app)
        let library = app.windows["ww.library.window"]
        let second = library.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "ww.show.sidebar.episode.", "Synthetic Episode 2", "Synthetic Episode 2"
        )).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        library.typeKey("i", modifierFlags: .command)
        let title = library.textFields["ww.inspector.episode.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Second revised\t")
        let renamed = editors.matching(NSPredicate(format: "title CONTAINS %@", "Second revised")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertTrue(first.title.contains("Synthetic Episode 1"))
        library.buttons["ww.library.episode.open"].click()
        XCTAssertEqual(editors.count, 2, "Opening an existing episode focuses its editor")
        renamed.typeKey("1", modifierFlags: .command)
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "New Window for")).firstMatch.click()
        XCTAssertEqual(editors.count, 3, "The explicit New Window command creates a second view of this episode")
        XCTAssertEqual(editors.matching(NSPredicate(format: "title CONTAINS %@", "Second revised")).count, 2)
    }

    func testLayoutModesPreserveVisibilityAndGroupBySpeaker() {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        window.typeKey("2", modifierFlags: .command)
        let tracks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "alignment.waveforms.track.")
        )
        XCTAssertTrue(tracks.element(boundBy: 1).waitForExistence(timeout: 20))
        let sourceIDs = Set(tracks.allElementsBoundByIndex.map(\.identifier))
        let ruler = app.staticTexts["alignment.waveforms.ruler"]
        let originalRange = ruler.value as? String ?? ruler.label
        let layout = app.descendants(matching: .any)["alignment.waveforms.layout"]
        XCTAssertTrue(layout.isHittable)
        layout.click()
        let modes = ["By recorder", "By speaker", "Overlay", "Speakers only"].map { app.menuItems[$0] }
        XCTAssertTrue(modes.allSatisfy(\.exists))
        XCTAssertEqual(modes.map(\.frame.minY), modes.map(\.frame.minY).sorted())
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["alignment.waveforms.speakerHeading.unknown"].waitForExistence(timeout: 5))
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        XCTAssertTrue(app.sliders["alignment.waveforms.laneHeight"].isHittable)
        let enabled = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.enabled."
        ))
        let firstToggleID = enabled.firstMatch.identifier
        enabled.firstMatch.click()
        XCTAssertEqual(tracks.count, 1)
        selectTimelineLayout("Overlay", in: app)
        let overlay = app.descendants(matching: .any)["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue((overlay.value as? String ?? overlay.label).contains("1 enabled track"))
        XCTAssertFalse(app.sliders["alignment.waveforms.laneHeight"].exists)
        selectTimelineLayout("By recorder", in: app)
        XCTAssertEqual(tracks.count, 1)
        app.checkBoxes[firstToggleID].click()
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        let recorderToggle = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.group."
        )).firstMatch
        recorderToggle.click()
        XCTAssertEqual(tracks.count, 1)
        selectTimelineLayout("By speaker", in: app)
        let restore = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.showRecorder."
        )).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        XCTAssertEqual(ruler.value as? String ?? ruler.label, originalRange)
        selectTimelineLayout("Overlay", in: app)
        XCTAssertTrue((overlay.value as? String ?? overlay.label).contains("2 enabled tracks"))
    }

    func testRecordingInspectorAndCompactTimelineControlsAtMinimumWidth() {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        window.typeKey("2", modifierFlags: .command)
        let settings = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.settings."
        )).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.click()
        let inspector = app.scrollViews["ww.inspector"]
        XCTAssertTrue(inspector.exists)
        XCTAssertTrue(inspector.popUpButtons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.speaker."
        )).firstMatch.exists)
        XCTAssertTrue(inspector.buttons["ww.inspector.alignment.manageRecordings"].exists)
        XCTAssertFalse(app.disclosureTriangles["Recordings, groups and speakers"].exists)
        let zoom = app.sliders["alignment.waveforms.zoom"]
        let height = app.sliders["alignment.waveforms.laneHeight"]
        let fit = app.buttons["alignment.waveforms.fitTimeline"]
        XCTAssertTrue(zoom.isHittable)
        XCTAssertTrue(height.isHittable)
        XCTAssertTrue(fit.isHittable)
        let ruler = app.descendants(matching: .any)["alignment.waveforms.ruler.surface"].firstMatch
        XCTAssertLessThan(abs(zoom.frame.midY - ruler.frame.minY), 65)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Episode-bound alignment at minimum width"
        shot.lifetime = .keepAlways
        add(shot)
        window.typeKey("i", modifierFlags: [.control, .command])
        XCTAssertFalse(inspector.exists)
        settings.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        inspector.buttons["ww.inspector.alignment.manageRecordings"].click()
        XCTAssertTrue(app.outlines["ww.setup.sources"].waitForExistence(timeout: 5))
    }

    func testTimingReferenceButtonAndSidebarAgreeWithRecordingsAndSpeakers() {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        window.typeKey("2", modifierFlags: .command)
        let settingsPrefix = "alignment.waveforms.settings."
        let currentSettings = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", settingsPrefix, "synthetic-studio.wav"
        )).firstMatch
        let targetSettings = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", settingsPrefix, "synthetic-remote.wav"
        )).firstMatch
        XCTAssertTrue(currentSettings.waitForExistence(timeout: 20))
        XCTAssertTrue(targetSettings.waitForExistence(timeout: 10))
        let currentID = String(currentSettings.identifier.dropFirst(settingsPrefix.count))
        let targetID = String(targetSettings.identifier.dropFirst(settingsPrefix.count))
        let currentStatus = app.descendants(matching: .any)
            .matching(identifier: "alignment.waveforms.referenceStatus.\(currentID)").firstMatch
        let targetStatus = app.descendants(matching: .any)
            .matching(identifier: "alignment.waveforms.referenceStatus.\(targetID)").firstMatch
        XCTAssertTrue(currentStatus.waitForExistence(timeout: 5))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Timing reference sidebar before selection"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertEqual(referenceText(currentStatus), "Timing reference")
        reveal(targetSettings, in: app.scrollViews["ww.alignment.workspace"])
        targetSettings.click()
        let actionID = "alignment.waveforms.preferredReference.\(targetID)"
        let action = app.buttons[actionID]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes[actionID].exists, "Choosing a reference is an action, not a preference checkbox")
        reveal(action, in: app.scrollViews["ww.inspector"])
        XCTAssertTrue(action.isEnabled)
        action.click()
        XCTAssertTrue(targetStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(referenceText(targetStatus), "Next alignment reference")
        XCTAssertEqual(referenceText(currentStatus), "Current timing reference")
        XCTAssertFalse(action.isEnabled)
        let manage = app.buttons["ww.inspector.alignment.manageRecordings"]
        reveal(manage, in: app.scrollViews["ww.inspector"])
        manage.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let sources = sheet.outlines["ww.setup.sources"]
        let targetSource = sources.staticTexts["synthetic-remote.wav"]
        XCTAssertTrue(targetSource.waitForExistence(timeout: 5))
        targetSource.click()
        let sourceAction = sheet.buttons["ww.inspector.source.timingReference"]
        XCTAssertTrue(sourceAction.waitForExistence(timeout: 5))
        XCTAssertFalse(sourceAction.isEnabled)
        let sourceStatus = sheet.descendants(matching: .any)
            .matching(identifier: "ww.inspector.source.timingReference.status").firstMatch
        XCTAssertEqual(referenceText(sourceStatus), "Next alignment reference")
        let currentGroup = sources.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label BEGINSWITH %@ OR value BEGINSWITH %@)",
            "ww.setup.group.", "Studio recorder", "Studio recorder"
        )).firstMatch
        XCTAssertTrue(currentGroup.waitForExistence(timeout: 5))
        currentGroup.click()
        let groupAction = sheet.buttons["ww.inspector.group.timingReference"]
        XCTAssertTrue(groupAction.waitForExistence(timeout: 5))
        XCTAssertTrue(groupAction.isEnabled)
        groupAction.click()
        XCTAssertFalse(groupAction.isEnabled)
        sheet.typeKey("z", modifierFlags: .command)
        let undoHierarchy = XCTAttachment(string: app.debugDescription)
        undoHierarchy.name = "Timing reference selection after dialog Undo"
        undoHierarchy.lifetime = .keepAlways
        add(undoHierarchy)
        XCTAssertTrue(groupAction.isEnabled, "One Undo restores the editor's pending reference selection")
        performEditCommand("redo:")
        XCTAssertFalse(groupAction.isEnabled)
        performEditCommand("undo:")
        app.menuBars.menuBarItems["Source"].click()
        let menuAction = app.menuBars.menuItems["Use as Timing Reference"]
        XCTAssertTrue(menuAction.isEnabled)
        menuAction.click()
        XCTAssertFalse(groupAction.isEnabled)
        sheet.buttons["Done"].click()
        XCTAssertEqual(referenceText(currentStatus), "Timing reference")
        XCTAssertFalse(targetStatus.exists, "Choosing the accepted reference clears the pending-change label")
        reveal(action, in: app.scrollViews["ww.inspector"])
        action.click()
        XCTAssertTrue(targetStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(referenceText(targetStatus), "Next alignment reference")
        XCTAssertEqual(referenceText(currentStatus), "Current timing reference", "Selection must not rebase current timing")
    }

    private func referenceText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    func testResetAlignmentToolbarConfirmsClearsAndRestoresWithUndoRedo() {
        let window = app.windows["ww.show.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        window.typeKey("2", modifierFlags: .command)
        let align = app.buttons["ww.workflow.alignTracks"]
        let reset = app.buttons["ww.workflow.resetAlignment"]
        XCTAssertTrue(reset.waitForExistence(timeout: 15))
        XCTAssertTrue(reset.isEnabled && reset.isHittable)
        XCTAssertGreaterThan(reset.frame.minX, align.frame.maxX)
        reset.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["Reset Alignment"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "zero offset and normal speed", "zero offset and normal speed"
        )).firstMatch.exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(reset.isEnabled)
        reset.click()
        let confirm = sheet.buttons["Reset Alignment"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitForEnabled(reset, enabled: false))
        let save = app.buttons["ww.show.saveStatus"]
        XCTAssertTrue(waitForValue("Saved", in: save))
        performEditCommand("undo:")
        XCTAssertTrue(waitForEnabled(reset, enabled: true))
        XCTAssertTrue(waitForValue("Saved", in: save))
        performEditCommand("redo:")
        XCTAssertTrue(waitForEnabled(reset, enabled: false))
        XCTAssertTrue(waitForValue("Saved", in: save))
    }

    private func waitForEnabled(_ element: XCUIElement, enabled: Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element
        )], timeout: 15) == .completed
    }

    private func waitForValue(_ text: String, in element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text), object: element
        )], timeout: 15) == .completed
    }

    private func performEditCommand(_ identifier: String) {
        app.menuBars.menuBarItems["Edit"].click()
        let command = app.menuBars.menuItems[identifier]
        XCTAssertTrue(command.exists)
        XCTAssertTrue(command.isEnabled)
        command.click()
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            let viewport = scroll.frame.intersection(app.windows["ww.show.window"].frame)
                .insetBy(dx: 2, dy: 8)
            let frame = element.frame
            if viewport.contains(frame), element.isHittable { return }
            let delta = max(-40, min(40, (viewport.midY - frame.midY) / 2))
            scroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTFail("Reference actions must be fully reachable away from the window's resize edge")
    }
}
