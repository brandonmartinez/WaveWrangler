import WWCore
import WWOrganizer

/// The per-entry checks a library adoption needs (`LibraryEntryObserving` refines this).
@MainActor
protocol LibraryEntryChecking: AnyObject {
    var details: [ShowID: LibraryEntryDetails] { get }
    /// Entries a check is running for, on any path (launch, Rebuild Library Index, Try Again, first checks).
    var checksInFlight: Set<ShowID> { get }
    /// Re-observe entries (Try Again / Rebuild Library Index…). Never on the main thread's I/O path.
    func refresh(_ ids: [ShowID]) async
}

/// A canonical library value arrived (after a failed or read-only load, Use That Library, Combine, a change from
/// another Mac, a verified show save): it's adopted into the session, and every entry this Mac hasn't checked yet
/// gets its first check, off the main thread (#193). Without that, shows another library brought in stay
/// "Checking…" and are missing from Unavailable.
@MainActor
final class CanonicalLibraryAdoption {
    enum Outcome: Equatable {
        /// The session wasn't loaded and now is; `changed` when queued bookkeeping changed it (persist then).
        case loaded(changed: Bool)
        case adopted
        case unchanged
    }

    private let entries: LibraryEntryChecking
    /// First checks asked for and not finished (they may not have reached `entries` yet).
    private var requested: Set<ShowID> = []
    /// The most recent first-check task (tests await it).
    private(set) var lastFirstCheck: Task<Void, Never>?

    init(entries: LibraryEntryChecking) {
        self.entries = entries
    }

    func adopt(_ canonical: LibraryModel, into session: inout LibrarySession, allowsEdits: Bool) -> Outcome {
        let outcome: Outcome
        if !session.isLoaded {
            outcome = .loaded(changed: session.didLoad(canonical, allowsEdits: allowsEdits))
        } else if canonical != session.library {
            session.adoptCanonical(canonical)
            outcome = .adopted
        } else {
            outcome = .unchanged
        }
        if session.isLoaded { checkUnchecked(in: session.library) }
        return outcome
    }

    private func checkUnchecked(in library: LibraryModel) {
        let ids = LibraryEntryRefresh.unchecked(library, details: entries.details, inFlight: entries.checksInFlight.union(requested))
        guard !ids.isEmpty else { return }
        requested.formUnion(ids)
        lastFirstCheck = Task { [entries] in
            await entries.refresh(ids)
            self.requested.subtract(ids)
        }
    }
}
