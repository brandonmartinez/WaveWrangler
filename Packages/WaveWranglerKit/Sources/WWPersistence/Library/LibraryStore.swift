import Foundation
import WWCore

public typealias LibraryCoder = JSONEnvelopeCoder<LibraryModel>

/// Result of loading the canonical library.
public enum LibraryLoadOutcome: Sendable, Equatable {
    case ready(revision: Int)
    /// No library existed (and no recovery records): a new empty one was published and verified.
    case created
    /// Written by a newer WaveWrangler: refused; the file is never written or downsaved.
    case refusedNewerFormat(found: Int, supported: Int)
    case needsMigration(fromSchema: Int)
    /// Damaged or missing; whole validated checkpoints (by revision) can be recovered as a new copy.
    case damaged(reason: String, recoveryRevisions: [Int])
    /// The configured location cannot be reached. Nothing is created there silently.
    case unavailable(reason: String)
}

/// The canonical library document store (C2/C5 for the library): a separate versioned document with its own
/// device-local prior checkpoints, a configurable location (app container by default, or a user-chosen —
/// possibly cloud — folder) and a rebuildable derived index kept outside canonical data.
///
/// Library edits are user commands, so each change is published immediately through the full publication
/// protocol (not autosave). Reconciliation only publishes when it changes something.
public actor LibraryStore {
    public private(set) var library: LibraryModel?
    public private(set) var index: LibraryIndex?
    public private(set) var lastLoad: LibraryLoadOutcome?
    public private(set) var locationStatus: LibraryLocationStatus

    private let containerFolder: URL
    private let settings: any LibraryLocationSettingsStoring
    private let bookmarks: any FolderBookmarking
    private let recovery: RecoveryStore
    private let indexCache: LibraryIndexCache
    private let publisher: DocumentPublisher<LibraryCoder>
    private let opener: DocumentOpener<LibraryCoder>
    private var session: CanonicalDocumentSession<LibraryCoder>?
    private var accessedFolder: URL?

    public init(
        containerFolder: URL,
        settings: any LibraryLocationSettingsStoring,
        bookmarks: any FolderBookmarking = SecurityScopedFolderBookmarks(),
        recovery: RecoveryStore,
        indexCache: LibraryIndexCache,
        ops: any FileOperations = LocalFileOperations(),
        coordination: any FileCoordinating = NSFileCoordination(),
        hooks: any PublicationHooks = NoPublicationHooks(),
        migrations: [MigrationStep<LibraryModel>] = []
    ) {
        self.containerFolder = containerFolder
        self.settings = settings
        self.bookmarks = bookmarks
        self.recovery = recovery
        self.indexCache = indexCache
        let coder = LibraryCoder.library
        self.publisher = DocumentPublisher(coder: coder, ops: ops, coordination: coordination, recovery: recovery, hooks: hooks)
        self.opener = DocumentOpener(coder: coder, ops: ops, coordination: coordination, recovery: recovery,
                                     migratableSchemas: Set(migrations.map(\.fromSchema)))
        self.locationStatus = .appContainer(containerFolder)
    }

    /// `~/Library/Application Support/WaveWrangler/Library` (inside the sandbox container when sandboxed).
    public static func defaultContainerFolder() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WaveWrangler/Library", directoryHint: .isDirectory)
    }

    // MARK: - Loading

    /// The library document URL for the current setting, or `nil` when the location is unavailable.
    public func currentLibraryURL() -> URL? {
        resolveFolder().map { $0.appending(path: settings.load().fileName) }
    }

    @discardableResult
    public func load() async -> LibraryLoadOutcome {
        let outcome = await performLoad()
        lastLoad = outcome
        return outcome
    }

    private func performLoad() async -> LibraryLoadOutcome {
        session = nil
        library = nil
        index = nil
        guard let folder = resolveFolder() else {
            if case let .unavailable(_, reason) = locationStatus { return .unavailable(reason: reason) }
            return .unavailable(reason: "The library location could not be resolved.")
        }
        let url = folder.appending(path: settings.load().fileName)
        if !publisher.ops.exists(url) {
            let candidates = opener.candidates(url: url, key: .library)
            if !candidates.isEmpty {
                return .damaged(reason: "The library file is missing.", recoveryRevisions: candidates.map(\.document.revision))
            }
            guard case .appContainer = settings.load().place else {
                return .unavailable(reason: "No library was found in the chosen folder. It may still be downloading or offline.")
            }
            return await createEmpty(at: url) ? .created : .unavailable(reason: "A new library could not be created.")
        }
        switch opener.open(url, key: .library) {
        case let .editable(document, fingerprint):
            adopt(CanonicalDocumentSession(key: .library, url: url, payload: document.payload, base: fingerprint,
                                           revision: document.revision, publisher: publisher))
            library = document.payload
            refreshIndex(digest: fingerprint.byteDigest)
            return .ready(revision: document.revision)
        case let .refusedNewerFormat(found, supported, _):
            return .refusedNewerFormat(found: found, supported: supported)
        case let .needsMigration(schema, _):
            return .needsMigration(fromSchema: schema)
        case let .damaged(error, candidates):
            return .damaged(reason: error.errorDescription ?? "\(error)", recoveryRevisions: candidates.map(\.document.revision))
        case let .unreadable(_, detail, candidates):
            if candidates.isEmpty { return .unavailable(reason: detail) }
            return .damaged(reason: detail, recoveryRevisions: candidates.map(\.document.revision))
        }
    }

    private func createEmpty(at url: URL) async -> Bool {
        let session = CanonicalDocumentSession(key: .library, url: url, payload: LibraryModel(), base: nil, revision: 0, publisher: publisher)
        guard (try? publisher.ops.createDirectory(url.deletingLastPathComponent())) != nil else { return false }
        library = LibraryModel()
        guard case .success = await save(session) else {
            library = nil
            return false
        }
        adopt(session)
        return true
    }

    // MARK: - Editing

    /// Applies a user library edit and publishes it. On failure the in-memory library keeps the edit (still
    /// unsaved) and the error is returned; nothing is acknowledged.
    @discardableResult
    public func update(_ transform: (LibraryModel) throws -> LibraryModel) async throws -> Result<PublicationReceipt, PublicationError> {
        guard let session else { return .failure(.readOnly("The library is not loaded.")) }
        guard let current = library else { return .failure(.readOnly("The library is not loaded.")) }
        let updated = try transform(current)
        guard updated != current || library == nil else {
            return .failure(.cancelled)
        }
        await session.edit { _ in updated }
        library = updated
        return await save(session)
    }

    /// Applies reconciliation observations; publishes only if anything changed. Entries are never dropped.
    @discardableResult
    public func reconcile(_ observations: [ShowID: ShowObservation], at date: Date = Date()) async -> Result<PublicationReceipt, PublicationError>? {
        guard let library else { return nil }
        let reconciled = LibraryReconciler.reconcile(library, observations: observations, at: date)
        guard reconciled != library else { return nil }
        return try? await update { _ in reconciled }
    }

    /// Records a verified show publication (C3 step 8). Never called for failed/uncertain saves.
    @discardableResult
    public func acknowledgeShowPublication(_ showID: ShowID, title: String, revision: Int) async -> Result<PublicationReceipt, PublicationError>? {
        try? await update { LibraryReconciler.acknowledging(showID, title: title, revision: revision, in: $0) }
    }

    public func recordRecent(_ showID: ShowID) async {
        _ = try? await update { LibraryReconciler.recordingRecent(showID, in: $0) }
    }

    public var saveStatus: DocumentSaveStatus? {
        get async { await session?.status }
    }

    // MARK: - Recovery

    /// Publishes a validated checkpoint as a **new** library file next to the damaged/missing one, switches to
    /// it and leaves the suspect file untouched.
    public func recoverAsNewCopy(revision: Int) async -> Result<PublicationReceipt, PublicationError> {
        guard let folder = resolveFolder() else { return .failure(.failed(stage: .baseCheck, kind: .unavailable, detail: "location unavailable")) }
        let current = folder.appending(path: settings.load().fileName)
        guard let candidate = opener.candidates(url: current, key: .library).first(where: { $0.document.revision == revision }) else {
            return .failure(.failed(stage: .baseCheck, kind: .other, detail: "no checkpoint at revision \(revision)"))
        }
        let name = "Library (Recovered r\(revision) \(UUID().uuidString.prefix(8))).wwlibrary"
        let destination = folder.appending(path: name)
        let recovered = CanonicalDocumentSession.recovered(candidate, originalURL: current, publisher: publisher)
        let result = await recovered.duplicate(to: destination)
        if case .success = result {
            var setting = settings.load()
            setting.fileName = name
            try? settings.save(setting)
            await load()
        }
        return result
    }

    // MARK: - Location

    /// Copies the library into `folder`, verifies the copy independently, then switches the setting. The
    /// previous copy is never deleted. An identical copy already there is adopted; a different library there
    /// is never overwritten.
    public func moveLibrary(to folder: URL) async -> Result<LibraryMoveOutcome, PublicationError> {
        await relocate(to: folder, place: { try .folder(bookmark: self.bookmarks.bookmark(for: folder), displayPath: folder.path) })
    }

    /// Moves the library back into the app container (same copy-verify-switch rules).
    public func moveLibraryToAppContainer() async -> Result<LibraryMoveOutcome, PublicationError> {
        await relocate(to: containerFolder, place: { .appContainer })
    }

    /// Switches to the library already in `folder` (after `.destinationHasDifferentLibrary`). Nothing is
    /// copied or deleted; the previous library stays where it was.
    public func adoptLibrary(in folder: URL) async throws -> LibraryLoadOutcome {
        var setting = settings.load()
        setting.place = folder.standardizedFileURL == containerFolder.standardizedFileURL
            ? .appContainer
            : .folder(bookmark: try bookmarks.bookmark(for: folder), displayPath: folder.path)
        try settings.save(setting)
        return await load()
    }

    private func relocate(to folder: URL, place: () throws -> LibraryLocationSetting.Place) async -> Result<LibraryMoveOutcome, PublicationError> {
        guard let session, let sourceURL = currentLibraryURL() else {
            return .failure(.readOnly("The library must be loaded before it can be moved."))
        }
        if await session.isDirty {
            if case let .failure(error) = await save(session) { return .failure(error) }
        }
        guard let base = await session.base else { return .failure(.readOnly("The library has not been saved yet.")) }
        let ops = publisher.ops
        let bytes: Data
        do {
            bytes = try publisher.coordination.coordinateReading(at: sourceURL) { try ops.read($0) }
        } catch {
            return .failure(.failed(stage: .baseCheck, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        guard RevisionFingerprint.digest(bytes) == base.byteDigest else {
            return .failure(.conflict(PublicationConflict(expected: base, onDisk: RevisionFingerprint(of: bytes), preservedCandidate: nil)))
        }
        let fileName = settings.load().fileName
        let destination = folder.appending(path: fileName)
        let started = folder == containerFolder ? false : bookmarks.startAccessing(folder)
        defer { if started { bookmarks.stopAccessing(folder) } }

        if ops.exists(destination) {
            guard let existing = try? publisher.coordination.coordinateReading(at: destination, { try ops.read($0) }) else {
                return .success(.destinationUnusable(destination, reason: "The existing file could not be read."))
            }
            if RevisionFingerprint.digest(existing) == base.byteDigest {
                return await switchSetting(place: place, outcome: .adoptedIdentical(destination))
            }
            if let decoded = try? publisher.coder.decode(existing) {
                return .success(.destinationHasDifferentLibrary(destination, revision: decoded.revision))
            }
            return .success(.destinationUnusable(destination, reason: "A file that is not a readable library is already there."))
        }

        do {
            try ops.createDirectory(folder)
            _ = try recovery.retainCheckpoint(bytes, for: .library)
            _ = try publisher.publish(
                candidate: bytes, revision: base.revision ?? 1, key: .library, to: destination, target: .newLocation,
                retainPrior: false, boundaries: (.publish, .stageWrite), isCancelled: { false }, step: .stagedReplace, acknowledge: nil
            )
        } catch let error as PublicationError {
            return .failure(error)
        } catch {
            return .failure(.failed(stage: .publish, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        return await switchSetting(place: place, outcome: .moved(to: destination, previousCopyKept: sourceURL))
    }

    private func switchSetting(place: () throws -> LibraryLocationSetting.Place, outcome: LibraryMoveOutcome) async -> Result<LibraryMoveOutcome, PublicationError> {
        var setting = settings.load()
        do {
            setting.place = try place()
            try settings.save(setting)
        } catch {
            return .failure(.failed(stage: .acknowledge, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        await load()
        return .success(outcome)
    }

    // MARK: - Internals

    private func adopt(_ session: CanonicalDocumentSession<LibraryCoder>) {
        self.session = session
    }

    private func save(_ session: CanonicalDocumentSession<LibraryCoder>) async -> Result<PublicationReceipt, PublicationError> {
        let cache = indexCache
        let model = library
        let result = await session.save(acknowledge: { receipt in
            if let model { try cache.store(LibraryIndex.build(from: model, libraryDigest: receipt.fingerprint.byteDigest)) }
        })
        if case let .success(receipt) = result, let model {
            index = LibraryIndex.build(from: model, libraryDigest: receipt.fingerprint.byteDigest)
        }
        return result
    }

    private func refreshIndex(digest: String) {
        guard let library else { return }
        index = indexCache.index(for: library, libraryDigest: digest).index
    }

    private func resolveFolder() -> URL? {
        let setting = settings.load()
        switch setting.place {
        case .appContainer:
            stopFolderAccess()
            locationStatus = .appContainer(containerFolder)
            return containerFolder
        case let .folder(bookmark, displayPath):
            do {
                let (url, stale) = try bookmarks.resolve(bookmark)
                if accessedFolder != url {
                    stopFolderAccess()
                    if bookmarks.startAccessing(url) { accessedFolder = url }
                }
                if stale, let refreshed = try? bookmarks.bookmark(for: url) {
                    var updated = setting
                    updated.place = .folder(bookmark: refreshed, displayPath: url.path)
                    try? settings.save(updated)
                }
                guard publisher.ops.exists(url) else {
                    locationStatus = .unavailable(displayPath: displayPath, reason: "The folder cannot be reached.")
                    return nil
                }
                locationStatus = .folder(url, displayPath: url.path)
                return url
            } catch {
                locationStatus = .unavailable(displayPath: displayPath, reason: "Permission to the folder must be granted again.")
                return nil
            }
        }
    }

    private func stopFolderAccess() {
        if let accessedFolder { bookmarks.stopAccessing(accessedFolder) }
        accessedFolder = nil
    }
}
