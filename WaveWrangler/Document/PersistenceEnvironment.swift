import AppKit
import Foundation
import Observation
import WWPersistence

/// App-wide persistence services: the device-local recovery store and the shared autosave gate.
///
/// Everything here is device-local and outside canonical documents. Locations are inside the sandbox
/// container (Application Support / Caches).
enum PersistenceEnvironment {
    /// UI-test runs (`-WWUITestHooks YES`) use separate preferences and storage so they never touch the
    /// user's settings, recovery records or library.
    /// Always `false` in Release builds: the hooks are compiled only into Debug builds.
    static let isUITestRun: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: UITestHooks.enabledKey)
        #else
        return false
        #endif
    }()

    /// Folder name under Application Support / Caches.
    static let storageName = isUITestRun ? "WaveWrangler-UITests" : "WaveWrangler"

    /// Where autosave preferences live (`UserDefaults` is not `Sendable`, so it is resolved per use).
    static var preferences: UserDefaults {
        isUITestRun ? (UserDefaults(suiteName: "com.brandonmartinez.wavewrangler.uitest-preferences") ?? .standard) : .standard
    }

    static func applicationSupport(_ path: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "\(storageName)/\(path)", directoryHint: .isDirectory)
    }

    static func caches(_ path: String) -> URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "\(storageName)/\(path)")
    }

    /// Device-local recovery records (prior checkpoints, C2b edit checkpoints, conflict candidates,
    /// migration backups, the library pending-edits journal).
    static let recovery: RecoveryStore = {
        let store = RecoveryStore(root: applicationSupport("Recovery"))
        store.removeStagingLeftovers()
        return store
    }()

    /// The actual autosave enabled flag, consulted at every scheduling boundary and automatic save entry.
    static let autosaveGate = AutosaveGate(AutosavePreference(defaults: preferences))
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
        // Capture weakly instead of reaching through `shared`: the notification is posted synchronously by our
        // own writes, which can happen while `shared` is still being initialized.
        //
        // Not in UI-test runs: there the launch arguments (`-WWUITestAutosave`, `-WWUITestAutosaveDelay`) and this
        // process's own changes are the policy. The isolated UI-test preferences suite is shared by every UI-test
        // app process on the host, so re-reading it on each defaults change could apply another (or a just-exited)
        // process's stored value over this run's launch arguments: a 30 s test delay silently became the previous
        // test's 1 s. Settings changes still reach the gate in UI-test runs, through this controller.
        if !PersistenceEnvironment.isUITestRun {
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFromDefaults() }
            }
        }
        #if DEBUG
        UITestHooks.installIfRequested(self)
        #endif
    }

    func update(_ newValue: AutosavePreference) {
        newValue.write(to: PersistenceEnvironment.preferences)
        apply(newValue)
    }

    private func syncFromDefaults() {
        let stored = AutosavePreference(defaults: PersistenceEnvironment.preferences)
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
