import AppKit
import Testing
import WWCore
import WWEpisodeSetup
import WWOrganizer
@testable import WaveWrangler

/// Hosted because the window, Setup selection and store are app-owned; no media is opened.
@MainActor
@Suite("Selected Primary review binding", .serialized)
struct TranscriptReviewBindingTests {
    private struct Fixture {
        let state: ShowWindowState
        let setup: EpisodeSetupModel
        let store: ShowDocumentStore
        let window: NSWindow
        let speaker: Speaker
        let first: Episode
        let second: Episode
        let firstSource: SourceRecord
        let secondSource: SourceRecord

        func input(_ text: String, from source: SourceRecord? = nil) -> SelectedPrimaryTranscriptReviewInput {
            let source = source ?? firstSource
            return SelectedPrimaryTranscriptReviewInput(
                primarySourceID: source.id.description,
                primarySourceName: source.displayNameHint,
                segments: [.init(id: "segment-1", text: text, words: [
                    .init(id: "word-1", text: "Untimed", sourceFrameRange: nil),
                ])]
            )
        }
    }

    private func fixture() -> Fixture {
        let speaker = Speaker(name: "Host")
        let firstSource = SourceRecord(
            displayNameHint: "synthetic-A", role: .primary, roleConfirmation: .userConfirmed
        )
        let secondSource = SourceRecord(
            displayNameHint: "synthetic-B", role: .primary, roleConfirmation: .userConfirmed
        )
        func episode(_ title: String, source: SourceRecord) -> Episode {
            Episode(title: title, sources: [source], speakerAssignments: [
                SpeakerAssignment(
                    speakerID: speaker.id,
                    primary: ChannelReference(sourceID: source.id, statedChannel: 0),
                    primaryConfirmation: .userConfirmed
                ),
            ])
        }
        let first = episode("A", source: firstSource)
        let second = episode("B", source: secondSource)
        let store = ShowDocumentStore(model: ShowDocumentModel(
            show: Show(title: "Synthetic"), speakers: [speaker], episodes: [first, second]
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 492),
                              styleMask: .titled, backing: .buffered, defer: false)
        let state = ShowWindowState(store: store)
        state.attach(to: window)
        let setup = EpisodeSetupModel(
            store: store, episodeID: first.id,
            engine: InMemorySourceSetupEngine(),
            preference: UserDefaultsSourceDownloadPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        setup.window = { [weak window] in window }
        setup.isOnScreen = true
        setup.speakerSelection = [speaker.id]
        return Fixture(state: state, setup: setup, store: store, window: window, speaker: speaker,
                       first: first, second: second, firstSource: firstSource, secondSource: secondSource)
    }

    @Test func episodeSwitchRefusesPresentedAndLateTranscripts() throws {
        let f = fixture()
        let binding = try #require(f.setup.captureSelectedPrimaryTranscriptReviewBinding())
        #expect(f.state.isCurrentSelectedPrimaryTranscript(binding))
        f.state.presentSelectedPrimaryTranscript(f.input("Only episode A"), boundTo: binding)
        #expect(f.state.reviewState.presentation.occurrences.map(\.text) == ["Only episode A"])
        #expect(f.state.reviewState.presentation.occurrences[0].wordTiming == "Word timing unavailable")

        f.state.sidebarSelection = .episode(f.second.id)
        #expect(!f.state.isCurrentSelectedPrimaryTranscript(binding))
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
        #expect(f.state.reviewState.presentation.notice.contains("unavailable"))
        f.state.presentSelectedPrimaryTranscript(f.input("Late episode A"), boundTo: binding)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
        f.state.sidebarSelection = .episode(f.first.id)
        #expect(!f.state.isCurrentSelectedPrimaryTranscript(binding))
        f.state.presentSelectedPrimaryTranscript(f.input("Returned to A"), boundTo: binding)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
    }

    @Test func speakerChangeAndPrimaryReassignmentRefuse() throws {
        let f = fixture()
        let binding = try #require(f.setup.captureSelectedPrimaryTranscriptReviewBinding())
        f.state.presentSelectedPrimaryTranscript(f.input("Original"), boundTo: binding)
        f.setup.speakerSelection = []
        #expect(!f.state.isCurrentSelectedPrimaryTranscript(binding))
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
        f.setup.speakerSelection = [f.speaker.id]
        f.state.presentSelectedPrimaryTranscript(f.input("Old speaker capture"), boundTo: binding)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)

        let newer = try #require(f.setup.captureSelectedPrimaryTranscriptReviewBinding())
        f.state.presentSelectedPrimaryTranscript(f.input("New capture"), boundTo: newer)
        var changed = f.store.model
        changed.episodes[0].speakerAssignments[0].primary =
            ChannelReference(sourceID: f.secondSource.id, statedChannel: 0)
        f.store.replaceLoadedModel(changed)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
        f.state.presentSelectedPrimaryTranscript(f.input("Stale source"), boundTo: newer)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
    }

