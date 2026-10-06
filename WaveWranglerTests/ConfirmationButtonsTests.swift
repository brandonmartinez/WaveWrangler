import AppKit
import Testing

/// #114 (A13, K05): confirmation sheets' button configuration. `ConfirmationButtons.swift` is compiled into this
/// unhosted target, so this runs without the app (and on CI's macOS, where UI tests can't show the macOS 27
/// behaviour: a destructive button never keeps Return).
@MainActor
@Suite("Confirmation buttons")
struct ConfirmationButtonsTests {
    private func configured(destructive: Bool, destructiveIsDefault: Bool) -> (confirm: NSButton, cancel: NSButton) {
        let alert = NSAlert()
        let confirm = alert.addButton(withTitle: "Delete")
        let cancel = alert.addButton(withTitle: "Cancel")
        ConfirmationButtons.configure(confirm: confirm, cancel: cancel, destructive: destructive, destructiveIsDefault: destructiveIsDefault)
        return (confirm, cancel)
    }

    @Test func chosenActionIsTheDefaultButtonWithoutDestructiveStyle() {
        let buttons = configured(destructive: true, destructiveIsDefault: true)
        #expect(buttons.confirm.keyEquivalent == "\r", "Return confirms")
        #expect(!buttons.confirm.hasDestructiveAction, "a destructive button can't keep Return on macOS 27")
        #expect(buttons.cancel.keyEquivalent == "\u{1b}", "Esc cancels")
    }

    @Test func unchosenDestructionHasDestructiveStyleAndNoDefaultButton() {
        let buttons = configured(destructive: true, destructiveIsDefault: false)
        #expect(buttons.confirm.keyEquivalent == "", "no default button")
        #expect(buttons.confirm.hasDestructiveAction)
        #expect(buttons.cancel.keyEquivalent == "\u{1b}", "Esc cancels")
    }

    @Test func nonDestructiveConfirmationWithoutDefault() {
        let buttons = configured(destructive: false, destructiveIsDefault: false)
        #expect(buttons.confirm.keyEquivalent == "")
        #expect(!buttons.confirm.hasDestructiveAction)
    }

    @Test func nonDestructiveDefaultConfirmation() {
        let buttons = configured(destructive: false, destructiveIsDefault: true)
        #expect(buttons.confirm.keyEquivalent == "\r")
        #expect(!buttons.confirm.hasDestructiveAction)
    }
}

/// #114: which Setup confirmations are chosen destruction (Return confirms, no destructive role).
/// `SetupConfirmationKind.swift` is compiled into this unhosted target; the app's `Confirmation.kind`
/// switch is exhaustive, so a new confirmation must pick a kind here.
@Suite("Setup confirmation kinds")
struct SetupConfirmationKindTests {
    @Test func chosenDeletesConfirmWithReturn() {
        #expect(SetupConfirmationKind.removeSources.isChosenDestruction)
        #expect(SetupConfirmationKind.deleteSpeaker.isChosenDestruction)
        #expect(SetupConfirmationKind.deleteGroup.isChosenDestruction)
    }

    @Test func cancelDownloadKeepsTheSafeSide() {
        #expect(!SetupConfirmationKind.cancelDownload.isChosenDestruction, "Keep Downloading stays the safe side")
    }

    @Test func everyKindIsClassified() {
        #expect(SetupConfirmationKind.allCases.filter(\.isChosenDestruction).count == 3)
        #expect(SetupConfirmationKind.allCases.count == 4)
    }
}
