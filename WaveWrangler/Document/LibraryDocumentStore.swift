import Foundation
import Observation
import WWCore
import WWPersistence

/// Main-actor adapter over the canonical `LibraryStore` for the library UI lane (`LibraryPersisting`-style:
/// load/save the `LibraryModel`; `LibraryEntryObserving` inputs via `reconcile`).
///
/// The library document is canonical user work with its own prior checkpoints; the derived index lives in
/// Caches and can be deleted at any time. Edits publish immediately through the full publication protocol.
@MainActor
@Observable
final class LibraryDocumentStore {
    static let shared = LibraryDocumentStore()

    private(set) var library: LibraryModel?
    private(set) var index: LibraryIndex?
    private(set) var loadOutcome: LibraryLoadOutcome?
    private(set) var saveStatus: DocumentSaveStatus?
    private(set) var locationStatus: LibraryLocationStatus?
    /// Design L1–L5 library-level state for the message bar.
    private(set) var levelState: LibraryLevelState = .notLoaded
    /// ST-36 summary of the last combine, for the message bar.
    private(set) var lastMergeSummary: LibraryMergeSummary?
    /// L2/L3 queued organizing edits ("Edits waiting").
    private(set) var pendingEditCount = 0
    private(set) var lastPendingOutcome: PendingEditsOutcome?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// Minimum interval between automatic retries while edits are waiting (Design L2: at most every 30 s).
    static let retryInterval: Duration = .seconds(30)

    /// Accessible status for queued edits, e.g. "Edits waiting — 3 library changes not saved yet".
    var pendingEditsStatus: String? {
        guard pendingEditCount > 0 else { return nil }
        return "Edits waiting — \(pendingEditCount) library change\(pendingEditCount == 1 ? "" : "s") not saved yet"
    }

    /// ST-34 text for Quit with queued edits. The journal is durable on this Mac, so nothing is lost on quit;
    /// the wording says so rather than threatening loss.
    var quitWarning: String? {
        guard pendingEditCount > 0 else { return nil }
        return "WaveWrangler couldn't save \(pendingEditCount) library change\(pendingEditCount == 1 ? "" : "s") yet. They're kept on this Mac and will be saved when your library folder is available again."
    }
    /// The most recent failed library publication, presented until the next success.
    private(set) var lastError: PublicationError?

    var isReadOnly: Bool { loadOutcome?.isReadOnly ?? true }

    @ObservationIgnored let store: LibraryStore

    init(store: LibraryStore? = nil) {
        self.store = store ?? LibraryStore(
            containerFolder: (try? LibraryStore.defaultContainerFolder())
                ?? FileManager.default.temporaryDirectory.appending(path: "WaveWrangler/Library", directoryHint: .isDirectory),
            settings: UserDefaultsLibraryLocationSettings(),
            recovery: PersistenceEnvironment.recovery,
            indexCache: LibraryIndexCache(url: (try? LibraryIndexCache.defaultURL())
                ?? FileManager.default.temporaryDirectory.appending(path: "WaveWrangler/LibraryIndex/index.json"))
        )
    }

    @discardableResult
    func load() async -> LibraryLoadOutcome {
        let outcome = await store.load()
        await refresh()
        return outcome
    }

    /// Applies a user library edit (collections, order, aliases…) and publishes it.
    @discardableResult
    func update(_ transform: @Sendable (LibraryModel) throws -> LibraryModel) async -> Bool {
        await ensureLoaded()
        let result = try? await store.update(transform)
        await refresh()
        switch result {
        case .published, .queued, .unchanged: lastError = nil; return true
        case let .failed(error): lastError = error; return false
        case nil: return false
        }
    }

    func reconcile(_ observations: [ShowID: ShowObservation]) async {
        await ensureLoaded()
        if case let .failed(error) = await store.reconcile(observations) { lastError = error }
        await refresh()
    }

