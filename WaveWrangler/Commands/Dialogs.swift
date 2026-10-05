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

    /// Confirms an uncommon destructive action. The destructive button is first but, per A13, the
    /// sheet has Cancel bound to Esc; `destructiveIsDefault` controls whether Return confirms.
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
        confirm.hasDestructiveAction = destructive
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        if !destructiveIsDefault {
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
