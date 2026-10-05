import Foundation
import Testing
import WWCore
@testable import WWOrganizer

/// Entry-list sorting used by the AppKit entry outline (#106): Name/Location/Status, Finder-style ordering.
@Suite("Library entry sorting")
struct LibraryEntrySortTests {
    private let rows: [LibraryEntryRow] = {
        let fixture = SyntheticLibraryFixture.make(shows: 12, sourceReferences: 24)
        return LibraryPresentation.entries(for: .shows, library: fixture.library, details: fixture.details)
    }()

    @Test func noKeysKeepsTheListOrder() {
        #expect(LibraryPresentation.sorted(rows, by: []).map(\.showID) == rows.map(\.showID))
    }

    @Test func nameSortsNumericallyLikeFinderBothWays() {
        let named = rows.prefix(3).enumerated().map { index, row in
            var row = row
            row.name = ["Show 10", "Show 9", "show 1"][index]
            return row
        }
        #expect(LibraryPresentation.sorted(named, by: [(.name, true)]).map(\.name) == ["show 1", "Show 9", "Show 10"])
        #expect(LibraryPresentation.sorted(named, by: [(.name, false)]).map(\.name) == ["Show 10", "Show 9", "show 1"])
    }

    @Test func secondaryKeyBreaksTiesAndTiesStayStable() {
        let sorted = LibraryPresentation.sorted(rows, by: [(.location, true), (.name, false)])
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let location = a.locationText.localizedStandardCompare(b.locationText)
            #expect(location != .orderedDescending)
            if location == .orderedSame { #expect(a.name.localizedStandardCompare(b.name) != .orderedAscending) }
        }
        let byStatus = LibraryPresentation.sorted(rows, by: [(.status, true)])
        let available = byStatus.filter { $0.status.statusText == rows.last?.status.statusText }.map(\.showID)
        #expect(available == rows.filter { $0.status.statusText == rows.last?.status.statusText }.map(\.showID), "equal keys keep list order")
    }
}
