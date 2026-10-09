import Foundation
import WWCore

/// A headless open canonical document: in-memory value, the exact on-disk base it was read from or last
/// published, honest dirty state and status. Used by the library store, the harness and CLI trials; the app's
/// NSDocument uses `DocumentPublisher` directly through the same protocol.
public actor CanonicalDocumentSession<Coder: CanonicalDocumentCoding> {
    public nonisolated let key: DocumentKey
    public private(set) var url: URL
    public private(set) var payload: Coder.Payload
    /// The exact bytes identity this session expects on disk. `nil` until first published.
    public private(set) var base: RevisionFingerprint?
    public private(set) var revision: Int
    public private(set) var isDirty: Bool
    public private(set) var status: DocumentSaveStatus
    /// Non-nil when edits and saves are refused (newer format, recovered checkpoint).
    public private(set) var readOnlyReason: String?
    /// False for unknown-newer documents: Save As/duplicate would be a down-save and is refused too.
    public nonisolated let allowsCopies: Bool

    private let publisher: DocumentPublisher<Coder>
    private let gate: AutosaveGate?
    private var originatingItem: FileItemIdentity?

    public init(
        key: DocumentKey,
        url: URL,
        payload: Coder.Payload,
        base: RevisionFingerprint?,
        revision: Int,
        publisher: DocumentPublisher<Coder>,
        gate: AutosaveGate? = nil,
        readOnlyReason: String? = nil,
        allowsCopies: Bool = true
    ) {
        self.key = key
        self.url = url
        self.payload = payload
        self.base = base
        self.originatingItem = base == nil ? nil : FileItemIdentity.observe(at: url)
        self.revision = revision
        self.isDirty = false
        self.publisher = publisher
        self.gate = gate
        self.readOnlyReason = readOnlyReason
        self.allowsCopies = allowsCopies
        self.status = DocumentSaveStatus(state: .clean(revision: base == nil ? nil : revision))
    }

    /// Opens an editable session, or returns the refusal/recovery outcome.
    public static func open(
        _ url: URL,
        key: DocumentKey?,
        opener: DocumentOpener<Coder>,
        publisher: DocumentPublisher<Coder>,
        gate: AutosaveGate? = nil,
        keyFor: (Coder.Payload) -> DocumentKey
    ) -> Result<CanonicalDocumentSession<Coder>, OpenFailure<Coder.Payload>> {
        switch opener.open(url, key: key) {
        case let .editable(document, fingerprint):
            let session = CanonicalDocumentSession(
                key: key ?? keyFor(document.payload), url: url, payload: document.payload,
                base: fingerprint, revision: document.revision, publisher: publisher, gate: gate
            )
            return .success(session)
        case let other:
            return .failure(OpenFailure(outcome: other))
        }
    }

    /// A document written by a newer WaveWrangler, shown read-only: edit, Save, autosave, Save As and
    /// duplicate (down-save) are all refused; nothing is ever written.
    public static func refusingNewerFormat(
        key: DocumentKey,
        url: URL,
        payload: Coder.Payload,
        found: Int,
        supported: Int,
        publisher: DocumentPublisher<Coder>
    ) -> CanonicalDocumentSession<Coder> {
        let session = CanonicalDocumentSession(
            key: key, url: url, payload: payload, base: nil, revision: 0, publisher: publisher,
            readOnlyReason: "Saved by a newer version of WaveWrangler (format \(found); this version supports \(supported)).",
            allowsCopies: false
        )
        return session
    }

    /// Opens a validated recovery checkpoint read-only (it can only be kept via `duplicate`).
    public static func recovered(
        _ candidate: RecoveryCandidate<Coder.Payload>,
        originalURL: URL,
        publisher: DocumentPublisher<Coder>
    ) -> CanonicalDocumentSession<Coder> {
        let session = CanonicalDocumentSession(
            key: candidate.checkpoint.key, url: originalURL, payload: candidate.document.payload,
            base: nil, revision: candidate.document.revision, publisher: publisher,
            readOnlyReason: "Recovered revision \(candidate.document.revision); save it as a new copy to keep it."
        )
        return session
    }

    // MARK: - Editing

    @discardableResult
    public func edit(_ transform: (Coder.Payload) throws -> Coder.Payload) rethrows -> Bool {
        guard readOnlyReason == nil else { return false }
        payload = try transform(payload)
        isDirty = true
        status.state = .edited(autosaveEnabled: gate?.isEnabled ?? true)
        return true
    }

    // MARK: - Saving

    /// Explicit Save (always attempted) or automatic save (skipped without writing while autosave is OFF).
    @discardableResult
    public func save(
        automatic: Bool = false,
        isCancelled: () -> Bool = { false },
        followUp: PublicationFollowUp = .none
    ) -> Result<PublicationReceipt, PublicationError> {
        if let readOnlyReason { return .failure(.readOnly(readOnlyReason)) }
        if automatic, let gate, !gate.isEnabled {
            status.state = .autosaveSkipped
            return .failure(.cancelled)
        }
        // Nothing pending for automatic work. An explicit Save still republishes and verifies disk truth.
        if automatic, !isDirty, base != nil { return .failure(.cancelled) }
        if base != nil {
            guard let originatingItem, FileItemIdentity.observe(at: url) == originatingItem else {
                isDirty = true
                let error = PublicationError.originConflict("The originating file's identity is missing or has changed. Reopen it or save a separate copy.")
                status.state = DocumentSaveState.from(error, retainedRevision: base?.revision)
                return .failure(error)
            }
        }
        status.state = .saving
        let target: PublicationTarget = base.map { .inPlace(expectedBase: $0) } ?? .newLocation
        let next = max(revision, base?.revision ?? 0) + 1
        do {
            let receipt = try publisher.publish(
                payload, revision: next, key: key, to: url, target: target, isCancelled: isCancelled, followUp: followUp
            )
            base = receipt.fingerprint
            originatingItem = FileItemIdentity.observe(at: url)
            revision = receipt.revision
            isDirty = false
            status.state = receipt.followUpIncomplete
                ? .savedFollowUpIncomplete(revision: receipt.revision, at: receipt.verifiedAt)
                : .saved(revision: receipt.revision, at: receipt.verifiedAt)
            return .success(receipt)
        } catch let error as PublicationError {
            status.state = DocumentSaveState.from(error, retainedRevision: base?.revision)
            // C2b: an automatic publication that failed or is uncertain still gets an edit checkpoint.
            if automatic, error != .cancelled { writeEditCheckpoint(keepingStatus: true) }
            return .failure(error)
        } catch {
            status.state = .acknowledgementUncertain(message: "\(error)")
            return .failure(.acknowledgementUncertain("\(error)"))
        }
    }

    /// Save As: publishes a new document at `destination` and continues editing there. The original file
    /// is never written.
    @discardableResult
    public func saveAs(
        _ destination: URL,
        replacingExisting: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> Result<PublicationReceipt, PublicationError> {
        if destination.standardizedFileURL == url.standardizedFileURL {
            let error = PublicationError.originConflict("Save As cannot bypass the originating file's in-place save checks.")
            isDirty = true
            status.state = DocumentSaveState.from(error, retainedRevision: base?.revision)
            return .failure(error)
        }
        let result = duplicate(to: destination, replacingExisting: replacingExisting, isCancelled: isCancelled)
        if case let .success(receipt) = result {
            url = destination
            base = receipt.fingerprint
            originatingItem = FileItemIdentity.observe(at: destination)
            revision = receipt.revision
            isDirty = false
            readOnlyReason = nil
            status.state = .saved(revision: receipt.revision, at: receipt.verifiedAt)
        }
        return result
    }

    /// Duplicate/keep-a-copy: publishes the current value at `destination`; this session is unchanged.
    /// Allowed for read-only recovered sessions (that is how a recovered checkpoint is kept); refused for
    /// newer-format sessions (`allowsCopies == false`), where it would be a down-save.
    public func duplicate(
        to destination: URL,
        replacingExisting: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> Result<PublicationReceipt, PublicationError> {
        guard allowsCopies else { return .failure(.readOnly(readOnlyReason ?? "This document can't be copied.")) }
        guard destination.standardizedFileURL != url.standardizedFileURL else {
            return .failure(.originConflict("A copy cannot bypass the originating file's in-place save checks."))
        }
        do {
            let receipt = try publisher.publish(
                payload, revision: max(revision, 1), key: key, to: destination,
                target: .saveAs(replacingExisting: replacingExisting), isCancelled: isCancelled
            )
            return .success(receipt)
        } catch let error as PublicationError {
            return .failure(error)
        } catch {
            return .failure(.acknowledgementUncertain("\(error)"))
        }
    }

    /// Records a C2b unpublished edit checkpoint (not a save). ON only; OFF creates none.
    @discardableResult
    public func writeEditCheckpoint(keepingStatus: Bool = false) -> Bool {
        guard isDirty, readOnlyReason == nil, gate?.isEnabled ?? true else { return false }
        do {
            guard let recovery = publisher.recovery else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let snapshot = try publisher.coder.encode(payload, revision: max(revision, base?.revision ?? 0) + 1)
            let record = try recovery.writeEditCheckpoint(
                snapshot: snapshot, base: base, schemaVersion: publisher.coder.format.currentSchemaVersion, for: key
            )
            if !keepingStatus { status.state = .recoveryCheckpoint(at: record.createdAt) }
            return true
        } catch {
            status.state = .saveFailed(retainedRevision: base?.revision, kind: WriteFailureKind(classifying: error),
                                       message: "Recovery checkpoint could not be written: \(error.localizedDescription)")
            return false
        }
    }

    /// Don't Save closes the session without retiring any recovery records.
    public func discardUnsavedChanges() {
    }

    public func refreshProviderConflicts() {
        status.providerConflicts = ProviderConflictReport.inspect(url)
    }
}

public struct OpenFailure<Payload: Sendable>: Error {
    public let outcome: OpenOutcome<Payload>
}
