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
