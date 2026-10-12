import AppKit
import Testing
import WWOrganizer

@MainActor
@Suite("Native save-status control")
struct NativeSaveStatusControlTests {
    private func presentation(_ state: DocumentSaveState) -> SaveStatusPresentation {
        SaveStatusPresentation(
            DocumentSaveStatus(state: state, autosaveEnabled: true),
            showName: "Synthetic", formatTime: { _ in "12:00" }
        )
    }

    @Test func recoveryKeepsHonestAccessibleStatus() {
        let control = NativeSaveStatusControl()
        let expected = presentation(.recoveryCheckpoint(at: Date(timeIntervalSince1970: 1_000)))
        control.update(presentation: expected, pointSize: 13, focusRequest: 0, activate: {})
        #expect(control.button.title == expected.itemText)
        #expect(control.button.accessibilityIdentifier() == "ww.show.saveStatus")
        #expect(control.button.accessibilityLabel() == expected.accessibilityLabel)
        #expect(control.button.accessibilityValue() as? String == expected.accessibilityValue)
        #expect(expected.accessibilityValue.contains("not saved"))
        #expect(control.button.accessibilityHelp() == expected.accessibilityHint)
        #expect(control.button.toolTip == expected.popoverText)
        #expect(control.button.image != nil)
        #expect(control.spinner.isHidden)
    }

    @Test func busyStatesKeepSpinnerAndDetailsButton() {
        let control = NativeSaveStatusControl()
        for state in [DocumentSaveState.checking, .saving(cancellable: true)] {
            let expected = presentation(state)
            control.update(presentation: expected, pointSize: 13, focusRequest: 0, activate: {})
            #expect(control.button.title == expected.itemText)
            #expect(control.button.image == nil)
            #expect(!control.spinner.isHidden)
            #expect(control.button.isEnabled)
        }
        control.update(
            presentation: presentation(.saved(at: nil, folderDisplayName: "Shows")),
            pointSize: 13, focusRequest: 0, activate: {}
        )
        #expect(control.spinner.isHidden)
        #expect(control.button.image != nil)
    }

    @Test func activationUsesLatestWindowAction() {
        let control = NativeSaveStatusControl()
        let expected = presentation(.edited)
        var activations = 0
        control.update(presentation: expected, pointSize: 13, focusRequest: 0) { activations += 1 }
        control.button.performClick(nil)
        #expect(activations == 1)
        control.update(presentation: expected, pointSize: 13, focusRequest: 0) { activations += 10 }
        control.button.performClick(nil)
        #expect(activations == 11)
    }

    @Test func textScalingKeepsTheSameNativeControl() {
        let control = NativeSaveStatusControl()
        let button = control.button
        let expected = presentation(.locationUnavailable)
        control.update(presentation: expected, pointSize: 13, focusRequest: 0, activate: {})
        let ordinaryWidth = button.intrinsicContentSize.width
        control.update(presentation: expected, pointSize: 26, focusRequest: 0, activate: {})
        #expect(control.button === button)
        #expect(control.button.font?.pointSize == 26)
        #expect(control.button.intrinsicContentSize.width > ordinaryWidth)
        #expect(control.button.accessibilityValue() as? String == expected.accessibilityValue)
    }
}
