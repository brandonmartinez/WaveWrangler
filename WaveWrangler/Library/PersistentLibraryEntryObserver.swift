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
        let toCheck = ids.filter { !Self.isCollision(details[$0]?.state) }
        guard !toCheck.isEmpty else { return }
        for id in toCheck { details[id, default: LibraryEntryDetails()].state = .checking }
        let store = self.store
        let results = await Task.detached(priority: .userInitiated) {
            toCheck.map { id in (id, store.check(id), store.pathHint(for: id)) }
        }.value
        for (id, check, hint) in results {
            if let hint { pathHints[id] = hint }
            var entry = details[id] ?? LibraryEntryDetails()
            switch check {
            case .unknown:
                entry.state = .locationUnknown
            case .reachable(let folder):
                entry.state = .available
                entry.locationDisplayName = folder
            case .notFound(let folder):
                entry.state = .notFound(folderDisplayName: folder)
            case .needsPermission:
                entry.state = .needsPermission
            case .unavailable:
                entry.state = .locationUnavailable
            }
            details[id] = entry
        }
    }

    // MARK: - Recording (from open show windows)

    func noteOpenShow(id: ShowID, model: ShowDocumentModel?, fileURL: URL?) {
        // Two open files with the same show identity (e.g. a Finder copy): surface it, never merge.
        let others = NSDocumentController.shared.documents.compactMap { $0 as? ShowDocument }.filter {
            $0.store.model.show.id == id && $0.fileURL != nil && $0.fileURL?.standardizedFileURL != fileURL?.standardizedFileURL
        }
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
        // Bookmark creation and the record write are file I/O: keep them off the main thread.
        Task.detached(priority: .utility) {
            try? store.record(id, at: fileURL, summary: summary)
        }
    }

    func noteOpened(id: ShowID) {
        let now = Date()
        details[id, default: LibraryEntryDetails(state: .available)].lastOpened = now
        let store = self.store
        Task.detached(priority: .utility) { store.noteOpened(id, at: now) }
    }

    // MARK: - Opening

    func openShow(_ id: ShowID, readOnly: Bool) async throws {
        if let open = NSDocumentController.shared.documents.compactMap({ $0 as? ShowDocument }).first(where: { $0.store.model.show.id == id }) {
            open.showWindows()
            return
        }
        let store = self.store
        let access: Result<ShowAccessGrant, ShowAccessError> = await Task.detached(priority: .userInitiated) {
            do throws(ShowAccessError) {
                return .success(try store.beginAccess(id))
            } catch {
                return .failure(error)
            }
        }.value
        let grant: ShowAccessGrant
        switch access {
        case .success(let value):
            grant = value
        case .failure(let error):
            details[id, default: LibraryEntryDetails()].state = Self.state(for: error)
            throw Self.backendError(for: error)
        }
        // Verify the ShowID before trusting the resolved file (a different show may be at that path).
        let identity = await Task.detached(priority: .userInitiated) {
            DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: nil).open(grant.url, key: .show(id))
        }.value
        if case .damaged(.identityMismatch, _) = identity {
            store.endAccess(grant)
            details[id, default: LibraryEntryDetails()].state = .notFound(folderDisplayName: grant.url.deletingLastPathComponent().lastPathComponent)
            throw LibraryBackendError.differentShow
        }
        do {
            let (document, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: grant.url, display: true)
            guard let show = document as? ShowDocument, show.store.model.show.id == id else {
                if !alreadyOpen { document.close() }
                store.endAccess(grant)
                throw LibraryBackendError.differentShow
            }
            if let previous = grants[id] { store.endAccess(previous) }
            grants[id] = grant
        } catch {
            if grants[id] != grant { store.endAccess(grant) }
            throw error
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
