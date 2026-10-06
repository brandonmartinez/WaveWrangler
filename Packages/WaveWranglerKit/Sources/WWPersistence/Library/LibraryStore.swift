import Foundation
import WWCore

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
    /// The location cannot be reached or needs permission (Design L2/L3). The newest verified library on this
    /// Mac is shown (labelled); organizing edits are **queued** in the device-local pending-edits journal and
    /// published when the location is reachable again (`LibraryEditResult.queued`).
    case unavailableShowingPrior(reason: String, revision: Int)

    /// Whether library edits are refused. `false` when edits are published (ready/created) or queued
    /// (`unavailableShowingPrior`); `true` for newer-format, migration-needed, damaged and unavailable-with-no-
    /// library outcomes. (A damaged pending-edits journal also refuses queueing; see `pendingJournalDamaged`.)
    public var isReadOnly: Bool {
        switch self {
        case .ready, .created, .unavailableShowingPrior: false
        case .refusedNewerFormat, .needsMigration, .damaged, .unavailable: true
        }
    }
}

/// Result of a library edit.
public enum LibraryEditResult: Sendable, Equatable {
    /// Published and read-back verified at the library location.
    case published(PublicationReceipt)
    /// The location is unreachable or needs permission (L2/L3): the edit is kept in the device-local
    /// pending-edits journal ("Edits waiting") and published when the location is reachable again.
    case queued(pendingEdits: Int)
    /// The edit changed nothing.
    case unchanged
    case failed(PublicationError)
}

/// Result of re-granting access to the library folder (Design L3 "Grant Access…").
public enum LibraryRegrantOutcome: Sendable, Equatable {
    /// The folder holds this same library (by `libraryID`). The new grant was saved, the library reloaded and
    /// any queued edits replayed with the normal rules (`pending`, if there were any).
    case regranted(load: LibraryLoadOutcome, pending: PendingEditsOutcome?)
    /// The folder holds a different library. Nothing was changed; offer "Use That Library" or another folder.
    case differentLibrary(URL, revision: Int?)
    /// No library file in that folder. Nothing was changed.
    case noLibraryThere(URL)
    /// The library there can't be verified (still no permission, offline, damaged or newer format). Nothing
    /// was changed.
    case cannotVerify(reason: String)
}

/// Result of applying queued library edits after the location became reachable.
public enum PendingEditsOutcome: Sendable, Equatable {
    case nothingPending
    /// The library on disk was unchanged since the edits were queued: published as edited.
    case applied(PublicationReceipt)
    /// The library on disk had diverged: every queued change was merged field by field onto it (this Mac's
    /// queued edit wins for the same field), verified present, and published.
    case merged(PublicationReceipt)
    /// Some queued changes cannot be carried onto the diverged library. The journal is kept and the library
    /// is in L4 ("changed on another Mac") until the user combines or chooses a version.
    case needsDecision([String])
    /// The library on disk already contained every queued edit; the journal was cleared.
    case alreadyIncluded
    /// Still unreachable or needing permission; the edits stay queued.
    case stillWaiting(reason: String)
    /// Could not apply (newer format, damaged, conflict during publication…); the edits stay queued.
    case refused(PublicationError)
    /// The journal itself is damaged; it is reported and retained, never applied or discarded.
    case journalDamaged
}

