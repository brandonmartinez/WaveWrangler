import AppKit
import Foundation
import Observation
import WWCore
import WWOrganizer
import WWPersistence

/// Device-local, persisted per-show library details (#88): where each show was last opened or saved on
/// this Mac (read-write bookmark via `LibraryShowLocations`) and its "as of last open" summary. Survives
/// relaunch. Checks run off the main thread and always end in a definite state (never an endless
/// "Checking…"). Opening resolves the bookmark, verifies the ShowID before trusting the file, and holds the
/// security scope only while that show is open.
@MainActor
@Observable
final class PersistentLibraryEntryObserver: LibraryEntryObserving {
    private(set) var details: [ShowID: LibraryEntryDetails] = [:]
    @ObservationIgnored let store: LibraryShowLocations
    @ObservationIgnored private var pathHints: [ShowID: String] = [:]
    @ObservationIgnored private var grants: [ShowID: ShowAccessGrant] = [:]
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    /// Bumped whenever an entry changes outside a check (window open, collision), so a check that started
    /// earlier can't overwrite newer state.
    @ObservationIgnored private var generations: [ShowID: Int] = [:]
    /// Store writes run one after another, in call order.
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    /// The app's store: device-local, inside the sandbox container (isolated for UI-test runs).
    static func makeDefault() -> PersistentLibraryEntryObserver {
        PersistentLibraryEntryObserver(store: LibraryShowLocations(root: PersistenceEnvironment.applicationSupport("LibraryShowLocations")))
    }

    init(store: LibraryShowLocations) {
        self.store = store
        for (id, summary) in store.allSummaries() {
            details[id] = Self.details(from: summary, state: .checking)
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // Let AppKit finish removing the document, then release scopes of shows that are no longer open.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.releaseClosedGrants() } }
        }
    }

    // MARK: - Checking

    func refresh(_ ids: [ShowID]) async {
        guard !ids.isEmpty else { return }
        for id in ids where !Self.isCollision(details[id]?.state) {
            details[id, default: LibraryEntryDetails()].state = .checking
        }
        let started = Dictionary(uniqueKeysWithValues: ids.map { ($0, generations[$0, default: 0]) })
        let store = self.store
        let checked = await Task.detached(priority: .userInitiated) {
            ids.map { id in (id, store.check(id), store.pathHint(for: id)) }
        }.value
        var results: [LibraryEntryCheckResult] = []
        for (id, check, hint) in checked {
            if let hint { pathHints[id] = hint }
            results.append(LibraryEntryCheckResult(showID: id, generation: started[id] ?? 0, observation: Self.observation(check)))
        }
        details = LibraryEntryRefresh.apply(results, to: details, currentGenerations: generations)
    }

    static func observation(_ check: ShowLocationCheck) -> LibraryEntryCheckResult.Observation {
        switch check {
        case .unknown: .unknown
        case .reachable(let folder): .reachable(folderDisplayName: folder)
        case .notFound(let folder): .notFound(folderDisplayName: folder)
        case .needsPermission: .needsPermission
        case .unavailable: .unavailable
        }
    }

    /// Runs store writes serially in call order (no older write lands after a newer one).
    private func enqueueWrite(_ work: @escaping @Sendable () -> Void) {
        let previous = writeChain
        writeChain = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }

    // MARK: - Recording (from open show windows)

    func noteOpenShow(id: ShowID, model: ShowDocumentModel?, fileURL: URL?) {
        // Two open files with the same show identity (e.g. a Finder copy): surface it, never merge.
        let others = NSDocumentController.shared.documents.compactMap { $0 as? ShowDocument }.filter {
            $0.store.model.show.id == id && $0.fileURL != nil && $0.fileURL?.standardizedFileURL != fileURL?.standardizedFileURL
        }
        generations[id, default: 0] += 1
        if let other = others.first, fileURL != nil {
            var entry = details[id] ?? LibraryEntryDetails()
            entry.state = .identityCollision(otherLocationDisplayName: other.fileURL?.deletingLastPathComponent().lastPathComponent)
            details[id] = entry
            return
        }
        var entry = details[id] ?? LibraryEntryDetails()
        entry.state = .available
        if let fileURL { entry.locationDisplayName = fileURL.deletingLastPathComponent().lastPathComponent }
        let summary = model.map(Self.summary)
        if let summary {
            entry.episodes = summary.episodes?.map { EpisodeSummary(id: $0.id, number: $0.number, title: $0.title) }
            entry.sourceReferenceCount = summary.sourceReferenceCount
        }
        details[id] = entry
        guard let fileURL else { return }
        pathHints[id] = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let store = self.store
        // Bookmark creation and the record write are file I/O: off the main thread, in order.
        enqueueWrite { try? store.record(id, at: fileURL, summary: summary) }
    }

