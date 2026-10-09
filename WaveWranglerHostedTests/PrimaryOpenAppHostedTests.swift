import Foundation
import Testing
import WWCore
import WWEpisodeSetup
@testable import WaveWrangler

/// In the actual app target; no source files, decoder, provider, or user recordings are opened.
@MainActor
@Suite("Setup Primary request wiring (synthetic)", .serialized)
struct PrimaryOpenAppHostedTests {
    private func fixture() -> (ShowDocumentStore, EpisodeSetupModel, InMemorySourceSetupEngine, Speaker, SourceRecord, ChannelReference) {
        let speaker = Speaker(name: "Synthetic")
        let source = SourceRecord(displayNameHint: "synthetic", role: .primary, roleConfirmation: .userConfirmed)
        let channel = ChannelReference(sourceID: source.id, statedChannel: 0)
        let episode = Episode(title: "Synthetic", sources: [source],
                              speakerAssignments: [SpeakerAssignment(speakerID: speaker.id, primary: channel,
                                                                      primaryConfirmation: .userConfirmed)])
        let store = ShowDocumentStore(model: ShowDocumentModel(show: Show(title: "Synthetic"),
                                                               speakers: [speaker], episodes: [episode]))
        let engine = InMemorySourceSetupEngine()
        let preference = UserDefaultsSourceDownloadPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let setup = EpisodeSetupModel(store: store, episodeID: episode.id, engine: engine, preference: preference)
        setup.selection = [.source(source.id)]
        setup.speakerSelection = [speaker.id]
        return (store, setup, engine, speaker, source, channel)
    }

    @Test func confirmedPrimaryStillRefusesBeforeAnySourceOpen() {
        let (_, setup, engine, speaker, _, channel) = fixture()
        #expect(setup.primaryOpenState().selectedChannel == channel)
        #expect(throws: PrimaryOpenRefusal.accessRecordUnversioned) {
            try setup.beginPrimaryContentOpen(speakerID: speaker.id, channel: channel)
        }
        #expect(engine.calls.isEmpty)
    }

    @Test func selectionABAAndRemovalRestoreAdvanceLiveGenerations() {
        let (store, setup, engine, _, source, channel) = fixture()
        let initial = setup.primaryOpenState()
        setup.selection = []
        setup.selection = [.source(source.id)]
        let restoredSelection = setup.primaryOpenState()
        #expect(restoredSelection.selectedChannel == channel)
        #expect(restoredSelection.selectionGeneration != initial.selectionGeneration)

        var removed = store.model
        removed.episodes[0].sources.removeAll()
        store.replaceLoadedModel(removed)
        #expect(setup.primaryOpenState().selectedChannel == nil)
        store.replaceLoadedModel(initial.model)
        let restoredDocument = setup.primaryOpenState()
        #expect(restoredDocument.model == initial.model)
        #expect(restoredDocument.documentGeneration != initial.documentGeneration)
        #expect(engine.calls.isEmpty)
    }

    @Test func backupAndWrongSpeakerCannotInheritSelection() {
        let (store, setup, engine, speaker, source, channel) = fixture()
        let backup = SourceRecord(displayNameHint: "synthetic backup", role: .backup, roleConfirmation: .userConfirmed)
        var changed = store.model
        changed.episodes[0].sources.append(backup)
        store.replaceLoadedModel(changed)
        setup.selection = [.source(backup.id)]
        #expect(setup.primaryOpenState().selectedChannel == nil)
        #expect(throws: PrimaryOpenRefusal.accessRecordUnversioned) {
            try setup.beginPrimaryContentOpen(speakerID: speaker.id,
                                              channel: ChannelReference(sourceID: backup.id, statedChannel: 0))
        }
        setup.selection = [.source(source.id)]
        setup.speakerSelection = [SpeakerID()]
        #expect(setup.primaryOpenState().selectedSpeakerID != speaker.id)
        #expect(throws: PrimaryOpenRefusal.accessRecordUnversioned) {
            try setup.beginPrimaryContentOpen(speakerID: speaker.id, channel: channel)
        }
        #expect(engine.calls.isEmpty)
    }
}
