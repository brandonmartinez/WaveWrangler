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
        let base = store.library ?? LibraryModel()
        guard await store.update({ transform($0) }) else {
            throw AdapterError.unavailable(store.lastError?.localizedDescription ?? "the library couldn't be updated")
        }
        // Published: the store's library already contains the edit. Queued (L2/L3): the store still shows
        // the last published value, so show the edit applied once to the value it was made against.
        if store.pendingEditCount > 0, store.library == base || store.library == nil { return transform(base) }
        return store.library ?? transform(base)
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
        case .folder(let url, _): .folder(displayName: LibraryFolderURL.displayName(for: url))
        case .unavailable(let path, _): .folder(displayName: LibraryFolderURL.displayName(for: URL(filePath: path)))
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
        case .newerFormat:
            store.library == nil
                ? .newerFormatNotViewable(folderDisplayName: folderDisplayName)
                : .newerFormat(folderDisplayName: folderDisplayName)
        case .damaged: .damaged
        @unknown default: .damaged
        }
    }

    var movePhase: LibraryMovePhase? { controller.isWorking ? .copying : nil }
    var isConnected: Bool { true }
    var pendingEditsStatus: String? { store.pendingEditsStatus }
    /// ST-34. Queued edits are kept on this Mac. With L3 they need Grant Access, not just the folder coming back.
    var quitWarning: String? {
        guard let warning = store.quitWarning else { return nil }
        if case .needsPermission = store.levelState {
            let count = store.pendingEditCount
            return "WaveWrangler couldn't save \(count) library change\(count == 1 ? "" : "s") yet. They're kept on this Mac and will be saved after you choose Grant Access… in the Library window to let WaveWrangler use your library folder again."
        }
        return warning
    }

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
            // Persistence reports library *file* URLs; name folders.
            let message = LibraryMoveWording.moved(to: LibraryFolderURL.displayName(for: url), previous: LibraryFolderURL.displayName(for: kept))
            resultMessage = message
            return .moved(message: message)
        case .success(.adoptedIdentical(let url)):
            let message = "Your library is now stored in “\(LibraryFolderURL.displayName(for: url))”. That folder already had an identical copy, so nothing needed to be copied."
            resultMessage = message
            return .moved(message: message)
        case .success(.destinationHasLibrary(let url, _)):
            return .destinationHasLibrary(folder: LibraryFolderURL.folder(for: url), blockedReason: nil)
        case .success(.destinationUnusable(let url, let reason)):
            // The folder has a library this version can't use (unreachable, needs permission, newer format,
            // damaged): offer the sheet with Use That Library disabled and the reason (ST-33 step 6).
            return .destinationHasLibrary(folder: LibraryFolderURL.folder(for: url), blockedReason: LibraryUIStore.sentence(reason) + " Nothing was written to the folder, and your current library is still in use.")
        case .success(.combined(_, _, let summary)):
            let message = Self.combineMessage(summary)
            resultMessage = message
            return .moved(message: message)
        case .failure(let error):
            return .failed(reason: "\(LibraryUIStore.sentence(error.localizedDescription)) WaveWrangler is still using your library in \(previous); nothing was changed.")
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

    /// Folder offered after Grant Access… found a different library (nothing changed yet).
    @ObservationIgnored private var offeredFolder: URL?

    func perform(_ action: LibraryLevelAction) async -> LibraryActionFollowUp {
        switch action {
        case .tryAgain:
            await store.retryPendingEdits()
            await controller.reload()
        case .combine:
            await store.resolveConflictByCombining()
            if let summary = store.lastMergeSummary { resultMessage = Self.combineMessage(summary) }
        case .useOtherMacsVersion:
            await store.resolveConflictUsingOtherVersion()
            await controller.reload()
            resultMessage = "Using the other Mac's library. This Mac's version was kept as a backup copy."
        case .grantAccess:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = LibraryRegrantWording.panelMessage
            panel.prompt = "Grant Access"
            switch store.locationStatus {
            case .folder(let url, _): panel.directoryURL = LibraryFolderURL.folder(for: url)
            case .unavailable(let path, _): panel.directoryURL = LibraryFolderURL.folder(for: URL(filePath: path))
            default: break
            }
            guard await panel.begin() == .OK, let url = panel.url else { return .none }
            await controller.regrantAccess(to: url)
            guard let outcome = controller.lastRegrantOutcome else { return .none }
            let result = Self.map(outcome)
            // Outcomes carry the library file URL; Use That Library needs the folder the user chose.
            if case .differentLibrary = outcome { offeredFolder = url }
            resultMessage = LibraryRegrantWording.message(for: result)
            return LibraryRegrantWording.followUp(for: result)
        case .recoverEarlierVersion:
            if case .damaged(let revisions) = store.levelState, let newest = revisions.max() {
                _ = await store.recover(revision: newest)
                await controller.reload()
            }
        case .librarySettings:
            SettingsWindowController.show(pane: .general)
        }
        return .none
    }

    func useOfferedLibrary() async -> LibraryMoveResult {
        guard let folder = offeredFolder else { return .failed(reason: "there's no library to use") }
        offeredFolder = nil
        return await useExistingLibrary(in: folder)
    }

    /// Persistence regrant outcome → UI result. `.regranted` never claims the same library was verified:
    /// persistence may accept a folder by its configured path when the library identity can't be read.
    static func map(_ outcome: LibraryRegrantOutcome) -> LibraryRegrantResult {
        switch outcome {
        case .regranted(_, let pending):
            let saved: Bool = switch pending {
            case .applied?, .merged?: true
            default: false
            }
            return .regranted(pendingEditsSaved: saved)
        case .differentLibrary(let url, _):
            return .differentLibrary(folderDisplayName: LibraryFolderURL.displayName(for: url))
        case .noLibraryThere(let url):
            return .noLibraryThere(folderDisplayName: LibraryFolderURL.displayName(for: url))
        case .cannotVerify(let reason):
            return .cannotVerify(reason: reason)
        @unknown default:
            return .cannotVerify(reason: "the result wasn't recognized")
        }
    }
}
