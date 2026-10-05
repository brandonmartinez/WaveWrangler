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

    private let publisher: DocumentPublisher<Coder>
    private let gate: AutosaveGate?

    public init(
        key: DocumentKey,
        url: URL,
        payload: Coder.Payload,
        base: RevisionFingerprint?,
        revision: Int,
        publisher: DocumentPublisher<Coder>,
        gate: AutosaveGate? = nil,
        readOnlyReason: String? = nil
    ) {
        self.key = key
        self.url = url
        self.payload = payload
        self.base = base
        self.revision = revision
        self.isDirty = false
        self.publisher = publisher
        self.gate = gate
        self.readOnlyReason = readOnlyReason
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
        status.state = .saving
        let target: PublicationTarget = base.map { .inPlace(expectedBase: $0) } ?? .newLocation
        let next = max(revision, base?.revision ?? 0) + 1
        do {
            let receipt = try publisher.publish(
                payload, revision: next, key: key, to: url, target: target, isCancelled: isCancelled, followUp: followUp
            )
            base = receipt.fingerprint
            revision = receipt.revision
            isDirty = false
            // The verified publication contains every edit: unpublished edit checkpoints are no longer needed.
            try? publisher.recovery?.discardEditCheckpoints(for: key)
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
    public func saveAs(_ destination: URL, replacingExisting: Bool = false) -> Result<PublicationReceipt, PublicationError> {
        let result = duplicate(to: destination, replacingExisting: replacingExisting)
        if case let .success(receipt) = result {
            url = destination
            base = receipt.fingerprint
            revision = receipt.revision
            isDirty = false
            readOnlyReason = nil
            status.state = .saved(revision: receipt.revision, at: receipt.verifiedAt)
        }
        return result
    }

    /// Duplicate/keep-a-copy: publishes the current value at `destination`; this session is unchanged.
    /// Allowed for read-only recovered sessions (that is how a recovered checkpoint is kept), refused for
    /// newer-format sessions by the caller never constructing one.
    public func duplicate(to destination: URL, replacingExisting: Bool = false) -> Result<PublicationReceipt, PublicationError> {
        do {
            let receipt = try publisher.publish(
                payload, revision: max(revision, 1), key: key, to: destination,
                target: .saveAs(replacingExisting: replacingExisting)
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
        guard isDirty, readOnlyReason == nil, gate?.isEnabled ?? true, let recovery = publisher.recovery,
              let snapshot = try? publisher.coder.encode(payload, revision: max(revision, base?.revision ?? 0) + 1)
        else { return false }
        do {
            let record = try recovery.writeEditCheckpoint(
                snapshot: snapshot, base: base, schemaVersion: publisher.coder.format.currentSchemaVersion, for: key
            )
            if !keepingStatus { status.state = .recoveryCheckpoint(at: record.createdAt) }
            return true
        } catch {
            return false
        }
    }

    /// Explicit Don't Save/Discard: the user chose to drop unsaved edits, so their checkpoints go too.
    public func discardUnsavedChanges() {
        try? publisher.recovery?.discardEditCheckpoints(for: key)
    }

    public func refreshProviderConflicts() {
        status.providerConflicts = ProviderConflictReport.inspect(url)
    }
}

public struct OpenFailure<Payload: Sendable>: Error {
    public let outcome: OpenOutcome<Payload>
}
