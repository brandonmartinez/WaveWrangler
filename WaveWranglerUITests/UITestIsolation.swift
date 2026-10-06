import XCTest

/// Isolates UI-test classes from each other (M1 exit gate; regression run 2 triage). Suites share the app's
/// isolated UI-test preferences (`com.brandonmartinez.wavewrangler.uitest-preferences`: library location, autosave
/// policy) and UI-test storage (`WaveWrangler-UITests`: library, recovery). A test that leaves e.g. a library location
/// pointing at its deleted temp folder, or autosave turned off, made later classes fail although each passes alone.
///
/// Before the first test of each test class, this launches the app once with `-WWUITestResetStorage YES
/// -WWUITestResetPreferences YES` and the empty in-memory library, then terminates it, so every class starts from a
/// fresh install. Within a class, and within a test, nothing is reset: relaunch-persistence tests keep their state.
///
/// Registered for the whole bundle as its `NSPrincipalClass` (`INFOPLIST_KEY_NSPrincipalClass`); XCTest instantiates
/// it when the bundle loads. Set `WW_UITEST_NO_CLASS_RESET=1` in the runner's environment to turn it off.
@objc(WWUITestIsolation)
final class UITestIsolation: NSObject, XCTestObservation {
    private var lastClass: String?

    override init() {
        super.init()
        guard ProcessInfo.processInfo.environment["WW_UITEST_NO_CLASS_RESET"] != "1" else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let className = String(describing: type(of: testCase))
        guard className != lastClass else { return }
        lastClass = className
        MainActor.assumeIsolated { Self.resetApp(before: className) }
    }

    @MainActor
    private static func resetApp(before className: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetStorage", "YES",
                               "-WWUITestResetPreferences", "YES", "-WWUITestLibraryFixture", "empty"]
        app.launch()
        app.terminate()
        print("UITestIsolation: reset UI-test storage and preferences before \(className)")
    }
}
