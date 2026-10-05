import Foundation
import WWCore

/// Interruption boundaries of the publication protocol (WW-009 C3 table). Each is a point *between* two
/// ordered steps and a fault-injection boundary in the harness.
///
/// Show documents use P1–P7. The library document uses the same publisher; its L1–L6 are P1–P6 with the
/// derived index update directly after L6 (the library has no library acknowledgement step).
public enum PublicationBoundary: String, Sendable, CaseIterable, Codable {
    /// P1/L1: candidate encoded and validated → retain the validated prior.
    case candidateValidated = "P1"
    /// P2/L2: prior retained → coordinated base check.
    case priorRetained = "P2"
    /// P3/L3: base check passed → bytes written (stage write; or the external safe-save).
    case baseChecked = "P3"
    /// P4/L4: staged bytes written and flushed → canonical replace. Publisher path only.
    case stagedFlushed = "P4"
    /// P5/L5: publication returned → independent read-back.
    case published = "P5"
    /// P6/L6: read-back verified → library acknowledgement (shows) or index update (library).
    case readBackVerified = "P6"
    /// P7: library acknowledged → derived index update (shows only).
    case libraryAcknowledged = "P7"
    /// Migration: original read → non-overwriting backup written.
    case migrationOriginalRead = "M1"
    /// Migration: backup preserved and verified → migrated whole revision staged/validated.
    case migrationBackupPreserved = "M2"
    /// Migration: migrated revision validated → publication (then P1–P6).
    case migrationValidated = "M3"

    /// The ordered show-document boundaries.
    public static let show: [PublicationBoundary] = [.candidateValidated, .priorRetained, .baseChecked, .stagedFlushed, .published, .readBackVerified, .libraryAcknowledged]
    /// The ordered library boundaries (L1–L6).
    public static let library: [PublicationBoundary] = [.candidateValidated, .priorRetained, .baseChecked, .stagedFlushed, .published, .readBackVerified]
    public static let migration: [PublicationBoundary] = [.migrationOriginalRead, .migrationBackupPreserved, .migrationValidated]

    public var libraryLabel: String {
        rawValue.hasPrefix("P") ? "L" + rawValue.dropFirst() : rawValue
    }
}

/// Observation/injection point reached at each boundary. Production uses `NoPublicationHooks`.
public protocol PublicationHooks: Sendable {
    func reached(_ boundary: PublicationBoundary) throws
}

public struct NoPublicationHooks: PublicationHooks {
    public init() {}
    public func reached(_ boundary: PublicationBoundary) throws {}
}

/// Where a candidate is being published.
public enum PublicationTarget: Sendable, Equatable {
    /// Ordinary Save/autosave over the revision this document last read or published.
    case inPlace(expectedBase: RevisionFingerprint)
    /// First publication to a location that must not already contain anything.
    case newLocation
    /// User-confirmed Save As/duplicate destination. The original document is never touched.
    case saveAs(replacingExisting: Bool)
}

/// Why a write failed, classified for honest user-facing status.
public enum WriteFailureKind: String, Sendable, Equatable, Codable {
    case diskFull
    case permissionDenied
    case unavailable
    case cancelled
    case other

