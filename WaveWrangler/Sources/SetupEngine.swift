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
        return WWSourcesSetupEngine(showID: showID, store: store, context: context, preference: AppSettingsDownloadPreference.shared)
    }

    private static let store: any DeviceAccessStore = {
        if let url = try? FileDeviceAccessStore.defaultFileURL() { return FileDeviceAccessStore(fileURL: url) }
        return InMemoryDeviceAccessStore()
    }()
}
