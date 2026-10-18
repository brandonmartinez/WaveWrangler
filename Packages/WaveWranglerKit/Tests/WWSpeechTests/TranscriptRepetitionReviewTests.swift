import Foundation
import Testing
import WWCore
import WWSpeech

@Suite("Conservative repetitive recognition review")
struct TranscriptRepetitionReviewTests {
    private func timed(_ text: [String], start: Double = 0) -> [TranscriptWord] {
        text.enumerated().map { index, text in
            let time = start + Double(index) * 0.25
            return TranscriptWord(text: text, sourceStartFrame: Int64(index * 12_000),
                sourceEndFrame: Int64(index * 12_000 + 10_000), alignedStart: time, alignedEnd: time + 0.2)
        }
    }

    @Test func flagsScreenshotLikeRepetitionWithoutChangingRawWordsOrAnchors() {
        let words = timed(["hello"] + Array(repeating: "no,", count: 30) + ["anyway"])
        let original = words
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: words) == Set(words[1..<31].map(\.id)))
        #expect(words == original)
    }

    @Test(arguments: [1, 3, 5, 6, 7])
    func oneWordThresholdProtectsOrdinaryStutters(_ count: Int) {
        let words = timed(Array(repeating: "I,", count: count))
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: words) ==
            (count >= 6 ? Set(words.map(\.id)) : []))
    }

    @Test func punctuationAndCaseDoNotHideLongRepetition() {
        let words = timed(["No,", "NO.", "no!", "No?", "no", "(no)"])
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: words) == Set(words.map(\.id)))
    }

    @Test func shortPhraseLoopsAreReviewHintsButNormalFillersAreNot() {
        let ordinary = timed(["um", "uh", "I", "I", "mean", "you", "know", "you", "know"])
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: ordinary).isEmpty)
        let repeated = timed(Array(repeating: ["you", "know"], count: 4).flatMap { $0 })
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: repeated) == Set(repeated.map(\.id)))
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: Array(repeated.prefix(6))).isEmpty)
    }

    @Test func pausesAndBackwardsTimingSeparateRuns() {
        let a = timed(["no", "no", "no"])
        let b = timed(["no", "no", "no"], start: 10)
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: a + b).isEmpty)
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: b + a).isEmpty)
    }

    @Test func missingTimingDoesNotHideRepetitionOrFabricatePositions() {
        let raw = TranscriptWord(text: "no, no, no, no, no, no,")
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: [raw]) == [raw.id])
        #expect(raw.alignedStart == nil && raw.sourceStartFrame == nil)
        let a = timed(["no", "no", "no"])
        let mixed = a.flatMap { [$0, TranscriptWord(text: "no")] }
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: mixed) == Set(mixed.map(\.id)))
        #expect(mixed.filter { $0.alignedStart == nil }.allSatisfy { $0.sourceStartFrame == nil })
        let separated = a + [TranscriptWord(text: "no")] + timed(["no", "no", "no"], start: 10)
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: separated).isEmpty)
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: []).isEmpty)
    }

    @Test func longRunsAreFullyFlaggedWithoutRepeatedRescanning() {
        let words = (0..<20_000).map { _ in TranscriptWord(text: "no,") }
        #expect(TranscriptRepetitionReview.suspectWordIDs(in: words).count == words.count)
    }
}
