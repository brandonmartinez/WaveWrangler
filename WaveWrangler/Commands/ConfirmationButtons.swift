import AppKit

/// Button configuration for confirmation sheets (Design A13, K05; #114). Also compiled into the unhosted
/// WaveWranglerTests target, so the configuration is checked without launching the app.
///
/// - `destructiveIsDefault` (the user chose the action, e.g. Delete Collection, Remove from Library): the confirm
///   button is the default button (Return), without destructive styling.
/// - otherwise (unchosen destruction, e.g. discarding unsaved changes): destructive styling when `destructive`,
///   and no default button.
///
/// Cancel is always bound to Esc. macOS 27 never lets a button be both destructive and the default:
/// `hasDestructiveAction` clears its Return key equivalent, and re-setting it is ignored.
enum ConfirmationButtons {
    static func configure(confirm: NSButton, cancel: NSButton, destructive: Bool, destructiveIsDefault: Bool) {
        cancel.keyEquivalent = "\u{1b}"
        if destructiveIsDefault {
            confirm.hasDestructiveAction = false
            confirm.keyEquivalent = "\r"
        } else {
            confirm.hasDestructiveAction = destructive
            confirm.keyEquivalent = ""
        }
    }
}
