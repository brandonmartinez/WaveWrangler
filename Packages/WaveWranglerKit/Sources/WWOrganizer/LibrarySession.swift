import Foundation
import WWCore

/// Pure state machine behind the Library window's store (review fixes for P6 ordering and IA-08):
///
/// - Nothing is persisted until the canonical library has loaded, never after a failed load, and never
///   while the library is read-only (L4 conflict, L5 newer format).
/// - Bookkeeping (a show was opened, a coherent save confirmed its title) that arrives before the library
///   is loaded or while it is read-only is queued and applied once edits are allowed — it never replaces
///   the stored library with an empty one.
/// - Undo/redo apply the *difference* an action made, so entries and recents added in between (e.g. a
///   show opened after a collection was deleted) survive undo.
public struct LibrarySession: Sendable, Equatable {
    public enum LoadState: Sendable, Equatable {
        case notLoaded
        case loaded
        case failed(reason: String)
    }

    public enum Bookkeeping: Sendable, Equatable {
        /// A show window opened: make it most recent. `confirmedTitle` is the last coherently saved title
        /// (nil when the open document has unsaved edits); it refreshes the entry's title. An entry that
        /// doesn't exist yet is added with `provisionalTitle` so the show is never dropped.
        case opened(ShowID, confirmedTitle: String?, provisionalTitle: String)
        /// A coherent save (D1) confirmed the show's current title.
        case confirmedTitle(ShowID, title: String)
    }

    /// What a reorder edit moved, so the move is applied as "these items moved by n" and never forces other
    /// items into the edit's order (which would overwrite a concurrent reorder elsewhere).
    public struct MoveIntent: Sendable, Equatable {
        public var collections: Set<CollectionID>
        public var shows: [CollectionID: Set<ShowID>]

        public init(collections: Set<CollectionID> = [], shows: [CollectionID: Set<ShowID>] = [:]) {
            self.collections = collections
            self.shows = shows
        }

        public static let none = MoveIntent()
    }

    /// One undoable library edit: the library before and after the action itself.
    public struct Change: Sendable, Equatable {
        public var before: LibraryModel
        public var after: LibraryModel
        public var moved: MoveIntent = .none

        /// Applies this edit to `model` (redo / storage transform).
        public func apply(to model: LibraryModel) -> LibraryModel {
            model.applyingDifference(from: before, to: after, moved: moved)
        }

        /// Reverts this edit on `model` (undo).
        public func revert(on model: LibraryModel) -> LibraryModel {
            model.applyingDifference(from: after, to: before, moved: moved)
        }
    }

    public enum EditRefusal: Error, Sendable, Equatable {
        case notLoaded
        case loadFailed(String)
        case readOnly
        case invalid(LibraryError)
    }

    public private(set) var library = LibraryModel()
    public private(set) var loadState = LoadState.notLoaded
    public private(set) var queued: [Bookkeeping] = []

    public init() {}

    public var isLoaded: Bool { loadState == .loaded }

    /// Whether the current value may be written to canonical storage.
    public func canPersist(allowsEdits: Bool) -> Bool { isLoaded && allowsEdits }

    // MARK: - Loading

    /// Adopts the loaded library and applies queued bookkeeping (if edits are allowed). Returns `true`
    /// when the value changed and should be persisted.
    public mutating func didLoad(_ model: LibraryModel, allowsEdits: Bool) -> Bool {
        library = model
        loadState = .loaded
        return flush(allowsEdits: allowsEdits)
    }

    public mutating func didFailLoad(reason: String) {
        loadState = .failed(reason: reason)
    }

    // MARK: - Bookkeeping (not undoable)

    /// Records bookkeeping; returns `true` when it was applied and changed the library (persist then).
    public mutating func record(_ item: Bookkeeping, allowsEdits: Bool) -> Bool {
        queued.append(item)
        return flush(allowsEdits: allowsEdits)
    }

    /// Items applied by the most recent successful `flush`, so storage can apply the same bookkeeping to
    /// its canonical value (never a whole-library snapshot).
    public private(set) var lastFlushed: [Bookkeeping] = []

