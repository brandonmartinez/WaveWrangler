import AppKit
import SwiftUI
import WWCore
import WWPersistence

/// The portable show document (`.wwshow`).
///
/// Persistence contract (WW-009 C3–C6):
/// - **Publication** runs through `DocumentPublisher` inside our `writeSafely` override with
///   `AlreadyCoordinated` (NSDocument's save is already a coordinated write): P1 candidate validated → P2
///   validated prior retained in the device-local recovery store → P3 base check against the exact bytes
///   this document read/published (another writer ⇒ conflict, nothing overwritten, candidate preserved) →
///   stock `super.writeSafely` safe-save (P4 is inside AppKit and not separately interruptible) → P5/P6
///   independent read-back of the published bytes. Only then is the save adopted and acknowledged to the
///   library (P7).
/// - **Autosave ON/configurable/OFF**: the actual enabled flag is consulted at `autosavesInPlace`,
///   `scheduleAutosaving()` and every `autosave(withImplicitCancellability:)` entry. OFF never schedules,
///   completes queued automatic requests with a cancellation (never a success-shaped `nil`), keeps the
///   document dirty and makes AppKit use its ordinary Save / Don't Save / Cancel review on Close and Quit
///   (`autosavesInPlace == false`). Explicit Save always uses the real file type.
/// - **C2b edit checkpoints** are written at quiescence when a verified publication is not expected within
///   1.5 s of the last edit (ON only) and offered for restore when the document is reopened.
@objc(ShowDocument)
final class ShowDocument: NSDocument {
    let store: ShowDocumentStore
    let status = DocumentStatusModel()
    private let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
    /// Publication of the last coherent value read or verified on disk (`nil` for a new document).
    /// `revision` is only an ordering hint; the publication ID and checksum identify what is on disk.
    private(set) var publication: PublicationStamp?
    /// Exact identity of the bytes this document last read or verified: the expected base for in-place saves.
    private var onDiskBase: RevisionFingerprint?
    /// The encoded candidate for the save in progress; `data(ofType:)` returns exactly these bytes.
    private var pendingCandidate: EncodedDocument?
    private var lastReceipt: PublicationReceipt?
    private var scheduler: QuiescenceScheduler?
    /// Offered C2b records whose Restore is currently in effect (Undo of the Restore removes the record again).
    /// They stay on disk until a verified publication that contains the restore, or an explicit Don't Save,
    /// resolves them, so a crash right after Restore loses nothing.
    private var restoredOfferURLs: Set<URL> = []
    /// Offered records opened as a separate copy (kept until that copy is saved) or hidden by the user.
    private var setAsideOfferURLs: Set<URL> = []
    /// Set on a separate copy opened from another show's offer: its first verified save resolves those records.
    private var resolvesOffer: OfferResolution?

    var revision: Int { publication?.revision ?? 0 }

    #if DEBUG
    /// Debug-only fault injection at the C3 boundaries (native holdout runner); `nil` in normal use.
    static var debugPublicationHooks: (any PublicationHooks)?
    /// Debug-only replacement for the shared library acknowledgement (native holdout runner).
    static var debugLibraryAcknowledger: (@MainActor (ShowID, String, PublicationStamp) async -> Void)?
    #endif
    var documentKey: DocumentKey { .show(store.model.show.id) }
    private var gate: AutosaveGate { PersistenceEnvironment.autosaveGate }
    private var recovery: RecoveryStore { PersistenceEnvironment.recovery }

    override init() {
        store = ShowDocumentStore(model: .untitled())
        super.init()
        store.document = self
        // Ensures preference changes written directly to UserDefaults (Settings) reach the autosave gate.
        _ = AutosavePolicyController.shared
        scheduler = QuiescenceScheduler(
            gate: PersistenceEnvironment.autosaveGate,
            queue: .main,
            onSkipped: { [weak self] in
                MainActor.assumeIsolated { self?.noteAutosaveSkipped() }
            },
            work: { [weak self] work in
                MainActor.assumeIsolated { self?.performQuiescentWork(work) }
            }
        )
    }

    /// Dynamic by design: while autosave is OFF, AppKit treats documents as non-autosaving, so Close and
    /// Quit present the native Save / Don't Save / Cancel decision instead of autosaving.
    override class var autosavesInPlace: Bool { PersistenceEnvironment.autosaveGate.isEnabled }

