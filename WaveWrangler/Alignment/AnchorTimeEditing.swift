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

    /// The value Return should commit, or nil when there is nothing to commit. An untouched field, a
    /// field edited back to the anchor's own value, and a field whose current text doesn't parse all
    /// leave the anchor exactly as it was.
    var committedValue: Double? {
        guard hasEdited, let value = currentValue, value != original else { return nil }
        return value
    }

    /// Whether the text currently in the field is a number, so a nudge never discards half-typed input.
    var isParsable: Bool { Self.parse(text) != nil }

    /// What Apply/Return should do with the field right now (#219 review finding 2). Invalid or empty
    /// text always refuses and reports `.invalid`, even when an earlier edit in this same session already
    /// parsed to a real value: committing that stale `seconds` over text the user has since overwritten
    /// is exactly the bug this closes. Only a value actually parsed from the *current* text can commit.
    enum ApplyOutcome: Equatable {
        case committed(Double)
        case unchanged
        case invalid
    }

    /// Validates the current text and decides the Apply outcome, keeping `seconds` in sync with a
    /// successful parse so a later nudge starts from it.
    mutating func apply() -> ApplyOutcome {
        guard let value = currentValue else { return .invalid }
        seconds = value
        guard hasEdited, value != original else { return .unchanged }
        return .committed(value)
    }

    /// The value represented by the field's current text: the full-precision value of record when the
    /// text still matches its own rendering (as it does right after a nudge), otherwise whatever the text
    /// parses to, or nil when it doesn't parse. This is the same starting point `nudge` uses, so an edit
    /// immediately overwritten with unparsable text never falls back to an earlier, superseded edit.
    private var currentValue: Double? {
        let value = text == Self.text(for: seconds) ? seconds : Self.parse(text)
        guard let value, value.isFinite else { return nil }
        return value
    }

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