    public init(classifying error: any Error) {
        let nsError = error as NSError
        let posix: Int32? = switch nsError.domain {
        case NSPOSIXErrorDomain: Int32(nsError.code)
        default: (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        }
        if let posix {
            switch posix {
            case ENOSPC, EDQUOT: self = .diskFull; return
            case EACCES, EPERM, EROFS: self = .permissionDenied; return
            case ENETDOWN, ENETUNREACH, ETIMEDOUT, EHOSTUNREACH, ENOENT, ENXIO: self = .unavailable; return
            case ECANCELED: self = .cancelled; return
            default: break
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteOutOfSpace: self = .diskFull
            case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteVolumeReadOnly: self = .permissionDenied
            case .fileNoSuchFile, .fileReadNoSuchFile, .fileReadUnknown, .ubiquitousFileUnavailable, .ubiquitousFileNotUploadedDueToQuota:
                self = .unavailable
            case .userCancelled: self = .cancelled
            default: self = .other
            }
            return
        }
        self = .other
    }
}

/// A conflict: the on-disk item is not the revision this save was based on. Nothing was overwritten.
public struct PublicationConflict: Sendable, Equatable {
    public let expected: RevisionFingerprint?
    /// `nil` when nothing is on disk any more (moved/deleted by someone else).
    public let onDisk: RevisionFingerprint?
    /// The competing in-memory candidate, preserved in the recovery store.
    public let preservedCandidate: URL?
}

/// Why a publication did not produce an acknowledged revision. Every case leaves the prior valid revision
/// in place (or, for `acknowledgementUncertain`, possibly a newer coherent one) — never a mixture.
public enum PublicationError: Error, Sendable, Equatable {
    /// The document is read-only (for example written by a newer WaveWrangler). Nothing was written.
    case readOnly(String)
    /// The candidate failed encoding/validation. Nothing was written.
    case invalidCandidate(PersistenceError)
    case conflict(PublicationConflict)
    /// The write failed before publication, after boundary `stage` was passed. The prior revision is unchanged on disk.
    case failed(stage: PublicationBoundary, kind: WriteFailureKind, detail: String)
    /// Cancelled before publication; nothing changed on disk.
    case cancelled
    /// Publication may have happened but could not be verified. The user must reopen/reconcile before
    /// anything treats it as saved.
    case acknowledgementUncertain(String)
}

extension PublicationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .readOnly: "This document is read-only and was not saved."
        case .invalidCandidate: "Your changes could not be prepared for saving."
        case .conflict: "Another version of this document is on disk. Your changes were not saved over it."
        case let .failed(_, kind, _):
            switch kind {
            case .diskFull: "The document could not be saved because the disk is full."
            case .permissionDenied: "The document could not be saved because WaveWrangler does not have permission."
            case .unavailable: "The document could not be saved because its location is unavailable."
            case .cancelled: "Saving was cancelled."
            case .other: "The document could not be saved."
            }
        case .cancelled: "Saving was cancelled."
        case .acknowledgementUncertain: "The save may have completed, but it could not be verified."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .readOnly: "Open it with the version of WaveWrangler that created it."
        case .invalidCandidate, .failed, .cancelled: "The previously saved revision is unchanged. Your changes are still open; try saving again."
        case .conflict: "Your changes are still open and a copy is kept on this Mac. Save them as a new document, or open the other version."
        case .acknowledgementUncertain: "Your changes are still open. Reopen the document to check what was saved."
        }
    }

    public var failureReason: String? {
        switch self {
        case let .readOnly(reason): reason
        case let .invalidCandidate(error): error.errorDescription
        case let .conflict(conflict): "Expected \(conflict.expected?.description ?? "no document"), found \(conflict.onDisk?.description ?? "nothing")."
        case let .failed(stage, _, detail): "\(stage.rawValue): \(detail)"
        case .cancelled: nil
        case let .acknowledgementUncertain(detail): detail
        }
    }
}

/// Evidence that a revision was published and independently verified on disk.
public struct PublicationReceipt: Sendable, Equatable {
    public let url: URL
    public let fingerprint: RevisionFingerprint
    /// Identity of the verified publication (fresh `publicationID` per write).
    public let publication: PublicationStamp
    /// The coherent prior revision retained before publication, if there was one.
    public let priorCheckpoint: RecoveryCheckpoint?
    public let verifiedAt: Date
    /// Publication was verified, but cancellation or a dependant (library/index) acknowledgement did not
    /// complete. The document itself is coherent at `revision`.
    public let followUpIncomplete: Bool

    /// Ordering hint only.
    public var revision: Int { publication.revision }

    func markingFollowUpIncomplete() -> PublicationReceipt {
        PublicationReceipt(url: url, fingerprint: fingerprint, publication: publication, priorCheckpoint: priorCheckpoint,
                           verifiedAt: verifiedAt, followUpIncomplete: true)
    }
}

/// How the verified candidate bytes are put in place.
public enum PublishStep {
    /// Stage in a private same-volume directory, flush, verify and replace (`FileOperations.replace`).
    case stagedReplace
    /// Delegate to an external safe-save (e.g. NSDocument's stock `writeSafely`). The closure must write
    /// exactly the given bytes to the URL; the result is still independently read back. P4 is not reachable
    /// on this path (no public hook inside the external replace).
    case external((URL, Data) throws -> Void)
}

/// Dependants acknowledged only after read-back verification (C3 step 8).
public struct PublicationFollowUp {
    /// Library acknowledgement (P6 → P7). Shows only.
    public var acknowledgeLibrary: ((PublicationReceipt) throws -> Void)?
    /// Derived index update (after P7 for shows, after L6 for the library).
    public var updateIndex: ((PublicationReceipt) throws -> Void)?

    public init(acknowledgeLibrary: ((PublicationReceipt) throws -> Void)? = nil, updateIndex: ((PublicationReceipt) throws -> Void)? = nil) {
        self.acknowledgeLibrary = acknowledgeLibrary
        self.updateIndex = updateIndex
    }