    /// C3 step 8 (P7): called only after a show publication was read-back verified.
    func acknowledgeShowPublication(_ showID: ShowID, title: String, publication: PublicationStamp) async {
        await ensureLoaded()
        _ = await store.acknowledgeShowPublication(showID, title: title, publication: publication)
        await store.recordRecent(showID)
        await refresh()
    }

    func recover(revision: Int) async -> Bool {
        let result = await store.recoverAsNewCopy(revision: revision)
        await refresh()
        if case let .failure(error) = result { lastError = error; return false }
        return true
    }

    /// L4 "Combine (Keep Everything)".
    func resolveConflictByCombining() async {
        switch await store.resolveConflictByCombining() {
        case let .success(summary): lastMergeSummary = summary; lastError = nil
        case let .failure(error): lastError = error
        }
        await refresh()
    }

    /// L4 "Use Other Mac's Version" (this Mac's version is kept as a backup copy).
    func resolveConflictUsingOtherVersion() async {
        await store.resolveConflictUsingOtherVersion()
        await refresh()
    }

    /// "Try Again": apply queued edits now if the location is reachable.
    func retryPendingEdits() async {
        lastPendingOutcome = await store.retryPendingEdits()
        if case let .combined(_, summary) = lastPendingOutcome { lastMergeSummary = summary }
        await refresh()
    }

    private func scheduleRetriesIfNeeded() {
        guard pendingEditCount > 0, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retryInterval)
                guard let self, self.pendingEditCount > 0 else { break }
                await self.retryPendingEdits()
            }
            self?.retryTask = nil
        }
    }

    func refresh() async {
        pendingEditCount = await store.pendingEditCount
        if let outcome = await store.lastPendingOutcome { lastPendingOutcome = outcome }
        scheduleRetriesIfNeeded()
        levelState = await store.levelState
        library = await store.library
        index = await store.index
        loadOutcome = await store.lastLoad
        saveStatus = await store.saveStatus
        locationStatus = await store.locationStatus
    }

    private func ensureLoaded() async {
        if await store.lastLoad == nil { await load() }
    }
}

/// Settings-pane controller for the canonical library location (C2a, coordinator decision 2026-10-04;
/// Design merge rules). Default: this Mac's app container. Choosing a folder copies, verifies and switches;
/// the previous location is always kept as a backup and never deleted.
@MainActor
@Observable
final class LibraryLocationController {
    static let shared = LibraryLocationController(library: .shared)

    private let library: LibraryDocumentStore
    /// Outcome of the last choose/combine/move, for the Settings pane to present.
    private(set) var lastOutcome: Result<LibraryMoveOutcome, PublicationError>?
    private(set) var isWorking = false
    private(set) var lastMergeSummary: LibraryMergeSummary?

    init(library: LibraryDocumentStore) {
        self.library = library
    }

    var status: LibraryLocationStatus? { library.locationStatus }

    /// R6 visibility: true while the library lives only in this Mac's container.
    var isStoredOnThisMacOnly: Bool {
        if case .appContainer = library.locationStatus { return true }
        return false
    }

    /// The user chose `folder` in an `NSOpenPanel`. If it already contains a different library the outcome is
    /// `.destinationHasLibrary`; then offer "Use That Library" (`useLibrary(in:)`) or Cancel.
    func choose(_ folder: URL) async {
        await run { await $0.moveLibrary(to: folder) }
    }

    /// "Use That Library": combine this Mac's library into the one in `folder` (nothing dropped) and switch.
    func useLibrary(in folder: URL) async {
        await run { await $0.useLibrary(in: folder) }
    }

    func moveToThisMac() async {
        await run { await $0.moveLibraryToAppContainer() }
    }

    private func run(_ operation: (LibraryStore) async -> Result<LibraryMoveOutcome, PublicationError>) async {
        isWorking = true
        defer { isWorking = false }
        if await library.store.lastLoad == nil { await library.load() }
        lastOutcome = await operation(library.store)
        await library.refresh()
        if case let .success(.combined(_, _, summary)) = lastOutcome { lastMergeSummary = summary }
    }
}
