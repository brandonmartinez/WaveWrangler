import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WWCore

/// Publication properties share the existing document store, including live saves and named undo bursts.
struct PublicationInspector: View {
    let store: ShowDocumentStore
    var episodeID: EpisodeID?
    @State private var expanded = false
    @State private var choosingArtwork = false
    @State private var importing = false
    @State private var error: String?

    private var episode: Episode? { episodeID.flatMap { store.residentModel.episode($0) } }
    private var metadata: PublicationMetadata {
        if episodeID != nil { return episode?.publication?.metadata ?? .init() }
        return store.residentModel.show.publication ?? .init()
    }
    private var defaults: PublicationMetadata { store.residentModel.show.publication ?? .init() }
    private var effective: PublicationMetadata {
        episodeID == nil ? metadata : metadata.inheriting(from: defaults)
    }
    private var artwork: PublicationArtwork? { effective.artwork?.image }

    var body: some View {
        DisclosureGroup("Publication", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(episodeID == nil
                     ? "Defaults for episodes and exports. Notes stay private."
                     : "Title is the track title; show title is the album. Notes stay private.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                textField(.publicDescription)
                if episodeID != nil {
                    EpisodePublicationDetails(store: store, episodeID: episodeID)
                }
                explicitContent
                artworkEditor
                if episodeID != nil {
                    DisclosureGroup("Override Show Defaults") { inheritedFields }
                } else {
                    inheritedFields
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("publication.error")
                }
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier(episodeID == nil ? "publication.show" : "publication.episode")
        .onDisappear { store.endCoalescing() }
        .fileImporter(isPresented: $choosingArtwork, allowedContentTypes: [.jpeg, .png]) { result in
            switch result {
            case .success(let url): importArtwork(url)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private var inheritedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            textField(.creator)
            textField(.publisher)
            textField(.copyright)
            textField(.genre)
            textField(.language)
            textField(.website)
        }
        .padding(.top, 4)
    }

    private func textField(_ field: PublicationTextProperty) -> some View {
        PublicationTextEditor(
            field: field, value: metadata[keyPath: field.path],
            inherited: episodeID == nil ? nil : defaults[keyPath: field.path],
            allowsInheritance: episodeID != nil,
            endEditing: { store.endCoalescing(); error = nil },
            apply: { value in
                change(coalescing: "publication.\(episodeID?.description ?? "show").\(field.rawValue)") {
                    $0[keyPath: field.path] = value
                }
            })
    }

    private var explicitContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Content", selection: Binding(
                get: { metadata.explicitContent.map { $0 ? 1 : 0 } ?? -1 },
                set: { value in
                    change { $0.explicitContent = value == -1 ? nil : value == 1 }
                }
            )) {
                Text(episodeID == nil ? "Not specified" : "Use Show Default").tag(-1)
                Text("Clean").tag(0)
                Text("Explicit").tag(1)
            }
            .accessibilityIdentifier("publication.explicitContent")
            if episodeID != nil, metadata.explicitContent == nil {
                Text("Show default: \(defaults.explicitContent.map { $0 ? "Explicit" : "Clean" } ?? "Not specified")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Artwork")
            if let artwork, let image = NSImage(data: artwork.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                    .accessibilityLabel("Publication artwork")
                Text("\(artwork.pixelWidth) × \(artwork.pixelHeight) pixels")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No artwork").font(.caption).foregroundStyle(.secondary)
            }
            if episodeID != nil, metadata.artwork == nil {
                Text("Inherited from show").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Image...") { choosingArtwork = true }
                    .accessibilityIdentifier("publication.chooseArtwork")
                if artwork != nil || (episodeID != nil && metadata.artwork == nil) {
                    Button(artwork == nil ? "Omit Artwork" : "Remove") {
                        change { $0.artwork = PublicationArtworkSelection.none }
                    }
                        .accessibilityIdentifier("publication.removeArtwork")
                }
            }
            if episodeID != nil, metadata.artwork != nil {
                Button("Use Show Artwork") { change { $0.artwork = nil } }
                    .accessibilityIdentifier("publication.inheritArtwork")
            }
            Text("JPEG or PNG, up to 10 MB and 4,096 pixels per side. Original bytes are copied into the show.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if importing { ProgressView("Importing artwork").controlSize(.small) }
        }
        .disabled(importing)
    }

    @discardableResult
    private func change(coalescing: String? = nil, _ update: (inout PublicationMetadata) -> Void) -> Bool {
        var next = metadata
        update(&next)
        let applied = store.apply("Edit Publication Metadata", coalescing: coalescing) { model throws(DomainError) in
            if let episodeID {
                guard let episode = model.episode(episodeID) else { throw .episodeNotFound(episodeID) }
                var publication = episode.publication ?? .init()
                publication.metadata = next
                return try model.settingEpisodePublication(publication, for: episodeID)
            }
            return try model.settingShowPublication(next)
        }
        error = applied ? nil : store.lastError.map(EpisodeSetupModel.describe)
        return applied
    }

    private func importArtwork(_ url: URL) {
        importing = true
        error = nil
        Task { @MainActor in
            defer { importing = false }
            do {
                let artwork = try await PublicationArtworkImport.read(url)
                // Apply only the artwork field to the current value, preserving intervening window edits.
                change { $0.artwork = .image(artwork) }
            } catch {
                self.error = (error as? DomainError).map(EpisodeSetupModel.describe) ?? error.localizedDescription
            }
        }
    }
}

enum PublicationArtworkImport {
    @concurrent static func read(_ url: URL) async throws -> PublicationArtwork {
        guard url.isFileURL else {
            throw DomainError.invalidPublication("Choose a local JPEG or PNG file.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= PublicationArtwork.maximumBytes {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: min(1_048_576, PublicationArtwork.maximumBytes + 1 - bytes.count)),
                  !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        try Task.checkCancellation()
        return try PublicationArtwork(data: bytes)
    }
}

private enum PublicationTextProperty: String {
    case creator, publisher, publicDescription, copyright, genre, language, website

    var title: String {
        switch self {
        case .creator: "Creator / artist"
        case .publisher: "Publisher"
        case .publicDescription: "Public description"
        case .copyright: "Copyright"
        case .genre: "Genre"
        case .language: "Language"
        case .website: "Website"
        }
    }

    var path: WritableKeyPath<PublicationMetadata, String?> {
        switch self {
        case .creator: \.creator
        case .publisher: \.publisher
        case .publicDescription: \.publicDescription
        case .copyright: \.copyright
        case .genre: \.genre
        case .language: \.language
        case .website: \.website
        }
    }
}

private struct PublicationTextEditor: View {
    let field: PublicationTextProperty
    let value: String?
    let inherited: String?
    let allowsInheritance: Bool
    let endEditing: () -> Void
    let apply: (String?) -> Bool
    @State private var draft = ""
    @State private var applied: String?
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.title)
                Spacer()
                if allowsInheritance, value != nil {
                    Button("Inherit") {
                        if apply(nil) { reload() }
                    }
                    .font(.caption)
                    .accessibilityLabel("Inherit \(field.title) from show")
                }
                if allowsInheritance, value == nil {
                    Button("Omit") {
                        if apply("") { reload() }
                    }
                    .font(.caption)
                    .accessibilityLabel("Omit \(field.title) in this episode")
                }
            }
            if field == .publicDescription {
                TextEditor(text: $draft)
                    .frame(minHeight: 70).scrollContentBackground(.hidden).padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .focused($focused)
                    .accessibilityLabel(field.title)
                    .accessibilityIdentifier("publication.\(field.rawValue)")
            } else {
                TextField(field == .language ? "en-US" : field == .website ? "https://example.com" : field.title, text: $draft)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel(field.title)
                    .accessibilityIdentifier("publication.\(field.rawValue)")
            }
            if allowsInheritance {
                Text(value == nil ? "Inherited from show" : draft.isEmpty ? "Omitted in this episode" : "Episode override")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if invalid {
                Text("This value has not been saved. Correct it or leave the field to restore the saved value.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: draft) { _, text in
            guard focused else { return }
            guard text != (value ?? inherited ?? "") else { return }
            invalid = !apply(text)
            if !invalid { applied = text }
        }
        .onChange(of: value) { _, value in
            if !focused || value != applied { reload() }
        }
        .onChange(of: inherited) { _, _ in
            if value == nil { reload() }
        }
        .onChange(of: focused) { _, focused in
            if !focused { endEditing(); reload() }
        }
        .onDisappear(perform: endEditing)
    }

    private func reload() {
        draft = value ?? inherited ?? ""
        applied = value
        invalid = false
    }
}

private struct EpisodePublicationDetails: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID?
    @State private var seasonDraft = ""
    @State private var seasonError: String?
    @FocusState private var seasonFocused: Bool

