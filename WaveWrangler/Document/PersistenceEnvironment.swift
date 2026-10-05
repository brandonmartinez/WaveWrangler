import AppKit
import Foundation
import Observation
import WWPersistence

/// App-wide persistence services: the device-local recovery store and the shared autosave gate.
///
/// Everything here is device-local and outside canonical documents. Locations are inside the sandbox
/// container (Application Support / Caches).
enum PersistenceEnvironment {
    /// Device-local recovery records (prior checkpoints, C2b edit checkpoints, conflict candidates,
    /// migration backups). Falls back to a temporary folder only if Application Support is unavailable.
    static let recovery: RecoveryStore = {
        let root = (try? RecoveryStore.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appending(path: "WaveWrangler/Recovery", directoryHint: .isDirectory)
        let store = RecoveryStore(root: root)
        store.removeStagingLeftovers()
        return store
    }()

    /// The actual autosave enabled flag, consulted at every scheduling boundary and automatic save entry.
    static let autosaveGate = AutosaveGate(AutosavePreference(defaults: .standard))
}

/// Autosave preference controller (C6): ON by default / configurable delay / OFF, persisted in
/// UserDefaults (`WWAutosaveEnabled`, `WWAutosaveDelaySeconds`; a missing key means the default).
///
/// The Settings pane (library UI lane) may bind to this object or write the UserDefaults keys directly;
/// either way the gate is updated and open documents react: turning autosave back ON publishes pending
/// edits, turning it OFF stops automatic publication (queued work is skipped, documents stay dirty).
@MainActor
@Observable
final class AutosavePolicyController {
    static let shared = AutosavePolicyController()

    private(set) var preference: AutosavePreference
    @ObservationIgnored private var observer: NSObjectProtocol?

    var isEnabled: Bool {
        get { preference.enabled }
        set { update(AutosavePreference(enabled: newValue, delaySeconds: preference.delaySeconds)) }
    }

    var delaySeconds: Double {
        get { preference.delaySeconds }
        set { update(AutosavePreference(enabled: preference.enabled, delaySeconds: newValue)) }
    }

    /// Accessible description of the current policy for Settings and document windows.
    var summary: String {
        guard preference.enabled else { return "Autosave is off. Unsaved changes are not protected until you save." }
        let delay = preference.delaySeconds == 1 ? "1 second" : "\(Int(preference.delaySeconds)) seconds"
        return "Autosave is on: changes are saved \(delay) after you stop editing."
    }

    private init() {
        preference = PersistenceEnvironment.autosaveGate.preference
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutosavePolicyController.shared.syncFromDefaults() }
        }
    }

    func update(_ newValue: AutosavePreference) {
        newValue.write(to: .standard)
        apply(newValue)
    }

    private func syncFromDefaults() {
        let stored = AutosavePreference(defaults: .standard)
        if stored != preference { apply(stored) }
    }

    private func apply(_ newValue: AutosavePreference) {
        let wasEnabled = preference.enabled
        preference = newValue
        PersistenceEnvironment.autosaveGate.preference = newValue
        for case let document as ShowDocument in NSDocumentController.shared.documents {
            document.autosavePolicyDidChange(wasEnabled: wasEnabled)
        }
    }
}