    /// Applies queued bookkeeping when loaded and editable. Returns `true` if the library changed.
    public mutating func flush(allowsEdits: Bool) -> Bool {
        lastFlushed = []
        guard isLoaded, allowsEdits, !queued.isEmpty else { return false }
        let original = library
        library = Self.applying(queued, to: library)
        lastFlushed = queued
        queued.removeAll()
        return library != original
    }

    /// Pure application of bookkeeping items (used for the session and for canonical storage).
    public static func applying(_ items: [Bookkeeping], to model: LibraryModel) -> LibraryModel {
        var library = model
        for item in items {
            switch item {
            case let .opened(id, confirmed, provisional):
                if let confirmed {
                    library = library.upsertingEntry(showID: id, title: confirmed)
                } else if library.entry(id) == nil {
                    library = library.upsertingEntry(showID: id, title: provisional)
                }
                library = library.recordingOpened(id)
            case let .confirmedTitle(id, title):
                if library.entry(id) != nil { library = library.upsertingEntry(showID: id, title: title) }
            }
        }
        return library
    }

    /// Adopts the canonical value after storage applied an edit, or when it changed elsewhere (another
    /// Mac, persistence acknowledging a verified show save). Ignored until loaded.
    public mutating func adoptCanonical(_ model: LibraryModel) {
        guard isLoaded else { return }
        library = model
    }

    // MARK: - Undoable edits

    /// Applies a user edit. Returns the change to register for undo (`nil` when nothing changed).
    public mutating func apply(
        allowsEdits: Bool,
        moving: MoveIntent = .none,
        _ operation: (LibraryModel) throws(LibraryError) -> LibraryModel
    ) throws(EditRefusal) -> Change? {
        switch loadState {
        case .notLoaded: throw .notLoaded
        case .failed(let reason): throw .loadFailed(reason)
        case .loaded: break
        }
        guard allowsEdits else { throw .readOnly }
        let updated: LibraryModel
        do {
            updated = try operation(library)
        } catch {
            throw .invalid(error)
        }
        guard updated != library else { return nil }
        let change = Change(before: library, after: updated, moved: moving)
        library = updated
        return change
    }

    /// Undo: reverts only what `change` did.
    public mutating func undo(_ change: Change) {
        library = change.revert(on: library)
    }

    /// Redo: re-applies only what `change` did.
    public mutating func redo(_ change: Change) {
        library = change.apply(to: library)
    }
}

extension LibraryModel {
    /// Applies the difference `from → to` to `self`, touching only what that edit changed. Everything else —
    /// entries, recents and collections added or changed elsewhere since (another Mac, a combine, a
    /// recovery, persistence acknowledging a verified show save) — is left as it is:
    ///
    /// - entries and recents: added/removed by identity;
    /// - collections: per collection ID — added/removed only if the edit added/removed them; renamed only if
    ///   the current name still equals the edit's before-value; membership applied as set add/remove with
    ///   new members placed after their predecessor; order changes applied relative to the members/collections
    ///   both versions share, leaving others in place.
    public func applyingDifference(from: LibraryModel, to: LibraryModel, moved: LibrarySession.MoveIntent = .none) -> LibraryModel {
        var result = self
        let fromIDs = Set(from.entries.map(\.showID))
        let toIDs = Set(to.entries.map(\.showID))
        let removed = fromIDs.subtracting(toIDs)
        let added = toIDs.subtracting(fromIDs)

        result.entries.removeAll { removed.contains($0.showID) }
        for entry in to.entries where added.contains(entry.showID) && result.entry(entry.showID) == nil {
            result.entries.append(entry)
        }

        let fromRecents = Set(from.recentShowIDs)
        let toRecents = Set(to.recentShowIDs)
        result.recentShowIDs.removeAll { fromRecents.contains($0) && !toRecents.contains($0) }
        for (index, id) in to.recentShowIDs.enumerated() where !fromRecents.contains(id) && !result.recentShowIDs.contains(id) {
            result.recentShowIDs.insert(id, at: min(index, result.recentShowIDs.count))
        }

        result.collections = Self.diffCollections(current: result.collections, from: from.collections, to: to.collections, moved: moved)
        let entryIDs = Set(result.entries.map(\.showID))
        for index in result.collections.indices {
            result.collections[index].showIDs.removeAll { !entryIDs.contains($0) }
        }
        return result
    }

