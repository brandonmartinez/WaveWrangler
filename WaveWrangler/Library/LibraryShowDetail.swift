import SwiftUI
import WWCore

struct LibraryShowDetail: View {
    @Bindable var state: LibraryWindowState
    @Bindable var show: ShowWindowState

    var body: some View {
        VStack(spacing: 0) {
            ShowMessageBar(state: show)
            if let message = state.actionMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .padding()
            }
            HStack {
                Text(show.store.model.show.title)
                    .wwFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .lineLimit(2)
                Spacer()
                SaveStatusItem(state: show)
            }
            .padding()
            LibraryEpisodeList(state: show) { state.openEpisode($0) }
                .frame(minHeight: 120)
            HStack {
                Button("Open Episode", systemImage: "arrow.up.forward.square") { state.openSelectedEpisode() }
                    .disabled(show.selectedEpisode == nil)
                    .keyboardShortcut(state.focusedRegion == .episodes ? .defaultAction : nil)
                    .accessibilityIdentifier("ww.library.episode.open")
                Spacer()
                Button("Show in Finder") { state.revealSelectedInFinder() }
                    .disabled(!state.store.services.entries.canRevealShow(show.store.model.show.id))
            }
            .padding()
            Divider()
            ScrollView {
                Group {
                    if show.sidebarSelection == .showInfo {
                        ShowInfoInspector(state: show)
                    } else if let episode = show.selectedEpisode {
                        EpisodeInspector(state: show, episodeID: episode.id)
                            .id(episode.id)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .wwFont(.body)
        .simultaneousGesture(TapGesture().onEnded { state.focusedRegion = .episodes })
        .onChange(of: show.episodeListFocused) { _, focused in
            if focused { state.focusedRegion = .episodes }
        }
        .onChange(of: show.store.model.episodes.map(\.id)) { old, _ in
            show.reconcileSelection(previousOrder: old)
        }
        .onChange(of: show.saveStatus.state) { old, new in
            show.saveStateDidChange(from: old, to: new)
        }
    }
}
