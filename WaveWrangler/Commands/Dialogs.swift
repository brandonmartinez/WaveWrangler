import AppKit

/// Native sheets for names and destructive confirmations. NSAlert gives standard keyboard behaviour:
/// Return = default, Esc = Cancel, focus returns to the invoking window afterwards.
@MainActor
enum Dialogs {
    /// Asks for a name in a sheet. Returns `nil` on Cancel.
    static func askForName(
        in window: NSWindow?,
        title: String,
        message: String? = nil,
        fieldLabel: String,
        initial: String = "",
        confirmTitle: String
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = fieldLabel
        field.setAccessibilityLabel(fieldLabel)
        field.setAccessibilityIdentifier("ww.dialog.name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = await run(alert, in: window)
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Confirms an uncommon destructive action. Cancel is bound to Esc. Per A13 ("destructive style only for
    /// unchosen destruction"):
    /// - `destructiveIsDefault` (the user chose the action, e.g. Delete Collection, Remove from Library): the
    ///   confirm button is the default button (Return), without destructive styling.
    /// - otherwise (e.g. discarding unsaved changes): destructive styling and no default button.
    /// macOS 27 never lets a button be both: `hasDestructiveAction` clears its Return key equivalent (#114).
    static func confirm(
        in window: NSWindow?,
        message: String,
        informative: String,
        confirmTitle: String,
        destructive: Bool = true,
        destructiveIsDefault: Bool = true
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = destructive ? .warning : .informational
        let confirm = alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        if destructiveIsDefault {
            confirm.keyEquivalent = "\r"
        } else {
            confirm.hasDestructiveAction = destructive
            confirm.keyEquivalent = ""
        }
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    /// Plain informational sheet (e.g. a refused action with its reason).
    static func inform(in window: NSWindow?, message: String, informative: String) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        _ = await run(alert, in: window)
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
