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
        /// A show window opened: add/refresh its entry and make it most recent.
        case opened(ShowID, title: String)
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

    /// Applies queued bookkeeping when loaded and editable. Returns `true` if the library changed.
    public mutating func flush(allowsEdits: Bool) -> Bool {
        guard isLoaded, allowsEdits, !queued.isEmpty else { return false }
        let original = library
        for item in queued {
            switch item {
            case let .opened(id, title):
                library = library.upsertingEntry(showID: id, title: title).recordingOpened(id)
            case let .confirmedTitle(id, title):
                if library.entry(id) != nil { library = library.upsertingEntry(showID: id, title: title) }
            }
        }
        queued.removeAll()
        return library != original
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
    /// Applies the difference `from → to` to `self`, leaving everything else (e.g. entries and recents
    /// added by bookkeeping since) untouched. Collections are only changed by undoable user actions, so
    /// they take `to`'s value, keeping only members that are still library entries.
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

        let entryIDs = Set(result.entries.map(\.showID))
        result.collections = to.collections.map { collection in
            var copy = collection
            copy.showIDs = collection.showIDs.filter { entryIDs.contains($0) }
            return copy
        }
        return result
    }
}
