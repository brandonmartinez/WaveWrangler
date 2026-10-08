import Foundation
import Testing

/// #219 review, finding 2. The Edit Anchor sheet used to render the aligned time with `%.3f`, which made it
/// lossy in both directions: a one-frame ↑/↓ nudge rounded back to the same text, and an untouched Return
/// committed the rounded value over a frame-exact anchor.
@Suite("Anchor time editing")
struct AnchorTimeEditingTests {
    private static let rate48k = 1.0 / 48_000
    private static let rate192k = 1.0 / 192_000
    private static let anchor = 12.345_678_9

    @Test func oneFrameNudgeMovesTheValueByExactlyOneFrame() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.nudge(steps: 1, step: Self.rate48k)
        #expect(editing.seconds == Self.anchor + Self.rate48k)
        editing.nudge(steps: -1, step: Self.rate48k)
        #expect(editing.seconds == Self.anchor + Self.rate48k - Self.rate48k)
    }

    @Test func oneFrameNudgeIsVisibleInTheRenderedText() {
        let before = AnchorTimeEditing(seconds: Self.anchor)
        var after = before
        after.nudge(steps: 1, step: Self.rate48k)
        #expect(after.text != before.text, "a one-frame nudge must change what the field shows")
        let shown = Double(after.text)
        #expect(shown != nil && shown != Self.anchor, "the shown value must not round back to the anchor")
        // The old `%.3f` rendering is what swallowed it.
        #expect(String(format: "%.3f", Self.anchor + Self.rate48k) == String(format: "%.3f", Self.anchor))
    }

    @Test func oneFrameNudgeIsVisibleAtTheHighestDecodedRate() {
        let before = AnchorTimeEditing(seconds: Self.anchor)
        var after = before
        after.nudge(steps: 1, step: Self.rate192k)
        #expect(after.text != before.text)
    }

    @Test func nudgeAccumulatesWithoutLosingFrames() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        for _ in 0..<4 { editing.nudge(steps: 1, step: Self.rate48k) }
        let drift = abs(editing.seconds - (Self.anchor + 4 * Self.rate48k))
        #expect(drift < Self.rate48k / 1_000, "four nudges must land four frames away, not zero")
    }

    @Test func untouchedReturnCommitsNothing() {
        let editing = AnchorTimeEditing(seconds: Self.anchor)
        #expect(editing.committedValue == nil, "Return on a field the user never touched is a no-op")
        #expect(editing.seconds == Self.anchor)
    }

    @Test func rerenderingTheSameTextIsNotAnEdit() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed(editing.text)
        #expect(!editing.hasEdited)
        #expect(editing.committedValue == nil)
    }

    @Test func typingBackTheOriginalValueCommitsNothing() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("0.5")
        editing.typed(AnchorTimeEditing.text(for: Self.anchor))
        #expect(editing.hasEdited)
        #expect(editing.committedValue == nil, "editing back to the anchor's own value leaves it unchanged")
    }

    @Test func nudgedValueIsCommitted() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.nudge(steps: 1, step: Self.rate48k)
        #expect(editing.committedValue == Self.anchor + Self.rate48k)
    }

    @Test func typedValueIsCommittedAtFullPrecision() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed(" 0.000020833 ")
        #expect(editing.committedValue == 0.000_020_833)
    }

    @Test func unparsableTextIsNeverCommittedAndBlocksNudging() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("abc")
        #expect(!editing.isParsable)
        #expect(editing.committedValue == nil, "an unparsable field must not commit the pre-edit value")
        editing.nudge(steps: 1, step: Self.rate48k)
        #expect(editing.text == "abc", "a nudge must not discard half-typed input")
    }

    // MARK: - Apply (#219 review finding 2)

    @Test func applyRefusesInvalidTextTypedAfterAValidEdit() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("5.0")
        editing.typed("abc")
        #expect(editing.apply() == .invalid, "invalid text must refuse, not commit the earlier valid edit")
        #expect(editing.committedValue == nil)
    }

    @Test func applyRefusesEmptyTextTypedAfterAValidEdit() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("5.0")
        editing.typed("")
        #expect(editing.apply() == .invalid, "an emptied field must refuse, not commit the earlier valid edit")
        #expect(editing.committedValue == nil)
    }

    @Test func applyRefusesInvalidTextTypedDirectlyOverTheOriginalValue() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("abc")
        #expect(editing.apply() == .invalid, "invalid text must refuse apply instead of dismissing silently")
    }

    @Test func applyIsANoOpForAnUntouchedField() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        #expect(editing.apply() == .unchanged)
        #expect(editing.seconds == Self.anchor)
    }

    @Test func applyIsANoOpForAValueEditedBackToTheOriginal() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed("0.5")
        editing.typed(AnchorTimeEditing.text(for: Self.anchor))
        #expect(editing.apply() == .unchanged)
    }

    @Test func applyCommitsANudgedValue() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.nudge(steps: 1, step: Self.rate48k)
        #expect(editing.apply() == .committed(Self.anchor + Self.rate48k))
    }

    @Test func applyCommitsATypedValueAtFullPrecision() {
        var editing = AnchorTimeEditing(seconds: Self.anchor)
        editing.typed(" 0.000020833 ")
        #expect(editing.apply() == .committed(0.000_020_833))
    }

    @Test func wholeMillisecondValuesStillReadLikeTheAnchorsTable() {
        #expect(AnchorTimeEditing.text(for: 0.125) == "0.125")
        #expect(AnchorTimeEditing.text(for: 0) == "0.000")
        #expect(AnchorTimeEditing.text(for: -1.5) == "-1.500")
    }
}
