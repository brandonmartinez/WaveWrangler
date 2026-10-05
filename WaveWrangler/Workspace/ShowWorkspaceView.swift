import SwiftUI
import WWCore

/// Placeholder episode workspace: editable show title and an episode list with add/remove.
/// The library/workspace UI owner replaces this with the real sidebar/workspace.
struct ShowWorkspaceView: View {
    let store: ShowDocumentStore

    @State private var titleDraft = ""
    @State private var selection: EpisodeID?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Show title") {
                TextField("Show title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
            }

            Text("Episodes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            List(store.model.episodes, selection: $selection) { episode in
                EpisodeRow(episode: episode)
            }
            .accessibilityLabel("Episodes")
            .overlay {
                if store.model.episodes.isEmpty {
                    ContentUnavailableView("No Episodes", systemImage: "list.bullet", description: Text("Add an episode to get started."))
                }
            }

            HStack {
                Button("Add Episode", systemImage: "plus", action: addEpisode)
                Button("Remove Episode", systemImage: "minus", action: removeSelectedEpisode)
                    .disabled(selection == nil)
                Spacer()
            }

            if let error = store.lastError {
                Text(Self.message(for: error))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Change not applied: \(Self.message(for: error))")
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { titleDraft = store.model.show.title }
        .onChange(of: store.model.show.title) { _, newValue in
            if !titleFocused { titleDraft = newValue }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
    }

    private func commitTitle() {
        guard titleDraft != store.model.show.title else { return }
        if !store.apply("Rename Show", { model throws(DomainError) in try model.renamingShow(to: titleDraft) }) {
            titleDraft = store.model.show.title
        }
    }

    private func addEpisode() {
        let number = (store.model.episodes.compactMap(\.number).max() ?? 0) + 1
        let episode = Episode(title: "Episode \(number)", number: number)
        if store.apply("Add Episode", { model throws(DomainError) in try model.addingEpisode(episode) }) {
            selection = episode.id
        }
    }

    private func removeSelectedEpisode() {
        guard let id = selection else { return }
        if store.apply("Remove Episode", { model throws(DomainError) in try model.removingEpisode(id) }) {
            selection = nil
        }
    }

    private static func message(for error: DomainError) -> String {
        switch error {
        case .emptyTitle: "A title can’t be empty."
        default: "The change could not be applied (\(error))."
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack {
            if let number = episode.number {
                Text("\(number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(episode.title)
            Spacer()
            Text(episode.status.rawValue.capitalized)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
