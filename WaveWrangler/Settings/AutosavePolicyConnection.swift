import Foundation

/// Whether Settings › General › "Save changes automatically" actually controls document autosave.
///
/// The persistence lane's autosave policy (reading `WWAutosaveEnabled`) sets `isConnected` when it is
/// installed. Until then the app autosaves in place exactly as stock NSDocument does, so the UI shows
/// autosave as On and does not offer an Off it can't honour.
@MainActor
enum AutosavePolicyConnection {
    static var isConnected = false

    static let notConnectedNote = "Turning autosave off isn't available in this version yet. WaveWrangler saves your changes automatically."

    /// The autosave behaviour the app really has right now.
    static var effectiveAutosaveEnabled: Bool {
        isConnected ? AppSettings.shared.autosaveEnabled : true
    }
}
