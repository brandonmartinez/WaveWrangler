import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    /// The exact model last independently verified on disk. Alignment reconciles verified publications;
    /// live inspection never treats the mutable in-memory model as persisted truth.
    private(set) var verifiedModel: ShowDocumentModel?

    #if DEBUG
    /// Debug-only fault injection at the C3 boundaries (native holdout runner); `nil` in normal use.
    static var debugPublicationHooks: (any PublicationHooks)?
    /// Debug-only replacement for the shared library acknowledgement (native holdout runner).
    static var debugLibraryAcknowledger: (@MainActor (ShowID, String, PublicationStamp) async -> Void)?
    /// Debug-only fault injection for the format update (#159, `-WWUITestFailFormatUpdate`); `nil` in normal use.
    static var debugFormatUpdateHooks: (any PublicationHooks)?
    /// Debug-only: runs before a show file is decoded (F-OLDER-BAD seeds an M1-era recovery checkpoint for it).
    static var debugBeforeRead: (@MainActor (URL) -> Void)?
    #endif
    /// ST-11: after a failed save with autosave ON, WaveWrangler retries automatically at most this often.
    static var saveRetryInterval: TimeInterval = 30
    /// The pending automatic retry after a failed save (ST-11). While it's pending, the failure state stays visible
    /// (edits and edit checkpoints don't flip it back to "Edited") and no other automatic attempt is made.
    private var saveRetry: DispatchWorkItem?
    /// D5: the exact bytes of a publication whose acknowledgement is uncertain. Its retry first checks whether these
    /// bytes are on disk and, if so, adopts them (verified by decoding) instead of republishing against a stale base.
    private var uncertainCandidate: Data?
    /// ST-16 "Save a Copy Elsewhere…" in progress: set while its save panel and save run.
    private var copyElsewhere: CopyElsewhereRequest?
    /// Suspends automatic saves of the original while Save a Copy Elsewhere… runs (#197 review).
    private var copyRetryGate = CopyElsewhereRetryGate()
    /// The key of the candidate being saved when it isn't this document's current show (a copy with a new ID).
    private var pendingCandidateKey: DocumentKey?
    var documentKey: DocumentKey { .show(store.model.show.id) }
    /// #159: the exact older-format bytes this document read; the update's "unchanged" check compares against them.
    private var formatUpdateOriginal: Data?
    /// #159: the D14 sheet is still to be shown (once, after the window's first frame).
    var formatUpdatePromptPending = false
    /// #159: an older-format show is open read-only until its update has published (D14/D15).
    var isAwaitingFormatUpdate: Bool { status.formatUpdate != nil }
    private var gate: AutosaveGate { PersistenceEnvironment.autosaveGate }
    private var recovery: RecoveryStore { PersistenceEnvironment.recovery }

    override init() {
        let interval = OpenSignposts.begin("document.init")
        defer { OpenSignposts.end(interval) }
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
        let interval = OpenSignposts.begin("document.makeWindowControllers")
        defer { OpenSignposts.end(interval) }
        let hosting = NSHostingController(rootView: ShowWorkspaceView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        #if DEBUG
        let initialHeight = UserDefaults.standard.bool(forKey: "WWUITestMinimumShowWindow") ? 440.0 : 520.0
        #else
        let initialHeight = 520.0
        #endif
        window.contentMinSize = NSSize(width: 760, height: 440)
        window.setContentSize(NSSize(width: 760, height: initialHeight))
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
        let interval = OpenSignposts.begin("document.read")
        defer { OpenSignposts.end(interval) }
        let data = try Data(contentsOf: url)
        try MainActor.assumeIsolated {
            #if DEBUG
            Self.debugBeforeRead?(url)
            #endif
            try load(data, url: url)
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        try MainActor.assumeIsolated { try load(data, url: nil) }
    }

    private func load(_ data: Data, url: URL?) throws {
        // A schema 1 show reports `.needsMigration`: it opens upgraded in memory, read-only, and nothing is written
        // until the user chooses Update (#159). Schema 1 recovery checkpoints stay offerable, upgraded in memory.
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery,
                                    migratableSchemas: ShowSchemaMigration.migratableSchemas,
                                    recoveryDecode: { try ShowSchemaMigration.decodeUpgradingOlder($0) })
        let outcome = OpenSignposts.measure("document.decode") { opener.outcome(for: data, url: url) }
        switch outcome {
        case let .editable(document, fingerprint):
            formatUpdateOriginal = nil
            formatUpdatePromptPending = false
            status.setFormatUpdate(nil)
            store.replaceLoadedModel(document.payload)
            verifiedModel = document.payload
            publication = document.publication
            onDiskBase = fingerprint
            status.set(.clean(revision: document.revision))
            // C2b: set this show's edit checkpoints aside as an offer now (synchronously, before any save or new
            // checkpoint could remove them) so nothing can be lost before the user decides.
            try? recovery.setAsideEditCheckpoints(for: .show(document.payload.show.id))
            // Evidence-only and presentation work runs after the window's first frame (SCALE-001 cold open):
            // the provider-version inspection and the C2b offer scan. Nothing is decided from them before that:
            // the offer's actions re-check against disk, and a save never depends on either.
            scheduleAfterFirstFrame()
        case let .refusedNewerFormat(found, supported, _):
            // Refuse with reason; nothing is ever written to a newer document.
            throw PersistenceError.unknownNewerSchema(found: found, supported: supported)
        case let .needsMigration(_, fingerprint):
            // #159 D14: view the whole older show upgraded in memory (the same decode the migration stages), read-only.
            // An older file that can't be decoded and verified whole is refused as damaged, unchanged, with its
            // validated recovery checkpoints offered as a new copy (M1's "Open Recovered Copy").
            let upgraded: DecodedDocument<ShowDocumentModel>
            switch opener.olderShowForViewing(data, url: url) {
            case let .viewable(document): upgraded = document
            case let .damaged(error, candidates): throw DocumentRecoveryOffer.error(for: error, candidates: candidates)
            }
            store.replaceLoadedModel(upgraded.payload)
            verifiedModel = upgraded.payload
            publication = upgraded.publication
            onDiskBase = fingerprint
            formatUpdateOriginal = data
            formatUpdatePromptPending = true
            status.setFormatUpdate(.needed)
            status.set(.clean(revision: upgraded.revision))
            // Edit checkpoints are set aside and offered only once the update has published (restoring is an edit).
            scheduleAfterFirstFrame()
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
        // #159: nothing writes the older show's file, or adopts another one, before its update has published.
        guard FormatUpdatePolicy.allowsSave(status.formatUpdate, adoptsPublication: Self.adoptsPublication(saveOperation),
                                            toOwnFile: url.standardizedFileURL == fileURL?.standardizedFileURL) else {
            completionHandler(formatUpdateSaveRefusal())
            return
        }

        if let request = copyElsewhere, saveOperation == .saveAsOperation {
            saveCopy(request, to: url, ofType: typeName, completionHandler: completionHandler)
            return
        }
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

    /// Publishes `expected` through the ordinary C3 NSDocument path and reports success only after the
    /// document's independent read-back verification has completed. A newer edit supersedes the request.
    func persistExpectedModel(
        _ expected: ShowDocumentModel,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard store.model == expected else {
            completion(.failure(CocoaError(.userCancelled)))
            return
        }
        guard let url = fileURL else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        save(to: url, ofType: fileType ?? DocumentTypes.show, for: .saveOperation) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    completion(.failure(error))
                } else if self.store.model != expected || !self.status.saveStatus.state.isVerifiedOnDisk {
                    completion(.failure(CocoaError(.userCancelled)))
                } else {
                    completion(.success(()))
                }
            }
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
            cancelSaveRetry()
            uncertainCandidate = nil
            publication = receipt.publication
            onDiskBase = receipt.fingerprint
            verifiedModel = candidateModel
            // #87: AppKit only marks an autosave in place as "autosaved"; clear "— Edited" exactly when the verified
            // publication holds the current model. Edits made during the save keep the document (and status) edited.
            let isAutosaveInPlace = saveOperation == .autosaveInPlaceOperation
            // #87 / M1 gate (T26): AppKit's own token update for an autosave in place clears the change count but keeps
            // its "recent changes", which keep "— Edited" beside the title; only `.changeCleared` resets them (measured:
            // `isDocumentEdited` is already false here). So clear exactly when the verified publication holds the
            // current model, whatever `isDocumentEdited` says.
            if isAutosaveInPlace,
               EditedStatePolicy.clearsEditedState(after: .autosaveInPlace, verified: true, publishedEqualsCurrent: store.model == candidateModel) {
                updateChangeCount(.changeCleared)
            }
            #if DEBUG
            if isAutosaveInPlace { traceEditedState("finishSave autosaveInPlace") }
            #endif
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
            acknowledgeToLibrary(receipt.publication)
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
            if case .acknowledgementUncertain = status.saveStatus.state { uncertainCandidate = candidateBytes }
            // ST-11: with autosave ON, a failed save is retried automatically (at most every `saveRetryInterval`).
            if gate.isEnabled, isDocumentEdited, status.saveStatus.state.isAutomaticallyRetryable { scheduleSaveRetry() }
        }
    }

    /// P7: the library learns of a verified publication (only after coherent disk truth).
    private func acknowledgeToLibrary(_ publication: PublicationStamp) {
        let model = store.model
        #if DEBUG
        if let acknowledge = Self.debugLibraryAcknowledger {
            Task { await acknowledge(model.show.id, model.show.title, publication) }
            return
        }
        #endif
        Task { await LibraryDocumentStore.shared.acknowledgeShowPublication(model.show.id, title: model.show.title, publication: publication) }
    }

    // MARK: - Save a Copy Elsewhere… (ST-16, T28) and the failed-save close sheet (T23 D7)

    struct CopyElsewhereRequest {
        let originalFolder: String
        let completion: ((Bool) -> Void)?
    }

    /// Opens the native save panel named "<Show> copy" and saves the show there as a new, separate show (new show
    /// ID, titled after the chosen name), like Save As: the window then edits the copy. The original file and its
    /// last saved version are untouched. `completion` gets whether the copy was saved.
    ///
    /// M1 gate (T23 D7, T28): not AppKit's Save As (`runModalSavePanel`). With autosave in place, that first autosaves
    /// the original where it is; while that folder can't be reached it fails, presents "could not be autosaved" and
    /// abandons the copy, and when the folder is reachable it would change the original. The panel is ours; the save
    /// is NSDocument's own Save As publication (`save(to:ofType:for:)`), with the same verification.
    func saveACopyElsewhere(completion: ((Bool) -> Void)? = nil) {
        guard copyElsewhere == nil else { completion?(false); return }
        let request = CopyElsewhereRequest(originalFolder: fileURL?.deletingLastPathComponent().lastPathComponent ?? "", completion: completion)
        copyElsewhere = request
        // The original keeps its last saved version while the copy is chosen and saved: no automatic save of it.
        copyRetryGate.begin(retryPending: saveRetry != nil)
        cancelSaveRetry()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.copyName(for: showFileName)
        if let type = fileType.flatMap({ UTType($0) }) { panel.allowedContentTypes = [type] }
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        let window = windowForSheet
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated { self?.saveChosenCopy(request, chosen: response == .OK ? panel.url : nil, window: window) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: chosen) } else { chosen(panel.runModal()) }
    }

    private func saveChosenCopy(_ request: CopyElsewhereRequest, chosen url: URL?, window: NSWindow?) {
        guard let url, let typeName = fileType else {
            copyElsewhere = nil
            endCopyFlow(copySaved: false)
            request.completion?(false)
            return
        }
        save(to: url, ofType: typeName, for: .saveAsOperation) { [weak self] error in
            guard let self else { return request.completion?(false) ?? () }
            self.copyElsewhere = nil
            self.endCopyFlow(copySaved: error == nil)
            if let error, !((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError) {
                if let window {
                    self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                } else {
                    _ = self.presentError(error)
                }
            }
            request.completion?(error == nil)
        }
    }

    /// Re-arms a retry suspended by the copy flow (cancelled or failed copy), after a fresh interval.
    private func endCopyFlow(copySaved: Bool) {
        if copyRetryGate.end(copySaved: copySaved), gate.isEnabled, isDocumentEdited { scheduleSaveRetry() }
    }

    /// The show's name as in its file name, without the extension. `displayName` includes ".wwshow" when the Mac
    /// shows all file extensions, which must not leak into "<Show> copy" or the close sheet's wording.
    var showFileName: String { fileURL?.deletingPathExtension().lastPathComponent ?? displayName }

    private func saveCopy(_ request: CopyElsewhereRequest, to url: URL, ofType typeName: String, completionHandler: @escaping (Error?) -> Void) {
        let name = url.deletingPathExtension().lastPathComponent
        let copy = (try? store.model.duplicatedAsNewShow().renamingShow(to: name)) ?? store.model.duplicatedAsNewShow()
        let originalKey = documentKey
        do {
            pendingCandidate = try coder.encodeDocument(copy, revision: 1, publicationID: UUID())
        } catch {
            status.set(.saveFailed(retainedRevision: publication?.revision, kind: .other, message: error.localizedDescription))
            completionHandler(error)
            return
        }
        pendingCandidateKey = .show(copy.show.id)
        lastReceipt = nil
        status.set(.saving)
        let candidateBytes = pendingCandidate?.data
        super.save(to: url, ofType: typeName, for: .saveAsOperation) { [weak self] error in
            guard let self else { return completionHandler(error) }
            self.pendingCandidateKey = nil
            if error == nil, self.lastReceipt != nil {
                // The window now edits the copy: a new show, so the original's undo history and edit checkpoints
                // (whose changes the copy now holds) don't carry over.
                self.store.replaceLoadedModel(copy)
                self.undoManager?.removeAllActions()
                try? self.recovery.discardEditCheckpoints(for: originalKey)
                self.status.setCopyNotice(Self.copyMessage(copyName: name, folder: url.deletingLastPathComponent().lastPathComponent,
                                                           originalFolder: request.originalFolder))
            }
            self.finishSave(saveOperation: .saveAsOperation, adopts: true, error: error, url: url, candidateBytes: candidateBytes,
                            candidateModel: copy, restoredAtSaveStart: [])
            completionHandler(error)
        }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        // T23 D7–D9: closing while the last save failed asks how to keep the changes (never AppKit's plain review,
        // and never closes silently). Every other state keeps AppKit's behaviour.
        guard isDocumentEdited, let window = windowForSheet, let sheet = failedSaveCloseSheet() else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let reply = { (shouldClose: Bool) in
            Self.reply(to: delegate, selector: shouldCloseSelector, document: self, shouldClose: shouldClose, contextInfo: contextInfo)
        }
        presentFailedSaveCloseSheet(sheet, in: window) { [weak self] choice in
            switch choice {
            case .saveACopyElsewhere: self?.saveACopyElsewhere(completion: reply)
            case .dontSave: reply(true)
            default: reply(false)
            }
        }
    }

    /// Calls AppKit's `document:shouldClose:contextInfo:` callback.
    private static func reply(to delegate: Any, selector: Selector?, document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let selector, let object = delegate as? NSObject, object.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(object.method(for: selector), to: Callback.self)(object, selector, document, ObjCBool(shouldClose), contextInfo)
    }

    // MARK: - Automatic retry after a failed save (ST-11)

    #if DEBUG
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        traceEditedState("updateChangeCount(withToken:) op \(saveOperation.rawValue)")
    }

    /// UI-test evidence only (F-OFFLINE seam): the edited state at each save-completion step.
    private func traceEditedState(_ step: String) {
        (Self.debugPublicationHooks as? UITestOfflineHooks)?.note("\(step): edited \(isDocumentEdited)")
    }
    #endif

    private func scheduleSaveRetry() {
        guard saveRetry == nil else { return }
        // During Save a Copy Elsewhere… the retry waits for the copy flow to end (re-armed then, after a fresh interval).
        guard copyRetryGate.allowsAutomaticSave else { copyRetryGate.suspendRetry(); return }
        status.setRetryingAutomatically(true)
        let retry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.performSaveRetry() }
        }
        saveRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveRetryInterval, execute: retry)
    }

    private func cancelSaveRetry() {
        saveRetry?.cancel()
        saveRetry = nil
        status.setRetryingAutomatically(false)
    }

    private func performSaveRetry() {
        saveRetry = nil
        status.setRetryingAutomatically(false)
        guard copyRetryGate.allowsAutomaticSave else { copyRetryGate.suspendRetry(); return }
        guard gate.isEnabled, isDocumentEdited, fileURL != nil else { return }
        // D5: if the uncertain publication did land, adopt it rather than republishing against the old base (which
        // would fail the base check and report a false conflict).
        if case .acknowledgementUncertain = status.saveStatus.state, adoptUncertainPublication() { return }
        autosave(withImplicitCancellability: false) { _ in }
    }

    /// Adopts the uncertain candidate when exactly its bytes are on disk and decode as a valid show: this document's
    /// on-disk base, publication and modification date become that revision. Returns `false` (nothing changed)
    /// otherwise; the caller then saves normally, and the base check stays honest.
    private func adoptUncertainPublication() -> Bool {
        guard let candidate = uncertainCandidate, let url = fileURL, let data = try? Data(contentsOf: url), data == candidate else { return false }
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        guard case let .editable(document, fingerprint) = opener.outcome(for: data, url: url) else { return false }
        uncertainCandidate = nil
        publication = document.publication
        onDiskBase = fingerprint
        verifiedModel = document.payload
        AlignmentRuntimeProvider.reconcileActive(for: self)
        fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if store.model == document.payload {
            updateChangeCount(.changeCleared)
            scheduler?.cancelPending()
            try? recovery.discardEditCheckpoints(for: documentKey)
            status.set(.saved(revision: document.revision, at: Date()))
        } else {
            // Edits made since that save are still unsaved: publish them normally against the adopted base.
            status.set(.edited(autosaveEnabled: gate.isEnabled))
            scheduler?.reschedulePending()
        }
        acknowledgeToLibrary(document.publication)
        return true
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated {
            guard FormatUpdatePolicy.allowsSave(status.formatUpdate, adoptsPublication: Self.adoptsPublication(saveOperation),
                                                toOwnFile: url.standardizedFileURL == fileURL?.standardizedFileURL) else {
                throw formatUpdateSaveRefusal()
            }
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
            (Self.debugPublicationHooks as? UITestOfflineHooks)?.target = url
            #endif
            let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery, hooks: hooks)
            lastReceipt = try publisher.publish(
                encoded: candidate, key: pendingCandidateKey ?? documentKey, to: url, target: target, retainPrior: inPlace,
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
        // While Save a Copy Elsewhere… runs, the original keeps its last saved version (an honest cancellation).
        guard copyRetryGate.allowsAutomaticSave else {
            completionHandler(CocoaError(.userCancelled))
            return
        }
        // ST-11: while a retry after a failed save is pending, other automatic attempts wait for it (it saves the
        // latest edits). Close/Quit autosaves (not implicitly cancellable) still go ahead.
        if saveRetry != nil, autosavingIsImplicitlyCancellable {
            completionHandler(CocoaError(.userCancelled))
            return
        }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        #if DEBUG
        if change == .changeDone || change == .changeUndone || change == .changeRedone { traceEditedState("updateChangeCount \(change.rawValue)") }
        #endif
        // ST-11: a visible save failure stays until the next attempt resolves it (no flicker back to "Edited").
        if isDocumentEdited, saveRetry == nil { status.set(.edited(autosaveEnabled: gate.isEnabled)) }
    }

    func autosavePolicyDidChange(wasEnabled: Bool) {
        if !gate.isEnabled {
            cancelSaveRetry()
            scheduler?.cancelPending()
            if isDocumentEdited { status.set(.edited(autosaveEnabled: false)) }
        } else if !wasEnabled, isDocumentEdited {
            // OFF → ON with pending edits: publish them.
            status.set(.edited(autosaveEnabled: true))
            scheduler?.reschedulePending()
        }
    }

    /// A coalesced edit changed the model without a new undo step (and so without `updateChangeCount`): restart
    /// quiescence so the next edit checkpoint or autosave contains the whole burst.
    func coalescedEditDidChangeModel() {
        guard isDocumentEdited else { return }
        scheduleAutosaving()
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
        // ST-11: a visible save failure isn't replaced by the checkpoint state (which reads as "Edited").
        guard !status.saveStatus.state.isAutomaticallyRetryable else { return }
        status.set(.recoveryCheckpoint(at: record.createdAt))
    }

    // MARK: - C2b recovery offer (#84)

    /// Re-reads the offered records and re-checks each against the publication on disk now.
    func refreshEditCheckpointOffer() {
        let showID = store.model.show.id
        let offer = EditCheckpointOffer.assess(
            recovery.offeredEditCheckpoints(for: documentKey),
            documentID: documentKey.rawValue, onDisk: onDiskBase, coder: coder,
            decodeOlder: ShowSchemaMigration.decodeUpgradingOlder,
            belongsToDocument: { $0.show.id == showID }
        ).excluding(restoredOfferURLs.union(setAsideOfferURLs))
        status.setEditCheckpointOffer(offer.isEmpty ? nil : offer)
    }

    /// "Restore Unsaved Changes": only while the record is based on exactly the publication on disk. Applies the
    /// whole snapshot as one undoable edit; the document is dirty and is never marked saved by a restore.
    func restoreOfferedEditCheckpoint() {
        refreshEditCheckpointOffer()
        guard let offer = status.editCheckpointOffer, let candidate = offer.candidate,
              offer.candidateMode(restoreInEffect: isEditCheckpointRestoreInEffect) == .restore else { return }
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

    /// A restored record is in effect (until it's saved, undone or discarded with Don't Save).
    var isEditCheckpointRestoreInEffect: Bool { !restoredOfferURLs.isEmpty }

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
        cancelSaveRetry()
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

    private var afterFirstFrameScheduled = false

    /// Runs the deferred open work after a window of this document first appears, on every display path:
    /// `showWindows()`, a window attached by state restoration (which never calls `showWindows()`;
    /// `windowDidAttach()` from the show window), or, on a revert while a window is visible, the next turn.
    /// A document that is never displayed presents neither the offer nor provider versions; its deferred work
    /// runs as soon as one of its windows appears.
    private func scheduleAfterFirstFrame() {
        afterFirstFrameScheduled = true
        if windowControllers.contains(where: { $0.window?.isVisible == true }) {
            DispatchQueue.main.async { [weak self] in self?.runAfterFirstFrame() }
        }
    }

    override func showWindows() {
        let firstShow = !windowControllers.contains { $0.window?.isVisible == true }
        let interval = firstShow ? OpenSignposts.begin("window.firstCommit") : nil
        super.showWindows()
        if firstShow { OpenSignposts.endAfterCommit(interval) }
        scheduleDeferredWorkAfterFrame()
        // #159: a D14 sheet that is still pending (it couldn't appear on an earlier display) is asked on the next turn,
        // once the window is on screen, whatever the deferred work above has already done.
        DispatchQueue.main.async { [weak self] in self?.presentFormatUpdatePromptIfNeeded() }
    }

    /// Called by the show window when it is attached, on every display path (including state restoration).
    func windowDidAttach() {
        scheduleDeferredWorkAfterFrame()
    }

    private func scheduleDeferredWorkAfterFrame() {
        guard afterFirstFrameScheduled else { return }
        OpenSignposts.afterFirstFrame { [weak self] in self?.runAfterFirstFrame() }
    }

    private func runAfterFirstFrame() {
        guard afterFirstFrameScheduled else { return }
        afterFirstFrameScheduled = false
        OpenSignposts.measure("document.deferred") {
            if let url = fileURL { status.setProviderConflicts(ProviderConflictReport.inspect(url)) }
            if !isAwaitingFormatUpdate { refreshEditCheckpointOffer() }
        }
        presentFormatUpdatePromptIfNeeded()
    }

    // MARK: - Format update (#159, C5)

    private func formatUpdateSaveRefusal() -> CocoaError {
        CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "“\(showFileName)” needs to be updated to the current format before it can be saved.",
            NSLocalizedRecoverySuggestionErrorKey: "Close and reopen the show, then choose Update. The original file wasn't changed.",
        ])
    }

    /// Update (D14) and Try Again (D15): runs the C5 migration off the main thread (backup → stage → validate → C3
    /// publication, coordinated on behalf of this document), then reads the file back independently and decides from
    /// what is on disk: a valid update of this show is adopted; exactly the original bytes mean D15; anything else is
    /// reported without claiming the original is unchanged.
    func updateFormat() {
        guard FormatUpdatePolicy.allowsUpdateAttempt(status.formatUpdate), let url = fileURL, let original = formatUpdateOriginal else { return }
        status.setFormatUpdate(.updating)
        let key = documentKey
        var hooks: any PublicationHooks = NoPublicationHooks()
        #if DEBUG
        if let debugHooks = Self.debugFormatUpdateHooks { hooks = debugHooks }
        #endif
        let coordination = PresenterFileCoordination(presenter: self)
        let migrator = DocumentMigrator.show(publisher: DocumentPublisher(coder: coder, coordination: coordination, recovery: recovery, hooks: hooks))
        // The activity keeps NSDocument's own saves, reverts and closes behind the update; the block's thread isn't
        // documented, so it hops to the main actor explicitly.
        performActivity(withSynchronousWaiting: false) { [weak self] finishActivity in
            let finish = ActivityCompletion(finishActivity)
            Task { @MainActor in
                let attempt = await Task.detached(priority: .userInitiated) {
                    let errorDetail: String?
                    do {
                        _ = try migrator.migrate(url, key: key)
                        errorDetail = nil
                    } catch {
                        errorDetail = Self.formatUpdateDetail(error)
                    }
                    let onDisk = try? coordination.coordinateReading(at: url) { try Data(contentsOf: $0) }
                    return (errorDetail: errorDetail, onDisk: onDisk)
                }.value
                self?.finishFormatUpdate(errorDetail: attempt.errorDetail, original: original, onDisk: attempt.onDisk, url: url)
                finish.run()
            }
        }
    }

    /// NSDocument's activity completion handler, carried to the main actor (it may be called from any thread).
    private struct ActivityCompletion: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private nonisolated static func formatUpdateDetail(_ error: any Error) -> String {
        if case let .invalidCandidate(reason) = error as? PublicationError, let description = reason.errorDescription {
            return description
        }
        if error is PublicationError { return error.localizedDescription }
        return (error as NSError).localizedFailureReason ?? error.localizedDescription
    }

    private func finishFormatUpdate(errorDetail: String?, original: Data, onDisk: Data?, url: URL) {
        guard status.formatUpdate == .updating else { return }
        guard fileURL?.standardizedFileURL == url.standardizedFileURL else {
            // The show was moved or renamed during the update: what's at its new location wasn't checked here.
            formatUpdateOriginal = nil
            status.setFormatUpdate(.interrupted(reason: "its file was moved while WaveWrangler was updating it. Close and reopen it to see what's there now"))
            return
        }
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery, identityOf: { .show($0.show.id) })
        var adopted: (document: DecodedDocument<ShowDocumentModel>, fingerprint: RevisionFingerprint)?
        if let onDisk, case let .editable(document, fingerprint) = opener.outcome(for: onDisk, url: url, key: documentKey) {
            adopted = (document, fingerprint)
        }
        switch FormatUpdateOutcome.classify(errorDetail: errorDetail, original: original, onDiskNow: onDisk,
                                            onDiskIsCurrentFormatOfThisShow: adopted != nil) {
        case .updated:
            guard let adopted else { return }
            store.replaceLoadedModel(adopted.document.payload)
            verifiedModel = adopted.document.payload
            publication = adopted.document.publication
            onDiskBase = adopted.fingerprint
            fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            formatUpdateOriginal = nil
            status.setFormatUpdate(nil)
            status.set(.saved(revision: adopted.document.revision, at: Date()))
            try? recovery.setAsideEditCheckpoints(for: documentKey)
            refreshEditCheckpointOffer()
            acknowledgeToLibrary(adopted.document.publication)
        case let .unchanged(detail):
            status.setFormatUpdate(.failed(detail: detail))
        case .changedElsewhere:
            formatUpdateOriginal = nil
            status.setFormatUpdate(.interrupted(
                reason: "its file was changed by something else while WaveWrangler was updating it. Close and reopen it to see what's there now"
            ))
        }
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
