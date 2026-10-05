import AppKit
import Foundation
import Observation
import WWCore
import WWOrganizer
import WWPersistence

/// Connects the library UI seams (`LibraryPersisting`, `LibraryLocationControlling`) to the persistence
/// lane's `LibraryDocumentStore` and `LibraryLocationController` (Document/). Pure mapping; all I/O stays in
/// WWPersistence's actor-isolated store.
@MainActor
@Observable
final class PersistenceLibraryBackend: LibraryPersisting, LibraryLocationControlling {
    @ObservationIgnored let store: LibraryDocumentStore
    @ObservationIgnored let controller: LibraryLocationController
    private(set) var resultMessage: String?

    init(store: LibraryDocumentStore = .shared, controller: LibraryLocationController = .shared) {
        self.store = store
        self.controller = controller
    }

    enum AdapterError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            }
        }
    }

    // MARK: - LibraryPersisting

    var isDurable: Bool { true }
    var currentLibrary: LibraryModel? { store.library }

    func loadLibrary() async throws -> LibraryModel {
        let outcome = await store.load()
        if let library = store.library { return library }
        throw AdapterError.unavailable(Self.describe(outcome))
    }

    func applyEdit(_ transform: @escaping @Sendable (LibraryModel) -> LibraryModel) async throws -> LibraryModel {
        let base = store.library
        guard await store.update({ transform($0) }) else {
            throw AdapterError.unavailable(store.lastError?.localizedDescription ?? "the library couldn't be updated")
        }
        // While edits are queued (L2/L3) the canonical value hasn't changed yet; show the queued result.
        if store.pendingEditCount > 0, let base { return transform(store.library ?? base) }
        return store.library ?? transform(base ?? LibraryModel())
    }

    private static func describe(_ outcome: LibraryLoadOutcome) -> String {
        switch outcome {
        case .ready, .created: "the library loaded without content"
        case .refusedNewerFormat: "the library was saved by a newer version of WaveWrangler"
        case .needsMigration: "the library needs to be updated to the current format"
        case .damaged(let reason, _): "the library is damaged (\(reason))"
        case .unavailable(let reason): reason
        @unknown default: "the library couldn't be read"
        }
    }

    // MARK: - LibraryLocationControlling

    var location: LibraryLocationChoice {
        switch store.locationStatus {
        case .folder(let url, _): .folder(displayName: url.lastPathComponent)
        case .unavailable(let path, _): .folder(displayName: (path as NSString).lastPathComponent)
        case .appContainer, nil: .inWaveWrangler
        @unknown default: .inWaveWrangler
        }
    }

    private var folderDisplayName: String {
        if case .folder(let name) = location { return name }
        return LibraryLocationChoice.inWaveWranglerTitle
    }

    var libraryState: WWOrganizer.LibraryLevelState {
        switch store.levelState {
        case .notLoaded, .ready: .ready
        case .unreachable: .unreachable(folderDisplayName: folderDisplayName, pendingChanges: store.pendingEditCount)
        case .needsPermission: .needsPermission(pendingChanges: store.pendingEditCount)
        case .changedElsewhere: .conflict
        case .newerFormat: .newerFormat(folderDisplayName: folderDisplayName)
        case .damaged: .damaged
        @unknown default: .damaged
        }
    }

    var movePhase: LibraryMovePhase? { controller.isWorking ? .copying : nil }
    var isConnected: Bool { true }
    var pendingEditsStatus: String? { store.pendingEditsStatus }
    var quitWarning: String? { store.quitWarning }

    func dismissResultMessage() { resultMessage = nil }

    func moveLibrary(to folder: URL?) async -> LibraryMoveResult {
        let previous = folderDisplayName
        if let folder {
            await controller.choose(folder)
        } else {
            await controller.moveToThisMac()
        }
        return result(previous: previous)
    }

    func useExistingLibrary(in folder: URL) async -> LibraryMoveResult {
        let previous = folderDisplayName
        await controller.useLibrary(in: folder)
        return result(previous: previous)
    }

    private func result(previous: String) -> LibraryMoveResult {
        switch controller.lastOutcome {
        case .success(.moved(let url, let kept)):
            let message = LibraryMoveWording.moved(to: url.lastPathComponent, previous: kept.deletingLastPathComponent().lastPathComponent)
            resultMessage = message
            return .moved(message: message)
        case .success(.adoptedIdentical(let url)):
            let message = "Your library is now stored in “\(url.lastPathComponent)”. It already had the same library."
            resultMessage = message
            return .moved(message: message)
        case .success(.destinationHasLibrary(let url, _)):
            return .destinationHasLibrary(folder: url, blockedReason: nil)
        case .success(.destinationUnusable(_, let reason)):
            return .failed(reason: "\(reason). WaveWrangler is still using your library in \(previous); nothing was changed.")
        case .success(.combined(_, _, let summary)):
            let message = Self.combineMessage(summary)
            resultMessage = message
            return .moved(message: message)
        case .failure(let error):
            return .failed(reason: "\(error.localizedDescription). WaveWrangler is still using your library in \(previous); nothing was changed.")
        case .none:
            return .failed(reason: "the move didn't complete. WaveWrangler is still using your library in \(previous); nothing was changed.")
        @unknown default:
            return .failed(reason: "the move didn't complete. WaveWrangler is still using your library in \(previous); nothing was changed.")
        }
    }

    /// ST-36 summary plus queued edits that couldn't be carried (kept in a backup copy on this Mac).
    static func combineMessage(_ summary: LibraryMergeSummary) -> String {
        var text = summary.message
        if let notCarried = LibraryMoveWording.queuedChangesNotCarried(summary.queuedChangesNotCarried) {
            text += " " + notCarried
        }
        return text
    }

    func cancelMove() {
        // The persistence controller's copy → verify → switch can't be interrupted from outside; the old
        // location stays in use until verification, so nothing is lost by letting it finish.
    }

    func perform(_ action: LibraryLevelAction) async {
        switch action {
        case .tryAgain:
            await store.retryPendingEdits()
        case .combine:
            await store.resolveConflictByCombining()
            if let summary = store.lastMergeSummary { resultMessage = Self.combineMessage(summary) }
        case .useOtherMacsVersion:
            await store.resolveConflictUsingOtherVersion()
            resultMessage = "Using the other Mac's library. This Mac's version was kept as a backup copy."
        case .grantAccess:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose your library folder again to let WaveWrangler use it."
            if case .folder(let url, _) = store.locationStatus { panel.directoryURL = url }
            guard await panel.begin() == .OK, let url = panel.url else { return }
            await controller.choose(url)
            await store.refresh()
        case .recoverEarlierVersion:
            if case .damaged(let revisions) = store.levelState, let newest = revisions.max() {
                _ = await store.recover(revision: newest)
            }
        case .librarySettings:
            SettingsWindowController.show(pane: .general)
        }
    }
}
