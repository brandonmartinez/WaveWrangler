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

    /// One undoable library edit: the library before and after the action itself.
    public struct Change: Sendable, Equatable {
        public var before: LibraryModel
        public var after: LibraryModel
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
        let change = Change(before: library, after: updated)
        library = updated
        return change
    }

    /// Undo: reverts only what `change` did.
    public mutating func undo(_ change: Change) {
        library = library.applyingDifference(from: change.after, to: change.before)
    }

    /// Redo: re-applies only what `change` did.
    public mutating func redo(_ change: Change) {
        library = library.applyingDifference(from: change.before, to: change.after)
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
    public func applyingDifference(from: LibraryModel, to: LibraryModel) -> LibraryModel {
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

        result.collections = Self.diffCollections(current: result.collections, from: from.collections, to: to.collections)
        let entryIDs = Set(result.entries.map(\.showID))
        for index in result.collections.indices {
            result.collections[index].showIDs.removeAll { !entryIDs.contains($0) }
        }
        return result
    }

    static func diffCollections(current: [LibraryCollection], from: [LibraryCollection], to: [LibraryCollection]) -> [LibraryCollection] {
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
            result[index].showIDs = diffOrdered(current: result[index].showIDs, from: before.showIDs, to: after.showIDs)
        }

        // Collections the edit added (e.g. undoing a delete): insert after their predecessor in `to`.
        for (position, collection) in to.enumerated() where fromByID[collection.id] == nil && !result.contains(where: { $0.id == collection.id }) {
            let predecessor = to[..<position].last { candidate in result.contains { $0.id == candidate.id } }
            let insertAt = predecessor.flatMap { p in result.firstIndex { $0.id == p.id } }.map { $0 + 1 } ?? 0
            result.insert(collection, at: insertAt)
        }

        // Collection order changes among collections all three share.
        let sharedOrder = from.map(\.id).filter { toByID[$0] != nil }
        let targetOrder = to.map(\.id).filter { fromByID[$0] != nil }
        if sharedOrder != targetOrder {
            let movable = Set(targetOrder)
            let slots = result.indices.filter { movable.contains(result[$0].id) }
            let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = targetOrder.compactMap { byID[$0] }
            if ordered.count == slots.count {
                for (slot, collection) in zip(slots, ordered) { result[slot] = collection }
            }
        }
        return result
    }

    /// Set add/remove plus relative reordering for an ordered list of IDs.
    static func diffOrdered<ID: Hashable>(current: [ID], from: [ID], to: [ID]) -> [ID] {
        let fromSet = Set(from)
        let toSet = Set(to)
        var result = current.filter { !(fromSet.contains($0) && !toSet.contains($0)) }
        for (position, id) in to.enumerated() where !fromSet.contains(id) && !result.contains(id) {
            let predecessor = to[..<position].last { result.contains($0) }
            let insertAt = predecessor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: insertAt)
        }
        let sharedBefore = from.filter { toSet.contains($0) }
        let sharedAfter = to.filter { fromSet.contains($0) }
        if sharedBefore != sharedAfter {
            let movable = Set(sharedAfter)
            let slots = result.indices.filter { movable.contains(result[$0]) }
            let ordered = sharedAfter.filter { result.contains($0) }
            if ordered.count == slots.count {
                for (slot, id) in zip(slots, ordered) { result[slot] = id }
            }
        }
        return result
    }
}
