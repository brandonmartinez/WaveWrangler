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
                    .onSubmit(finishTitleEditing)
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
        .onChange(of: titleDraft) { _, newValue in applyTitleLive(newValue) }
        .onChange(of: store.model.show.title) { _, newValue in
            // Undo/redo or a reload changed the title; don't fight in-progress whitespace while typing.
            if Self.trimmed(titleDraft) != newValue { titleDraft = newValue }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { finishTitleEditing() }
        }
    }

    /// Applies every keystroke to the model (one coalesced "Rename Show" undo step per editing burst), so
    /// Save/autosave/Close/Quit never miss a typed title. An empty draft is not applied; the last
    /// non-empty title stays in the model and is restored when editing ends.
    private func applyTitleLive(_ draft: String) {
        let title = Self.trimmed(draft)
        guard !title.isEmpty, title != store.model.show.title else { return }
        store.apply("Rename Show", coalescing: "show-title") { model throws(DomainError) in try model.renamingShow(to: title) }
    }

    private func finishTitleEditing() {
        store.endCoalescing()
        titleDraft = store.model.show.title
    }

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
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