    static func diffCollections(
        current: [LibraryCollection],
        from: [LibraryCollection],
        to: [LibraryCollection],
        moved: LibrarySession.MoveIntent = .none
    ) -> [LibraryCollection] {
        let fromByID = Dictionary(from.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let toByID = Dictionary(to.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = current.filter { !(fromByID[$0.id] != nil && toByID[$0.id] == nil) }

        // Changes to collections both versions have.
        for index in result.indices {
            let id = result[index].id
            guard let before = fromByID[id], let after = toByID[id] else { continue }
            if before.name != after.name, result[index].name == before.name {
                result[index].name = after.name
            }
            result[index].showIDs = diffOrdered(
                current: result[index].showIDs, from: before.showIDs, to: after.showIDs, moved: moved.shows[id]
            )
        }

        // Collections the edit added (e.g. undoing a delete): insert after their predecessor in `to`.
        for (position, collection) in to.enumerated() where fromByID[collection.id] == nil && !result.contains(where: { $0.id == collection.id }) {
            let predecessor = to[..<position].last { candidate in result.contains { $0.id == candidate.id } }
            let insertAt = predecessor.flatMap { p in result.firstIndex { $0.id == p.id } }.map { $0 + 1 } ?? 0
            result.insert(collection, at: insertAt)
        }

        // Collection order: move only what the edit moved, by its offset.
        let orderedIDs = diffOrdered(
            current: result.map(\.id), from: from.map(\.id), to: to.map(\.id),
            moved: moved.collections.isEmpty ? nil : moved.collections, membershipChanges: false
        )
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result = orderedIDs.compactMap { byID[$0] }
        return result
    }

    /// Set add/remove plus moves for an ordered list of IDs. Only items the edit moved change position, each
    /// by the offset it moved in the edit (clamped), so a concurrent reorder elsewhere is kept. `moved` is
    /// the edit's intent; without it, the items outside a longest common subsequence count as moved.
    static func diffOrdered<ID: Hashable>(current: [ID], from: [ID], to: [ID], moved: Set<ID>? = nil, membershipChanges: Bool = true) -> [ID] {
        let fromSet = Set(from)
        let toSet = Set(to)
        var result = current
        if membershipChanges { result.removeAll { fromSet.contains($0) && !toSet.contains($0) } }
        let sharedBefore = from.filter { toSet.contains($0) }
        let sharedAfter = to.filter { fromSet.contains($0) }
        if sharedBefore != sharedAfter {
            let movedItems = moved ?? Set(sharedAfter).subtracting(longestCommonSubsequence(sharedBefore, sharedAfter))
            // Apply moves in the edit's final order so several moved items keep their relative placement.
            for id in sharedAfter where movedItems.contains(id) {
                guard let oldIndex = sharedBefore.firstIndex(of: id), let newIndex = sharedAfter.firstIndex(of: id),
                      let currentIndex = result.firstIndex(of: id) else { continue }
                let delta = newIndex - oldIndex
                guard delta != 0 else { continue }
                result.remove(at: currentIndex)
                result.insert(id, at: min(max(currentIndex + delta, 0), result.count))
            }
        }
        if membershipChanges {
            for (position, id) in to.enumerated() where !fromSet.contains(id) && !result.contains(id) {
                let predecessor = to[..<position].last { result.contains($0) }
                let insertAt = predecessor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(id, at: insertAt)
            }
        }
        return result
    }

    static func longestCommonSubsequence<ID: Hashable>(_ a: [ID], _ b: [ID]) -> Set<ID> {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result = Set<ID>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.insert(a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
