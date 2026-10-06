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
/// - `-WWUITestOffline YES` (F-OFFLINE, T26–T28): every show publication fails at P1 (nothing is written) with the
///   error a folder that can't be reached produces, until the distributed notification
///   `com.brandonmartinez.wavewrangler.uitest.offline.off` "reconnects" (`.offline.on` disconnects again). Each
///   publication attempt is counted; the count and the offline flag are written to the named pasteboard
///   `com.brandonmartinez.wavewrangler.uitest` as JSON `{"publicationAttempts": n, "offline": bool, "attemptTimes": [s]}`
///   (attempt times are seconds since 1970, the same clock as the test runner's).
/// - `-WWUITestSaveRetryInterval <seconds>` shortens the automatic retry after a failed save (ST-11; 30 s).
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
        if let interval = UserDefaults.standard.string(forKey: "WWUITestSaveRetryInterval").flatMap(Double.init), interval > 0 {
            ShowDocument.saveRetryInterval = interval
        }
        if UserDefaults.standard.bool(forKey: "WWUITestOffline") {
            ShowDocument.debugPublicationHooks = UITestOfflineHooks.shared
            UITestOfflineHooks.shared.publish()
            for (name, offline) in [(UITestOfflineHooks.onNotification, true), (UITestOfflineHooks.offNotification, false)] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    UITestOfflineHooks.shared.setOffline(offline)
                })
            }
        }
    }
}

/// F-OFFLINE seam: simulates a show folder that can't be reached. Publication fails at P1, before anything is
/// written, with the Cocoa error for a missing item (classified `.unavailable`, the same as a real unreachable
/// folder). Counts every publication attempt, offline or not.
final class UITestOfflineHooks: PublicationHooks, @unchecked Sendable {
    static let shared = UITestOfflineHooks()
    static let onNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.offline.on")
    static let offNotification = Notification.Name("com.brandonmartinez.wavewrangler.uitest.offline.off")
    static let pasteboard = NSPasteboard.Name("com.brandonmartinez.wavewrangler.uitest")

    private let lock = NSLock()
    private var offline = true
    private var attempts = 0
    private var attemptTimes: [Double] = []

    func reached(_ boundary: PublicationBoundary) throws {
        guard boundary == .candidateValidated else { return }
        let failing = lock.withLock {
            attempts += 1
            attemptTimes.append(Date().timeIntervalSince1970)
            return offline
        }
        publish()
        if failing {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedFailureReasonErrorKey: "The folder can't be reached (simulated)."])
        }
    }

    func setOffline(_ value: Bool) {
        lock.withLock { offline = value }
        publish()
    }

    func publish() {
        let (count, isOffline, times) = lock.withLock { (attempts, offline, attemptTimes) }
        let json = #"{"publicationAttempts": \#(count), "offline": \#(isOffline), "attemptTimes": [\#(times.map { String($0) }.joined(separator: ", "))]}"#
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let board = NSPasteboard(name: Self.pasteboard)
                board.clearContents()
                board.setString(json, forType: .string)
            }
        }
    }
}
#endif
