import AppKit
import WWOrganizer

/// Process entry point. The app is AppKit-hosted (NSApplication + NSDocumentController) with SwiftUI views
/// inside document windows; there is no storyboard and no SwiftUI `App`/`DocumentGroup` scene.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        #if DEBUG
        OfflineSocketProbe.captureStartupDescriptors()
        #endif
        // The first `shared` access creates NSApp, so this makes it a WaveWranglerApplication (#126).
        let app = WaveWranglerApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: AppPreferences.registrationDefaults)
        LaunchFixtures.applyBeforeLaunch()
        NSApp.mainMenu = MainMenu.make()
        EpisodeSetupIntegration.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        OfflineSocketProbe.runIfRequested()
        #endif
        // Load the canonical library before any show window can record bookkeeping into it.
        Task { await LibraryUIStore.shared.load() }
        LaunchFixtures.applyAfterLaunch()
        // IA-05: restore windows open at quit; otherwise show the Library window. Never alert at launch.
        DispatchQueue.main.async {
            if !LaunchFixtures.suppressesLibraryAtLaunch, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                LibraryWindowController.show()
            }
        }
    }

    /// IA-04: there are no "Untitled" shows; File › New Show… asks for a name and location first.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { LibraryWindowController.show() }
        return false
    }

    /// ST-34: quitting with queued library changes asks first (no default button). The queued edits are kept
    /// on this Mac by persistence, and the wording says so.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = LibraryUIStore.shared.services.location.quitWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit WaveWrangler?"
        alert.informativeText = warning
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
