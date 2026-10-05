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
}
