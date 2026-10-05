import Foundation
import Testing
import WWCore
@testable import WWOrganizer

/// #108 review: content-only changes don't reload the whole list, and reconciliation never jumps the scroll
/// position back to the selection; only model-originated selection changes scroll.
@Suite("Library entry list reconciliation")
struct LibraryEntryListReconcilerTests {
    private let fixture = SyntheticLibraryFixture.make(shows: 30, sourceReferences: 60)
    private var shows: [LibraryEntryRow] { LibraryPresentation.entries(for: .shows, library: fixture.library, details: fixture.details) }
    private var recent: [LibraryEntryRow] { LibraryPresentation.entries(for: .recent, library: fixture.library, details: fixture.details) }

    @Test func firstApplyReloadsAndAnUnchangedModelDoesNothing() {
        var reconciler = LibraryEntryListReconciler()
        #expect(reconciler.reconcile(rows: shows, list: .shows, selection: []).update == .reloadAll)
        let again = reconciler.reconcile(rows: shows, list: .shows, selection: [])
        #expect(again == .init(update: .none, selection: [], scrollToRow: nil, scrollToTop: false))
    }

    @Test func contentOnlyChangeReloadsJustThoseRowsAndKeepsSelectionWithoutScrolling() {
        var reconciler = LibraryEntryListReconciler()
        let selected = shows[25].showID
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [])
        reconciler.noteUserSelection([selected])
        var changed = shows
        changed[3].status = LibraryEntryStatePresentation(.checking, showName: changed[3].name)
        changed[7].episodeCount = 99
        let plan = reconciler.reconcile(rows: changed, list: .shows, selection: [selected])
        #expect(plan.update == .reloadRows([3, 7]))
        #expect(plan.selection == [25])
        #expect(plan.scrollToRow == nil, "a background status refresh must not jump the list to the selection")
        #expect(!plan.scrollToTop)
    }

    @Test func reorderOrMembershipChangeReloadsAllButRestoresSelectionWithoutScrolling() {
        var reconciler = LibraryEntryListReconciler()
        let selected = shows[20].showID
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [selected])
        let reversed = Array(shows.reversed())
        let plan = reconciler.reconcile(rows: reversed, list: .shows, selection: [selected])
        #expect(plan.update == .reloadAll)
        #expect(plan.selection == [shows.count - 1 - 20])
        #expect(plan.scrollToRow == nil)
        let removed = reconciler.reconcile(rows: Array(reversed.dropFirst()), list: .shows, selection: [selected])
        #expect(removed.update == .reloadAll)
        #expect(removed.scrollToRow == nil)
    }

    @Test func modelSelectionChangeScrollsToTheFirstSelectedRow() {
        var reconciler = LibraryEntryListReconciler()
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [])
        let plan = reconciler.reconcile(rows: shows, list: .shows, selection: [shows[28].showID, shows[12].showID])
        #expect(plan.update == .none)
        #expect(plan.selection == [12, 28])
        #expect(plan.scrollToRow == 12)
    }

    @Test func userSelectionEchoedBackByTheModelDoesNotScroll() {
        var reconciler = LibraryEntryListReconciler()
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [])
        reconciler.noteUserSelection([shows[5].showID])
        #expect(reconciler.reconcile(rows: shows, list: .shows, selection: [shows[5].showID]).scrollToRow == nil)
    }

    @Test func switchingListsReloadsAndStartsAtTheTop() {
        var reconciler = LibraryEntryListReconciler()
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [])
        let plan = reconciler.reconcile(rows: recent, list: .recent, selection: [])
        #expect(plan.update == .reloadAll)
        #expect(plan.scrollToTop)
        #expect(plan.scrollToRow == nil)
    }

    @Test func forcedReloadReloadsEverythingAndKeepsSelection() {
        var reconciler = LibraryEntryListReconciler()
        let selected = shows[2].showID
        _ = reconciler.reconcile(rows: shows, list: .shows, selection: [selected])
        let plan = reconciler.reconcile(rows: shows, list: .shows, selection: [selected], forceReload: true)
        #expect(plan.update == .reloadAll)
        #expect(plan.selection == [2])
        #expect(plan.scrollToRow == nil)
    }
}
