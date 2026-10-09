import Foundation
import Testing
import WWCore
import WWEpisodeSetup

@Suite("App-owned selected Primary intent (not a source grant)")
@MainActor
struct SelectedPrimarySourceIntentTests {
    private func setup() -> (EpisodeSetupModel, SpeakerID, SourceID, SourceID) {
        let speaker = Speaker(name: "Generated")
        let epoch = RecordingEpoch(label: "Take")
        let group = RecorderGroup(name: "Recorder", epochs: [epoch])
        let placement = SourcePlacement(recorderGroupID: group.id, epochID: epoch.id)
        let primary = SourceRecord(
            displayNameHint: "generated-primary",
            observations: SourceObservations(channelCount: .known(2)),
            placement: placement,
            role: .primary, roleConfirmation: .userConfirmed
        )
        let backup = SourceRecord(
            displayNameHint: "generated-backup",
            observations: SourceObservations(channelCount: .known(1)),
            placement: placement,
            role: .backup, roleConfirmation: .userConfirmed
        )
        let episode = Episode(
            title: "Generated", recorderGroups: [group], sources: [primary, backup],
            speakerAssignments: [
                SpeakerAssignment(
                    speakerID: speaker.id,
                    primary: ChannelReference(sourceID: primary.id, statedChannel: 1),
                    primaryConfirmation: .userConfirmed,
                    backups: [ChannelReference(sourceID: backup.id, statedChannel: 0)]
                )
            ]
        )
        let model = ShowDocumentModel(
            show: Show(title: "Generated"), speakers: [speaker], episodes: [episode]
        )
        let setup = EpisodeSetupModel(
            store: ShowDocumentStore(model: model), episodeID: episode.id,
            engine: InMemorySourceSetupEngine(),
            preference: UserDefaultsSourceDownloadPreference()
        )
        setup.isOnScreen = true
        setup.selection = [.source(primary.id)]
        setup.speakerSelection = [speaker.id]
        return (setup, speaker.id, primary.id, backup.id)
    }

    @Test func rowSpeakerAndChannelMustMatchTheConfirmedPrimary() throws {
        let (setup, speaker, primary, backup) = setup()
        let intent = try setup.captureSelectedPrimarySource()
        #expect(intent.speaker == speaker)
        #expect(intent.channel == ChannelReference(sourceID: primary, statedChannel: 1))
        #expect(setup.isCurrentSelectedPrimarySource(intent))

        setup.selection = [.source(backup)]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.selection = [.channel(primary, SpeakerID())]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.selection = [.source(primary)]
        setup.speakerSelection = [SpeakerID()]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.speakerSelection = [speaker]
        #expect(!setup.isCurrentSelectedPrimarySource(intent),
                "restoring identical selections cannot revive an earlier intent")
        #expect(try setup.captureSelectedPrimarySource().channel.statedChannel == 1)

        let original = setup.store.model
        for channel in [-1, 2] {
            var changed = original
            changed.episodes[0].speakerAssignments[0].primary =
                ChannelReference(sourceID: primary, statedChannel: channel)
            setup.store.replaceLoadedModel(changed)
            #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                try setup.captureSelectedPrimarySource()
            }
        }
        var unconfirmed = original
        unconfirmed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        setup.store.replaceLoadedModel(unconfirmed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        unconfirmed = original
        unconfirmed.episodes[0].sources[0].roleConfirmation = .provisional
        setup.store.replaceLoadedModel(unconfirmed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
    }

    @Test func removalRestorationAndMapOrDocumentABAInvalidateTheOldIntent() throws {
        let (setup, _, primary, _) = setup()
        let intent = try setup.captureSelectedPrimarySource()
        let original = setup.store.model
        let beforeRemoval = try #require(setup.store.captureMutationGeneration())

        var removed = original
        removed.episodes[0].sources.removeAll { $0.id == primary }
        setup.store.replaceLoadedModel(removed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.store.replaceLoadedModel(original)
        #expect(!setup.store.isCurrentMutationGeneration(beforeRemoval),
                "a restored source inventory is not a restored document generation")
        #expect(setup.isCurrentSelectedPrimarySource(intent),
                "selection intent alone cannot attest to document or access-store generation")

        let generation = try #require(setup.store.captureMutationGeneration())
        var changed = original
        changed.episodes[0].alignment = EpisodeAlignment()
        setup.store.replaceLoadedModel(changed)
        setup.store.replaceLoadedModel(original)
        #expect(!setup.store.isCurrentMutationGeneration(generation),
                "restoring equal map/document values cannot restore an old publication generation")
    }

    @Test func missingAcceptedMapAndOffscreenSelectionCannotTurnIntentIntoPCM() throws {
        let (setup, _, _, _) = setup()
        let intent = try setup.captureSelectedPrimarySource()
        #expect(throws: SelectedPrimarySourceReadRefusal.acceptedMapUnavailable) {
            try SelectedPrimarySourceReadIssuer.validatePortableMapWindow(
                model: setup.store.model, selection: intent, startingAt: 0
            )
        }
        setup.isOnScreen = false
        #expect(!setup.isCurrentSelectedPrimarySource(intent))
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
    }
}
