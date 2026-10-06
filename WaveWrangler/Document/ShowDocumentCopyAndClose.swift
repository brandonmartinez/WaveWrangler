import AppKit
import WWOrganizer

/// Wording and presentation for Save a Copy Elsewhere… (ST-16, T28) and the failed-save close sheet (T23 D7–D9),
/// from the design lane's `SaveStatusPresentation` and `CloseDecision`. Kept apart from `ShowDocument.swift`, whose
/// persistence types share names with WWOrganizer's presentation types.
extension ShowDocument: DocumentStatusActionHandling {
    func performSaveStatusAction(_ action: SaveStatusAction, from window: NSWindow?) -> Bool {
        switch action {
        case .saveACopyElsewhere:
            saveACopyElsewhere()
            return true
        default:
            return false
        }
    }

    static func copyName(for showName: String) -> String { SaveStatusPresentation.copyName(for: showName) }

    static func copyMessage(copyName: String, folder: String, originalFolder: String) -> String {
        SaveStatusPresentation.copyMessage(copyName: copyName, folder: folder, originalFolder: originalFolder)
    }

    /// The D7–D9 close sheet for the current failed save, or `nil` when the state doesn't call for one.
    func failedSaveCloseSheet() -> CloseSheet? {
        let autosave = PersistenceEnvironment.autosaveGate.isEnabled
        let mapped = ShowDocumentStatusMapping.map(
            status.saveStatus.state, readOnlyReason: nil, autosaveEnabled: autosave,
            folderDisplayName: fileURL?.deletingLastPathComponent().lastPathComponent
        )
        guard case let .sheet(sheet) = CloseDecision(state: mapped.state, autosaveEnabled: autosave, showName: showFileName),
              sheet.buttons.contains(.saveACopyElsewhere) else { return nil }
        return sheet
    }

    /// Presents `sheet` on `window`: its first button is the default (Return), Cancel is Escape and Don't Save is ⌘⌫.
    func presentFailedSaveCloseSheet(_ sheet: CloseSheet, in window: NSWindow, choice: @escaping (CloseSheetButton) -> Void) {
        let alert = NSAlert()
        alert.messageText = sheet.message
        alert.informativeText = sheet.informative
        for button in sheet.buttons {
            let added = alert.addButton(withTitle: button.rawValue)
            switch button {
            case .cancel:
                added.keyEquivalent = "\u{1b}"
            case .dontSave:
                added.keyEquivalent = "\u{7f}"
                added.keyEquivalentModifierMask = .command
            default:
                break
            }
        }
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            choice(sheet.buttons.indices.contains(index) ? sheet.buttons[index] : .cancel)
        }
    }
}
