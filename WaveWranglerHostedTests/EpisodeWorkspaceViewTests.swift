import Foundation
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Saved episode workspace views", .serialized)
struct EpisodeWorkspaceViewTests {
    @Test func viewRestoresAcrossNewStatesWithoutEditingTheDocument() throws {
        let episode = Episode(title: "One")
        let other = Episode(title: "Two")
        let model = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode, other])
        let store = ShowDocumentStore(model: model)
        let state = ShowWindowState(store: store, episodeID: episode.id)
        let listening = state.listeningState(for: episode.id)
        var view = listening.workspace
        view.layout = .speakersOnly
        view.normalizeView = true
        view.showProposedAlignment = false
        view.laneHeight = 172
        view.startSeconds = -2.5
        view.durationSeconds = 12
        view.playheadSeconds = 3.25
        view.trackScrollOffset = 220
        view.collapsedSpeakers = [SpeakerID()]
        view.collapsedRecorders = [RecorderGroupID()]
        listening.workspace = view
        state.workspaceInspector = .transcript
        state.recordingsPresented = true
        state.inspectorPresented = false
        let saved = listening.workspace
        let reopened = ShowWindowState(store: ShowDocumentStore(model: model), episodeID: episode.id)
        #expect(reopened.listeningState(for: episode.id).workspace == saved)
        #expect(reopened.workspaceInspector == .transcript && !reopened.inspectorPresented && reopened.recordingsPresented)
        #expect(reopened.listeningState(for: episode.id).playback == .init(), "Saved views do not restore an old Solo/Mute mix")
        #expect(reopened.listeningState(for: other.id).workspace == EpisodeWorkspaceViewState())
        #expect(store.model == model && store.modelGeneration == 0, "View changes are not document edits or Undo entries")
        let differentShow = ShowWindowState(store: ShowDocumentStore(model: ShowDocumentModel(
            show: Show(title: "Different"), episodes: [episode])), episodeID: episode.id)
        #expect(differentShow.listeningState(for: episode.id).workspace == EpisodeWorkspaceViewState())
    }

    @Test func invalidViewsCannotOverwriteTheLastValidView() throws {
        let name = "WaveWrangler-WorkspaceViewTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defer { EpisodeWorkspaceViewStore.flushPending() }
        let store = EpisodeWorkspaceViewStore(defaults: defaults, show: ShowID(), episode: EpisodeID(), namespace: name)
        #expect(store.load() == nil)
        var view = EpisodeWorkspaceViewState()
        view.layout = .overlay
        view.startSeconds = 10
        store.save(view)
        var invalid = view
        invalid.durationSeconds = .nan
        store.save(invalid)
        #expect(store.load() == view)
        invalid = view
        invalid.trackScrollOffset = -.infinity
        store.save(invalid)
        #expect(store.load() == view)
    }

    @Test func navigationWritesAreCoalescedAndTheLatestViewIsAvailableImmediately() throws {
        let name = "WaveWrangler-WorkspaceViewTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let show = ShowID(), episode = EpisodeID()
        let store = EpisodeWorkspaceViewStore(defaults: defaults, show: show, episode: episode, namespace: name)
        var view = EpisodeWorkspaceViewState()
        for position in 0..<1_000 {
            view.startSeconds = Double(position) / 10
            store.save(view)
        }
        #expect(defaults.data(forKey: "WWEpisodeWorkspaceView.v1.\(show).\(episode)") == nil,
                "A synchronous navigation burst performs no JSON encoding or preference writes")
        let reopened = EpisodeWorkspaceViewStore(defaults: try #require(UserDefaults(suiteName: name)),
            show: show, episode: episode, namespace: name)
        #expect(reopened.load() == view, "Immediate reopening sees pending navigation, not an older disk value")
        EpisodeWorkspaceViewStore.flushPending()
        #expect(defaults.data(forKey: "WWEpisodeWorkspaceView.v1.\(show).\(episode)") != nil)
        #expect(reopened.load() == view)
    }
}
