import SwiftUI
import WWCore
import WWOrganizer

/// Setup destination: the Sources and Speakers container for one episode.
struct SetupContainerView: View {
    @Bindable var state: ShowWindowState
    let episode: Episode
    @Environment(\.wwTextSize) private var textSize

    var body: some View {
        EpisodeSetupContent(
            store: state.store, episodeID: episode.id, textScale: CGFloat(textSize.scale)
        )
        .id(episode.id)
    }
}
