import Foundation
import WWCore

/// Decides how the Library entry list applies a new model state (#106 review): reload only the rows whose
/// content changed when the list keeps its membership and order, restore the selection after any reload
/// without moving the scroll position, scroll to the selection only when the model (not the user) changed it,
/// and return to the top when the sidebar shows a different list.
public struct LibraryEntryListReconciler: Sendable {
    public enum Update: Equatable, Sendable {
        case none
        /// Same shows in the same order; only these rows' content changed.
        case reloadRows(IndexSet)
        /// Membership or order changed (or a forced reload, e.g. a text size change).
        case reloadAll
    }

    public struct Plan: Equatable, Sendable {
        public var update: Update
        /// Row indexes the table's selection must equal after the update.
        public var selection: IndexSet
        /// Row to scroll to: only when the model changed the selection.
        public var scrollToRow: Int?
        /// The sidebar switched lists (and no selection to reveal): show the new list from its top.
        public var scrollToTop: Bool
    }

    public private(set) var rows: [LibraryEntryRow] = []
    private var list: LibrarySidebarItem?
    private var appliedSelection: Set<ShowID> = []

    public init() {}

    /// `rows` are the displayed (sorted) rows.
    public mutating func reconcile(rows newRows: [LibraryEntryRow], list newList: LibrarySidebarItem, selection: Set<ShowID>, forceReload: Bool = false) -> Plan {
        let switchedList = list != nil && list != newList
        let update: Update
        if forceReload || switchedList || rows.map(\.showID) != newRows.map(\.showID) {
            update = rows.isEmpty && newRows.isEmpty && !forceReload ? .none : .reloadAll
        } else {
            let changed = IndexSet(newRows.indices.filter { rows[$0] != newRows[$0] })
            update = changed.isEmpty ? .none : .reloadRows(changed)
        }
        let indexes = IndexSet(newRows.indices.filter { selection.contains(newRows[$0].showID) })
        let modelChangedSelection = selection != appliedSelection
        rows = newRows
        list = newList
        appliedSelection = selection
        let scrollToRow = modelChangedSelection ? indexes.first : nil
        return Plan(update: update, selection: indexes, scrollToRow: scrollToRow, scrollToTop: switchedList && scrollToRow == nil)
    }

    /// The user changed the selection in the table; the model will echo it back, which must not scroll.
    public mutating func noteUserSelection(_ selection: Set<ShowID>) {
        appliedSelection = selection
    }
}
