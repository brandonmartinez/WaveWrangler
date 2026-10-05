import AppKit
import WWCore
import WWOrganizer
import WWPersistence

/// Launch-argument fixtures for XCUITests (Debug builds only). Synthetic data only: generated in memory
/// or in the app container's temporary directory; never user recordings or folders.
///
/// - `-WWUITestResetPreferences YES`: remove WaveWrangler preference keys (fresh defaults).
/// - `-WWUITestLibraryFixture lib100|empty`: seed the in-memory library (F-LIB100 / F-EMPTY).
/// - `-WWUITestLibraryFixture lib100files`: F-LIB100 whose 97 available entries are backed by real
///   synthetic `.wwshow` files (5 episodes, 10 metadata-only source references each; 1,000 references in
///   the library) generated once in the container's temporary directory and reused by later launches, so
///   shows open from the library (WW-007 / M1-SCALE-001 native timing).
/// - `-WWUITestResetStorage YES` (with `-WWUITestHooks YES`): delete the isolated UI-test storage (library,
///   show locations, recovery) so a test starts clean; later launches without it keep the data (relaunch).
/// - `-WWUITestOpenWithoutShowWindows <folder/name.wwshow>`: see `UITestHooks` (restoration-equivalent open).
/// - `-WWUITestOpenShow <name>` (+ `-WWUITestShowEpisodes <n>`): create a synthetic show and open it
///   (the Library window is then not shown at launch).
/// - `-WWUITestAppearance aqua|darkAqua|highContrastAqua|highContrastDarkAqua`: app appearance for C04/C07
///   checks. The high-contrast names are AppKit's Increase Contrast appearances (labelled "override, not
///   system setting" in evidence; implements the `-WWForceIncreaseContrast` idea of the acceptance suite).
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
        if defaults.bool(forKey: "WWUITestResetStorage"), PersistenceEnvironment.isUITestRun {
            // Only the isolated UI-test storage ("WaveWrangler-UITests"), never the user's.
            let root = PersistenceEnvironment.applicationSupport("")
            if root.path(percentEncoded: false).contains("WaveWrangler-UITests") {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: PersistenceEnvironment.caches(""))
            }
            UserDefaults(suiteName: "com.brandonmartinez.wavewrangler.uitest-preferences")?.removeObject(forKey: "WWLibraryLocation")
            if let folder = defaults.string(forKey: "WWUITestShowFolder"), folder.hasPrefix("WWUITests-") {
                try? FileManager.default.removeItem(at: URL(filePath: NSTemporaryDirectory()).appending(path: folder, directoryHint: .isDirectory))
            }
        }
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
        let appearances: [String: NSAppearance.Name] = [
            "aqua": .aqua, "darkAqua": .darkAqua,
            "highContrastAqua": .accessibilityHighContrastAqua, "highContrastDarkAqua": .accessibilityHighContrastDarkAqua,
        ]
        if let name = defaults.string(forKey: "WWUITestAppearance").flatMap({ appearances[$0] }) {
            NSApp.appearance = NSAppearance(named: name)
        }
        switch defaults.string(forKey: "WWUITestLibraryFixture") {
        case "lib100":
            let fixture = SyntheticLibraryFixture.make()
            let backend = InMemoryLibraryBackend(seed: fixture.library, details: fixture.details)
            LibraryServices.current = LibraryServices(persistence: backend, entries: backend, location: backend)
        case "lib100files":
            let fixture = SyntheticLibraryFixture.make()
            let locations = SyntheticShowFiles.ensure(fixture)
            let backend = InMemoryLibraryBackend(seed: fixture.library, details: fixture.details, locations: locations)
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
        UITestHooks.openWithoutShowWindowsIfRequested()
        guard let name = defaults.string(forKey: "WWUITestOpenShow"), !name.isEmpty else { return }
        let count = max(0, defaults.integer(forKey: "WWUITestShowEpisodes"))
        // A stable folder name when asked (relaunch tests reopen the same show); otherwise unique.
        let folderName = defaults.string(forKey: "WWUITestShowFolder") ?? "WWUITests-\(UUID().uuidString)"
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: folderName, directoryHint: .isDirectory)
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

#if DEBUG
/// Writes the F-LIB100 shows as real documents (synthetic metadata only; no audio files exist or are read).
@MainActor
enum SyntheticShowFiles {
    static func ensure(_ fixture: SyntheticLibraryFixture.Output) -> [ShowID: URL] {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "WWUITestLibrary100-v1", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let publisher = DocumentPublisher(coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: nil)
        var locations: [ShowID: URL] = [:]
        for entry in fixture.library.entries {
            guard let details = fixture.details[entry.showID], details.state == .available else { continue }
            let url = folder.appending(path: "\(entry.lastKnownTitle).wwshow")
            locations[entry.showID] = url
            if FileManager.default.fileExists(atPath: url.path) { continue }
            var model = ShowDocumentModel.untitled(id: entry.showID, title: entry.lastKnownTitle)
            let episodes = details.episodes ?? []
            let references = details.sourceReferenceCount ?? 0
            for (index, summary) in episodes.enumerated() {
                let count = references / max(episodes.count, 1) + (index < references % max(episodes.count, 1) ? 1 : 0)
                let sources = (0..<count).map { SourceRecord(displayNameHint: "synthetic-\(summary.number ?? index + 1)-\($0 + 1).wav") }
                model = (try? model.addingEpisode(Episode(id: summary.id, title: summary.title, number: summary.number, sources: sources))) ?? model
            }
            _ = try? publisher.publish(model, revision: 1, key: .show(entry.showID), to: url, target: .newLocation)
        }
        return locations
    }
}
#endif
