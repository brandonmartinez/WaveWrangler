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
        let recorderMode = layout.descendants(matching: .any)["By recorder"]
        let speakerMode = layout.descendants(matching: .any)["By speaker"]
        let overlayMode = layout.descendants(matching: .any)["Overlay"]
        XCTAssertTrue(recorderMode.isHittable)
        XCTAssertTrue(speakerMode.isHittable)
        XCTAssertTrue(overlayMode.isHittable)
        XCTAssertLessThan(speakerMode.frame.minX, recorderMode.frame.minX)
        XCTAssertLessThan(recorderMode.frame.minX, overlayMode.frame.minX)
        XCTAssertTrue(app.staticTexts["alignment.waveforms.speakerHeading.unknown"].waitForExistence(timeout: 5))
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        XCTAssertTrue(app.sliders["alignment.waveforms.laneHeight"].isHittable)
        let enabled = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.enabled."
        ))
        let firstToggleID = enabled.firstMatch.identifier
        enabled.firstMatch.click()
        XCTAssertEqual(tracks.count, 1)
        overlayMode.click()
        let overlay = app.descendants(matching: .any)["alignment.waveforms.overlay.unknown"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue((overlay.value as? String ?? overlay.label).contains("1 enabled track"))
        XCTAssertFalse(app.sliders["alignment.waveforms.laneHeight"].exists)
        recorderMode.click()
        XCTAssertEqual(tracks.count, 1)
        app.checkBoxes[firstToggleID].click()
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        let recorderToggle = app.checkBoxes.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.group."
        )).firstMatch
        recorderToggle.click()
        XCTAssertEqual(tracks.count, 1)
        speakerMode.click()
        let restore = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "alignment.waveforms.showRecorder."
        )).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        XCTAssertEqual(Set(tracks.allElementsBoundByIndex.map(\.identifier)), sourceIDs)
        XCTAssertEqual(ruler.value as? String ?? ruler.label, originalRange)
        overlayMode.click()
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
}
