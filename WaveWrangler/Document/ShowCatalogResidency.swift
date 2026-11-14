import Foundation
import WWCore
import WWPersistence

/// One immutable logical revision. Residency may change without changing its identity or Undo value.
@MainActor
final class ShowEpisodeRevision {
    let summary: CatalogEpisodeSummary
    let validationHeader: ShowCatalogHeader
    private enum Storage {
        case resident(Episode, archive: StoredCatalogEpisode?)
        case stored(StoredCatalogEpisode)
    }
    private var storage: Storage

    init(_ episode: Episode, header: ShowCatalogHeader) {
        summary = CatalogEpisodeSummary(episode)
        validationHeader = header
        storage = .resident(episode, archive: nil)
    }

    init(_ episode: StoredCatalogEpisode, header: ShowCatalogHeader) {
        summary = episode.summary
        validationHeader = header
        storage = .stored(episode)
    }

    var resident: Episode? {
        if case .resident(let episode, _) = storage { return episode }
        return nil
    }

    var archived: StoredCatalogEpisode? {
        switch storage {
        case .resident(_, let archive): archive
        case .stored(let archive): archive
        }
    }

    var captured: ShowCatalogDraft.EpisodePayload {
        switch storage {
        case .stored(let record), .resident(_, .some(let record)): .stored(record)
        case .resident(let episode, nil): .resident(episode)
        }
    }

    func loaded(_ episode: Episode) { storage = .resident(episode, archive: archived) }
    func archived(_ record: StoredCatalogEpisode) {
        storage = resident.map { .resident($0, archive: record) } ?? .stored(record)
    }
    func evict() {
        if let archived { storage = .stored(archived) }
    }
}

@MainActor
struct ShowCatalogRevision {
    let identity: UUID
    var header: ShowCatalogHeader
    var episodes: [ShowEpisodeRevision]

    init(model: ShowDocumentModel) {
        identity = UUID()
        header = ShowCatalogHeader(model)
        let header = self.header
        episodes = model.episodes.map { ShowEpisodeRevision($0, header: header) }
    }

    init(catalog: ShowCatalog) {
        identity = UUID()
        header = catalog.header
        let header = self.header
        episodes = catalog.episodes.map { ShowEpisodeRevision($0, header: header) }
    }

    init(header: ShowCatalogHeader, episodes: [ShowEpisodeRevision]) {
        identity = UUID()
        self.header = header
        self.episodes = episodes
    }

    var residentModel: ShowDocumentModel {
        header.operationModel(episodes: episodes.compactMap(\.resident))
    }

    func captured(archiveOwner: ShowCatalog?) -> ShowCatalogDraft {
        ShowCatalogDraft(header: header, episodes: episodes.map(\.captured), archiveOwner: archiveOwner)
    }
}

/// Shares admission with native publication; a load never claims another unbounded worker pool.
enum ShowCatalogWork {
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            ShowPersistenceLane.enqueue {
                continuation.resume(with: Result(catching: operation))
            }
        }
        try Task.checkCancellation()
        return value
    }
}
