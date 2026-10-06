import SwiftUI

/// #138: text and symbols on an emphasized (accent-filled) selection are drawn in opaque white.
///
/// In a sidebar `List`, a selected row's label uses the vibrant primary style. With the system Increase
/// Contrast setting on (macOS 27.0.1), that label rendered as about 55 % white blended into the accent fill
/// (#94B6F8 on #0A6CF0, 2.33:1). Explicit white is not vibrant, so the label stays white and reaches the
/// accent's measured white-text ratio (≥ 4.5:1 for every `AccentColor` variant; see `AccentColorContrastTests`).
/// Applies only while SwiftUI reports an emphasized selection behind the view (`backgroundProminence ==
/// .increased`), so unemphasized selections (inactive window, list not focused) keep the system colours.
struct EmphasizedSelectionForeground: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(Color.white)
        } else {
            content
        }
    }
}

extension View {
    /// See `EmphasizedSelectionForeground` (#138).
    func emphasizedSelectionForeground() -> some View {
        modifier(EmphasizedSelectionForeground())
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