    override func makeWindowControllers() {
        let hosting = NSHostingController(rootView: ShowWorkspaceView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        window.tabbingMode = .preferred
        addWindowController(NSWindowController(window: window))
    }

    // NSDocument declares reading/writing nonisolated because subclasses may opt into concurrent reading
    // or asynchronous writing. This class keeps both disabled (the defaults), so AppKit calls these on the
    // main thread; `assumeIsolated` enforces that rather than silently racing the store.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool {
        false
    }

    // MARK: - Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        try MainActor.assumeIsolated { try load(data, url: url) }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        try MainActor.assumeIsolated { try load(data, url: nil) }
    }

    private func load(_ data: Data, url: URL?) throws {
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        switch opener.outcome(for: data, url: url) {
        case let .editable(document, fingerprint):
            store.replaceLoadedModel(document.payload)
            publication = document.publication
            onDiskBase = fingerprint
            status.set(.clean(revision: document.revision))
            if let url { status.setProviderConflicts(ProviderConflictReport.inspect(url)) }
            // C2b: set this show's edit checkpoints aside as an offer, so later saves and new checkpoints
            // can't remove them before the user decides (Restore, Open as Separate Copy or Discard).
            try? recovery.setAsideEditCheckpoints(for: .show(document.payload.show.id))
            refreshEditCheckpointOffer()
        case let .refusedNewerFormat(found, supported, _):
            // Refuse with reason; nothing is ever written to a newer document.
            throw PersistenceError.unknownNewerSchema(found: found, supported: supported)
        case let .needsMigration(schema, _):
            throw PersistenceError.unsupportedOlderSchema(found: schema, minimum: DocumentFormat.show.minimumReadableSchemaVersion)
        case let .damaged(error, candidates):
            throw DocumentRecoveryOffer.error(for: error, candidates: candidates)
        case let .unreadable(kind, detail, _):
            throw CocoaError(kind == .permissionDenied ? .fileReadNoPermission : .fileReadUnknown,
                             userInfo: [NSLocalizedFailureReasonErrorKey: detail])
        }
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            if let pendingCandidate { return pendingCandidate.data }
            return try coder.encodeDocument(store.model, revision: revision + 1, publicationID: UUID()).data
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // The model is already current (edits apply live); end any coalesced burst so that an edit made
        // after this save registers new undo and marks the document dirty again.
        store.endCoalescing()
        do {
            pendingCandidate = try coder.encodeDocument(store.model, revision: revision + 1, publicationID: UUID())
        } catch {
            status.set(.saveFailed(retainedRevision: publication?.revision, kind: .other, message: error.localizedDescription))
            completionHandler(error)
            return
        }
        lastReceipt = nil
        let adopts = Self.adoptsPublication(saveOperation)
        if adopts { status.set(.saving) }
        let candidateBytes = pendingCandidate?.data
        let candidateModel = store.model
        let restoredAtSaveStart = restoredOfferURLs
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { return completionHandler(error) }
            self.finishSave(saveOperation: saveOperation, adopts: adopts, error: error, url: url, candidateBytes: candidateBytes,
                            candidateModel: candidateModel, restoredAtSaveStart: restoredAtSaveStart)
            completionHandler(error)
        }
    }

    /// Only these operations make the written file *this* document's on-disk revision. Save To (export) and
    /// autosave-elsewhere copies never become the base for later in-place saves.
    static func adoptsPublication(_ operation: NSDocument.SaveOperationType) -> Bool {
        switch operation {
        case .saveOperation, .saveAsOperation, .autosaveInPlaceOperation: true
        case .saveToOperation, .autosaveElsewhereOperation, .autosaveAsOperation: false
        @unknown default: false
        }
    }

    private func finishSave(
        saveOperation: NSDocument.SaveOperationType, adopts: Bool, error: Error?, url: URL, candidateBytes: Data?, candidateModel: ShowDocumentModel,
        restoredAtSaveStart: Set<URL>
    ) {
        let receipt = lastReceipt
        lastReceipt = nil
        pendingCandidate = nil
        if error == nil, adopts, let receipt {
            publication = receipt.publication
            onDiskBase = receipt.fingerprint
            // #87: AppKit only marks an autosave in place as "autosaved"; clear "— Edited" exactly when the verified
            // publication holds the current model. Edits made during the save keep the document (and status) edited.
            let isAutosaveInPlace = saveOperation == .autosaveInPlaceOperation
            if isAutosaveInPlace, isDocumentEdited,
               EditedStatePolicy.clearsEditedState(after: .autosaveInPlace, verified: true, publishedEqualsCurrent: store.model == candidateModel) {
                updateChangeCount(.changeCleared)
            }
            if !isDocumentEdited {
                scheduler?.cancelPending()
                try? recovery.discardEditCheckpoints(for: documentKey)
            }
            resolveOfferRecordsAfterVerifiedSave(
                restoredAtSaveStart: restoredAtSaveStart, publishedEqualsCurrent: store.model == candidateModel
            )
            if isAutosaveInPlace, isDocumentEdited {
                status.set(.edited(autosaveEnabled: gate.isEnabled))
            } else {
                status.set(.saved(revision: receipt.revision, at: receipt.verifiedAt))
            }
            let model = store.model
            #if DEBUG
            if let acknowledge = Self.debugLibraryAcknowledger {
                Task { await acknowledge(model.show.id, model.show.title, receipt.publication) }
                return
            }
            #endif
            Task { await LibraryDocumentStore.shared.acknowledgeShowPublication(model.show.id, title: model.show.title, publication: receipt.publication) }
        } else if let error {
            if let publicationError = error as? PublicationError {
                status.set(DocumentSaveState.from(publicationError, retainedRevision: publication?.revision))
            } else if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError {
                status.set(gate.isEnabled ? .cancelled : .autosaveSkipped)
            } else if let candidateBytes, (try? Data(contentsOf: url)) == candidateBytes {
                // The candidate is on disk although the save reported an error: never "failed, retained".
                status.set(.acknowledgementUncertain(message: error.localizedDescription))
            } else {
                status.set(.saveFailed(retainedRevision: publication?.revision, kind: WriteFailureKind(classifying: error), message: error.localizedDescription))
            }
            // C2b: a failed or uncertain automatic publication still leaves an edit checkpoint (ON only).
            if saveOperation == .autosaveInPlaceOperation || saveOperation == .autosaveElsewhereOperation { writeEditCheckpoint() }
        }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated {
            let candidate = try pendingCandidate ?? coder.encodeDocument(store.model, revision: revision + 1, publicationID: UUID())
            pendingCandidate = candidate
            let inPlace = (saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation)
                && url.standardizedFileURL == fileURL?.standardizedFileURL
            let target: PublicationTarget = if inPlace {
                onDiskBase.map { .inPlace(expectedBase: $0) } ?? .newLocation
            } else {
                // User-confirmed Save As / Save To destination, or AppKit's own autosave-elsewhere location.
                .saveAs(replacingExisting: true)
            }
            var hooks: any PublicationHooks = NoPublicationHooks()
            #if DEBUG
            if let debugHooks = Self.debugPublicationHooks { hooks = debugHooks }
            #endif
            let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery, hooks: hooks)
            lastReceipt = try publisher.publish(
                encoded: candidate, key: documentKey, to: url, target: target, retainPrior: inPlace,
                isCancelled: { false },
                step: .external { _, _ in
                    // Stock safe-save; it calls `data(ofType:)`, which returns exactly the candidate bytes.
                    try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
                },
                followUp: .none
            )
        }
    }

    // MARK: - Autosave policy (C6)

    override func scheduleAutosaving() {
        // Documented customization point. OFF: nothing is scheduled and the document stays dirty.
        guard gate.isEnabled else {
            if isDocumentEdited { status.set(.edited(autosaveEnabled: false)) }
            return
        }
        scheduler?.noteEdit()
    }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        // Every automatic entry (our scheduler, window/app deactivation, Close/Quit while ON) re-checks the flag.
        guard gate.isEnabled else {
            noteAutosaveSkipped()
            completionHandler(CocoaError(.userCancelled))
            return
        }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if isDocumentEdited { status.set(.edited(autosaveEnabled: gate.isEnabled)) }
    }

    func autosavePolicyDidChange(wasEnabled: Bool) {
        if !gate.isEnabled {
            scheduler?.cancelPending()
            if isDocumentEdited { status.set(.edited(autosaveEnabled: false)) }
        } else if !wasEnabled, isDocumentEdited {
            // OFF → ON with pending edits: publish them.
            status.set(.edited(autosaveEnabled: true))
            scheduler?.reschedulePending()
        }
    }

    private func performQuiescentWork(_ work: QuiescentWork) {
        switch work {
        case .publish:
            guard isDocumentEdited || fileURL == nil else { return }
            autosave(withImplicitCancellability: true) { _ in }
        case .editCheckpoint:
            writeEditCheckpoint()
        }
    }

    private func noteAutosaveSkipped() {
        if isDocumentEdited { status.set(.autosaveSkipped) }
    }

    // MARK: - C2b edit checkpoints

    private func writeEditCheckpoint() {
        guard gate.isEnabled, isDocumentEdited,
              let snapshot = try? coder.encode(store.model, revision: revision + 1),
              let record = try? recovery.writeEditCheckpoint(
                  snapshot: snapshot, base: onDiskBase, schemaVersion: coder.format.currentSchemaVersion, for: documentKey
              )
        else { return }
        status.set(.recoveryCheckpoint(at: record.createdAt))
    }

    // MARK: - C2b recovery offer (#84)

    /// Re-reads the offered records and re-checks each against the publication on disk now.
    func refreshEditCheckpointOffer() {
        let showID = store.model.show.id
        let offer = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: documentKey),
            documentID: documentKey.rawValue, onDisk: onDiskBase, coder: coder,
            belongsToDocument: { $0.show.id == showID }
        ).excluding(restoredOfferURLs.union(setAsideOfferURLs))
        status.setEditCheckpointOffer(offer.isEmpty ? nil : offer)
    }

    /// "Restore Unsaved Changes": only while the record is based on exactly the publication on disk. Applies the
    /// whole snapshot as one undoable edit; the document is dirty and is never marked saved by a restore.
    func restoreOfferedEditCheckpoint() {
        refreshEditCheckpointOffer()
        guard let offer = status.editCheckpointOffer, let candidate = offer.candidate, candidate.relation == .basedOnCurrent else { return }
        // One undo step: the model change (which marks the document dirty) and the "restored" mark, so Undo of the
        // restore also un-marks the record and offers it again; Redo marks it again.
        let undo = undoManager
        undo?.beginUndoGrouping()
        store.apply("Restore Unsaved Changes") { _ in candidate.payload }
        markRestored(candidate.url)
        undo?.setActionName("Restore Unsaved Changes")
        undo?.endUndoGrouping()
    }

    private func markRestored(_ url: URL) {
        restoredOfferURLs.insert(url)
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.unmarkRestored(url) }
        }
        refreshEditCheckpointOffer()
    }

    private func unmarkRestored(_ url: URL) {
        restoredOfferURLs.remove(url)
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.markRestored(url) }
        }
        refreshEditCheckpointOffer()
    }

    /// "Open as Separate Copy": a new untitled show (new show ID, so it can't be mistaken for this one), dirty
    /// and unsaved. Never merged into this show and never published by itself. The records stay until the copy
    /// is saved; if the copy is closed without saving, the offer returns here.
    func openOfferedEditCheckpointAsCopy() {
        guard let offer = status.editCheckpointOffer, let candidate = offer.candidate else { return }
        let urls: Set<URL> = [candidate.url]
        let copy = ShowDocument.openUntitledCopy(of: candidate.payload.duplicatedAsNewShow())
        copy.resolvesOffer = OfferResolution(key: documentKey, urls: Array(urls), source: self)
        setAsideOfferURLs.formUnion(urls)
        refreshEditCheckpointOffer()
    }

    /// Discard (after the user confirmed): deletes exactly the record shown. Other records (for example from
    /// another crashed session) and problem reports stay and are offered next.
    func discardOfferedEditCheckpoint() {
        guard let candidate = status.editCheckpointOffer?.candidate else { return }
        try? recovery.discardOfferedEditCheckpoints([candidate.url], for: documentKey)
        refreshEditCheckpointOffer()
    }

    /// Hides the "couldn't be restored" report in this window (after confirmation). Nothing is deleted.
    func hideEditCheckpointProblems() {
        guard let offer = status.editCheckpointOffer else { return }
        setAsideOfferURLs.formUnion(offer.problems.map(\.url))
        refreshEditCheckpointOffer()
    }

    var editCheckpointProblemURLs: [URL] { status.editCheckpointOffer?.problems.map(\.url) ?? [] }

    /// After a verified publication of this document. A restored record is deleted only when the publication
    /// contains its restore: the restore was in effect when the save started and still is, and the published
    /// candidate equals the current model (no undo or edits in between). Otherwise it stays for a later save.
    private func resolveOfferRecordsAfterVerifiedSave(restoredAtSaveStart: Set<URL>, publishedEqualsCurrent: Bool) {
        let contained = RestoredEditCheckpoints.resolved(byPublicationStartedWith: restoredAtSaveStart, restoredNow: restoredOfferURLs,
                                                         publishedEqualsCurrent: publishedEqualsCurrent)
        if !contained.isEmpty {
            try? recovery.discardOfferedEditCheckpoints(Array(contained), for: documentKey)
            restoredOfferURLs.subtract(contained)
        }
        if let resolution = resolvesOffer {
            resolvesOffer = nil
            try? recovery.discardOfferedEditCheckpoints(resolution.urls, for: resolution.key)
            resolution.source?.offerCopyWasSaved(Set(resolution.urls))
        }
        // A restore offer becomes "based on an older revision" once a newer version is saved.
        refreshEditCheckpointOffer()
    }

    fileprivate func offerCopyWasSaved(_ urls: Set<URL>) {
        setAsideOfferURLs.subtract(urls)
        refreshEditCheckpointOffer()
    }

    fileprivate func offerCopyClosedUnsaved(_ urls: Set<URL>) {
        setAsideOfferURLs.subtract(urls)
        refreshEditCheckpointOffer()
    }

    struct OfferResolution {
        let key: DocumentKey
        let urls: [URL]
        weak var source: ShowDocument?
    }

    override func close() {
        // Closing while still edited means the user chose Don't Save: drop this document's edit checkpoints.
        if isDocumentEdited {
            try? recovery.discardEditCheckpoints(for: documentKey)
            // Don't Save after a restore discards the restored changes too (C2b retention (b)).
            if !restoredOfferURLs.isEmpty { try? recovery.discardOfferedEditCheckpoints(Array(restoredOfferURLs), for: documentKey) }
        }
        if let resolution = resolvesOffer {
            // A copy closed without saving: the records stay, and the original show offers them again.
            resolvesOffer = nil
            resolution.source?.offerCopyClosedUnsaved(Set(resolution.urls))
        }
        scheduler?.cancelPending()
        super.close()
    }

    // MARK: - Provider versions (evidence only)

    override func presentedItemDidGain(_ version: NSFileVersion) {
        super.presentedItemDidGain(version)
        refreshProviderConflictsSoon()
    }

    override func presentedItemDidResolveConflict(_ version: NSFileVersion) {
        super.presentedItemDidResolveConflict(version)
        refreshProviderConflictsSoon()
    }

    private nonisolated func refreshProviderConflictsSoon() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let url = self.fileURL else { return }
                self.status.setProviderConflicts(ProviderConflictReport.inspect(url))
            }
        }
    }

    // MARK: - Copies

    /// Opens `model` in a new untitled, dirty document (used for recovered checkpoints and edit-checkpoint
    /// copies). It can only be kept by saving it as a new document; nothing existing is overwritten.
    @discardableResult
    static func openUntitledCopy(of model: ShowDocumentModel) -> ShowDocument {
        let document = ShowDocument()
        document.store.replaceLoadedModel(model)
        document.updateChangeCount(.changeDone)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    /// Duplicate (File ▸ Duplicate) creates a distinct show with a new `ShowID`, so the original and the
    /// copy can coexist in the library. Show-scoped IDs (episodes, sources, speakers…) are kept.
    override func duplicate() throws -> NSDocument {
        let copy = try super.duplicate()
        guard let show = copy as? ShowDocument else { return copy }
        show.store.replaceLoadedModel(store.model.duplicatedAsNewShow())
        show.publication = nil
        show.onDiskBase = nil
        show.updateChangeCount(.changeDone)
        return show
    }
}

