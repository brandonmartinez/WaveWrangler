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
        case .updateFormat:
            // D14 fallback (status item Update…): ask again on the window the action came from.
            if status.formatUpdate == .needed {
                formatUpdatePromptPending = true
                presentFormatUpdatePromptIfNeeded(preferring: window)
            }
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
    ///
    /// Asked only on a window the user can see (preferring `preferred`, e.g. the window that just became key). With
    /// none (every window is a background tab, minimized or not yet shown) the prompt stays pending: it's asked when a
    /// window of this show becomes key or is shown, and Update… in the status item asks it again at any time.
    func presentFormatUpdatePromptIfNeeded(preferring preferred: NSWindow? = nil) {
        let ownWindows = windowControllers.compactMap(\.window)
        let candidates = (preferred.map { [$0] } ?? []).filter { ownWindows.contains($0) } + ownWindows
        let window = candidates.first { Self.promptWindow($0).canShowPrompt }
        guard FormatUpdatePolicy.shouldPresentPrompt(pending: formatUpdatePromptPending, state: status.formatUpdate,
                                                     window: window.map(Self.promptWindow)),
              let window else { return }
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

    private static func promptWindow(_ window: NSWindow) -> FormatUpdatePromptWindow {
        FormatUpdatePromptWindow(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                                 isSelectedTab: window.tabGroup.map { $0.selectedWindow == nil || $0.selectedWindow === window } ?? true)
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
