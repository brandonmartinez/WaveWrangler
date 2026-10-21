import Foundation
import Testing
import WWCore

@Suite("Retained raw transcript history")
struct TranscriptHistoryTests {
    private func transcript(id: UUID = UUID(), text: String) -> SpeakerTranscript {
        .init(id: id, speaker: SpeakerID(), primary: .init(sourceID: SourceID(), statedChannel: 0),
              sourceRate: 16_000, sourceIdentity: String(repeating: "a", count: 64),
              alignmentRevision: 1, model: "synthetic", workingRange: nil,
              words: [.init(text: text)])
    }

    @Test func retranscriptionPreservesAllPreviousRawAndUntimedSpeech() throws {
        let first = transcript(text: "Original speech with no trustworthy timing")
        let second = transcript(text: "Replacement")
        let initial = EpisodeCleanup(transcripts: [first])
        let updated = try initial.replacingTranscripts([second])
        #expect(updated.transcripts == [second])
        #expect(updated.transcriptHistory == [first])
        #expect(updated.isValid)
        #expect(try updated.replacingTranscripts([second]) == updated)
        let third = transcript(text: "Another recognition")
        let latest = try updated.replacingTranscripts([third])
        #expect(latest.transcriptHistory == [first, second])
        let reopened = try JSONDecoder().decode(EpisodeCleanup.self, from: JSONEncoder().encode(latest))
        #expect(reopened == latest)
        #expect(reopened.transcriptHistory?.first?.words.first?.alignedStart == nil)
    }

    @Test func immutableTranscriptIdentityCannotBeReusedForDifferentRawText() {
        let first = transcript(text: "Original")
        var changed = first
        changed.words[0].text = "Changed"
        #expect(throws: DomainError.self) {
            try EpisodeCleanup(transcripts: [first]).replacingTranscripts([changed])
        }
    }
}