    private var episode: Episode? { episodeID.flatMap { store.residentModel.episode($0) } }

    var body: some View {
        if let episode {
            VStack(alignment: .leading, spacing: 5) {
                Text("Season")
                TextField("Optional season number", text: $seasonDraft)
                    .textFieldStyle(.roundedBorder).focused($seasonFocused)
                    .accessibilityIdentifier("publication.season")
                if let seasonError {
                    Label(seasonError, systemImage: "exclamationmark.triangle").font(.caption)
                }
                Picker("Episode type", selection: Binding(
                    get: { episode.publication?.episodeType?.rawValue ?? "" },
                    set: { value in
                        update { $0.episodeType = PublicationEpisodeType(rawValue: value) }
                    })) {
                    Text("Not specified").tag("")
                    ForEach(PublicationEpisodeType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type.rawValue)
                    }
                }
                .accessibilityIdentifier("publication.episodeType")
                Text("Publication date")
                if let day = episode.publishedOn, let date = DayConversion.date(from: day) {
                    DatePicker("Publication date", selection: Binding(
                        get: { date }, set: { setDate(DayConversion.day(from: $0)) }), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden()
                        .accessibilityIdentifier("publication.date")
                    Button("Remove Publication Date") { setDate(nil) }
                } else {
                    Button("Set Publication Date") { setDate(DayConversion.day(from: Date())) }
                }
                Text("A date does not change the episode's published status.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { seasonDraft = episode.publication?.season.map(String.init) ?? "" }
            .onChange(of: seasonDraft) { _, value in
                guard seasonFocused else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty || Int(trimmed).map({ $0 > 0 }) == true else {
                    seasonError = "Enter a whole number of 1 or more, or leave empty."
                    return
                }
                update(coalescing: "publication.season.\(episode.id)") { $0.season = Int(trimmed) }
            }
            .onChange(of: episode.publication?.season) { _, season in
                seasonDraft = season.map(String.init) ?? ""
            }
            .onChange(of: seasonFocused) { _, focused in
                if !focused {
                    store.endCoalescing()
                    seasonDraft = episode.publication?.season.map(String.init) ?? ""
                    seasonError = nil
                }
            }
        }
    }

    private func update(coalescing: String? = nil, _ change: (inout EpisodePublication) -> Void) {
        guard let episode else { return }
        var next = episode.publication ?? .init()
        change(&next)
        let applied = store.apply("Edit Episode Publication", coalescing: coalescing) { model throws(DomainError) in
            try model.settingEpisodePublication(next, for: episode.id)
        }
        seasonError = applied ? nil : store.lastError.map(EpisodeSetupModel.describe)
    }

    private func setDate(_ day: CalendarDay?) {
        guard let episode else { return }
        let applied = store.apply("Edit Publication Date") { model throws(DomainError) in
            try model.settingEpisodePublishedOn(day, for: episode.id)
        }
        seasonError = applied ? nil : store.lastError.map(EpisodeSetupModel.describe)
    }
}
