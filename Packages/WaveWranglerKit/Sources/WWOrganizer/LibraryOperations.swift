import Foundation
import WWCore

/// Why a library operation refused to produce a new value.
public enum LibraryError: Error, Sendable, Equatable {
    case emptyName
    case collectionNotFound(CollectionID)
    case duplicateCollection(CollectionID)
    case entryNotFound(ShowID)
}

/// Pure, validated library operations (collections, recents, removal). Each returns a new value or throws
/// without partial mutation; the Library window registers undo with the user-facing name.
///
/// Removing anything from the library or from a collection never deletes a show file or its episodes.
extension LibraryModel {
    public static let recentLimit = 20

    public func entry(_ id: ShowID) -> LibraryShowEntry? {
        entries.first { $0.showID == id }
    }

    public func collection(_ id: CollectionID) -> LibraryCollection? {
        collections.first { $0.id == id }
    }

    public func addingCollection(_ collection: LibraryCollection) throws(LibraryError) -> LibraryModel {
        guard self.collection(collection.id) == nil else { throw .duplicateCollection(collection.id) }
        let name = try Self.validatedName(collection.name)
        let unknown = collection.showIDs.first { entry($0) == nil }
        if let unknown { throw .entryNotFound(unknown) }
        var copy = self
        var added = collection
        added.name = name
        copy.collections.append(added)
        return copy
    }

    public func renamingCollection(_ id: CollectionID, to name: String) throws(LibraryError) -> LibraryModel {
        let trimmed = try Self.validatedName(name)
        return try updatingCollection(id) { $0.name = trimmed }
    }

    /// Deletes the collection only; its member shows stay in the library.
    public func deletingCollection(_ id: CollectionID) throws(LibraryError) -> LibraryModel {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { throw .collectionNotFound(id) }
        var copy = self
        copy.collections.remove(at: index)
        return copy
    }

    public func canMoveCollection(_ id: CollectionID, by offset: Int) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        return collections.indices.contains(index + offset) && offset != 0
    }

    /// Move Up (−1) / Move Down (+1). At the list edge the value is returned unchanged.
    public func movingCollection(_ id: CollectionID, by offset: Int) throws(LibraryError) -> LibraryModel {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { throw .collectionNotFound(id) }
        let target = index + offset
        guard collections.indices.contains(target), target != index else { return self }
        var copy = self
        let moved = copy.collections.remove(at: index)
        copy.collections.insert(moved, at: target)
        return copy
    }

    /// Drag reorder with SwiftUI `onMove` semantics (`destination` is an index in the original array).
    public func movingCollections(fromOffsets source: IndexSet, toOffset destination: Int) -> LibraryModel {
        var copy = self
        copy.collections = Self.moving(collections, fromOffsets: source, toOffset: destination)
        return copy
    }

    /// Adds shows to a collection, skipping shows that are already members; order is kept.
    public func addingShows(_ ids: [ShowID], toCollection collectionID: CollectionID) throws(LibraryError) -> LibraryModel {
        if let unknown = ids.first(where: { entry($0) == nil }) { throw .entryNotFound(unknown) }
        return try updatingCollection(collectionID) { collection in
            for id in ids where !collection.showIDs.contains(id) {
                collection.showIDs.append(id)
            }
        }
    }

    public func removingShows(_ ids: [ShowID], fromCollection collectionID: CollectionID) throws(LibraryError) -> LibraryModel {
        try updatingCollection(collectionID) { collection in
            collection.showIDs.removeAll { ids.contains($0) }
        }
    }

    public func movingShow(_ id: ShowID, inCollection collectionID: CollectionID, by offset: Int) throws(LibraryError) -> LibraryModel {
        try updatingCollection(collectionID) { collection in
            guard let index = collection.showIDs.firstIndex(of: id) else { return }
            let target = index + offset
            guard collection.showIDs.indices.contains(target) else { return }
            collection.showIDs.swapAt(index, target)
        }
    }

    /// Remove from Library: removes the entries and their collection/recent references. The show files are
    /// untouched and can be added again with File › Open.
    public func removingEntries(_ ids: [ShowID]) throws(LibraryError) -> LibraryModel {
        if let unknown = ids.first(where: { entry($0) == nil }) { throw .entryNotFound(unknown) }
        let removed = Set(ids)
        var copy = self
        copy.entries.removeAll { removed.contains($0.showID) }
        for index in copy.collections.indices {
            copy.collections[index].showIDs.removeAll { removed.contains($0) }
        }
        copy.recentShowIDs.removeAll { removed.contains($0) }
        return copy
    }

    /// Adds a library entry for a show, or refreshes its last-known title. Clears a recorded unavailable
    /// note because the show was just reached.
    public func upsertingEntry(showID: ShowID, title: String) -> LibraryModel {
        var copy = self
        if let index = copy.entries.firstIndex(where: { $0.showID == showID }) {
            copy.entries[index].lastKnownTitle = title
            copy.entries[index].unavailable = nil
        } else {
            copy.entries.append(LibraryShowEntry(showID: showID, lastKnownTitle: title))
        }
        return copy
    }

    /// Records a show as most recently opened (newest first, bounded).
    public func recordingOpened(_ id: ShowID, limit: Int = LibraryModel.recentLimit) -> LibraryModel {
        var copy = self
        copy.recentShowIDs.removeAll { $0 == id }
        copy.recentShowIDs.insert(id, at: 0)
        if copy.recentShowIDs.count > limit {
            copy.recentShowIDs.removeLast(copy.recentShowIDs.count - limit)
        }
        return copy
    }

    // MARK: - Helpers

    private func updatingCollection(
        _ id: CollectionID,
        _ transform: (inout LibraryCollection) -> Void
    ) throws(LibraryError) -> LibraryModel {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { throw .collectionNotFound(id) }
        var copy = self
        transform(&copy.collections[index])
        return copy
    }

    private static func validatedName(_ name: String) throws(LibraryError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        return trimmed
    }

    static func moving<Element>(_ array: [Element], fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let valid = source.filter { array.indices.contains($0) }
        guard !valid.isEmpty else { return array }
        let moved = valid.map { array[$0] }
        var remaining: [Element] = []
        var insertion = 0
        for (index, element) in array.enumerated() {
            if index == destination { insertion = remaining.count }
            if !valid.contains(index) { remaining.append(element) }
        }
        if destination >= array.count { insertion = remaining.count }
        remaining.insert(contentsOf: moved, at: insertion)
        return remaining
    }
}
