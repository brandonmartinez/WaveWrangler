import Testing
import WWCore
@testable import WWOrganizer

@Suite("Library entry refresh merging (#97 review)")
struct LibraryEntryRefreshTests {
    @Test func collisionFoundDuringACheckIsNotOverwritten() {
        let id = ShowID()
        // A check started at generation 0; meanwhile a window opened and found an identity collision (gen 1).
        let details: [ShowID: LibraryEntryDetails] = [id: LibraryEntryDetails(state: .identityCollision(otherLocationDisplayName: "Desktop"))]
        let result = LibraryEntryCheckResult(showID: id, generation: 0, observation: .reachable(folderDisplayName: "Podcasts"))
        let merged = LibraryEntryRefresh.apply([result], to: details, currentGenerations: [id: 1])
        #expect(merged[id]?.state == .identityCollision(otherLocationDisplayName: "Desktop"))
        // Even with a matching generation, a check never replaces a collision.
        let sameGeneration = LibraryEntryRefresh.apply([result], to: details, currentGenerations: [id: 0])
        #expect(sameGeneration[id]?.state == .identityCollision(otherLocationDisplayName: "Desktop"))
    }

    @Test func staleResultsAreDroppedAndCurrentOnesApplied() {
        let a = ShowID(), b = ShowID(), c = ShowID()
        let details: [ShowID: LibraryEntryDetails] = [
            a: LibraryEntryDetails(state: .checking),
            b: LibraryEntryDetails(state: .available, locationDisplayName: "Fresh"),
            c: LibraryEntryDetails(state: .checking),
        ]
        let merged = LibraryEntryRefresh.apply([
            .init(showID: a, generation: 3, observation: .unknown),
            .init(showID: b, generation: 1, observation: .notFound(folderDisplayName: "Old")),
            .init(showID: c, generation: 0, observation: .needsPermission),
        ], to: details, currentGenerations: [a: 3, b: 2])
        #expect(merged[a]?.state == .locationUnknown, "no record ends in Location unknown, never Checking")
        #expect(merged[b]?.state == .available, "stale result dropped (the window opened since)")
        #expect(merged[b]?.locationDisplayName == "Fresh")
        #expect(merged[c]?.state == .needsPermission)
    }

    /// #193: entries with no details (brought in by another library) or still "Checking…" (seeded from this Mac's
    /// location records) need a check, unless one is running; checked entries don't.
    @Test func entriesWithoutACompletedCheckNeedOneUnlessARunningCheckCoversThem() {
        let known = ShowID(), seeded = ShowID(), running = ShowID(), broughtIn1 = ShowID(), broughtIn2 = ShowID()
        let library = LibraryModel(entries: [known, broughtIn1, seeded, running, broughtIn2].map { LibraryShowEntry(showID: $0, lastKnownTitle: "Show") })
        let details: [ShowID: LibraryEntryDetails] = [
            known: LibraryEntryDetails(state: .available, locationDisplayName: "Podcasts"),
            seeded: LibraryEntryDetails(state: .checking, locationDisplayName: "Desktop"),
            running: LibraryEntryDetails(state: .checking),
        ]
        #expect(LibraryEntryRefresh.unchecked(library, details: details, inFlight: [running]) == [broughtIn1, seeded, broughtIn2], "library order")
        // Until checked they don't count as needing attention; after the check (no record) they do.
        #expect(LibraryPresentation.sidebar(library: library, details: details).libraryRows[2].accessibilityValue == "None")
        let checked = LibraryEntryRefresh.apply([broughtIn1, seeded, running, broughtIn2].map {
            .init(showID: $0, generation: 0, observation: .unknown)
        }, to: details, currentGenerations: [:])
        #expect(LibraryEntryRefresh.unchecked(library, details: checked).isEmpty)
        #expect(LibraryPresentation.sidebar(library: library, details: checked).libraryRows[2].accessibilityValue == "4 items need attention")
    }
}
