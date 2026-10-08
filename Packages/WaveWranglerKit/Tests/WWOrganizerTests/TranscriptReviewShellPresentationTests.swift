import Testing
@testable import WWOrganizer

@Suite("Transcript review shell presentation")
struct TranscriptReviewShellPresentationTests {
    @Test func syntheticFixtureNeverClaimsAnalysisOrTiming() {
        #expect(TranscriptReviewShellPresentation.occurrences.count == 2)
        #expect(TranscriptReviewShellPresentation.occurrences.allSatisfy { $0.title.contains("Synthetic") })
        #expect(TranscriptReviewShellPresentation.occurrences.allSatisfy { $0.note.localizedCaseInsensitiveContains("no ") })
        #expect(TranscriptReviewShellPresentation.occurrences.allSatisfy { $0.tokenStubID.hasPrefix("token-stub-") })
        #expect(TranscriptReviewShellPresentation.lanes.contains { $0.label.contains("Primary") })
        #expect(TranscriptReviewShellPresentation.lanes.contains { $0.label.contains("Backup") })
        #expect(TranscriptReviewShellPresentation.lanes.allSatisfy { $0.state.contains("not analyzed") })
        #expect(TranscriptReviewShellPresentation.timeDomains.map(\.1) == [
            "Source time", "Group time", "Aligned time", "Output time",
        ])
        #expect(TranscriptReviewShellPresentation.timeNotEstablished.contains("Not established"))
        #expect(TranscriptReviewShellPresentation.noProposalState.contains("no analysis"))
    }

    @Test func reviewActionsStayBlockedWithoutSafetyEvidence() {
        #expect(TranscriptReviewShellPresentation.acceptBlockedReason.contains("all-lane backing"))
        #expect(TranscriptReviewShellPresentation.acceptBlockedReason.contains("protection coverage"))
        #expect(TranscriptReviewShellPresentation.liftBlockedReason.contains("all-lane backing"))
        #expect(TranscriptReviewShellPresentation.liftBlockedReason.contains("protection coverage"))
        #expect(TranscriptReviewShellPresentation.rejectBlockedReason.contains("no proposal"))
        #expect(TranscriptReviewShellPresentation.fullPreviewBlockedReason.contains("every affected lane"))
        #expect(TranscriptReviewShellPresentation.singleLaneAuditionBlockedReason.contains("not a full preview"))
        #expect(TranscriptReviewShellPresentation.noLiveSourceReason.contains("Setup"))
    }
}
