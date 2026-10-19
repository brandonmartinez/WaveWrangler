import Foundation
import Testing
import WWCore

@Suite("Episode cleanup range and transcript state")
struct EpisodeCleanupTests {
    @Test func markersAreSharedNondestructiveAndResettable() throws {
        let episode = Episode(title: "Episode", sources: [SourceRecord(displayNameHint: "Original")])
        let original = ShowDocumentModel(show: Show(title: "Show"), episodes: [episode])
        let range = EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 30, tracksOut: 120)
        let changed = try original.settingCleanup(EpisodeCleanup(workingRange: range), in: episode.id)
        #expect(changed.episodes[0].sources == original.episodes[0].sources)
        #expect(original.episodes[0].cleanup == nil)
        #expect(changed.episodes[0].cleanup?.workingRange == range)
        #expect(try changed.settingCleanup(nil, in: episode.id) == original)
        #expect(try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func invalidMarkersAndPartialWordCoordinatesRefuse() throws {
        let episode = Episode(title: "Episode")
        let model = ShowDocumentModel(show: Show(title: "Show"), episodes: [episode])
        for range in [
            EpisodeWorkingRange(alignmentRevision: 0),
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: .nan),
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 5, tracksOut: 5),
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 10, tracksOut: 5),
        ] {
            #expect(!range.isValid)
            #expect(throws: DomainError.invalidCleanup) {
                try model.settingCleanup(EpisodeCleanup(workingRange: range), in: episode.id)
            }
        }
        #expect(TranscriptWord(text: "um").isValid)
        #expect(!TranscriptWord(text: "um", alignedStart: 1, alignedEnd: 2).isValid)
        #expect(!TranscriptWord(text: "").isValid)
        #expect(TranscriptWord(text: "um", sourceStartFrame: 16_000, sourceEndFrame: 32_000,
                               alignedStart: 2, alignedEnd: 3).isValid)
    }

    @Test func staleOriginsRemainInspectableAfterSourceRemoval() throws {
        let source = SourceID(), speaker = SpeakerID()
        let transcript = SpeakerTranscript(speaker: speaker,
            primary: ChannelReference(sourceID: source, statedChannel: 0), sourceRate: 16_000,
            sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
            model: "test", workingRange: nil, words: [
                TranscriptWord(text: "um", sourceStartFrame: 16_000, sourceEndFrame: 20_000,
                               alignedStart: 1, alignedEnd: 1.25),
            ])
        let episode = Episode(title: "Episode", cleanup: EpisodeCleanup(transcripts: [transcript]).proposingFillers())
        let model = ShowDocumentModel(show: Show(title: "Show"), episodes: [episode])
        #expect(model.validationIssues().isEmpty, "Staleness is not structural corruption")
        #expect(episode.cleanup?.fillerReviews?.count == 1, "The removed source's original review remains inspectable")
        var duplicate = episode.cleanup!
        duplicate.transcripts.append(transcript)
        #expect(!duplicate.isValid)
    }

    private func transcript() -> SpeakerTranscript {
        SpeakerTranscript(speaker: SpeakerID(),
            primary: ChannelReference(sourceID: SourceID(), statedChannel: 0), sourceRate: 16_000,
            sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
            model: "synthetic:captured-recipe", workingRange: nil, words: [
                TranscriptWord(text: " Um, ", sourceStartFrame: 16_000, sourceEndFrame: 20_000,
                               alignedStart: 1, alignedEnd: 1.25),
                TranscriptWord(text: "UH!", sourceStartFrame: 24_000, sourceEndFrame: 28_000,
                               alignedStart: 1.5, alignedEnd: 1.75),
                TranscriptWord(text: "erm"),
                TranscriptWord(text: "summer", sourceStartFrame: 32_000, sourceEndFrame: 36_000,
                               alignedStart: 2, alignedEnd: 2.25),
            ])
    }

    @Test func exactHesitationsProposeOnlyTimedWordsWithoutChangingRawData() throws {
        let transcript = transcript()
        let cleanup = EpisodeCleanup(transcripts: [transcript])
        let proposed = cleanup.proposingFillers()
        let reviews = try #require(proposed.fillerReviews)
        #expect(reviews.count == 2)
        #expect(reviews.allSatisfy { $0.isValid })
        #expect(proposed.transcripts == cleanup.transcripts)
        #expect(reviews.map(\.word?.text) == [" Um, ", "UH!"])
        #expect(reviews.allSatisfy { $0.bounds == $0.detectedBounds && $0.humanBounds == nil })
        #expect(reviews.allSatisfy { $0.transcriptID == transcript.id && $0.modelRecipe == transcript.model })
        #expect(proposed.proposingFillers() == proposed, "Repeated scans never duplicate or overwrite decisions")
        for text in ["um-hum", "uh huh", "like", "ergo", "uh2", "hmm"] {
            #expect(!FillerTimingReview.isHesitation(text))
        }
        for text in ["UM", "(uh)", "“Erm!”", "er…"] { #expect(FillerTimingReview.isHesitation(text)) }
    }

    @Test func humanBoundsAndRejectionsKeepTheDetectedReferenceAndRawTranscript() throws {
        var cleanup = EpisodeCleanup(transcripts: [transcript()]).proposingFillers()
        let original = cleanup
        cleanup.fillerReviews![0].humanBounds = FillerTimingBounds(sourceStartFrame: 15_840,
            sourceEndFrame: 20_320, alignedStart: 0.99, alignedEnd: 1.27)
        cleanup.fillerReviews![0].decision = .reviewed
        #expect(cleanup.fillerReviews![0].status == "Adjusted")
        #expect(cleanup.fillerReviews![0].detectedBounds == original.fillerReviews![0].detectedBounds)
        cleanup.fillerReviews![1].decision = .rejected
        #expect(cleanup.proposingFillers() == cleanup)
        #expect(cleanup.transcripts == original.transcripts)
        cleanup.fillerReviews![0].revertToDetected()
        #expect(cleanup.fillerReviews![0] == original.fillerReviews![0])
        cleanup.fillerReviews![0].decision = .reviewed
        #expect(cleanup.fillerReviews![0].status == "Reviewed unchanged")
        #expect(cleanup.isValid)
        #expect(try JSONDecoder().decode(EpisodeCleanup.self, from: JSONEncoder().encode(cleanup)) == cleanup)
    }

    @Test func replacedTranscriptRetainsStaleDecisionsWithoutRebindingByText() throws {
        var cleanup = EpisodeCleanup(transcripts: [transcript()]).proposingFillers()
        let old = try #require(cleanup.fillerReviews?.first)
        var replacement = cleanup.transcripts[0]
        #expect(old.matches(replacement))
        replacement.words[0].alignedStart = 0.9
        #expect(!old.matches(replacement), "Even same-ID word retiming invalidates the captured word")
        replacement = cleanup.transcripts[0]
        replacement.id = UUID()
        cleanup.transcripts = [replacement]
        cleanup = cleanup.proposingFillers()
        #expect(cleanup.fillerReviews?.count == 4)
        #expect(cleanup.fillerReviews?.first == old)
        #expect(!old.matches(replacement))
        cleanup.transcripts = []
        #expect(cleanup.isValid, "History remains structurally valid without its original transcript/source")
    }

    @Test func manualProposalsNeverFabricateDetectionsAndInvalidBoundsRefuse() throws {
        let transcript = transcript()
        let manual = FillerTimingReview(origin: .manual, speaker: transcript.speaker, primary: transcript.primary,
            sourceRate: transcript.sourceRate, sourceIdentity: transcript.sourceIdentity, alignmentRevision: 1,
            initialBounds: FillerTimingBounds(sourceStartFrame: 100, sourceEndFrame: 200,
                                            alignedStart: 0.00625, alignedEnd: 0.0125))
        #expect(manual.isValid && manual.detectedBounds == nil && manual.transcriptID == nil)
        var invalid = manual
        invalid.humanBounds = FillerTimingBounds(sourceStartFrame: 200, sourceEndFrame: 100,
                                               alignedStart: 0.02, alignedEnd: 0.01)
        #expect(!invalid.isValid)
        var cleanup = EpisodeCleanup(fillerReviews: [manual, manual])
        #expect(!cleanup.isValid)
        cleanup.fillerReviews = [invalid]
        #expect(!cleanup.isValid)
    }
}
