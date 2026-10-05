import Foundation
import Testing
import WWCore
@testable import WWOrganizer

@Suite("Library operations")
struct LibraryOperationTests {
    let a = ShowID()
    let b = ShowID()
    let c = ShowID()

    var library: LibraryModel {
        LibraryModel(entries: [
            LibraryShowEntry(showID: a, lastKnownTitle: "Alpha"),
            LibraryShowEntry(showID: b, lastKnownTitle: "Bravo"),
            LibraryShowEntry(showID: c, lastKnownTitle: "Charlie"),
        ], recentShowIDs: [c, a])
    }

    @Test func createRenameDeleteCollectionNeverDeletesShows() throws {
        let collection = LibraryCollection(name: "  In Progress  ")
        var model = try library.addingCollection(collection)
        #expect(model.collections.map(\.name) == ["In Progress"])
        model = try model.addingShows([a, b, a], toCollection: collection.id)
        #expect(model.collection(collection.id)?.showIDs == [a, b])
        model = try model.renamingCollection(collection.id, to: "Season 2")
        #expect(model.collection(collection.id)?.name == "Season 2")
        #expect(throws: LibraryError.emptyName) { try model.renamingCollection(collection.id, to: "   ") }
        model = try model.deletingCollection(collection.id)
        #expect(model.collections.isEmpty)
        #expect(model.entries.count == 3)
    }

    @Test func moveCollectionsByMenuAndDrag() throws {
        let one = LibraryCollection(name: "One")
        let two = LibraryCollection(name: "Two")
        let three = LibraryCollection(name: "Three")
        var model = try library.addingCollection(one).addingCollection(two).addingCollection(three)
        #expect(!model.canMoveCollection(one.id, by: -1))
        #expect(model.canMoveCollection(one.id, by: 1))
        model = try model.movingCollection(three.id, by: -1)
        #expect(model.collections.map(\.name) == ["One", "Three", "Two"])
        #expect(try model.movingCollection(one.id, by: -1) == model)
        model = model.movingCollections(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.collections.map(\.name) == ["Three", "Two", "One"])
        model = model.movingCollections(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.collections.map(\.name) == ["One", "Three", "Two"])
    }

    @Test func removeFromCollectionKeepsLibraryEntry() throws {
        let collection = LibraryCollection(name: "C", showIDs: [a, b])
        let model = try library.addingCollection(collection).removingShows([a], fromCollection: collection.id)
        #expect(model.collection(collection.id)?.showIDs == [b])
        #expect(model.entry(a) != nil)
    }

    @Test func removeFromLibraryDropsReferencesOnly() throws {
        let collection = LibraryCollection(name: "C", showIDs: [a, b])
        let model = try library.addingCollection(collection).removingEntries([a])
        #expect(model.entry(a) == nil)
        #expect(model.collection(collection.id)?.showIDs == [b])
        #expect(model.recentShowIDs == [c])
        #expect(throws: LibraryError.entryNotFound(a)) { try model.removingEntries([a]) }
    }

    @Test func recentsAreNewestFirstAndBounded() {
        var model = library.recordingOpened(b)
        #expect(model.recentShowIDs == [b, c, a])
        model = model.recordingOpened(c)
        #expect(model.recentShowIDs == [c, b, a])
        #expect(model.recordingOpened(a, limit: 2).recentShowIDs == [a, c])
    }

    @Test func upsertRefreshesTitleAndClearsUnavailableNote() {
        var model = library
        model.entries[0].unavailable = UnavailableRecord(note: "Not found", recordedAt: Date())
        model = model.upsertingEntry(showID: a, title: "Alpha 2")
        #expect(model.entry(a)?.lastKnownTitle == "Alpha 2")
        #expect(model.entry(a)?.unavailable == nil)
        let d = ShowID()
        #expect(model.upsertingEntry(showID: d, title: "Delta").entries.count == 4)
    }
}

@Suite("Library presentation")
struct LibraryPresentationTests {
    @Test func sidebarCountsAndValues() {
        let fixture = SyntheticLibraryFixture.make()
        let snapshot = LibraryPresentation.sidebar(library: fixture.library, details: fixture.details)
        #expect(snapshot.libraryRows.map(\.title) == ["Shows", "Recent", "Unavailable"])
        #expect(snapshot.libraryRows[0].accessibilityValue == "100 shows")
        #expect(snapshot.libraryRows[1].accessibilityValue == "10 items")
        #expect(snapshot.libraryRows[2].accessibilityValue == "3 items need attention")
        #expect(snapshot.libraryRows[2].countText == "(3)")
        #expect(snapshot.collectionRows.count == 5)
        #expect(snapshot.collectionRows[0].accessibilityLabel == "Synthetic Collection 1, collection")
        #expect(snapshot.collectionRows[0].item.accessibilityIdentifier.hasPrefix("ww.library.sidebar.collection."))
    }

    @Test func emptyLibraryStillShowsUnavailableWithNone() {
        let snapshot = LibraryPresentation.sidebar(library: LibraryModel(), details: [:])
        #expect(snapshot.libraryRows[2].accessibilityValue == "None")
        #expect(snapshot.libraryRows[2].countText == nil)
        #expect(snapshot.libraryRows[0].accessibilityValue == "0 shows")
    }

