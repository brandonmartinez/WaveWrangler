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
    private static var engines: [ShowID: any SourceSetupEngine] = [:]
    private static let context = SourceAccessContext()
    private static let fixture: InMemorySourceSetupEngine? = SetupFixtures.isActive ? SetupFixtures.statesEngine() : nil

    static func engine(for showID: ShowID) -> any SourceSetupEngine {
        if let fixture { return fixture }
        if let existing = engines[showID] { return existing }
        let engine = WWSourcesSetupEngine(showID: showID, store: store, context: context, preference: AppSettingsDownloadPreference.shared)
        engines[showID] = engine
        return engine
    }

    private static let store: any DeviceAccessStore = {
        if let url = try? FileDeviceAccessStore.defaultFileURL() { return FileDeviceAccessStore(fileURL: url) }
        return InMemoryDeviceAccessStore()
    }()
}