    func noteOpened(id: ShowID) {
        let now = Date()
        details[id, default: LibraryEntryDetails(state: .available)].lastOpened = now
        let store = self.store
        enqueueWrite { store.noteOpened(id, at: now) }
    }

    // MARK: - Opening

    func openShow(_ id: ShowID, readOnly: Bool) async throws {
        if let open = NSDocumentController.shared.documents.compactMap({ $0 as? ShowDocument }).first(where: { $0.store.model.show.id == id }) {
            open.showWindows()
            return
        }
        let store = self.store
        let opener = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: nil)
        do {
            // Resolve, start the scope and verify the ShowID; the store ends access exactly once on any
            // failure, including a failed NSDocument open below.
            let grant = try await store.openVerified(id, opener: opener) { grant in
                let (document, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: grant.url, display: true)
                guard let show = document as? ShowDocument, show.store.model.show.id == id else {
                    if !alreadyOpen { document.close() }
                    throw LibraryBackendError.differentShow
                }
            }
            if let previous = grants[id] { store.endAccess(previous) }
            grants[id] = grant
        } catch let error as ShowAccessError {
            details[id, default: LibraryEntryDetails()].state = Self.state(for: error)
            throw Self.backendError(for: error)
        } catch let error as ShowOpenError {
            if case .differentShow(let folder) = error {
                details[id, default: LibraryEntryDetails()].state = .notFound(folderDisplayName: folder)
            }
            throw LibraryBackendError.differentShow
        }
    }

    /// Stops the security scope of shows whose last window closed.
    private func releaseClosedGrants() {
        let openIDs = Set(NSDocumentController.shared.documents.compactMap { ($0 as? ShowDocument)?.store.model.show.id })
        for (id, grant) in grants where !openIDs.contains(id) {
            store.endAccess(grant)
            grants[id] = nil
        }
    }

    func locateShow(_ id: ShowID) async throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wwShow]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the show file. WaveWrangler checks the show inside the file, not its name."
        if let hint = pathHints[id] { panel.directoryURL = URL(filePath: hint).deletingLastPathComponent() }
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let document = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        guard let show = document.0 as? ShowDocument else { throw LibraryBackendError.notAShowFile }
        guard show.store.model.show.id == id else { throw LibraryBackendError.differentShow }
        // The window's open records the new location (read-write bookmark) via `noteOpenShow`.
    }

    func canRevealShow(_ id: ShowID) -> Bool { pathHints[id] != nil }

    func revealShowInFinder(_ id: ShowID) -> Bool {
        guard let hint = pathHints[id] else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: hint)])
        return true
    }

    // MARK: - Mapping

    static func summary(_ model: ShowDocumentModel) -> ShowLastOpenSummary {
        ShowLastOpenSummary(
            showID: model.show.id,
            episodes: model.episodes.map { .init(id: $0.id, number: $0.number, title: $0.title) },
            sourceReferenceCount: model.episodes.reduce(0) { $0 + $1.sources.count }
        )
    }

    static func details(from summary: ShowLastOpenSummary, state: LibraryEntryState) -> LibraryEntryDetails {
        LibraryEntryDetails(
            state: state,
            locationDisplayName: summary.folderDisplayName,
            lastOpened: summary.lastOpened,
            episodes: summary.episodes?.map { EpisodeSummary(id: $0.id, number: $0.number, title: $0.title) },
            sourceReferenceCount: summary.sourceReferenceCount
        )
    }

    static func state(for error: ShowAccessError) -> LibraryEntryState {
        switch error {
        case .noRecord: .locationUnknown
        case .needsPermission: .needsPermission
        case .notFound(let folder): .notFound(folderDisplayName: folder)
        }
    }

    static func backendError(for error: ShowAccessError) -> LibraryBackendError {
        switch error {
        case .noRecord: .showLocationUnknown
        case .needsPermission: .needsPermission
        case .notFound: .showNotFound
        }
    }

    private static func isCollision(_ state: LibraryEntryState?) -> Bool {
        if case .identityCollision = state { return true }
        return false
    }
}
