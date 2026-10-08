import Foundation

/// Editing state for the Edit Anchor sheet's aligned time (#219).
///
/// The `Double` is the value of record and the text is only its rendering. Rendering the anchor to
/// milliseconds made the sheet lossy twice over: a one-frame ↑/↓ nudge (about 21 µs at 48 kHz) rounded
/// straight back to the same text and was lost, and a Return on a field the user never touched committed
/// that rounded value over a frame-exact anchor. Nudges move `seconds` directly, and nothing is committed
/// unless the user actually changed the value.
struct AnchorTimeEditing: Equatable {
    /// Decimals rendered. One output frame is 1/192000 s ≈ 5.2 µs at the highest rate the decoder accepts,
    /// so six decimals would render a nudge there as no change at all; nine always shows one frame.
    static let decimals = 9
    /// Decimals always kept, so a whole-millisecond anchor still reads like the Anchors table.
    static let minimumDecimals = 3

    /// The anchor's value when the sheet opened; an untouched Return must leave it bit-identical.
    let original: Double
    private(set) var seconds: Double
    private(set) var text: String
    private(set) var hasEdited = false

    init(seconds: Double) {
        original = seconds
        self.seconds = seconds
        text = Self.text(for: seconds)
    }

    /// The value Return should commit, or nil when there is nothing to commit. An untouched field and a
    /// field edited back to the anchor's own value both leave the anchor exactly as it was.
    var committedValue: Double? {
        guard hasEdited, seconds != original else { return nil }
        return seconds
    }

    /// Whether the text currently in the field is a number, so a nudge never discards half-typed input.
    var isParsable: Bool { Self.parse(text) != nil }

    /// Moves the value of record by `steps` frames (or by a coarse step), never the rounded text.
    mutating func nudge(steps: Double, step: Double) {
        guard step.isFinite, step != 0 else { return }
        // The text is only a rendering, so nudging starts from the full-precision value whenever the field
        // still shows it. A value the user typed is the base instead, and half-typed input is left alone.
        let base = text == Self.text(for: seconds) ? seconds : Self.parse(text)
        guard let base, base.isFinite else { return }
        seconds = base + steps * step
        text = Self.text(for: seconds)
        hasEdited = true
    }

    /// Records a change the user typed. A programmatic re-render is not an edit.
    mutating func typed(_ newText: String) {
        guard newText != text else { return }
        text = newText
        hasEdited = true
        if let parsed = Self.parse(newText) { seconds = parsed }
    }

    /// Renders a value precisely enough that a one-frame step is visible, without trailing noise.
    static func text(for seconds: Double) -> String {
        let rendered = String(format: "%.\(decimals)f", seconds)
        guard let dot = rendered.firstIndex(of: ".") else { return rendered }
        let floor = rendered.index(dot, offsetBy: minimumDecimals + 1)
        var end = rendered.endIndex
        while end > floor, rendered[rendered.index(before: end)] == "0" {
            end = rendered.index(before: end)
        }
        return String(rendered[..<end])
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }
}
