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
/// - `-WWUITestCenterWindows YES`: place windows fully on the main display (stable audits).
@MainActor
enum LaunchFixtures {
    /// Debug-only: keep a window entirely on the primary display (the one with the menu bar) so audits sample its own pixels.
    static func placeForTesting(_ window: NSWindow) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "WWUITestCenterWindows"), let visible = NSScreen.screens.first?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
        #endif
    }

    static var suppressesLibraryAtLaunch: Bool {
        #if DEBUG
        return !(UserDefaults.standard.string(forKey: "WWUITestOpenShow") ?? "").isEmpty
        #else
        return false
        #endif
    }

    static func applyBeforeLaunch() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "WWUITestResetPreferences") {
            defaults.removeObject(forKey: "NSWindow Frame WaveWranglerLibraryWindow")
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
