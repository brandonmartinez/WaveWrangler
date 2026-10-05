import Foundation

/// Whether Settings › General › "Save changes automatically" actually controls document autosave.
///
/// The persistence lane's `AutosavePolicyController` (Document/) owns the policy (`WWAutosaveEnabled`,
/// `WWAutosaveDelaySeconds`, in `PersistenceEnvironment.preferences`) and applies it to open documents, so
/// the toggle binds to it and the connection is real. Keep `isConnected` false in any build where the
/// controller isn't the source of truth, so the UI never offers an Off it can't honour.
@MainActor
enum AutosavePolicyConnection {
    static var isConnected = true

    static let notConnectedNote = "Turning autosave off isn't available in this version yet. WaveWrangler saves your changes automatically."

    /// The autosave behaviour the app really has right now.
    static var effectiveAutosaveEnabled: Bool {
        isConnected ? AutosavePolicyController.shared.isEnabled : true
    }

    static func setEnabled(_ enabled: Bool) {
        guard isConnected else { return }
        AutosavePolicyController.shared.isEnabled = enabled
    }
}
