import AppKit

/// Process entry point. The app is AppKit-hosted (NSApplication + NSDocumentController) with SwiftUI views
/// inside document windows; there is no storyboard and no SwiftUI `App`/`DocumentGroup` scene.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = MainMenu.make()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
