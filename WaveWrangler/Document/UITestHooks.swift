import Foundation

/// Test-only controls for XCUITests, active only when the app is launched with `-WWUITestHooks YES`
/// (argument domain). They isolate storage (see `PersistenceEnvironment`) and let a test change the autosave
/// policy while documents are open, exactly as the Settings pane would.
///
/// - `-WWUITestAutosave ON|OFF` sets the policy at launch.
/// - Distributed notifications `com.brandonmartinez.wavewrangler.uitest.autosave.on` / `.off` toggle it later.
@MainActor
enum UITestHooks {
    nonisolated static let enabledKey = "WWUITestHooks"
    static let autosaveArgumentKey = "WWUITestAutosave"
    static let autosaveOnNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.on")
    static let autosaveOffNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")

    private static var observers: [NSObjectProtocol] = []

    static func installIfRequested(_ controller: AutosavePolicyController) {
        guard PersistenceEnvironment.isUITestRun, observers.isEmpty else { return }
        if let value = UserDefaults.standard.string(forKey: autosaveArgumentKey) {
            controller.isEnabled = value.uppercased() == "ON"
        }
        let center = DistributedNotificationCenter.default()
        for (name, enabled) in [(autosaveOnNotification, true), (autosaveOffNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AutosavePolicyController.shared.isEnabled = enabled }
            })
        }
    }
}
