import SwiftUI
import WWCore
import WWOrganizer

/// Hook for the source UI lane: when set, the Setup destination hosts this view for the selected episode
/// (Sources outline + Speakers table per IA §4.3). Until then a clearly named placeholder is shown.
@MainActor
enum SetupSourcesContent {
    static var makeView: ((ShowDocumentStore, EpisodeID) -> AnyView)?
}

/// Setup destination: the Sources and Speakers container for one episode.
struct SetupContainerView: View {
    @Bindable var state: ShowWindowState
    let episode: Episode

    var body: some View {
        if let factory = SetupSourcesContent.makeView {
            factory(state.store, episode.id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        let speakers = state.store.model.speakers
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sources")
                            .wwFont(.title3)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(episode.sources.count)")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(episode.sources.count) sources")
                        Spacer()
                        Button("Import Sources…") {
                            CommandRouter.shared.importSources(nil)
                        }
                        .disabled(!state.canEdit)
                        .help("Import Sources… (⇧⌘I)")
                    }
                    Text("Recordings you add to “\(episode.title)” appear here, grouped by recorder. WaveWrangler adds references to your files and never moves, renames or changes them.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Organizing sources isn't available in this version yet.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sources")
                .accessibilityIdentifier("ww.setup.sources")

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speakers")
                            .wwFont(.title3)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(speakers.count)")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(speakers.count) speakers")
                    }
                    if speakers.isEmpty {
                        Text("No speakers yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(speakers) { speaker in
                            Text(speaker.name)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Speakers")
                .accessibilityIdentifier("ww.setup.speakers")
            }
            .wwFont(.body)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