    public static var none: PublicationFollowUp { PublicationFollowUp() }
}

/// Executes the ordered C3 publication protocol for one candidate revision:
///
/// 3. encode and validate the complete candidate with a fresh publication ID — **P1**;
/// 4. retain the validated prior (the on-disk bytes, only if they are exactly the expected base) — **P2**;
/// 5. coordinated base check: any difference from the expected base is a conflict; the candidate is
///    preserved device-locally and nothing is overwritten — **P3**;
/// 6. stage privately + flush + verify — **P4** — then replace (or the external safe-save) — **P5**;
/// 7. independent read-back must match the candidate's bytes and publication — **P6**;
/// 8. acknowledge to the library — **P7** — then update the derived index.
///
/// Steps 4–7 run inside one coordinated write. Coordination is not a lock and the base check is not a
/// provider compare-and-swap; the read-back is what establishes coherent local disk truth.
public struct DocumentPublisher<Coder: CanonicalDocumentCoding>: Sendable {
    public let coder: Coder
    public let ops: any FileOperations
    public let coordination: any FileCoordinating
    public let recovery: RecoveryStore?
    public let hooks: any PublicationHooks

    public init(
        coder: Coder,
        ops: any FileOperations = LocalFileOperations(),
        coordination: any FileCoordinating = NSFileCoordination(),
        recovery: RecoveryStore?,
        hooks: any PublicationHooks = NoPublicationHooks()
    ) {
        self.coder = coder
        self.ops = ops
        self.coordination = coordination
        self.recovery = recovery
        self.hooks = hooks
    }

    /// Encodes `payload` as `revision` with a fresh publication ID and publishes it. Throws
    /// `PublicationError`; injected harness interruptions propagate unchanged (modelling process death).
    public func publish(
        _ payload: Coder.Payload,
        revision: Int,
        key: DocumentKey,
        to url: URL,
        target: PublicationTarget,
        retainPrior: Bool = true,
        isCancelled: () -> Bool = { false },
        step: PublishStep = .stagedReplace,
        followUp: PublicationFollowUp = .none
    ) throws -> PublicationReceipt {
        let encoded: EncodedDocument
        do {
            encoded = try coder.encodeDocument(payload, revision: revision, publicationID: UUID())
        } catch {
            throw PublicationError.invalidCandidate(error)
        }
        if case let .inPlace(base) = target, let baseRevision = base.revision, revision <= baseRevision {
            throw PublicationError.invalidCandidate(.invalidRevision(revision))
        }
        return try publish(encoded: encoded, key: key, to: url, target: target, retainPrior: retainPrior,
                           isCancelled: isCancelled, step: step, followUp: followUp)
    }

