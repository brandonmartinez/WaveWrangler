import AppKit
import Foundation
import WWCore
import WWEpisodeSetup
import WWSources

/// Chooses the source engine behind the Setup UI's `SourceSetupEngine` seam.
///
/// - Default: `WWSourcesSetupEngine` per show — device access records keyed by
///   `DeviceAccessKey(showID, sourceID)` in the device-local `FileDeviceAccessStore`, metadata-only
///   import, availability monitor, transfer controller and relink evaluator.
/// - `WW_SETUP_ENGINE=fixture-states` (UI tests only): scripted in-memory engine with simulated provider
///   states; it never touches the file system.
@MainActor
enum SetupEngineProvider {
    private static let context = SourceAccessContext()

    /// One engine per open show, shared by its windows; the last window to close shuts it down (its
    /// monitor stops and it no longer follows the download preference).
    static let registry = SetupEngineRegistry<ShowID> { showID in
        if let fixture = SetupFixtures.statesEngine() { return fixture }
        return WWSourcesSetupEngine(showID: showID, store: store, context: context, preference: AppSettingsDownloadPreference.shared, connectivity: NetworkPathConnectivity())
    }

    /// Leases per show window: the engine stays alive while any window of the show is open (including
    /// user-requested downloads while Setup isn't showing) and shuts down when the last one closes.
    static let leases = SetupEngineLeases<ObjectIdentifier, ShowID>(registry: registry)
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Starts watching `window` for close. Call synchronously as soon as the window is known (before
    /// any lease), so a close can never be missed.
    static func watchClose(of window: NSWindow) {
        let owner = ObjectIdentifier(window)
        guard closeObservers[owner] == nil else { return }
        leases.ownerOpened(owner)
        closeObservers[owner] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = closeObservers.removeValue(forKey: owner) { NotificationCenter.default.removeObserver(observer) }
                Task { await leases.ownerClosed(owner) }
            }
        }
    }

    static func engine(for window: NSWindow, show: ShowID) async -> any SourceSetupEngine {
        await leases.engine(for: ObjectIdentifier(window), key: show)
    }

    private static let store: any DeviceAccessStore = {
        // UI-test runs keep source access records with their other isolated storage, never the user's.
        if PersistenceEnvironment.isUITestRun {
            let url = PersistenceEnvironment.applicationSupport("DeviceAccess").appending(path: "source-access-records.json")
            #if DEBUG
            // `-WWUITestResetSourceAccess YES`: start without records, as on a Mac that never granted access.
            if UserDefaults.standard.bool(forKey: "WWUITestResetSourceAccess") { try? FileManager.default.removeItem(at: url) }
            #endif
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return FileDeviceAccessStore(fileURL: url)
        }
        if let url = try? FileDeviceAccessStore.defaultFileURL() { return FileDeviceAccessStore(fileURL: url) }
        return InMemoryDeviceAccessStore()
    }()
}
