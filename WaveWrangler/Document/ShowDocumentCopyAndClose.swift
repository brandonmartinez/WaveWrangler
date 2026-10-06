import AppKit
import WWOrganizer

/// Wording and presentation for Save a Copy Elsewhere… (ST-16, T28) and the failed-save close sheet (T23 D7–D9),
/// from the design lane's `SaveStatusPresentation` and `CloseDecision`. Kept apart from `ShowDocument.swift`, whose
/// persistence types share names with WWOrganizer's presentation types.
extension ShowDocument: DocumentStatusActionHandling {
    func performSaveStatusAction(_ action: SaveStatusAction, from window: NSWindow?) -> Bool {
        switch action {
        case .saveACopyElsewhere:
            // T28: whether the copy was saved or the panel cancelled, focus returns to the save-status item.
            saveACopyElsewhere { _ in ShowWindowRegistry.state(for: window)?.focusSaveStatus() }
            return true
        case .tryAgain where isAwaitingFormatUpdate:
            // D15 Try Again re-runs the update; never a save, which an older show can't do.
            updateFormat()
            return true
        case .showDetails where isAwaitingFormatUpdate:
            if case let .failed(detail) = status.formatUpdate {
                Task { @MainActor [showFileName] in
                    await Dialogs.inform(in: window, message: "Couldn’t update “\(showFileName)”",
                                         informative: "\(detail) The original file is unchanged.")
                }
            }
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

    /// D14 (T21): once the window has appeared, asks whether to update an older-format show. Update is the default
    /// (Return) and runs the C5 migration; Open Read-Only (⌘R) keeps the in-memory upgrade and writes nothing; Cancel
    /// (Escape) closes the show unchanged.
    func presentFormatUpdatePromptIfNeeded() {
        guard formatUpdatePromptPending, status.formatUpdate == .needed,
              let window = windowControllers.lazy.compactMap(\.window).first(where: \.isVisible) else { return }
        formatUpdatePromptPending = false
        let prompt = FormatUpdatePrompt(showName: showFileName)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        for button in prompt.buttons {
            let added = alert.addButton(withTitle: button.rawValue)
            switch button {
            case .update:
                added.setAccessibilityIdentifier("ww.formatUpdate.update")
            case .openReadOnly:
                added.keyEquivalent = "r"
                added.keyEquivalentModifierMask = .command
                added.setAccessibilityIdentifier("ww.formatUpdate.openReadOnly")
            case .cancel:
                added.keyEquivalent = "\u{1b}"
                added.setAccessibilityIdentifier("ww.formatUpdate.cancel")
            }
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = prompt.buttons.indices.contains(index) ? prompt.buttons[index] : .cancel
            MainActor.assumeIsolated {
                guard let self else { return }
                switch choice {
                case .update: self.updateFormat()
                case .openReadOnly: break
                case .cancel: self.close()
                }
            }
        }
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