/// The canonical library document store (C2/C5 for the library): a separate versioned document with its own
/// device-local prior checkpoints, a configurable location (app container by default, or a user-chosen —
/// possibly cloud — folder) and a rebuildable derived index kept outside canonical data.
///
/// Library edits are user commands, so each change is published immediately through the full publication
/// protocol (not autosave). Reconciliation only publishes when it changes something. While the location is
/// unreachable or needs permission (L2/L3), organizing edits are kept in a device-local pending-edits
/// journal and applied — through the same base check, with ST-36 combine on divergence — once it is
/// reachable again. Queued edits are never dropped silently.
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
    private var hasConflict = false
    private let providerVersions: any ProviderVersionInspecting
    /// Provider conflict versions of the library file (iCloud kept another Mac's concurrent copy) whose changes
    /// the current library doesn't contain: L4 until combined or set aside (#117).
    public private(set) var providerConflicts: [ProviderConflictVersion] = []
    private var providerConflictPayloads: [String: LibraryModel] = [:]
    /// The retained checkpoint each provider version forked from (when this Mac kept one).
    private var providerConflictBases: [String: LibraryModel] = [:]
    /// Provider conflict versions that can't be read or decoded, hold a different library, or couldn't be backed
    /// up: reported (the Library window's notice), kept unresolved and never applied.
    public private(set) var unusableProviderConflicts: [ProviderConflictVersion] = []
    /// Provider conflict versions this store backed up and marked resolved (cumulative): their contents were
    /// already in the library, or were combined into it. Each one's backup is in the recovery store.
    public private(set) var resolvedProviderConflicts: [ProviderConflictVersion] = []
    /// Queued edits (L2/L3), mirrored from the device-local journal.
    public private(set) var pendingEdits: PendingLibraryEdits?
    /// True when the journal exists but cannot be read; it is reported and never overwritten.
    public private(set) var pendingJournalDamaged = false
    /// The exact library identity (and bytes) behind the verified library shown while unreachable.
    private var displayedBase: RevisionFingerprint?
    private var displayedBaseBytes: Data?

    /// "<n> library changes not saved yet".
    public var pendingEditCount: Int { pendingEdits?.editCount ?? 0 }

    /// Reports a move's steps as they happen (`nil` when it ends); for progress shown while it runs.
    private var moveStepHandler: (@Sendable (LibraryMoveStep?) -> Void)?

    public func onMoveStep(_ handler: (@Sendable (LibraryMoveStep?) -> Void)?) {
        moveStepHandler = handler
    }

    public init(
        containerFolder: URL,
        settings: any LibraryLocationSettingsStoring,
        bookmarks: any FolderBookmarking = SecurityScopedFolderBookmarks(),
        recovery: RecoveryStore,
        indexCache: LibraryIndexCache,
        ops: any FileOperations = LocalFileOperations(),
        coordination: any FileCoordinating = NSFileCoordination(),
        hooks: any PublicationHooks = NoPublicationHooks(),
        migrations: [MigrationStep<LibraryModel>] = [],
        providerVersions: any ProviderVersionInspecting = FileVersionInspector()
    ) {
        self.providerVersions = providerVersions
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

    /// Loads the library; if queued edits exist and the location is reachable, applies them first.
    @discardableResult
    private func loadUnlocked() async -> LibraryLoadOutcome {
        lastLoad = await performLoad()
        if pendingEdits != nil, lastLoad == .created || { if case .ready = lastLoad { true } else { false } }() {
            // Queued edits are never published over a concurrent copy the user hasn't seen (#117).
            lastPendingOutcome = hasConflict ? holdPendingEditsForDecision() : await applyPendingEdits()
        }
        return lastLoad!
    }

    /// The outcome of the last automatic or explicit attempt to apply queued edits.
    public private(set) var lastPendingOutcome: PendingEditsOutcome?

    /// "Try Again" / periodic retry (the app retries at most every 30 s while edits are waiting).
    private func retryPendingEditsUnlocked() async -> PendingEditsOutcome {
        guard pendingEdits != nil || pendingJournalDamaged else { return .nothingPending }
        lastLoad = await performLoad()
        let outcome: PendingEditsOutcome
        switch lastLoad! {
        case .ready, .created:
            outcome = hasConflict ? holdPendingEditsForDecision() : await applyPendingEdits()
        case let .unavailable(reason), let .unavailableShowingPrior(reason, _):
            outcome = pendingJournalDamaged ? .journalDamaged : .stillWaiting(reason: reason)
        case let .refusedNewerFormat(found, supported):
            outcome = .refused(.readOnly("The library was saved by a newer version of WaveWrangler (format \(found); this version supports \(supported))."))
        case let .needsMigration(schema):
            outcome = .refused(.readOnly("The library uses an older format (\(schema)) that must be updated first."))
        case let .damaged(reason, _):
            outcome = .refused(.readOnly(reason))
        }
        lastPendingOutcome = outcome
        return outcome
    }

    private func loadJournal() {
        switch recovery.pendingLibraryEdits() {
        case nil: pendingEdits = nil; pendingJournalDamaged = false
        case let .success(record): pendingEdits = record; pendingJournalDamaged = false
        case .failure: pendingEdits = nil; pendingJournalDamaged = true
        }
    }

    private func performLoad() async -> LibraryLoadOutcome {
        loadJournal()
        let outcome = await loadFromLocation()
        // While unreachable, show the queued library (edits waiting) rather than the older prior.
        switch outcome {
        case .unavailable, .unavailableShowingPrior:
            if let pendingEdits, let queued = try? publisher.coder.decode(pendingEdits.snapshot) {
                library = queued.payload
                index = LibraryIndex.build(from: queued.payload, libraryDigest: RevisionFingerprint.digest(pendingEdits.snapshot))
            }
        default: break
        }
        return outcome
    }

    private func loadFromLocation() async -> LibraryLoadOutcome {
        hasConflict = false
        providerConflicts = []
        providerConflictPayloads = [:]
        providerConflictBases = [:]
        unusableProviderConflicts = []
        displayedBase = nil
        displayedBaseBytes = nil
        session = nil
        library = nil
        index = nil
        guard let folder = resolveFolder() else {
            var reason = "The library location could not be resolved."
            if case let .unavailable(_, detail) = locationStatus { reason = detail }
            return showPriorReadOnly(reason: reason)
        }
        let url = folder.appending(path: settings.load().fileName)
        if !publisher.ops.exists(url) {
            let candidates = libraryCandidates(url: url)
            if !candidates.isEmpty {
                return .damaged(reason: "The library file is missing.", recoveryRevisions: candidates.map(\.document.revision))
            }
            guard case .appContainer = settings.load().place else {
                return showPriorReadOnly(reason: "No library was found in the chosen folder. It may still be downloading or offline.")
            }
            return await createEmpty(at: url) ? .created : .unavailable(reason: "A new library could not be created.")
        }
        switch opener.open(url, key: .library) {
        case let .editable(document, fingerprint):
            // A different (real) library at this location is not this library: refuse it like damage and offer
            // this library's own checkpoints. The file is left untouched.
            if let expected = settings.load().libraryID.flatMap(Self.real), let found = Self.real(document.payload.libraryID), found != expected {
                return .damaged(reason: "A different library is at this library's location.",
                                recoveryRevisions: libraryCandidates(url: url).map(\.document.revision))
            }
            adopt(CanonicalDocumentSession(key: .library, url: url, payload: document.payload, base: fingerprint,
                                           revision: document.revision, publisher: publisher))
            library = document.payload
            refreshIndex(digest: fingerprint.byteDigest)
            retainVerifiedCurrent(at: url, fingerprint: fingerprint)
            recordLocationIdentity(document.payload.libraryID)
            detectProviderConflicts(at: url, current: document.payload)
            return .ready(revision: document.revision)
        case let .refusedNewerFormat(found, supported, _):
            return .refusedNewerFormat(found: found, supported: supported)
        case let .needsMigration(schema, _):
            return .needsMigration(fromSchema: schema)
        case let .damaged(error, _):
            return .damaged(reason: error.errorDescription ?? "\(error)", recoveryRevisions: libraryCandidates(url: url).map(\.document.revision))
        case let .unreadable(kind, detail, _):
            return showPriorReadOnly(reason: kind == .permissionDenied ? "Permission to the library must be granted again." : detail)
        }
    }

    /// C2a: an unreachable location shows the last validated prior read-only; never a new empty library.
    private func showPriorReadOnly(reason: String) -> LibraryLoadOutcome {
        guard let prior = libraryCandidates(url: nil).first else { return .unavailable(reason: reason) }
        library = prior.document.payload
        displayedBase = prior.checkpoint.fingerprint
        displayedBaseBytes = try? recovery.bytes(of: prior.checkpoint)
        index = LibraryIndex.build(from: prior.document.payload, libraryDigest: prior.checkpoint.fingerprint.byteDigest)
        return .unavailableShowingPrior(reason: reason, revision: prior.document.revision)
    }

    private func createEmpty(at url: URL) async -> Bool {
        let empty = LibraryModel()
        let session = CanonicalDocumentSession(key: .library, url: url, payload: empty, base: nil, revision: 0, publisher: publisher)
        guard (try? publisher.ops.createDirectory(url.deletingLastPathComponent())) != nil else { return false }
        library = empty
        guard case .success = await save(session) else {
            library = nil
            return false
        }
        adopt(session)
        recordLocationIdentity(empty.libraryID)
        return true
    }

    // MARK: - Editing

    /// Applies a user library edit and publishes it — or, while the location is unreachable or needs
    /// permission (L2/L3), queues it in the device-local journal. On a publication failure the in-memory
    /// library keeps the edit (still unsaved) and the error is returned; nothing is acknowledged.
    private func updateUnlocked(_ transform: (LibraryModel) throws -> LibraryModel) async throws -> LibraryEditResult {
        guard let current = library else { return .failed(.readOnly("The library is not loaded.")) }
        // The library's identity is not editable: whatever the transform returns keeps the current ID.
        var updated = try transform(current)
        updated.libraryID = current.libraryID
        guard let session else {
            switch lastLoad {
            case .unavailable, .unavailableShowingPrior:
                return queue(updated, over: current)
            default:
                return .failed(.readOnly("The library can't be changed right now."))
            }
        }
        // A concurrent copy from another Mac may have arrived since the load (#117): never edit over it unseen.
        detectProviderConflicts(at: await session.url, current: current)
        guard !hasConflict else {
            return .failed(.readOnly("Your library was changed on another Mac. Combine or choose a version first."))
        }
        guard updated != current else { return .unchanged }
        await session.edit { _ in updated }
        library = updated
        switch await save(session) {
        case let .success(receipt): return .published(receipt)
        case let .failure(error):
            if case .conflict = error { hasConflict = true }
            return .failed(error)
        }
    }

    private func queue(_ updated: LibraryModel, over current: LibraryModel) -> LibraryEditResult {
        guard updated != current else { return .unchanged }
        guard !pendingJournalDamaged else {
            return .failed(.readOnly("Library changes can't be kept right now because the record of waiting changes is damaged."))
        }
        let base = pendingEdits?.base ?? displayedBase
        let snapshot: Data
        do {
            snapshot = try publisher.coder.encode(updated, revision: max(1, (base?.revision ?? 0) + 1))
        } catch {
            return .failed(.invalidCandidate(error))
        }
        let now = Date()
        let record = PendingLibraryEdits(
            base: base, baseSnapshot: pendingEdits?.baseSnapshot ?? displayedBaseBytes,
            editCount: (pendingEdits?.editCount ?? 0) + 1,
            firstQueuedAt: pendingEdits?.firstQueuedAt ?? now, lastQueuedAt: now, snapshot: snapshot
        )
        do {
            try recovery.writePendingLibraryEdits(record)
        } catch {
            return .failed(.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        pendingEdits = record
        library = (try? publisher.coder.decode(snapshot).payload) ?? updated
        index = LibraryIndex.build(from: library!, libraryDigest: RevisionFingerprint.digest(snapshot))
        return .queued(pendingEdits: record.editCount)
    }

    /// Applies the journal over the library now loaded from a reachable location.
    /// L4 with queued edits: the journal is kept and the queued library is what Combine combines (as when a
    /// replay can't carry every queued change).
    private func holdPendingEditsForDecision() -> PendingEditsOutcome {
        if let pendingEdits, let queued = try? publisher.coder.decode(pendingEdits.snapshot).payload { library = queued }
        return .needsDecision(["The library was changed on another Mac at the same time."])
    }

    private func applyPendingEdits() async -> PendingEditsOutcome {
        guard let pending = pendingEdits else { return pendingJournalDamaged ? .journalDamaged : .nothingPending }
        guard let session, let onDisk = library, let diskBase = await session.base else {
            return .stillWaiting(reason: "The library is not loaded.")
        }
        // A concurrent copy may have arrived since the load: re-check right before publishing (#117).
        detectProviderConflicts(at: await session.url, current: onDisk)
        guard !hasConflict else { return holdPendingEditsForDecision() }
        guard let queued = try? publisher.coder.decode(pending.snapshot).payload else { return .journalDamaged }
        var result: LibraryModel
        if let base = pending.base, base.byteDigest == diskBase.byteDigest {
            result = queued
            // Identity is the library on disk's, never the journal snapshot's (which may be provisional).
            result.libraryID = onDisk.libraryID
        } else {
            // Diverged: three-way merge of this Mac's queued changes onto the library on disk.
            let base = pending.baseSnapshot.flatMap { try? publisher.coder.decode($0).payload } ?? LibraryModel()
            let merged = QueuedLibraryEdits.apply(base: base, mine: queued, onto: onDisk)
            // Both sides' changes since the base must survive: this Mac's queued edits and the other Mac's.
            var problems = merged.uncarried
                + QueuedLibraryEdits.missingChanges(base: base, mine: queued, in: merged.library)
                + QueuedLibraryEdits.missingChanges(base: base, mine: onDisk, in: merged.library).map { "another Mac's change: \($0)" }
            if case let .invalidPayload(issues)? = Self.validationError(of: merged.library, coder: publisher.coder) {
                problems += issues.map(\.description)
            }
            guard problems.isEmpty else {
                // Never drop a queued change: keep the journal and let the user decide (L4).
                hasConflict = true
                library = queued
                return .needsDecision(problems)
            }
            result = merged.library
        }
        guard result != onDisk else {
            try? recovery.clearPendingLibraryEdits()
            pendingEdits = nil
            return .alreadyIncluded
        }
        await session.edit { _ in result }
        library = result
        switch await save(session) {
        case let .success(receipt):
            // Only now, with every queued edit verified on disk, is the journal cleared.
            try? recovery.clearPendingLibraryEdits()
            pendingEdits = nil
            return pending.base?.byteDigest == diskBase.byteDigest ? .applied(receipt) : .merged(receipt)
        case let .failure(error):
            if case .conflict = error { hasConflict = true }
            return .refused(error)
        }
    }

    private static func validationError(of library: LibraryModel, coder: LibraryCoder) -> PersistenceError? {
        do {
            _ = try coder.encode(library, revision: 1)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Provider conflict versions (#117)

    /// iCloud (or another provider) keeps the losing copy of two concurrent library publications as an
    /// unresolved conflict version. A version holding changes the current library lacks puts the library in L4;
    /// one whose changes are already included is backed up and marked resolved; one that can't be read or holds
    /// a different library is reported and left unresolved.
    private func detectProviderConflicts(at url: URL, current: LibraryModel) {
        var usable: [ProviderConflictVersion] = []
        var payloads: [String: LibraryModel] = [:]
        var unusable: [ProviderConflictVersion] = []
        var included: [ProviderConflictVersion] = []
        for version in providerVersions.unresolvedConflictVersions(of: url) {
            guard let bytes = version.bytes, let decoded = try? publisher.coder.decode(bytes),
                  Self.sameLibrary(decoded.payload.libraryID, current.libraryID) else {
                unusable.append(version)
                continue
            }
            let bases = forkBases(forRevision: decoded.revision)
            if LibraryMerge.isIncluded(decoded.payload, forkBases: bases, in: current) {
                included.append(version)
            } else {
                usable.append(version)
                payloads[version.id] = decoded.payload
                providerConflictBases[version.id] = bases.first
            }
        }
        providerConflicts = usable
        providerConflictPayloads = payloads
        unusableProviderConflicts = unusable
        if !included.isEmpty { resolveProviderVersions(included, at: url) }
        if !usable.isEmpty { hasConflict = true }
    }
    /// This Mac's retained checkpoints of this library one revision before `revision`: where a concurrent copy of
    /// that revision can have forked from.
    private func forkBases(forRevision revision: Int) -> [LibraryModel] {
        libraryCandidates(url: nil).filter { $0.document.revision == revision - 1 }.map(\.document.payload)
    }

    /// Two IDs are the same library unless both are real (schema 2+) and differ.
    private static func sameLibrary(_ a: LibraryID, _ b: LibraryID) -> Bool {
        guard let a = real(a), let b = real(b) else { return true }
        return a == b
    }

    /// Backs each version up in the device-local recovery store, then marks only the backed-up ones resolved.
    /// Every version ends up somewhere the user can see: resolved (`resolvedProviderConflicts`, backup kept) or,
    /// if it couldn't be backed up or marked resolved, unresolved in `unusableProviderConflicts` (the notice).
    private func resolveProviderVersions(_ versions: [ProviderConflictVersion], at url: URL) {
        var backedUp: Set<String> = []
        for version in versions {
            guard let bytes = version.bytes, (try? recovery.preserveConflictCandidate(bytes, for: .library)) != nil else { continue }
            backedUp.insert(version.id)
        }
        let resolved = !backedUp.isEmpty && (try? providerVersions.markResolved(backedUp, of: url)) != nil ? backedUp : []
        for version in versions {
            providerConflicts.removeAll { $0.id == version.id }
            providerConflictPayloads[version.id] = nil
            providerConflictBases[version.id] = nil
            if resolved.contains(version.id) {
                resolvedProviderConflicts.append(version)
            } else if !unusableProviderConflicts.contains(where: { $0.id == version.id }) {
                unusableProviderConflicts.append(version)
            }
        }
    }

    // MARK: - Library-level state and L4 resolution

    /// Design L1–L5 (plus damaged) for the message bar.
    public var levelState: LibraryLevelState {
        if hasConflict { return .changedElsewhere }
        switch lastLoad {
        case nil: return .notLoaded
        case .ready, .created: return .ready
        case .refusedNewerFormat: return .newerFormat
        case .needsMigration: return .newerFormat
        case let .damaged(_, revisions): return .damaged(recoveryRevisions: revisions)
        case let .unavailable(reason), let .unavailableShowingPrior(reason, _):
            return reason.localizedCaseInsensitiveContains("permission") ? .needsPermission : .unreachable(reason: reason)
        }
    }

    /// L4 "Combine (Keep Everything)": combines this Mac's unsaved library into the version on disk with
    /// ST-36 and publishes the result against that exact version. Both inputs stay unchanged on failure.
    private func resolveConflictByCombiningUnlocked() async -> Result<LibraryMergeSummary, PublicationError> {
        guard let mine = library, let url = currentLibraryURL() else { return .failure(.readOnly("The library is not loaded.")) }
        let ops = publisher.ops
        let bytes: Data
        do {
            bytes = try publisher.coordination.coordinateReading(at: url) { try ops.read($0) }
        } catch {
            return .failure(.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        let theirs: DecodedDocument<LibraryModel>
        do {
            theirs = try publisher.coder.decode(bytes)
        } catch {
            return .failure(.readOnly(error.errorDescription ?? "\(error)"))
        }
        var (combined, summary) = LibraryMerge.combineWithSummary(thisMac: mine, into: theirs.payload)
        // Provider conflict versions (#117): every other Mac's concurrent copy is combined the same way.
        let combinedVersions = providerConflicts.filter { providerConflictPayloads[$0.id] != nil }
        for version in combinedVersions {
            var (next, part) = LibraryMerge.combineWithSummary(thisMac: providerConflictPayloads[version.id]!, into: combined)
            combined = next
            // With a fork base, every uncarried change (renames, removals, reorders…) is listed below instead.
            if providerConflictBases[version.id] != nil { part.entryChangesNotCarried = [] }
            summary.add(part)
        }
        // Surfacing, not merging: whatever the other copies changed that Combine (ST-36) doesn't apply — removals,
        // reorders, renames — is listed for the user; the copies themselves are backed up before resolution.
        for version in combinedVersions {
            summary.entryChangesNotCarried += LibraryMerge.uncarriedProviderChanges(
                providerConflictPayloads[version.id]!, forkBase: providerConflictBases[version.id], in: combined)
        }
        // ST-36 keeps every entry, collection and recent item, but it is not a field merge: queued changes it
        // can't carry (for example an alias edited on both sides) are reported and kept in a backup copy.
        if let pendingEdits {
            let base = pendingEdits.baseSnapshot.flatMap { try? publisher.coder.decode($0).payload } ?? LibraryModel()
            summary.queuedChangesNotCarried = QueuedLibraryEdits.missingChanges(base: base, mine: mine, in: combined, countingCopies: true)
        }
        do {
            combined = try prepareForPublication(combined, replacing: bytes)
            _ = try publisher.publish(combined, revision: theirs.revision + 1, key: .library, to: url,
                                      target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        } catch let error as PublicationError {
            return .failure(error)
        } catch {
            return .failure(.acknowledgementUncertain("\(error)"))
        }
        hasConflict = false
        // The combined library is published and verified: back each provider version up, then mark it resolved.
        resolveProviderVersions(combinedVersions, at: url)
        // Keep the queued edits as a backup copy before retiring the journal; never delete them unbacked.
        if let pendingEdits {
            do {
                _ = try recovery.preserveConflictCandidate(pendingEdits.snapshot, for: .library)
                try recovery.clearPendingLibraryEdits()
                self.pendingEdits = nil
            } catch {
                // The journal stays; the combined library is published either way.
            }
        }
        await loadUnlocked()
        return .success(summary)
    }

    /// L4 "Use Other Mac's Version": this Mac's version is kept as a backup copy in the recovery store, then
    /// the on-disk version is loaded.
    private func resolveConflictUsingOtherVersionUnlocked() async -> LibraryLoadOutcome {
        // Provider conflict versions (#117) are set aside the same way: backed up, then marked resolved.
        if let url = currentLibraryURL() {
            resolveProviderVersions(providerConflicts, at: url)
        }
        if let mine = library, let bytes = try? publisher.coder.encode(mine, revision: max(1, (await session?.revision) ?? 1)) {
            _ = try? recovery.preserveConflictCandidate(bytes, for: .library)
        }
        if let pendingEdits {
            // The queued edits stay available as a backup copy before the journal is retired.
            _ = try? recovery.preserveConflictCandidate(pendingEdits.snapshot, for: .library)
            try? recovery.clearPendingLibraryEdits()
            self.pendingEdits = nil
        }
        hasConflict = false
        return await loadUnlocked()
    }

    /// Applies reconciliation observations; publishes only if anything changed. Entries are never dropped.
    /// Automatic reconciliation is not queued while the location is unreachable (only user edits are).
    private func reconcileUnlocked(_ observations: [ShowID: ShowObservation], at date: Date) async -> LibraryEditResult? {
        guard let library, session != nil else { return nil }
        let reconciled = LibraryReconciler.reconcile(library, observations: observations, at: date)
        guard reconciled != library else { return nil }
        return try? await updateUnlocked { _ in reconciled }
    }

    /// Records a verified show publication (C3 step 8). Never called for failed/uncertain saves. Queued
    /// while the library location is unreachable.
    private func acknowledgeShowPublicationUnlocked(_ showID: ShowID, title: String, publication: PublicationStamp) async -> LibraryEditResult? {
        try? await updateUnlocked { LibraryReconciler.acknowledging(showID, title: title, publication: publication, in: $0) }
    }

    private func recordRecentUnlocked(_ showID: ShowID) async {
        _ = try? await updateUnlocked { LibraryReconciler.recordingRecent(showID, in: $0) }
    }

    public var saveStatus: DocumentSaveStatus? {
        get async { await session?.status }
    }

    // MARK: - Recovery

    /// Publishes a validated checkpoint as a **new** library file next to the damaged/missing one, switches to
    /// it and leaves the suspect file untouched.
    private func recoverAsNewCopyUnlocked(revision: Int) async -> Result<PublicationReceipt, PublicationError> {
        guard let folder = resolveFolder() else { return .failure(.failed(stage: .candidateValidated, kind: .unavailable, detail: "location unavailable")) }
        let current = folder.appending(path: settings.load().fileName)
        guard let candidate = libraryCandidates(url: current).first(where: { $0.document.revision == revision }) else {
            return .failure(.failed(stage: .candidateValidated, kind: .other, detail: "no checkpoint at revision \(revision)"))
        }
        let name = "Library (Recovered r\(revision) \(UUID().uuidString.prefix(8))).wwlibrary"
        let destination = folder.appending(path: name)
        var payload = candidate.document.payload
        if LibraryCoder.isProvisional(payload.libraryID) { payload.libraryID = LibraryID() }
        let recovered = CanonicalDocumentSession.recovered(
            RecoveryCandidate(checkpoint: candidate.checkpoint, document: DecodedDocument(payload: payload, publication: candidate.document.publication)),
            originalURL: current, publisher: publisher
        )
        let result = await recovered.duplicate(to: destination)
        if case .success = result {
            var setting = settings.load()
            setting.fileName = name
            setting.libraryID = Self.real(payload.libraryID) ?? setting.libraryID
            try? settings.save(setting)
            await loadUnlocked()
        }
        return result
    }

    // MARK: - Location (C2a + Design merge rules)

    /// Copies the library into `folder`, verifies the copy independently, then switches the setting. The
    /// previous copy is **kept** as a backup and never deleted. An identical copy already there is adopted;
    /// a different library there is never overwritten (`.destinationHasLibrary` → `useLibrary(in:)` or cancel).
    private func moveLibraryUnlocked(to folder: URL) async -> Result<LibraryMoveOutcome, PublicationError> {
        await relocate(to: folder, place: { try .folder(bookmark: self.bookmarks.bookmark(for: folder), displayPath: folder.path) })
    }

    /// Moves the library back into the app container (same copy-verify-switch rules).
    private func moveLibraryToAppContainerUnlocked() async -> Result<LibraryMoveOutcome, PublicationError> {
        await relocate(to: containerFolder, place: { .appContainer })
    }

    /// "Use That Library": combines this Mac's library into the library already in `folder` (collections,
    /// entries including unavailable ones, and recents — nothing dropped), publishes the combined library
    /// there with the full protocol, then switches to it. If the target is unreachable, needs permission or
    /// has a newer format, nothing is written. The previous location is kept as a backup and never deleted.
    private func useLibraryUnlocked(in folder: URL) async -> Result<LibraryMoveOutcome, PublicationError> {
        guard let mine = library else { return .failure(.readOnly("The library must be loaded first.")) }
        let previous = currentLibraryURL()
        let isContainer = folder.standardizedFileURL == containerFolder.standardizedFileURL
        let started = isContainer ? false : bookmarks.startAccessing(folder)
        defer { if started { bookmarks.stopAccessing(folder) } }
        let destination = folder.appending(path: settings.load().fileName)
        let ops = publisher.ops
        let bytes: Data
        do {
            bytes = try publisher.coordination.coordinateReading(at: destination) { try ops.read($0) }
        } catch {
            return .failure(.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        let theirs: DecodedDocument<LibraryModel>
        do {
            theirs = try publisher.coder.decode(bytes)
        } catch let .unknownNewerSchema(found, supported) {
            return .failure(.readOnly("That library was saved by a newer version of WaveWrangler (format \(found); this version supports \(supported))."))
        } catch {
            return .failure(.invalidCandidate(error))
        }
        var (combined, summary) = LibraryMerge.combineWithSummary(thisMac: mine, into: theirs.payload)
        if combined != theirs.payload {
            do {
                combined = try prepareForPublication(combined, replacing: bytes)
                _ = try publisher.publish(
                    combined, revision: theirs.revision + 1, key: .library, to: destination,
                    target: .inPlace(expectedBase: RevisionFingerprint(of: bytes))
                )
            } catch let error as PublicationError {
                return .failure(error)
            } catch {
                return .failure(.acknowledgementUncertain("\(error)"))
            }
        }
        // Any queued edits were part of `mine` and are now verified in the combined library.
        if pendingEdits != nil {
            try? recovery.clearPendingLibraryEdits()
            pendingEdits = nil
        }
        let place: () throws -> LibraryLocationSetting.Place = {
            isContainer ? .appContainer : .folder(bookmark: try self.bookmarks.bookmark(for: folder), displayPath: folder.path)
        }
        return await switchSetting(place: place, libraryID: combined.libraryID, outcome: .combined(into: destination, previousCopyKept: previous, summary: summary))
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
            return .failure(.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        // (1) validate the current library: exactly our verified base.
        guard RevisionFingerprint.digest(bytes) == base.byteDigest, let current = try? publisher.coder.decode(bytes) else {
            return .failure(.conflict(PublicationConflict(expected: base, onDisk: RevisionFingerprint(of: bytes), preservedCandidate: nil)))
        }
        let destination = folder.appending(path: settings.load().fileName)
        let started = folder.standardizedFileURL == containerFolder.standardizedFileURL ? false : bookmarks.startAccessing(folder)
        defer { if started { bookmarks.stopAccessing(folder) } }

        if ops.exists(destination) {
            let existing: Data
            do {
                existing = try publisher.coordination.coordinateReading(at: destination) { try ops.read($0) }
            } catch {
                return .success(.destinationUnusable(destination, problem: Self.isPermissionError(error) ? .needsPermission : .unreadable))
            }
            if RevisionFingerprint.digest(existing) == base.byteDigest {
                return await switchSetting(place: place, libraryID: current.payload.libraryID, outcome: .adoptedIdentical(destination))
            }
            do {
                let decoded = try publisher.coder.decode(existing)
                return .success(.destinationHasLibrary(destination, revision: decoded.revision))
            } catch let .unknownNewerSchema(found, supported) {
                return .success(.destinationUnusable(destination, problem: .newerFormat(found: found, supported: supported)))
            } catch {
                return .success(.destinationUnusable(destination, problem: .notALibrary))
            }
        }

        // (2) coordinated copy of the exact bytes, (3) independent read-back inside the publisher.
        moveStepHandler?(.copying)
        defer { moveStepHandler?(nil) }
        do {
            try ops.createDirectory(folder)
            _ = try recovery.retainCheckpoint(bytes, for: .library)
            _ = try publisher.publish(
                encoded: EncodedDocument(data: bytes, publication: current.publication), key: .library, to: destination,
                target: .newLocation, retainPrior: false, isCancelled: { false }, step: .stagedReplace, followUp: .none
            )
        } catch let error as PublicationError {
            return .failure(error)
        } catch {
            return .failure(.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        // (4) check the copy (read back, then loaded as the library by the switch); the previous copy stays where it was.
        moveStepHandler?(.checking)
        return await switchSetting(place: place, libraryID: current.payload.libraryID, outcome: .moved(to: destination, previousCopyKept: sourceURL))
    }

    private func switchSetting(place: () throws -> LibraryLocationSetting.Place, libraryID: LibraryID, outcome: LibraryMoveOutcome) async -> Result<LibraryMoveOutcome, PublicationError> {
        var setting = settings.load()
        do {
            setting.place = try place()
            setting.libraryID = Self.real(libraryID)
            try settings.save(setting)
        } catch {
            return .failure(.failed(stage: .readBackVerified, kind: WriteFailureKind(classifying: error), detail: "\(error)"))
        }
        await loadUnlocked()
        return .success(outcome)
    }

    // MARK: - Serialized public operations

    /// Every public operation runs its whole read → transform → publish → adopt sequence under this FIFO
    /// gate, so actor reentrancy at an `await` can never interleave two sequences on stale state.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private func exclusively<T>(_ body: () async throws -> T) async rethrows -> T {
        while gateBusy {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        gateBusy = true
        defer {
            gateBusy = false
            if !gateWaiters.isEmpty { gateWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Loads the library; if queued edits exist and the location is reachable, applies them first.
    @discardableResult
    public func load() async -> LibraryLoadOutcome {
        await exclusively { await loadUnlocked() }
    }

    /// "Try Again" / periodic retry (the app retries at most every 30 s while edits are waiting).
    @discardableResult
    public func retryPendingEdits() async -> PendingEditsOutcome {
        await exclusively { await retryPendingEditsUnlocked() }
    }

    /// Re-adopts the library at the configured location (after Grant Access, recovery, "Use Other Mac's
    /// Version", or when the user chooses Try Again). Same as `load()`; queued edits are replayed if reachable.
    @discardableResult
    public func reload() async -> LibraryLoadOutcome {
        await exclusively { await loadUnlocked() }
    }

    /// "Grant Access…": the user re-selected the library folder in an open panel. Creates a new read-write
    /// security-scoped bookmark, confirms the folder holds **this** library (by `libraryID`, not by path),
    /// saves the grant, reloads and replays queued edits with the normal rules. Nothing changes unless the
    /// identity is confirmed. A folder that was renamed or moved is accepted when the identity matches.
    public func regrantAccess(to folder: URL) async -> LibraryRegrantOutcome {
        await exclusively { await regrantAccessUnlocked(to: folder) }
    }

    /// The identity of the library this Mac uses: the identity recorded with the location setting when it was
    /// last verified (load, move/combine, Grant Access), else queued edits, the library shown, or the newest
    /// verified record. `nil` when nothing is known.
    public func expectedLibraryID() -> LibraryID? {
        knownIdentity() ?? library.map(\.libraryID).flatMap(Self.real)
    }

    private static func real(_ id: LibraryID) -> LibraryID? {
        LibraryCoder.isProvisional(id) ? nil : id
    }

    /// Before any canonical library write: a provisional (schema 1) ID becomes a fresh real identity, and if
    /// the bytes being replaced are schema 1 they are kept as a non-overwriting migration backup.
    private func prepareForPublication(_ model: LibraryModel, replacing bytes: Data?) throws -> LibraryModel {
        if let bytes, LibraryCoder.isSchema1(bytes) {
            try recovery.preserveMigrationBackup(bytes, schemaVersion: 1, for: .library)
        }
        var prepared = model
        if LibraryCoder.isProvisional(prepared.libraryID) { prepared.libraryID = LibraryID() }
        return prepared
    }

    /// The real (schema 2+) identity known on this Mac, ignoring provisional schema 1 IDs.
    private func knownIdentity() -> LibraryID? {
        if let recorded = settings.load().libraryID.flatMap(Self.real) { return recorded }
        if let pendingEdits, let id = (try? publisher.coder.decode(pendingEdits.snapshot)).flatMap({ Self.real($0.payload.libraryID) }) {
            return id
        }
        if let current = recovery.verifiedCurrent(for: .library),
           let id = (try? publisher.coder.decode(recovery.bytes(of: current))).flatMap({ Self.real($0.payload.libraryID) }) {
            return id
        }
        return nil
    }

    /// Whole validated recovery records of **this** library (by the expected identity), the verified-current
    /// record first, then priors newest first. Records of other libraries kept under the same key (for example
    /// the previous library after "Use That Library") are never offered as this library's.
    private func libraryCandidates(url: URL?) -> [RecoveryCandidate<LibraryModel>] {
        let all = opener.candidates(url: url, key: .library)
        let identity = knownIdentity()
        let current = recovery.verifiedCurrent(for: .library)?.fingerprint.byteDigest
        // Rank: 0 = verified-current record of this library, 1 = this library's priors, 2 = schema 1 records
        // (unknown identity, kept after). Records of a different real library are excluded.
        func rank(_ candidate: RecoveryCandidate<LibraryModel>) -> Int? {
            let id = candidate.document.payload.libraryID
            if LibraryCoder.isProvisional(id) { return identity == nil && candidate.checkpoint.fingerprint.byteDigest == current ? 0 : 2 }
            if let identity, id != identity { return nil }
            return candidate.checkpoint.fingerprint.byteDigest == current ? 0 : 1
        }
        return all
            .compactMap { candidate in rank(candidate).map { (candidate, $0) } }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.document.revision > rhs.0.document.revision }
            .map(\.0)
    }

    private func recordLocationIdentity(_ id: LibraryID) {
        guard !LibraryCoder.isProvisional(id) else { return }
        var setting = settings.load()
        guard setting.libraryID != id else { return }
        setting.libraryID = id
        try? settings.save(setting)
    }

    private func regrantAccessUnlocked(to folder: URL) async -> LibraryRegrantOutcome {
        let expected = expectedLibraryID()
        let setting = settings.load()
        let bookmark: Data
        do {
            bookmark = try bookmarks.bookmark(for: folder)
        } catch {
            return .cannotVerify(reason: "WaveWrangler couldn't get permission to use that folder.")
        }
        let started = bookmarks.startAccessing(folder)
        defer { if started { bookmarks.stopAccessing(folder) } }

        let url = folder.appending(path: setting.fileName)
        guard publisher.ops.exists(url) else { return .noLibraryThere(url) }
        let ops = publisher.ops
        let bytes: Data
        do {
            bytes = try publisher.coordination.coordinateReading(at: url) { try ops.read($0) }
        } catch {
            return .cannotVerify(reason: "The library in that folder can't be read right now.")
        }
        let found: DecodedDocument<LibraryModel>
        do {
            found = try publisher.coder.decode(bytes)
        } catch .unknownNewerSchema {
            return .cannotVerify(reason: "The library in that folder was saved by a newer version of WaveWrangler.")
        } catch {
            return .cannotVerify(reason: error.errorDescription ?? "The library in that folder is damaged.")
        }
        if let expected, !LibraryCoder.isProvisional(found.payload.libraryID) {
            guard found.payload.libraryID == expected else { return .differentLibrary(url, revision: found.revision) }
        } else {
            // Unknown identity on either side (no real ID known here, or a schema 1 library there).
            // Nothing on this Mac identifies the library: only the very same configured folder is accepted.
            guard case let .folder(_, displayPath) = setting.place,
                  URL(fileURLWithPath: displayPath).standardizedFileURL.path == folder.standardizedFileURL.path
            else { return .differentLibrary(url, revision: found.revision) }
        }
        var updated = setting
        updated.place = folder.standardizedFileURL == containerFolder.standardizedFileURL
            ? .appContainer
            : .folder(bookmark: bookmark, displayPath: folder.path)
        updated.libraryID = Self.real(found.payload.libraryID) ?? setting.libraryID
        do {
            try settings.save(updated)
        } catch {
            return .cannotVerify(reason: "The new permission couldn't be saved.")
        }
        let hadPending = pendingEdits != nil
        lastPendingOutcome = nil
        let outcome = await loadUnlocked()
        return .regranted(load: outcome, pending: hadPending ? (lastPendingOutcome ?? .stillWaiting(reason: "\(outcome)")) : nil)
    }

    /// Applies a user library edit and publishes it — or, while the location is unreachable or needs
    /// permission (L2/L3), queues it in the device-local journal. `transform` always sees the latest value.
    @discardableResult
    public func update(_ transform: (LibraryModel) throws -> LibraryModel) async throws -> LibraryEditResult {
        try await exclusively { try await updateUnlocked(transform) }
    }

    /// Automatic reconciliation is not queued while the location is unreachable (only user edits are).
    @discardableResult
    public func reconcile(_ observations: [ShowID: ShowObservation], at date: Date = Date()) async -> LibraryEditResult? {
        await exclusively { await reconcileUnlocked(observations, at: date) }
    }

    /// Records a verified show publication (C3 step 8). Queued while the library location is unreachable.
    @discardableResult
    public func acknowledgeShowPublication(_ showID: ShowID, title: String, publication: PublicationStamp) async -> LibraryEditResult? {
        await exclusively { await acknowledgeShowPublicationUnlocked(showID, title: title, publication: publication) }
    }

    public func recordRecent(_ showID: ShowID) async {
        await exclusively { await recordRecentUnlocked(showID) }
    }

    /// L4 "Combine (Keep Everything)" (ST-36).
    public func resolveConflictByCombining() async -> Result<LibraryMergeSummary, PublicationError> {
        await exclusively { await resolveConflictByCombiningUnlocked() }
    }

    /// L4 "Use Other Mac's Version"; this Mac's version (and any queued edits) are kept as a backup copy.
    @discardableResult
    public func resolveConflictUsingOtherVersion() async -> LibraryLoadOutcome {
        await exclusively { await resolveConflictUsingOtherVersionUnlocked() }
    }

    public func recoverAsNewCopy(revision: Int) async -> Result<PublicationReceipt, PublicationError> {
        await exclusively { await recoverAsNewCopyUnlocked(revision: revision) }
    }

    public func moveLibrary(to folder: URL) async -> Result<LibraryMoveOutcome, PublicationError> {
        await exclusively { await moveLibraryUnlocked(to: folder) }
    }

    public func moveLibraryToAppContainer() async -> Result<LibraryMoveOutcome, PublicationError> {
        await exclusively { await moveLibraryToAppContainerUnlocked() }
    }

    public func useLibrary(in folder: URL) async -> Result<LibraryMoveOutcome, PublicationError> {
        await exclusively { await useLibraryUnlocked(in: folder) }
    }

    // MARK: - Internals

    private func adopt(_ session: CanonicalDocumentSession<LibraryCoder>) {
        self.session = session
    }

    private func save(_ session: CanonicalDocumentSession<LibraryCoder>) async -> Result<PublicationReceipt, PublicationError> {
        // Upgrading a schema 1 library: keep its exact bytes as a non-overwriting migration backup first.
        // Only when the coordinated on-disk bytes are still exactly that base: if another writer replaced them,
        // they are not the original being replaced and the publisher's base check reports the conflict (L4).
        if let base = await session.base, base.schemaVersion == 1 {
            let url = await session.url
            let ops = publisher.ops
            if let original = try? publisher.coordination.coordinateReading(at: url, { try ops.read($0) }),
               RevisionFingerprint.digest(original) == base.byteDigest {
                guard (try? recovery.preserveMigrationBackup(original, schemaVersion: 1, for: .library)) != nil else {
                    return .failure(.failed(stage: .candidateValidated, kind: .other, detail: "The previous library format couldn't be backed up before updating."))
                }
            }
        }
        // Schema 1 identities are provisional: the first schema 2 publication gets a real one.
        if LibraryCoder.isProvisional(await session.payload.libraryID) {
            let fresh = LibraryID()
            await session.edit { var model = $0; model.libraryID = fresh; return model }
            library?.libraryID = fresh
        }
        let cache = indexCache
        // The exact value being published (the gate guarantees nothing else changes it meanwhile).
        let model: LibraryModel? = await session.payload
        let result = await session.save(followUp: PublicationFollowUp(updateIndex: { receipt in
            if let model { try cache.store(LibraryIndex.build(from: model, libraryDigest: receipt.fingerprint.byteDigest)) }
        }))
        if case let .success(receipt) = result, let model {
            index = LibraryIndex.build(from: model, libraryDigest: receipt.fingerprint.byteDigest)
            retainVerifiedCurrent(at: receipt.url, fingerprint: receipt.fingerprint)
            // The store's session always publishes at the configured location.
            recordLocationIdentity(model.libraryID)
        }
        return result
    }

    /// Keeps the verified current library as a checkpoint too, so an unreachable location shows the latest
    /// verified library (not one revision older) and queued edits start from it.
    private func retainVerifiedCurrent(at url: URL, fingerprint: RevisionFingerprint) {
        guard let bytes = try? publisher.ops.read(url), RevisionFingerprint.digest(bytes) == fingerprint.byteDigest else { return }
        try? recovery.recordVerifiedCurrent(bytes, for: .library)
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

    /// Permission refusals (sandbox or POSIX), as distinct from a file that can't be reached or read right now.
    static func isPermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue || error.code == CocoaError.fileWriteNoPermission.rawValue {
                return true
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func stopFolderAccess() {
        if let accessedFolder { bookmarks.stopAccessing(accessedFolder) }
        accessedFolder = nil
    }
}
