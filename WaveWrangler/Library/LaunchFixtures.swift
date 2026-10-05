import AppKit
import WWCore
import WWOrganizer

/// Launch-argument fixtures for XCUITests (Debug builds only). Synthetic data only: generated in memory
/// or in the app container's temporary directory; never user recordings or folders.
///
/// - `-WWUITestResetPreferences YES`: remove WaveWrangler preference keys (fresh defaults).
/// - `-WWUITestLibraryFixture lib100|empty`: seed the in-memory library (F-LIB100 / F-EMPTY).
/// - `-WWUITestOpenShow <name>` (+ `-WWUITestShowEpisodes <n>`): create a synthetic show and open it
///   (the Library window is then not shown at launch).
/// - `-WWUITestCenterWindows YES` (implied by `-WWUITestHooks YES`): place windows fully on the primary
///   display so audits and clicks never straddle a display edge.
@MainActor
enum LaunchFixtures {
    /// Debug-only: keep a window entirely on the primary display (the one with the menu bar) so audits sample its own pixels.
    static func placeForTesting(_ window: NSWindow) {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "WWUITestCenterWindows") || defaults.bool(forKey: "WWUITestHooks"),
              let visible = NSScreen.screens.first?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
        #endif
    }

    /// UI tests that open documents themselves (persistence's lifecycle tests, `-WWUITestOpenShow`) don't
    /// get the Library window at launch, so it can't cover the document window.
    static var suppressesLibraryAtLaunch: Bool {
        #if DEBUG
        let defaults = UserDefaults.standard
        if !(defaults.string(forKey: "WWUITestOpenShow") ?? "").isEmpty { return true }
        return defaults.bool(forKey: "WWUITestHooks") && defaults.string(forKey: "WWUITestLibraryFixture") == nil
        #else
        return false
        #endif
    }

    static func applyBeforeLaunch() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "WWUITestResetPreferences") {
            defaults.removeObject(forKey: "NSWindow Frame WaveWranglerLibraryWindow")
            // Persistence's isolated UI-test preferences (autosave policy) also start from the defaults, so
            // results don't depend on test order.
            if let suite = UserDefaults(suiteName: "com.brandonmartinez.wavewrangler.uitest-preferences") {
                for key in [PreferenceKey.autosaveEnabled, "WWAutosaveDelaySeconds"] { suite.removeObject(forKey: key) }
            }
            for key in [PreferenceKey.autosaveEnabled, PreferenceKey.downloadSourcesAutomatically, PreferenceKey.textSizePercent, PreferenceKey.settingsLastPane] {
                defaults.removeObject(forKey: key)
            }
        }
        switch defaults.string(forKey: "WWUITestLibraryFixture") {
        case "lib100":
            let fixture = SyntheticLibraryFixture.make()
            let backend = InMemoryLibraryBackend(seed: fixture.library, details: fixture.details)
            LibraryServices.current = LibraryServices(persistence: backend, entries: backend, location: backend)
        case "empty":
            let backend = InMemoryLibraryBackend()
            LibraryServices.current = LibraryServices(persistence: backend, entries: backend, location: backend)
        default:
            break
        }
        #endif
    }

    static func applyAfterLaunch() {
        #if DEBUG
        let defaults = UserDefaults.standard
        // Autosave delay for UI tests, set through the policy controller (its preferences are an isolated
        // suite in UI-test runs, so a plain argument doesn't reach them). Allowed values: 1/2/5/10/30 s.
        let delay = defaults.double(forKey: "WWUITestAutosaveDelaySeconds")
        if delay > 0 { AutosavePolicyController.shared.delaySeconds = delay }
        guard let name = defaults.string(forKey: "WWUITestOpenShow"), !name.isEmpty else { return }
        let count = max(0, defaults.integer(forKey: "WWUITestShowEpisodes"))
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "WWUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSApp.presentError(error)
            return
        }
        let episodes = (0..<count).map { Episode(title: "Synthetic Episode \($0 + 1)", number: $0 + 1) }
        NewShowCommand.create(at: folder.appending(path: "\(name).wwshow"), episodes: episodes)
        #endif
    }
}
