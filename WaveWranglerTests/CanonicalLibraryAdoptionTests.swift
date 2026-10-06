import Testing
import WWCore
import WWOrganizer

/// #193 wiring: adopting a canonical library (Use That Library, Combine, another Mac, a load after Grant Access)
/// gives exactly the entries this Mac hasn't checked their first check, once, alongside checks already running.
/// `LibraryUIStore.canonicalLibraryDidChange` adopts only through `CanonicalLibraryAdoption`.
@MainActor
@Suite("Canonical library adoption")
struct CanonicalLibraryAdoptionTests {
    private final class Checks: LibraryEntryChecking {
        var details: [ShowID: LibraryEntryDetails] = [:]
        var checksInFlight: Set<ShowID> = []
        var refreshed: [[ShowID]] = []
        func refresh(_ ids: [ShowID]) async { refreshed.append(ids) }
    }

    private func library(_ ids: [ShowID]) -> LibraryModel {
        LibraryModel(entries: ids.map { LibraryShowEntry(showID: $0, lastKnownTitle: "Show") })
    }

    @Test func adoptingAChangedLibraryChecksExactlyTheEntriesWithoutACompletedCheck() async throws {
        let known = ShowID(), seeded = ShowID(), running = ShowID(), broughtIn = ShowID()
        let checks = Checks()
        checks.details = [
            known: LibraryEntryDetails(state: .available),
            seeded: LibraryEntryDetails(state: .checking),
            running: LibraryEntryDetails(state: .checking),
        ]
        checks.checksInFlight = [running]
        let adoption = CanonicalLibraryAdoption(entries: checks)
        var session = LibrarySession()
        _ = session.didLoad(library([known]), allowsEdits: true)

        let combined = library([known, seeded, running, broughtIn])
        let adopted = adoption.adopt(combined, session: session, allowsEdits: true)
        #expect(adopted.outcome == .adopted)
        session = try #require(adopted.session)
        #expect(session.library.entries.map(\.showID) == [known, seeded, running, broughtIn])
        // The same value arriving again (another observation) before the check ran asks for nothing more, and
        // leaves the session as it is (no reassignment of the observable store).
        #expect(adoption.adopt(combined, session: session, allowsEdits: true) == .init(outcome: .unchanged, session: nil))
        await adoption.lastFirstCheck?.value
        #expect(checks.refreshed == [[seeded, broughtIn]], "only unchecked entries with no running check, once")
    }

    @Test func aLoadThroughAdoptionChecksItsEntries() async {
        let a = ShowID(), b = ShowID()
        let checks = Checks()
        let adoption = CanonicalLibraryAdoption(entries: checks)
        let loaded = adoption.adopt(library([a, b]), session: LibrarySession(), allowsEdits: false)
        #expect(loaded.outcome == .loaded(changed: false))
        #expect(loaded.session?.isLoaded == true)
        await adoption.lastFirstCheck?.value
        #expect(checks.refreshed == [[a, b]])
    }

    @Test func nothingIsCheckedWhenEveryEntryHasACompletedCheck() async {
        let a = ShowID()
        let checks = Checks()
        checks.details = [a: LibraryEntryDetails(state: .locationUnknown)]
        let adoption = CanonicalLibraryAdoption(entries: checks)
        _ = adoption.adopt(library([a]), session: LibrarySession(), allowsEdits: true)
        #expect(adoption.lastFirstCheck == nil)
        #expect(checks.refreshed.isEmpty)
    }
}
