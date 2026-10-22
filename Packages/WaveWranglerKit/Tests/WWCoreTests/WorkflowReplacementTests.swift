import Foundation
import Testing
import WWCore

@Suite("Workflow replacement preserves user judgment")
struct WorkflowReplacementTests {
    private func transcript() -> SpeakerTranscript {
        let words: [TranscriptWord] = (1...4).map { index in
            let frame = Int64(index) * 16_000
            let start = Double(index)
            return TranscriptWord(text: "um", sourceStartFrame: frame, sourceEndFrame: frame + 4_000,
                alignedStart: start, alignedEnd: start + 0.25)
        }
        return SpeakerTranscript(speaker: SpeakerID(), primary: .init(sourceID: SourceID(), statedChannel: 0),
            sourceRate: 16_000, sourceIdentity: String(repeating: "a", count: 64),
            alignmentRevision: 1, model: "synthetic-v1", workingRange: nil,
            words: words)
    }

    @Test func repeatKeepsExactReviewedManualAndRejectedOriginsButRegeneratesPending() throws {
        let original = transcript()
        var cleanup = EpisodeCleanup(workingRange: .init(alignmentRevision: 1, tracksIn: 0, tracksOut: 10),
            transcripts: [original], manualCuts: [
                .init(alignmentRevision: 1, startFrame: 240_000, endFrame: 288_000),
            ]).proposingFillers()
        cleanup.fillerReviews![0].decision = .reviewed
        cleanup.fillerReviews![0].humanBounds = .init(sourceStartFrame: 15_840, sourceEndFrame: 20_320,
            alignedStart: 0.99, alignedEnd: 1.27)
        cleanup.fillerReviews![1].decision = .rejected
        let manualWord = original.words[2]
        let manual = FillerTimingReview(origin: .manual, speaker: original.speaker, primary: original.primary,
            sourceRate: original.sourceRate, sourceIdentity: original.sourceIdentity, alignmentRevision: 1,
            transcriptID: original.id, word: manualWord, modelRecipe: original.model,
            initialBounds: try #require(FillerTimingBounds(word: manualWord)))
        cleanup.fillerReviews!.append(manual)
        let preserved = cleanup.fillerReviews!.filter(\.retainsUserJudgment)
        let oldPending = cleanup.fillerReviews![3]
        var replacement = original
        replacement.id = UUID()
        replacement.model = "synthetic-v2"
        replacement.words = original.words.map {
            TranscriptWord(text: $0.text, sourceStartFrame: $0.sourceStartFrame! + 80,
                sourceEndFrame: $0.sourceEndFrame! + 80, alignedStart: $0.alignedStart! + 0.005,
                alignedEnd: $0.alignedEnd! + 0.005)
        }
        let result = try cleanup.replacingTranscripts([replacement])
        #expect(result.isValid)
        #expect(result.workingRange == cleanup.workingRange && result.manualCuts == cleanup.manualCuts)
        #expect(result.transcriptHistory == [original])
        #expect(result.fillerReviews?.filter(\.retainsUserJudgment) == preserved)
        #expect(result.fillerReviews?.contains(oldPending) == false)
        #expect(result.fillerReviews?.count == 4, "Three validated events suppress replacement-word duplicates; one undecided event is regenerated")
        for review in preserved {
            #expect(result.capturedTranscript(for: review) == original)
            #expect(!review.matches(replacement), "No invented association to replacement words")
        }
        #expect(result.capturedTranscript(for: oldPending) == nil, "Unvalidated historical words cannot activate marks")
        #expect(try JSONDecoder().decode(EpisodeCleanup.self, from: JSONEncoder().encode(result)) == result)
        #expect(try result.replacingTranscripts([replacement]) == result)
    }

    @Test func eventSuppressionNeverCrossesSourceChannelIdentityOrAlignment() throws {
        var cleanup = EpisodeCleanup(transcripts: [transcript()]).proposingFillers()
        cleanup.fillerReviews![0].decision = .rejected
        let review = cleanup.fillerReviews![0]
        var replacement = cleanup.transcripts[0]
        replacement.id = UUID()
        replacement.words = [replacement.words[0]]
        #expect(FillerTimingReview.detections(in: replacement).first.map(review.coversSameEvent) == true)
        for changed in [
            SpeakerTranscript(speaker: replacement.speaker, primary: .init(sourceID: replacement.primary.sourceID, statedChannel: 1),
                sourceRate: replacement.sourceRate, sourceIdentity: replacement.sourceIdentity, alignmentRevision: 1,
                model: replacement.model, workingRange: nil, words: replacement.words),
            SpeakerTranscript(speaker: replacement.speaker, primary: replacement.primary,
                sourceRate: replacement.sourceRate, sourceIdentity: String(repeating: "b", count: 64), alignmentRevision: 1,
                model: replacement.model, workingRange: nil, words: replacement.words),
            SpeakerTranscript(speaker: replacement.speaker, primary: replacement.primary,
                sourceRate: replacement.sourceRate, sourceIdentity: replacement.sourceIdentity, alignmentRevision: 2,
                model: replacement.model, workingRange: nil, words: replacement.words),
        ] {
            #expect(FillerTimingReview.detections(in: changed).first.map(review.coversSameEvent) == false)
            let replaced = try cleanup.replacingTranscripts([changed])
            #expect(replaced.fillerReviews?.count == 2, "A different channel, media identity or alignment cannot suppress a new event")
        }
    }

    @Test func pendingManualMarkWithoutTranscriptRemainsExact() throws {
        let original = transcript()
        let manual = FillerTimingReview(origin: .manual, speaker: original.speaker, primary: original.primary,
            sourceRate: original.sourceRate, sourceIdentity: original.sourceIdentity, alignmentRevision: 1,
            initialBounds: .init(sourceStartFrame: 16_001, sourceEndFrame: 19_999,
                                 alignedStart: 1.0000625, alignedEnd: 1.2499375))
        let cleanup = EpisodeCleanup(transcripts: [original], fillerReviews: [manual])
        var replacement = original
        replacement.id = UUID()
        replacement.model = "another-local-model"
        replacement.words = []
        let result = try cleanup.replacingTranscripts([replacement])
        #expect(result.fillerReviews == [manual])
        #expect(result.fillerReviews?.first?.decision == .pending)
        #expect(result.transcriptHistory == [original])
    }

    @Test func replacementAlignmentRetiresActiveWorkWithoutDestroyingHistory() throws {
        let original = transcript()
        let cleanup = EpisodeCleanup(workingRange: .init(alignmentRevision: 1, tracksIn: 1, tracksOut: 9),
            transcripts: [original], manualCuts: [.init(alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000)])
            .proposingFillers()
        let reset = try cleanup.resettingForReplacementAlignment()
        #expect(reset.transcripts.isEmpty && reset.workingRange == nil)
        #expect(reset.transcriptHistory == [original])
        #expect(reset.fillerReviews == cleanup.fillerReviews && reset.manualCuts == cleanup.manualCuts)
        var episode = Episode(title: "Replacement", cleanup: reset)
        episode.alignment = EpisodeAlignment(acceptedRevision: 2)
        #expect(episode.activeManualCuts.isEmpty)
        #expect(try reset.resettingForReplacementAlignment() == reset)
        #expect(cleanup.transcripts == [original], "Preparing replacement never mutates prior work")
    }
}
