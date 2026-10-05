import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WWCore
import WWOrganizer

// Seams between the library UI and the persistence lane (library store, reconciliation, location).
// The Library window talks only to these protocols. `InMemoryLibraryBackend` stands in until the real
// implementations merge; it never claims durability it doesn't have.

/// Canonical library document storage (`.wwlibrary`). Implementations must not do file I/O on the main
/// actor; `async` lets them hop to their own executor.
@MainActor
protocol LibraryPersisting: AnyObject {
    /// `false` while the library lives only in memory; the Library window says so honestly.
    var isDurable: Bool { get }
    func loadLibrary() async throws -> LibraryModel
    func saveLibrary(_ model: LibraryModel) async throws
}

/// Derived, device-local per-show details and the actions that need show locations. Observable.
@MainActor
protocol LibraryEntryObserving: AnyObject {
    var details: [ShowID: LibraryEntryDetails] { get }
    /// Re-observe entries (Try Again / Rebuild Library Index…). Never on the main thread's I/O path.
    func refresh(_ ids: [ShowID]) async
    func openShow(_ id: ShowID, readOnly: Bool) async throws
    func revealShowInFinder(_ id: ShowID) -> Bool
    /// Locate…/Grant Access…: lets the user pick the show file; the implementation matches by the show
    /// identity inside the file, never by name.
    func locateShow(_ id: ShowID) async throws
    func canRevealShow(_ id: ShowID) -> Bool
    /// Reconciliation input from an open show window: the document is authoritative for show content.
    func noteOpenShow(id: ShowID, model: ShowDocumentModel, fileURL: URL?)
    /// The show was opened (for "Last Opened").
    func noteOpened(id: ShowID)
}

extension UTType {
    static var wwShow: UTType { UTType(DocumentTypes.show) ?? .json }
}

/// Settings › General › Library location and library-level states (states-and-recovery §5.1; the
/// persistence lane's `LibraryLocationController`). Observable.
@MainActor
protocol LibraryLocationControlling: AnyObject {
    var location: LibraryLocationChoice { get }
    var libraryState: LibraryLevelState { get }
    /// Non-nil while a copy → verify → retire move is in progress.
    var movePhase: LibraryMovePhase? { get }
    /// `false` while library storage isn't connected in this build; Settings says so.
    var isConnected: Bool { get }
    /// Moves the library to `folder` (`nil` = back into WaveWrangler). Switches only after verification;
    /// on failure the old location stays in use and unchanged.
    func moveLibrary(to folder: URL?) async throws
    func cancelMove()
    func perform(_ action: LibraryLevelAction) async
}

/// Errors the in-memory stand-in reports in plain language.
enum LibraryBackendError: LocalizedError {
    case showLocationUnknown
    case notAShowFile
    case differentShow
    case libraryStorageNotConnected

    var errorDescription: String? {
        switch self {
        case .showLocationUnknown: "WaveWrangler doesn't know where this show is saved on this Mac. Use Locate… to choose it."
        case .notAShowFile: "That file isn't a WaveWrangler show."
        case .differentShow: "That file is a different show, so it wasn't linked."
        case .libraryStorageNotConnected: "moving the library isn't available in this version yet"
        }
    }
}

/// The services the library UI uses. The app delegate installs real implementations when available.
@MainActor
struct LibraryServices {
    var persistence: LibraryPersisting
    var entries: LibraryEntryObserving
    var location: LibraryLocationControlling

    static var current: LibraryServices = {
        let backend = InMemoryLibraryBackend()
        return LibraryServices(persistence: backend, entries: backend, location: backend)
    }()
}

/// In-memory stand-in for the persistence lane's library store. Keeps library data for this run only
/// and learns show locations from shows the user opens in this run (location hints, never identity).
@MainActor
@Observable
final class InMemoryLibraryBackend: LibraryPersisting, LibraryEntryObserving, LibraryLocationControlling {
    private var stored = LibraryModel()
    private(set) var details: [ShowID: LibraryEntryDetails] = [:]
    @ObservationIgnored private var locations: [ShowID: URL] = [:]
    let location = LibraryLocationChoice.inWaveWrangler
    let libraryState = LibraryLevelState.ready
    let movePhase: LibraryMovePhase? = nil
    let isConnected = false

    var isDurable: Bool { false }

    init(seed: LibraryModel = LibraryModel(), details: [ShowID: LibraryEntryDetails] = [:]) {
        stored = seed
        self.details = details
    }

    func loadLibrary() async throws -> LibraryModel { stored }

    func saveLibrary(_ model: LibraryModel) async throws { stored = model }

    func refresh(_ ids: [ShowID]) async {
        for id in ids where details[id]?.state == .checking || details[id] == nil {
            details[id, default: LibraryEntryDetails()].state = locations[id] == nil ? .checking : .available
        }
    }

    /// Records what an open show window knows ("as of last open").
    func noteOpenShow(id: ShowID, model: ShowDocumentModel, fileURL: URL?) {
        // Two open files with the same show identity (e.g. a Finder copy): surface it, never merge.
        let others = NSDocumentController.shared.documents.compactMap { $0 as? ShowDocument }.filter {
            $0.store.model.show.id == id && $0.fileURL != nil && $0.fileURL?.standardizedFileURL != fileURL?.standardizedFileURL
        }
        if let other = others.first, fileURL != nil {
            details[id] = LibraryEntryDetails(
                state: .identityCollision(otherLocationDisplayName: other.fileURL?.deletingLastPathComponent().lastPathComponent),
                locationDisplayName: fileURL.map { $0.deletingLastPathComponent().lastPathComponent },
                lastOpened: details[id]?.lastOpened ?? Date(),
                episodes: details[id]?.episodes,
                sourceReferenceCount: details[id]?.sourceReferenceCount
            )
            return
        }
        if let fileURL { locations[id] = fileURL }
        let episodes = model.episodes.map { EpisodeSummary(id: $0.id, number: $0.number, title: $0.title) }
        let refs = model.episodes.reduce(0) { $0 + $1.sources.count }
        details[id] = LibraryEntryDetails(
            state: .available,
            locationDisplayName: fileURL.map { $0.deletingLastPathComponent().lastPathComponent },
            lastOpened: details[id]?.lastOpened ?? Date(),
            episodes: episodes,
            sourceReferenceCount: refs
        )
    }

    func noteOpened(id: ShowID) {
        details[id, default: LibraryEntryDetails(state: .available)].lastOpened = Date()
    }

    func openShow(_ id: ShowID, readOnly: Bool) async throws {
        guard let url = locations[id] else { throw LibraryBackendError.showLocationUnknown }
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
    }

    func canRevealShow(_ id: ShowID) -> Bool { locations[id] != nil }

    func revealShowInFinder(_ id: ShowID) -> Bool {
        guard let url = locations[id] else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    func locateShow(_ id: ShowID) async throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wwShow]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the show file. WaveWrangler checks the show inside the file, not its name."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let document = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        guard let show = document.0 as? ShowDocument else { throw LibraryBackendError.notAShowFile }
        guard show.store.model.show.id == id else { throw LibraryBackendError.differentShow }
    }

    func moveLibrary(to folder: URL?) async throws {
        throw LibraryBackendError.libraryStorageNotConnected
    }

    func cancelMove() {}

    func perform(_ action: LibraryLevelAction) async {}
}
