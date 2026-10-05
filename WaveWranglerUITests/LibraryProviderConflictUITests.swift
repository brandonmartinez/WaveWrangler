import XCTest

/// #117: the Library window tells the user about cloud-provider conflict versions of the library that
/// WaveWrangler can't use; the notice is a labelled, identified message bar and the library stays usable.
@MainActor
final class LibraryProviderConflictUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func launch(conflicts: Int?) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES", "-WWUITestLibraryFixture", "lib100"]
            + (conflicts.map { ["-WWUITestProviderConflicts", "\($0)"] } ?? [])
        app.launch()
        app.activate()
        XCTAssertTrue(app.outlines["ww.library.sidebar"].waitForExistence(timeout: 15))
    }

    private var notice: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ww.library.messageBar.providerConflicts").firstMatch
    }

    func testUnusableProviderConflictsAreAnnouncedInTheMessageBar() throws {
        launch(conflicts: 2)
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "provider conflict message bar")
        XCTAssertEqual(notice.label, "Other copies of your library weren't used")
        let body = notice.staticTexts.allElementsBoundByIndex.compactMap { ($0.value as? String) ?? $0.label }
        XCTAssertTrue(body.contains { $0.hasPrefix("Your cloud service kept 2 other copies of your library") && $0.contains("hasn't used, changed or removed them") },
                      "body says what happened and that nothing was changed: \(body)")
        XCTAssertTrue(app.outlines["ww.library.entries"].exists, "the library stays usable")
    }

    func testNoNoticeWithoutConflicts() throws {
        launch(conflicts: nil)
        XCTAssertFalse(notice.waitForExistence(timeout: 2), "no provider conflict message bar")
    }
}