    /// Publishes already-encoded bytes (exact copies such as library relocation, or the candidate an
    /// NSDocument save will write through `.external`).
    public func publish(
        encoded: EncodedDocument,
        key: DocumentKey,
        to url: URL,
        target: PublicationTarget,
        retainPrior: Bool,
        isCancelled: () -> Bool,
        step: PublishStep,
        followUp: PublicationFollowUp
    ) throws -> PublicationReceipt {
        let candidate = encoded.data
        let candidateFingerprint = RevisionFingerprint(of: candidate)
        var stagingDirectory: URL?
        defer {
            if let stagingDirectory { try? ops.remove(stagingDirectory) }
        }

        let (prior, verifiedAt): (RecoveryCheckpoint?, Date) = try coordination.coordinateWriting(at: url) { url in
            try hooks.reached(.candidateValidated)

            // Step 4: retain the validated prior — only bytes that are exactly the expected base.
            var prior: RecoveryCheckpoint?
            if retainPrior, case let .inPlace(expected) = target, let recovery,
               let onDisk = try? ops.read(url), RevisionFingerprint.digest(onDisk) == expected.byteDigest {
                do {
                    prior = try recovery.retainCheckpoint(onDisk, for: key)
                } catch where !(error is any InjectedInterruption) {
                    throw PublicationError.failed(stage: .candidateValidated, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                }
            }
            try hooks.reached(.priorRetained)

            // Step 5: coordinated base check.
            let onDisk: Data?
            do {
                onDisk = ops.exists(url) ? try ops.read(url) : nil
            } catch where !(error is any InjectedInterruption) {
                throw PublicationError.failed(stage: .priorRetained, kind: WriteFailureKind(classifying: error), detail: "\(error)")
            }
            let onDiskFingerprint = onDisk.map(RevisionFingerprint.init(of:))
            switch target {
            case let .inPlace(expected):
                if onDiskFingerprint?.byteDigest != expected.byteDigest {
                    throw conflict(expected: expected, onDisk: onDiskFingerprint, candidate: candidate, key: key)
                }
            case .newLocation, .saveAs(replacingExisting: false):
                if onDiskFingerprint != nil {
                    throw conflict(expected: nil, onDisk: onDiskFingerprint, candidate: candidate, key: key)
                }
            case .saveAs(replacingExisting: true):
                break
            }
            try hooks.reached(.baseChecked)

            // Step 6: stage + flush + verify, then replace (or the external safe-save).
            var staged: URL?
            if case .stagedReplace = step {
                do {
                    let directory = try ops.makeStagingDirectory(appropriateFor: url)
                    stagingDirectory = directory
                    let file = directory.appending(path: url.lastPathComponent)
                    try ops.writeNew(candidate, to: file)
                    staged = file
                    let stagedBytes = try ops.read(file)
                    guard stagedBytes == candidate, (try? coder.decode(stagedBytes)) != nil else {
                        throw PublicationError.failed(stage: .baseChecked, kind: .other, detail: "staged bytes failed verification")
                    }
                } catch let error as PublicationError {
                    throw error
                } catch where !(error is any InjectedInterruption) {
                    throw PublicationError.failed(stage: .baseChecked, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                }
                try hooks.reached(.stagedFlushed)
            }
            if !isCancelled() {
                do {
                    switch step {
                    case .stagedReplace: try ops.replace(url, withStaged: staged!)
                    case let .external(write): try write(url, candidate)
                    }
                } catch where !(error is any InjectedInterruption) {
                    // Determine what is actually on disk rather than guessing.
                    let now = try? ops.read(url)
                    if let now, RevisionFingerprint.digest(now) == candidateFingerprint.byteDigest {
                        // Published despite the reported error; continue to verification.
                    } else if now.map(RevisionFingerprint.digest) == onDiskFingerprint?.byteDigest {
                        throw PublicationError.failed(stage: .stagedFlushed, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                    } else {
                        throw PublicationError.acknowledgementUncertain("publication reported \(error) and the on-disk state is unknown")
                    }
                }
            } else {
                throw PublicationError.cancelled
            }
            try hooks.reached(.published)

            // Step 7: independent read-back of coherent disk truth.
            let readBack: Data
            do {
                readBack = try ops.read(url)
            } catch where !(error is any InjectedInterruption) {
                throw PublicationError.acknowledgementUncertain("read-back failed: \(error)")
            }
            guard RevisionFingerprint.digest(readBack) == candidateFingerprint.byteDigest,
                  let decoded = try? coder.decode(readBack), decoded.publication == encoded.publication
            else {
                throw PublicationError.acknowledgementUncertain("read-back did not match publication \(encoded.publication.publicationID)")
            }
            return (prior, Date())
        }
        try hooks.reached(.readBackVerified)

        try? recovery?.recordLocation(url, for: key)
        var receipt = PublicationReceipt(
            url: url, fingerprint: candidateFingerprint, publication: encoded.publication,
            priorCheckpoint: prior, verifiedAt: verifiedAt, followUpIncomplete: isCancelled()
        )
        guard !receipt.followUpIncomplete else { return receipt }
        // Step 8: acknowledge, then the derived index.
        if let acknowledge = followUp.acknowledgeLibrary {
            do {
                try acknowledge(receipt)
            } catch where !(error is any InjectedInterruption) {
                return receipt.markingFollowUpIncomplete()
            }
            try hooks.reached(.libraryAcknowledged)
        }
        if let updateIndex = followUp.updateIndex {
            do {
                try updateIndex(receipt)
            } catch where !(error is any InjectedInterruption) {
                receipt = receipt.markingFollowUpIncomplete()
            }
        }
        return receipt
    }

    private func conflict(expected: RevisionFingerprint?, onDisk: RevisionFingerprint?, candidate: Data, key: DocumentKey) -> PublicationError {
        let preserved = try? recovery?.preserveConflictCandidate(candidate, for: key)
        return .conflict(PublicationConflict(expected: expected, onDisk: onDisk, preservedCandidate: preserved))
    }
}

/// Marker for harness-injected process interruptions. Persistence never catches or converts these, so the
/// harness can model the process dying at that exact point (no cleanup runs through dead file operations).
public protocol InjectedInterruption: Error {}