    @Test func equalModelUndoAndCloseCannotReanimateOldHandoff() throws {
        let f = fixture()
        let binding = try #require(f.setup.captureSelectedPrimaryTranscriptReviewBinding())
        let original = f.store.model
        var edited = original
        edited.episodes[0].speakerAssignments[0].primary = nil
        f.store.replaceLoadedModel(edited)
        f.store.replaceLoadedModel(original)
        #expect(!f.state.isCurrentSelectedPrimaryTranscript(binding))
        f.state.presentSelectedPrimaryTranscript(f.input("Late after undo"), boundTo: binding)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)

        let fresh = try #require(f.setup.captureSelectedPrimaryTranscriptReviewBinding())
        f.state.presentSelectedPrimaryTranscript(f.input("Wrong source", from: f.secondSource), boundTo: fresh)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
        f.state.reviewWindowDidClose()
        #expect(!f.state.isCurrentSelectedPrimaryTranscript(fresh))
        f.state.presentSelectedPrimaryTranscript(f.input("Late after close"), boundTo: fresh)
        #expect(f.state.reviewState.presentation.occurrences.isEmpty)
    }

    @Test func noSelectedOrUnconfirmedPrimaryCannotIssueBinding() {
        let f = fixture()
        f.setup.speakerSelection = []
        #expect(f.setup.captureSelectedPrimaryTranscriptReviewBinding() == nil)
        f.setup.speakerSelection = [f.speaker.id]
        var unconfirmed = f.store.model
        unconfirmed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        f.store.replaceLoadedModel(unconfirmed)
        #expect(f.setup.captureSelectedPrimaryTranscriptReviewBinding() == nil)

        var unknownChannel = f.store.model
        unknownChannel.episodes[0].speakerAssignments[0].primaryConfirmation = .userConfirmed
        unknownChannel.episodes[0].speakerAssignments[0].primary =
            ChannelReference(sourceID: f.firstSource.id, statedChannel: nil)
        f.store.replaceLoadedModel(unknownChannel)
        #expect(f.setup.captureSelectedPrimaryTranscriptReviewBinding() == nil)
    }

    @Test func unboundSyntheticFixtureNeverBecomesSuppliedEvidence() {
        let f = fixture()
        #expect(f.state.reviewState.presentation == .syntheticFixture)
        f.state.sidebarSelection = .episode(f.second.id)
        f.store.replaceLoadedModel(f.store.model)
        #expect(f.state.reviewState.presentation == .syntheticFixture)
    }

    @Test func everyPublishedModelHasANewGenerationIncludingEqualLoadsAndCoalescing() {
        let f = fixture()
        let initial = f.store.modelGeneration
        f.store.replaceLoadedModel(f.store.model)
        #expect(f.store.modelGeneration == initial + 1)
        let beforeEdit = f.store.modelGeneration
        #expect(f.store.apply("Rename", coalescing: "title") { model in
            var model = model
            model.show.title = "First title"
            return model
        })
        #expect(f.store.apply("Rename", coalescing: "title") { model in
            var model = model
            model.show.title = "Second title"
            return model
        })
        #expect(f.store.modelGeneration == beforeEdit + 2)
    }
}
