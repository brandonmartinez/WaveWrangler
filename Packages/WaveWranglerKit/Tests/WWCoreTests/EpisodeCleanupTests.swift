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
            model: "test", workingRange: nil, words: [TranscriptWord(text: "um")])
        let episode = Episode(title: "Episode", cleanup: EpisodeCleanup(transcripts: [transcript]))
        let model = ShowDocumentModel(show: Show(title: "Show"), episodes: [episode])
        #expect(model.validationIssues().isEmpty, "Staleness is not structural corruption")
        var duplicate = episode.cleanup!
        duplicate.transcripts.append(transcript)
        #expect(!duplicate.isValid)
    }
}
