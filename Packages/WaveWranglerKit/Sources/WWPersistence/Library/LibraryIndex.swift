import Foundation
import WWCore

/// Rebuildable derived lookup/search index over the canonical library (C2: disposable, outside canonical
/// data). Deleting it loses nothing: `build(from:)` recreates it from the library alone.
public struct LibraryIndex: Sendable, Equatable, Codable {
    public static let version = 1

    public struct Show: Sendable, Equatable, Codable {
        public let showID: ShowID
        public let displayName: String
        public let sortKey: String
        public let searchTokens: [String]
        public let collectionIDs: [CollectionID]
        public let isUnavailable: Bool
    }

    public let version: Int
    /// Digest of the canonical library bytes this index was built from (staleness check).
    public let libraryDigest: String
    public let shows: [Show]
    public let showsByCollection: [CollectionID: [ShowID]]

    public static func build(from library: LibraryModel, libraryDigest: String) -> LibraryIndex {
        var membership: [ShowID: [CollectionID]] = [:]
        var byCollection: [CollectionID: [ShowID]] = [:]
        for collection in library.collections {
            byCollection[collection.id] = collection.showIDs
            for showID in collection.showIDs { membership[showID, default: []].append(collection.id) }
        }
        let shows = library.entries.map { entry in
            let name = entry.alias ?? entry.lastKnownTitle
            let tokens = Set(([entry.lastKnownTitle] + (entry.alias.map { [$0] } ?? []))
                .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) })
            return Show(
                showID: entry.showID, displayName: name,
                sortKey: name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                searchTokens: tokens.sorted(), collectionIDs: membership[entry.showID] ?? [],
                isUnavailable: entry.unavailable != nil
            )
        }
        .sorted { ($0.sortKey, $0.showID.rawValue.uuidString) < ($1.sortKey, $1.showID.rawValue.uuidString) }
        return LibraryIndex(version: version, libraryDigest: libraryDigest, shows: shows, showsByCollection: byCollection)
    }

    public func search(_ text: String) -> [ShowID] {
        let needles = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !needles.isEmpty else { return shows.map(\.showID) }
        return shows.filter { show in needles.allSatisfy { needle in show.searchTokens.contains { $0.hasPrefix(needle) } } }.map(\.showID)
    }
}

/// Disk cache for `LibraryIndex` under Caches. Missing, stale or damaged caches are simply rebuilt.
public struct LibraryIndexCache: Sendable {
    public let url: URL
    private let ops: any FileOperations

    public init(url: URL, ops: any FileOperations = LocalFileOperations()) {
        self.url = url
        self.ops = ops
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WaveWrangler/LibraryIndex/index.json")
    }

    /// The cached index if it was built from exactly `libraryDigest`; otherwise rebuilds and stores it.
    public func index(for library: LibraryModel, libraryDigest: String) -> (index: LibraryIndex, rebuilt: Bool) {
        if let data = try? ops.read(url), let cached = try? JSONDecoder().decode(LibraryIndex.self, from: data),
           cached.version == LibraryIndex.version, cached.libraryDigest == libraryDigest {
            return (cached, false)
        }
        let index = LibraryIndex.build(from: library, libraryDigest: libraryDigest)
        try? store(index)
        return (index, true)
    }

    public func store(_ index: LibraryIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(index)
        let directory = url.deletingLastPathComponent()
        try ops.createDirectory(directory)
        let staged = directory.appending(path: ".index-\(UUID().uuidString)")
        try ops.writeNew(data, to: staged)
        try ops.replace(url, withStaged: staged)
    }

    /// Deletes the derived cache (safe at any time).
    public func invalidate() {
        if ops.exists(url) { try? ops.remove(url) }
    }
}
