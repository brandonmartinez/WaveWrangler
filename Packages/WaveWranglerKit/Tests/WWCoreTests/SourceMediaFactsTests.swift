import Foundation
import Testing
import WWCore

@Suite("Observed recording metadata")
struct SourceMediaFactsTests {
    @Test func observationsAreHonestCompleteAndRetainKnownFactsWhenUnavailable() throws {
        let source = SourceRecord(displayNameHint: "synthetic.wav")
        let episode = Episode(title: "Synthetic", sources: [source])
        let original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let facts = SourceObservations(durationSeconds: .known(1.25), channelCount: .known(2), sampleRate: .known(48_000))
        #expect(facts.isComplete)
        #expect(!SourceObservations().isComplete)
        let observed = try original.recordingMediaObservations(facts, source: source.id, in: episode.id)
        #expect(observed.episodes[0].sources[0].observations == facts)
        #expect(try observed.recordingMediaObservations(SourceObservations(), source: source.id, in: episode.id) == observed)
        #expect(try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(observed)) == observed)
    }

    @Test func actualChannelCountExposesConflictsWithoutErasingAssignmentsOrPretendingUnknown() throws {
        let source = SourceRecord(displayNameHint: "synthetic.wav",
            placement: SourcePlacement(channelLabels: [ChannelLabel(channel: 3, label: "Stated")]))
        let episode = Episode(title: "Synthetic", sources: [source])
        let original = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        #expect(throws: DomainError.channelOutOfRange(.init(sourceID: source.id, statedChannel: 3), channelCount: 2)) {
            try original.recordingMediaObservations(.init(channelCount: .known(2)), source: source.id, in: episode.id)
        }
        #expect(original.episodes[0].sources[0].observations.channelCount == .unknown)
        #expect(original.episodes[0].sources[0].placement == source.placement)
    }

    @Test(arguments: [
        SourceObservations(durationSeconds: .known(.nan)),
        SourceObservations(durationSeconds: .known(-1)),
        SourceObservations(channelCount: .known(0)),
        SourceObservations(sampleRate: .known(.infinity)),
        SourceObservations(sampleRate: .known(0)),
    ]) func invalidMeasurementsCannotEnterCanonicalState(_ observations: SourceObservations) {
        #expect(!observations.isValid)
    }
}
