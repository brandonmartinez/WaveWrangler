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
/// actor; `async` lets them hop to their own executor. Edits are applied as transforms on the canonical
/// value (never whole snapshots), so they compose with changes made elsewhere (another Mac, verified show
/// saves acknowledged by persistence).
@MainActor
protocol LibraryPersisting: AnyObject {
    /// `false` while the library lives only in memory; the Library window says so honestly.
    var isDurable: Bool { get }
    /// The canonical value as storage currently knows it (observable); `nil` until loaded.
    var currentLibrary: LibraryModel? { get }
    func loadLibrary() async throws -> LibraryModel
    /// Applies `transform` to the canonical value and publishes it; returns the new canonical value.
    func applyEdit(_ transform: @escaping @Sendable (LibraryModel) -> LibraryModel) async throws -> LibraryModel
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
    /// `model` is `nil` when the window has unsaved edits (only the location and open time are recorded).
    func noteOpenShow(id: ShowID, model: ShowDocumentModel?, fileURL: URL?)
    /// The show was opened (for "Last Opened").
    func noteOpened(id: ShowID)
}

extension UTType {
    static var wwShow: UTType { UTType(DocumentTypes.show) ?? .json }
}

/// Result of choosing a library location (states-and-recovery §5.1, ST-33).
enum LibraryMoveResult: Equatable, Sendable {
    /// Switched after verification; `message` is the message-bar text.
    case moved(message: String)
    /// The folder already has a WaveWrangler library: offer Use That Library (disabled with `blockedReason`).
    case destinationHasLibrary(folder: URL, blockedReason: String?)
    case failed(reason: String)
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
    /// "Edits waiting — n library changes not saved yet" while edits are queued (L2/L3).
    var pendingEditsStatus: String? { get }
    /// ST-34 quit text when queued edits exist (they're kept on this Mac).
    var quitWarning: String? { get }
    /// Outcome text for the message bar (moves, combine summaries incl. edits not carried).
    var resultMessage: String? { get }
    /// #117: cloud-provider conflict versions of the library that WaveWrangler can't use (unreadable, or another
    /// library). Kept, never applied; the Library window says so until they're gone.
    var providerConflictNotice: String? { get }
    func dismissResultMessage()
    /// Moves the library to `folder` (`nil` = back into WaveWrangler). Switches only after verification;
    /// on failure the old location stays in use and unchanged; the old copy is never deleted.
    func moveLibrary(to folder: URL?) async -> LibraryMoveResult
    /// "Use That Library": combine into the library already in `folder` (ST-36), then switch.
    func useExistingLibrary(in folder: URL) async -> LibraryMoveResult
    func cancelMove()
    /// Performs a library-level action; may ask the window to offer a choice (e.g. a different library).
    func perform(_ action: LibraryLevelAction) async -> LibraryActionFollowUp
    /// "Use That Library" for the folder offered by the last `.offerDifferentLibrary` follow-up.
    func useOfferedLibrary() async -> LibraryMoveResult
}

/// Errors the in-memory stand-in reports in plain language.
enum LibraryBackendError: LocalizedError {
    case showLocationUnknown
    case notAShowFile
    case differentShow
    case libraryStorageNotConnected
    case needsPermission
    case showNotFound

    var errorDescription: String? {
        switch self {
        case .showLocationUnknown: "WaveWrangler doesn't know where this show is saved on this Mac. Use Locate… to choose it."
        case .notAShowFile: "That file isn't a WaveWrangler show."
        case .differentShow: "That file is a different show, so it wasn't linked."
        case .libraryStorageNotConnected: "moving the library isn't available in this version yet"
        case .needsPermission: "WaveWrangler needs your permission to open this show again. Use Grant Access… to choose it."
        case .showNotFound: "WaveWrangler can't find this show where it was last saved. Use Locate… to find it."
        }
    }
}

/// The services the library UI uses. The app delegate installs real implementations when available.
@MainActor
struct LibraryServices {
    var persistence: LibraryPersisting
    var entries: LibraryEntryObserving
    var location: LibraryLocationControlling

    /// Canonical library storage and location come from the persistence lane; per-show locations and
    /// "as of last open" details are device-local and persisted (`PersistentLibraryEntryObserver`).
    static var current: LibraryServices = {
        let observer = PersistentLibraryEntryObserver.makeDefault()
        let persistence = PersistenceLibraryBackend()
        return LibraryServices(persistence: persistence, entries: observer, location: persistence)
    }()
}

/// In-memory library backend: the per-show details observer in normal runs, and the whole library for UI
/// tests and previews. Keeps data for this run only and learns show locations from shows opened in this
/// run (location hints, never identity).
@MainActor
@Observable
final class InMemoryLibraryBackend: LibraryPersisting, LibraryEntryObserving, LibraryLocationControlling {
    @ObservationIgnored private var stored = LibraryModel()
    private(set) var details: [ShowID: LibraryEntryDetails] = [:]
    @ObservationIgnored private var locations: [ShowID: URL] = [:]
    let location = LibraryLocationChoice.inWaveWrangler
    let libraryState = LibraryLevelState.ready
    let movePhase: LibraryMovePhase? = nil
    let isConnected = false
    let pendingEditsStatus: String? = nil
    let quitWarning: String? = nil
    let resultMessage: String? = nil
    /// UI tests set this through `-WWUITestProviderConflicts n`.
    var providerConflictNotice: String?

    func dismissResultMessage() {}

    var isDurable: Bool { false }

    init(seed: LibraryModel = LibraryModel(), details: [ShowID: LibraryEntryDetails] = [:]) {
        stored = seed
        self.details = details
    }

    var currentLibrary: LibraryModel? { stored }

    func loadLibrary() async throws -> LibraryModel { stored }

    func applyEdit(_ transform: @escaping @Sendable (LibraryModel) -> LibraryModel) async throws -> LibraryModel {
        stored = transform(stored)
        return stored
    }

    func refresh(_ ids: [ShowID]) async {
        for id in ids where details[id]?.state == .checking || details[id] == nil {
            details[id, default: LibraryEntryDetails()].state = locations[id] == nil ? .checking : .available
        }
    }

    /// Records what an open show window knows ("as of last open").
    func noteOpenShow(id: ShowID, model: ShowDocumentModel?, fileURL: URL?) {
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
        let episodes = model.map { $0.episodes.map { EpisodeSummary(id: $0.id, number: $0.number, title: $0.title) } } ?? details[id]?.episodes
        let refs = model.map { $0.episodes.reduce(0) { $0 + $1.sources.count } } ?? details[id]?.sourceReferenceCount
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
        let interval = OpenSignposts.begin("library.openShow")
        defer { OpenSignposts.end(interval) }
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

    func moveLibrary(to folder: URL?) async -> LibraryMoveResult {
        .failed(reason: LibraryBackendError.libraryStorageNotConnected.localizedDescription)
    }

    func useExistingLibrary(in folder: URL) async -> LibraryMoveResult {
        .failed(reason: LibraryBackendError.libraryStorageNotConnected.localizedDescription)
    }

    func cancelMove() {}

    func perform(_ action: LibraryLevelAction) async -> LibraryActionFollowUp { .none }

    func useOfferedLibrary() async -> LibraryMoveResult {
        .failed(reason: LibraryBackendError.libraryStorageNotConnected.localizedDescription)
    }
}
