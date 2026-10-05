import Foundation
import Testing
import WWCore
@testable import WWOrganizer

@Suite("Library session: load gating, read-only, bookkeeping and undo (review fixes)")
struct LibrarySessionTests {
    let stored: LibraryModel = {
        let fixture = SyntheticLibraryFixture.make(shows: 10, sourceReferences: 40, collections: 2)
        return fixture.library
    }()

    @Test func showOpenedBeforeLoadIsQueuedAndNeverReplacesTheStoredLibrary() {
        var session = LibrarySession()
        let early = ShowID()
        let r1 = session.record(.opened(early, confirmedTitle: "Opened at launch", provisionalTitle: "Opened at launch"), allowsEdits: true)
        #expect(r1 == false)
        #expect(session.canPersist(allowsEdits: true) == false)
        #expect(session.library == LibraryModel(), "nothing applied to the empty placeholder")
        let r2 = session.didLoad(stored, allowsEdits: true)
        #expect(r2 == true)
        #expect(session.library.entries.count == stored.entries.count + 1)
        #expect(session.library.collections == stored.collections)
        #expect(session.library.recentShowIDs.first == early)
        #expect(session.queued.isEmpty)
    }

    @Test func failedLoadNeverPersistsOrEdits() {
        var session = LibrarySession()
        session.didFailLoad(reason: "unreadable")
        let r3 = session.record(.opened(ShowID(), confirmedTitle: "S", provisionalTitle: "S"), allowsEdits: true)
        #expect(r3 == false)
        #expect(session.canPersist(allowsEdits: true) == false)
        let failed = session
        #expect(throws: LibrarySession.EditRefusal.loadFailed("unreadable")) {
            var copy = failed
            _ = try copy.apply(allowsEdits: true) { library throws(LibraryError) in try library.addingCollection(LibraryCollection(name: "X")) }
        }
        #expect(throws: LibrarySession.EditRefusal.notLoaded) {
            var fresh = LibrarySession()
            _ = try fresh.apply(allowsEdits: true) { $0 }
        }
    }

    @Test func readOnlyLibraryRefusesEditsAndQueuesBookkeepingUntilEditable() throws {
        var session = LibrarySession()
        let r4 = session.didLoad(stored, allowsEdits: false)
        #expect(r4 == false)
        #expect(session.canPersist(allowsEdits: false) == false)
        let readOnly = session
        #expect(throws: LibrarySession.EditRefusal.readOnly) {
            var copy = readOnly
            _ = try copy.apply(allowsEdits: false) { library throws(LibraryError) in try library.addingCollection(LibraryCollection(name: "X")) }
        }
        let opened = ShowID()
        let r5 = session.record(.opened(opened, confirmedTitle: "S", provisionalTitle: "S"), allowsEdits: false)
        #expect(r5 == false)
        #expect(session.library == stored)
        let r6 = session.flush(allowsEdits: true)
        #expect(r6 == true)
        #expect(session.library.entry(opened) != nil)
    }

    @Test func undoKeepsEntriesAndRecentsAddedInBetween() throws {
        var session = LibrarySession()
        _ = session.didLoad(stored, allowsEdits: true)
        let collection = try #require(stored.collections.first)
        let applied = try session.apply(allowsEdits: true) { library throws(LibraryError) in try library.deletingCollection(collection.id) }
        let change = try #require(applied)
        let newShow = ShowID()
        let r7 = session.record(.opened(newShow, confirmedTitle: "Opened after delete", provisionalTitle: "Opened after delete"), allowsEdits: true)
        #expect(r7)
        session.undo(change)
        #expect(session.library.collections == stored.collections, "collection restored with members and order")
        #expect(session.library.entry(newShow) != nil, "entry added since is kept")
        #expect(session.library.recentShowIDs.first == newShow, "recent added since is kept")
        session.redo(change)
        #expect(session.library.collection(collection.id) == nil)
        #expect(session.library.entry(newShow) != nil)
    }

    @Test func undoRemoveFromLibraryRestoresEntryMembershipAndRecentPosition() throws {
        var session = LibrarySession()
        _ = session.didLoad(stored, allowsEdits: true)
        let collection = try #require(stored.collections.first)
        let victim = try #require(collection.showIDs.first)
        let applied = try session.apply(allowsEdits: true) { library throws(LibraryError) in try library.removingEntries([victim]) }
        let change = try #require(applied)
        #expect(session.library.entry(victim) == nil)
        let other = ShowID()
        _ = session.record(.opened(other, confirmedTitle: "Other", provisionalTitle: "Other"), allowsEdits: true)
        session.undo(change)
        #expect(session.library.entry(victim) != nil)
        #expect(session.library.collection(collection.id)?.showIDs == collection.showIDs)
        #expect(session.library.entry(other) != nil)
        session.redo(change)
        #expect(session.library.entry(victim) == nil)
        #expect(session.library.collection(collection.id)?.showIDs.contains(victim) == false)
        #expect(session.library.entry(other) != nil)
    }

    @Test func openingWithUnsavedEditsDoesNotTakeTheUnsavedTitle() {
        var session = LibrarySession()
        _ = session.didLoad(stored, allowsEdits: true)
        let id = stored.entries[0].showID
        let original = stored.entries[0].lastKnownTitle
        let changed = session.record(.opened(id, confirmedTitle: nil, provisionalTitle: "Unsaved title"), allowsEdits: true)
        #expect(changed)
        #expect(session.library.entry(id)?.lastKnownTitle == original)
        #expect(session.library.recentShowIDs.first == id)
        let fresh = ShowID()
        _ = session.record(.opened(fresh, confirmedTitle: nil, provisionalTitle: "New show"), allowsEdits: true)
        #expect(session.library.entry(fresh)?.lastKnownTitle == "New show", "a new show is never dropped")
    }

    @Test func confirmedTitleOnlyRefreshesKnownEntries() {
        var session = LibrarySession()
        _ = session.didLoad(stored, allowsEdits: true)
        let unknown = ShowID()
        let r8 = session.record(.confirmedTitle(unknown, title: "x"), allowsEdits: true)
        #expect(r8 == false)
        let id = stored.entries[0].showID
        let r9 = session.record(.confirmedTitle(id, title: "Renamed and saved"), allowsEdits: true)
        #expect(r9)
        #expect(session.library.entry(id)?.lastKnownTitle == "Renamed and saved")
    }
}