/// Error for a damaged show file that offers whole validated checkpoints from this Mac as a new copy.
/// The damaged file is never modified.
enum DocumentRecoveryOffer {
    static func error(for error: PersistenceError, candidates: [RecoveryCandidate<ShowDocumentModel>]) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: error.errorDescription ?? "The document is damaged.",
            NSLocalizedFailureReasonErrorKey: error.failureReason ?? "",
        ]
        if let newest = candidates.first {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] =
                "A complete earlier revision (\(newest.document.revision)) is kept on this Mac. You can open it as a new, unsaved copy. The damaged file is left unchanged."
            userInfo[NSLocalizedRecoveryOptionsErrorKey] = ["Open Recovered Copy", "Cancel"]
            userInfo[NSRecoveryAttempterErrorKey] = RecoveryAttempter(model: newest.document.payload)
        } else {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = error.recoverySuggestion ?? ""
        }
        return NSError(domain: "com.brandonmartinez.wavewrangler.persistence", code: 1, userInfo: userInfo)
    }

    /// NSErrorRecoveryAttempting: AppKit calls this on the main thread from error presentation.
    final class RecoveryAttempter: NSObject {
        let model: ShowDocumentModel

        init(model: ShowDocumentModel) {
            self.model = model
        }

        override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
            guard recoveryOptionIndex == 0 else { return false }
            let model = model
            MainActor.assumeIsolated { _ = ShowDocument.openUntitledCopy(of: model) }
            return true
        }
    }
}