    @Test func unavailableIsAFilterNotAMove() {
        let fixture = SyntheticLibraryFixture.make()
        let unavailable = LibraryPresentation.entries(for: .unavailable, library: fixture.library, details: fixture.details)
        #expect(unavailable.map(\.status.statusText).sorted() == ["Can't find show file", "Needs newer WaveWrangler", "Needs permission"])
        let shows = LibraryPresentation.entries(for: .shows, library: fixture.library, details: fixture.details)
        #expect(shows.count == 100)
        #expect(Set(unavailable.map(\.showID)).isSubset(of: Set(shows.map(\.showID))))
        #expect(shows.first?.name == "Synthetic Show 001")
    }

    @Test func unobservedEntriesSayCheckingAndRecordedNotesStayVisible() {
        let id = ShowID()
        var library = LibraryModel(entries: [LibraryShowEntry(showID: id, lastKnownTitle: "S")])
        #expect(LibraryPresentation.entries(for: .shows, library: library, details: [:]).first?.status.statusText == "Checking…")
        library.entries[0].unavailable = UnavailableRecord(note: "The drive wasn't connected.", recordedAt: Date())
        let row = LibraryPresentation.entries(for: .shows, library: library, details: [:]).first
        #expect(row?.status.statusText == "Unavailable")
        #expect(row?.status.needsAttention == true)
        #expect(row?.locationText == "Location unknown")
    }

    @Test func entryStateWordingAndRemedies() {
        let notFound = LibraryEntryStatePresentation(.notFound(folderDisplayName: "Podcasts"), showName: "Garage Talk")
        #expect(notFound.explanation == "WaveWrangler can't find “Garage Talk” at Podcasts. It may have been moved, renamed or deleted.")
        #expect(notFound.remedies == [.locate, .removeFromLibrary])
        #expect(LibraryEntryStatePresentation(.needsPermission, showName: "x").remedies == [.grantAccess])
        #expect(LibraryEntryStatePresentation(.locationUnavailable, showName: "x").statusText == "Location unavailable")
        #expect(LibraryEntryStatePresentation(.outOfDate, showName: "x").needsAttention == false)
        let unknown = LibraryEntryStatePresentation(.locationUnknown, showName: "Garage Talk")
        #expect(unknown.statusText == "Location unknown")
        #expect(unknown.symbolName == "location.slash", "a final state with a symbol, not a spinner")
        #expect(unknown.remedies == [.locate, .removeFromLibrary])
        #expect(unknown.needsAttention)
    }

    @Test func recentAndCollectionKeepUserOrder() throws {
        let fixture = SyntheticLibraryFixture.make()
        let recent = LibraryPresentation.entries(for: .recent, library: fixture.library, details: fixture.details)
        #expect(recent.map(\.showID) == fixture.library.recentShowIDs)
        let collection = try #require(fixture.library.collections.first)
        let rows = LibraryPresentation.entries(for: .collection(collection.id), library: fixture.library, details: fixture.details)
        #expect(rows.map(\.showID) == collection.showIDs)
    }
}

@Suite("Workspace operations")
struct WorkspaceOperationTests {
    @Test func episodeMetadataEditsAndMoves() throws {
        let one = Episode(title: "One", number: 1)
        let two = Episode(title: "Two", number: 2)
        var model = try ShowDocumentModel.untitled().addingEpisode(one).addingEpisode(two)
        model = try model.settingEpisodeNumber(one.id, to: 12)
        model = try model.settingEpisodeRecordedOn(one.id, to: CalendarDay(year: 2026, month: 10, day: 3))
        model = try model.settingEpisodeNotes(one.id, to: "Synthetic notes")
        #expect(model.episode(one.id)?.number == 12)
        #expect(model.episode(one.id)?.recordedOn?.description == "2026-10-03")
        #expect(model.episode(one.id)?.notes == "Synthetic notes")
        #expect(model.canMoveEpisode(two.id, by: -1))
        #expect(!model.canMoveEpisode(two.id, by: 1))
        model = try model.movingEpisode(two.id, by: -1)
        #expect(model.episodes.map(\.title) == ["Two", "One"])
        #expect(model.nextNewEpisode().title == "Episode 13")
        #expect(ShowDocumentModel.untitled().nextNewEpisode().title == "Episode 1")
        #expect(throws: DomainError.episodeNotFound(EpisodeID(UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1))))) {
            try model.settingEpisodeNumber(EpisodeID(UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1))), to: 1)
        }
    }

    @Test(arguments: [("12", 12 as Int?), ("", nil), ("  7 ", 7)])
    func validNumbers(_ input: String, _ expected: Int?) throws {
        #expect(try EpisodeNumberInput.parse(input).get() == expected)
    }

    @Test(arguments: ["-1", "1.5", "abc", "١٢", "99999999"])
    func invalidNumbersAreRejectedWithMessage(_ input: String) {
        #expect(throws: EpisodeNumberInputError.notAWholeNumber) { try EpisodeNumberInput.parse(input).get() }
        #expect(EpisodeNumberInputError.notAWholeNumber.message == "Enter a whole number")
    }
}
