import Testing
@testable import WWOrganizer

@Suite("Transcript review presentation")
struct TranscriptReviewPresentationTests {
    @Test func suppliedSelectedPrimaryTranscriptPreservesProvenanceAndMissingTiming() {
        let input = SelectedPrimaryTranscriptReviewInput(
            primarySourceID: "source-primary",
            primarySourceName: "Studio recorder",
            segments: [
                .init(
                    id: "segment-1",
                    text: "A supplied transcript sentence.",
                    words: [
                        .init(id: "word-1", text: "A", sourceFrameRange: 42...48),
                        .init(id: "word-2", text: "supplied", sourceFrameRange: nil),
                    ]
                ),
                .init(
                    id: "segment-2",
                    text: "An untimed supplied sentence.",
                    words: [
                        .init(id: "word-3", text: "An", sourceFrameRange: nil),
                    ]
                ),
            ]
        )

        let result = TranscriptReviewPresentation.validate(input)
        guard case .success(let presentation) = result else {
            Issue.record("Expected supplied Primary transcript to validate")
            return
        }
        let supplied = TranscriptReviewPresentation.supplied(presentation)

        #expect(supplied.notice.contains("Studio recorder"))
        #expect(supplied.notice.contains("Backup excluded"))
        #expect(supplied.occurrences.map(\.text) == [
            "A supplied transcript sentence.",
            "An untimed supplied sentence.",
        ])
        #expect(supplied.occurrences[0].detail.contains("Selected Primary"))
        #expect(supplied.occurrences[0].wordTiming.contains("1 of 2"))
        #expect(supplied.occurrences[1].wordTiming == "Word timing unavailable")
        #expect(supplied.lanes.contains { $0.label == "Backup" && $0.state.contains("excluded") })
        #expect(supplied.blockedReason.contains("No filler, cut, audition, preview, or edit authority"))
        #expect(!supplied.permitsProposals)
    }

    @Test func malformedSelectedPrimaryInputBecomesAnExplicitRefusal() {
        let input = SelectedPrimaryTranscriptReviewInput(
            primarySourceID: "",
            primarySourceName: "Unidentified",
            segments: []
        )

        let result = TranscriptReviewPresentation.validate(input)
        guard case .failure(let failure) = result else {
            Issue.record("Expected malformed transcript to be refused")
            return
        }
        let presentation = TranscriptReviewPresentation.refusal(failure.refusal)

        #expect(failure == .missingPrimarySource)
        #expect(presentation.occurrences.isEmpty)
        #expect(presentation.notice.contains("unavailable"))
        #expect(presentation.blockedReason.contains("refused"))
        #expect(presentation.lanes.contains { $0.label == "Backup" && $0.state.contains("Excluded") })
    }
}
