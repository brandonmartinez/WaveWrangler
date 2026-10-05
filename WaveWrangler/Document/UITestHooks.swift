import Foundation

/// Test-only controls for XCUITests, active only when the app is launched with `-WWUITestHooks YES`
/// (argument domain). They isolate storage (see `PersistenceEnvironment`) and let a test change the autosave
/// policy while documents are open, exactly as the Settings pane would.
///
/// - `-WWUITestAutosave ON|OFF` sets the policy at launch.
/// - `-WWUITestAutosaveDelay <seconds>` sets the autosave delay at launch (default 1 s when absent, so a delay
///   left in the UI-test preferences by one test never leaks into the next).
/// - Distributed notifications `com.brandonmartinez.wavewrangler.uitest.autosave.on` / `.off` toggle it later.
/// - `-WWUITestOpenWithoutShowWindows <folder/name.wwshow>` (relative to the app's temporary directory) opens a
///   show the way state restoration does: read, window controllers made, window ordered front, and never
///   `showWindows()`. Used to test work that must run on every display path.
///
/// Debug builds only: in Release the whole type is compiled out, so `-WWUITestHooks YES` and the
/// distributed notifications have no effect (`PersistenceEnvironment.isUITestRun` is always `false`).
#if DEBUG
import AppKit
import WWPersistence

@MainActor
enum UITestHooks {
    nonisolated static let enabledKey = "WWUITestHooks"
    static let autosaveArgumentKey = "WWUITestAutosave"
    static let autosaveDelayArgumentKey = "WWUITestAutosaveDelay"
    static let autosaveOnNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.on")
    static let autosaveOffNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")

    private static var observers: [NSObjectProtocol] = []

    static func openWithoutShowWindowsIfRequested() {
        guard PersistenceEnvironment.isUITestRun,
              let path = UserDefaults.standard.string(forKey: "WWUITestOpenWithoutShowWindows"), !path.isEmpty else { return }
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: path)
        do {
            let document = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        } catch {
            NSApp.presentError(error)
        }
    }

    static func installIfRequested(_ controller: AutosavePolicyController) {
        guard PersistenceEnvironment.isUITestRun, observers.isEmpty else { return }
        if let value = UserDefaults.standard.string(forKey: autosaveArgumentKey) {
            controller.isEnabled = value.uppercased() == "ON"
        }
        let delay = UserDefaults.standard.string(forKey: autosaveDelayArgumentKey).flatMap(Double.init) ?? AutosavePreference.defaultDelay
        if controller.delaySeconds != delay { controller.delaySeconds = delay }
        let center = DistributedNotificationCenter.default()
        for (name, enabled) in [(autosaveOnNotification, true), (autosaveOffNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AutosavePolicyController.shared.isEnabled = enabled }
            })
        }
    }
}
#endif
