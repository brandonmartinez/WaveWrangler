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

    @Test func syntheticProposalsExposeOnlyProvisionalPresentationMetadata() {
        #expect(TranscriptReviewShellPresentation.proposals.count == 2)
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.id.hasPrefix("synthetic-proposal-") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.occurrenceID.hasPrefix("synthetic-") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.rationale.contains("not model output") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.timingState.contains("Timing unavailable") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.sourceState.contains("no selected Primary") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.protectionState.contains("Protection unsupported") })
        #expect(TranscriptReviewShellPresentation.proposals.allSatisfy { $0.status.contains("not verified or actionable") })
    }

    @Test func reviewActionsStayBlockedWithoutSafetyEvidence() {
        for reason in [
            TranscriptReviewShellPresentation.acceptBlockedReason,
            TranscriptReviewShellPresentation.liftBlockedReason,
            TranscriptReviewShellPresentation.rejectBlockedReason,
        ] {
            #expect(reason.contains("verified source"))
            #expect(reason.contains("word timing"))
            #expect(reason.contains("current map"))
            #expect(reason.contains("protection coverage"))
            #expect(reason.contains("human"))
        }
        #expect(TranscriptReviewShellPresentation.fullPreviewBlockedReason.contains("all-lane backing"))
        #expect(TranscriptReviewShellPresentation.singleLaneAuditionBlockedReason.contains("not a full preview"))
        #expect(TranscriptReviewShellPresentation.noLiveSourceReason.contains("Setup"))
    }
}
