import SwiftUI

/// #138/#139: text and symbols on an emphasized (accent-filled) sidebar selection are drawn in opaque white.
///
/// With the system Increase Contrast setting on, in dark appearance (macOS 27.0.1), a selected sidebar row's label
/// rendered as a vibrant tint blended into the accent fill (#94B3F4 on #0B65E8, 2.48:1). Explicit white renders
/// non-vibrant and reaches 5.2:1 (diagnostic run, this Mac, 2026-10-05). SwiftUI's `backgroundProminence` never
/// reads `.increased` in the macOS sidebar `List`, so emphasis is derived from the row's own state instead: the
/// row is selected, its list has keyboard focus, and the window is key (the conditions under which AppKit draws
/// the accent-filled selection). An unemphasized (grey) selection keeps the system colours.
struct EmphasizedSelectionForeground: ViewModifier {
    let isSelectedInFocusedList: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if isSelectedInFocusedList && controlActiveState == .key {
            content.foregroundStyle(Color.white)
        } else {
            content
        }
    }
}

extension View {
    /// See `EmphasizedSelectionForeground` (#138/#139).
    func emphasizedSelectionForeground(selectedInFocusedList: Bool) -> some View {
        modifier(EmphasizedSelectionForeground(isSelectedInFocusedList: selectedInFocusedList))
    }
}

extension View {
    /// #139: checked checkboxes use `CheckboxTint`, which equals `AccentColor` except in dark + Increase Contrast.
    /// There one blue can't serve both white selection text (≥ 4.5:1, needs a dark blue) and a checked-box fill
    /// that stands out from the dark sheet background (≥ 3:1 against #363636, needs a lighter blue), so checkboxes
    /// get the lighter #2F86FF. The white checkmark on it stays ≥ 3:1. Measured by `testAccentTintedControls`.
    func checkboxTint() -> some View {
        tint(Color("CheckboxTint"))
    }
}
