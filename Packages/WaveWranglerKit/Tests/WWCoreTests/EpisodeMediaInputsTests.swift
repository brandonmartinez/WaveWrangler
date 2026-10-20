import Testing
import WWCore

@Suite("Scoped episode media inputs")
struct EpisodeMediaInputsTests {
    private func fixture() -> ShowDocumentModel {
        let speaker = Speaker(name: "Host")
        let epoch = RecordingEpoch(label: "Take")
        let group = RecorderGroup(name: "Recorder", epochs: [epoch])
        let source = SourceRecord(displayNameHint: "Synthetic",
            observations: .init(channelCount: .known(1)),
            placement: .init(recorderGroupID: group.id, epochID: epoch.id))
        return ShowDocumentModel(show: Show(title: "Show"), speakers: [speaker], episodes: [
            Episode(title: "Episode", recorderGroups: [group], sources: [source],
                speakerAssignments: [.init(speakerID: speaker.id,
                    primary: .init(sourceID: source.id, statedChannel: 0))]),
            Episode(title: "Unrelated"),
        ])
    }

    @Test func presentationAndOtherEpisodesAreNotJobInputs() throws {
        let original = fixture(), id = original.episodes[0].id
        var changed = try original.settingSpeakerAppearance(.init(color: .teal),
            for: original.speakers[0].id, in: id)
        changed.show.title = "Renamed show"
        changed.speakers[0].name = "Renamed host"
        changed.episodes[0].sources[0].displayNameHint = "Renamed recording"
        changed.episodes[0].recorderGroups[0].name = "New origin label"
        changed.episodes[0].recorderGroups[0].icon = .computer
        changed.episodes[0].recorderGroups[0].epochs[0].label = "Renamed take"
        changed.episodes[0].recorderGroups[0].epochs[0].note = "A note"
        changed.episodes[0].notes = "Editing notes"
        changed.episodes[1].sources.append(SourceRecord(displayNameHint: "Other"))
        #expect(changed.hasSameMediaInputs(as: original, in: id, includingWorkingRange: true))
    }

    @Test func realAudioChangesAndDeletedEpisodesInvalidateResults() {
        let original = fixture(), id = original.episodes[0].id
        var changed = original
        changed.episodes[0].sources[0].role = .backup
        #expect(!changed.hasSameMediaInputs(as: original, in: id))
        changed = original
        changed.episodes[0].sources[0].observations.channelCount = .known(2)
        #expect(!changed.hasSameMediaInputs(as: original, in: id))
        changed = original
        changed.episodes[0].speakerAssignments[0].primary = nil
        #expect(!changed.hasSameMediaInputs(as: original, in: id))
        changed = original
        changed.episodes[0].recorderGroups[0].preferredAlignmentReference = true
        #expect(!changed.hasSameMediaInputs(as: original, in: id))
        changed.episodes.removeFirst()
        #expect(!changed.hasSameMediaInputs(as: original, in: id))
        #expect(!changed.hasSameMediaInputs(as: changed, in: id))
    }

    @Test func workingRangeIsAJobInputButNotAPlaybackOrWaveformInput() {
        let original = fixture(), id = original.episodes[0].id
        var changed = original
        changed.episodes[0].cleanup = .init(workingRange: .init(alignmentRevision: 1, tracksIn: 2, tracksOut: 4))
        #expect(changed.hasSameMediaInputs(as: original, in: id))
        #expect(!changed.hasSameMediaInputs(as: original, in: id, includingWorkingRange: true))
    }
}
