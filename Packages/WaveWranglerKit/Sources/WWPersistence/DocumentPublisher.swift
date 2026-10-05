import Foundation

/// Ordered points of the publication protocol (C3). Each one is a fault-injection boundary in the harness.
public enum PublicationBoundary: String, Sendable, CaseIterable, Codable {
    /// Coordinated re-read of the on-disk base and comparison with the expected revision.
    case baseCheck
    /// Writing the complete candidate revision into a private staging file.
    case stageWrite
    /// Re-reading the staged bytes and verifying envelope, checksum and revision.
    case stagedChecksum
    /// Retaining the validated coherent prior revision in the device-local recovery store.
    case retainPrior
    /// Replacing the canonical file with the staged candidate.
    case publish
    /// Independent read-back of the published bytes.
    case readBackVerify
    /// Acknowledging the verified revision to dependants (library/index).
    case acknowledge
    /// Migration: preserving the original and staging the migrated whole revision.
    case migrationStage
    /// Migration: publishing the migrated revision.
    case migrationPublish
}

/// Observation/injection points around each boundary. Production uses `NoPublicationHooks`.
public protocol PublicationHooks: Sendable {
    func willEnter(_ boundary: PublicationBoundary) throws
    func didComplete(_ boundary: PublicationBoundary) throws
}

public struct NoPublicationHooks: PublicationHooks {
    public init() {}
    public func willEnter(_ boundary: PublicationBoundary) throws {}
    public func didComplete(_ boundary: PublicationBoundary) throws {}
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
    /// The write failed before publication. The prior revision is unchanged on disk.
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
    public let revision: Int
    /// The coherent prior revision retained before publication, if there was one.
    public let priorCheckpoint: RecoveryCheckpoint?
    public let verifiedAt: Date
    /// Publication was verified, but cancellation or a dependant (library/index) acknowledgement did not
    /// complete. The document itself is coherent at `revision`.
    public let followUpIncomplete: Bool
}

/// How the verified candidate bytes are put in place.
public enum PublishStep {
    /// Stage in a private same-volume directory and replace (`FileOperations.replace`).
    case stagedReplace
    /// Delegate to an external safe-save (e.g. NSDocument's stock `writeSafely`). The closure must write
    /// exactly the given bytes to the URL; the result is still independently read back.
    case external((URL, Data) throws -> Void)
}

/// Executes the ordered C3 publication protocol for one candidate revision.
///
/// 1. Encode and validate the complete candidate (nothing touched on failure).
/// 2. Coordinated: re-read the on-disk base; any difference from the expected base is a conflict — the
///    candidate is preserved device-locally and nothing is overwritten.
/// 3. Stage the candidate privately and verify the staged bytes.
/// 4. Retain the validated prior in the recovery store.
/// 5. Publish by replacement (or the external safe-save).
/// 6. Independently read back and verify the published bytes; anything else is acknowledgement-uncertain.
/// 7. Only then acknowledge to dependants.
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

    /// Publishes `payload` as `revision`. Throws `PublicationError`; injected harness interruptions propagate
    /// unchanged so the harness can model process death at that point.
    public func publish(
        _ payload: Coder.Payload,
        revision: Int,
        key: DocumentKey,
        to url: URL,
        target: PublicationTarget,
        retainPrior: Bool = true,
        boundaries: (publish: PublicationBoundary, stage: PublicationBoundary) = (.publish, .stageWrite),
        isCancelled: () -> Bool = { false },
        step: PublishStep = .stagedReplace,
        acknowledge: ((PublicationReceipt) throws -> Void)? = nil
    ) throws -> PublicationReceipt {
        let candidate: Data
        do {
            candidate = try coder.encode(payload, revision: revision)
        } catch {
            throw PublicationError.invalidCandidate(error)
        }
        if case let .inPlace(base) = target, let baseRevision = base.revision, revision <= baseRevision {
            throw PublicationError.invalidCandidate(.invalidRevision(revision))
        }
        return try publish(
            candidate: candidate, revision: revision, key: key, to: url, target: target, retainPrior: retainPrior,
            boundaries: boundaries, isCancelled: isCancelled, step: step, acknowledge: acknowledge
        )
    }

    // swiftlint:disable:next function_body_length
    func publish(
        candidate: Data,
        revision: Int,
        key: DocumentKey,
        to url: URL,
        target: PublicationTarget,
        retainPrior: Bool,
        boundaries: (publish: PublicationBoundary, stage: PublicationBoundary),
        isCancelled: () -> Bool,
        step: PublishStep,
        acknowledge: ((PublicationReceipt) throws -> Void)?
    ) throws -> PublicationReceipt {
        let candidateFingerprint = RevisionFingerprint(of: candidate)
        var stagingDirectory: URL?
        defer {
            if let stagingDirectory { try? ops.remove(stagingDirectory) }
        }

        let (prior, verifiedAt): (RecoveryCheckpoint?, Date) = try coordination.coordinateWriting(at: url) { url in
            // Base check.
            try hooks.willEnter(.baseCheck)
            let onDisk: Data?
            do {
                onDisk = ops.exists(url) ? try ops.read(url) : nil
            } catch {
                throw PublicationError.failed(stage: .baseCheck, kind: WriteFailureKind(classifying: error), detail: "\(error)")
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
            try hooks.didComplete(.baseCheck)

            // Stage + verify (only for our own replacement path).
            var staged: URL?
            if case .stagedReplace = step {
                try hooks.willEnter(boundaries.stage)
                do {
                    let directory = try ops.makeStagingDirectory(appropriateFor: url)
                    stagingDirectory = directory
                    let file = directory.appending(path: url.lastPathComponent)
                    try ops.writeNew(candidate, to: file)
                    staged = file
                } catch let error as PublicationError {
                    throw error
                } catch where !(error is any InjectedInterruption) {
                    throw PublicationError.failed(stage: boundaries.stage, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                }
                try hooks.didComplete(boundaries.stage)

                try hooks.willEnter(.stagedChecksum)
                do {
                    let stagedBytes = try ops.read(staged!)
                    guard stagedBytes == candidate else {
                        throw PublicationError.failed(stage: .stagedChecksum, kind: .other, detail: "staged bytes differ from candidate")
                    }
                    _ = try coder.decode(stagedBytes)
                } catch let error as PublicationError {
                    throw error
                } catch let error as PersistenceError {
                    throw PublicationError.failed(stage: .stagedChecksum, kind: .other, detail: "\(error)")
                } catch where !(error is any InjectedInterruption) {
                    throw PublicationError.failed(stage: .stagedChecksum, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                }
                try hooks.didComplete(.stagedChecksum)
            }

            // Retain the validated coherent prior (bytes equal the base this document read/published).
            var prior: RecoveryCheckpoint?
            if retainPrior, case .inPlace = target, let onDisk, let recovery {
                try hooks.willEnter(.retainPrior)
                do {
                    prior = try recovery.retainCheckpoint(onDisk, for: key)
                } catch where !(error is any InjectedInterruption) {
                    throw PublicationError.failed(stage: .retainPrior, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                }
                try hooks.didComplete(.retainPrior)
            }

            guard !isCancelled() else { throw PublicationError.cancelled }

            // Publish.
            try hooks.willEnter(boundaries.publish)
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
                    throw PublicationError.failed(stage: boundaries.publish, kind: WriteFailureKind(classifying: error), detail: "\(error)")
                } else {
                    throw PublicationError.acknowledgementUncertain("publication reported \(error) and the on-disk state is unknown")
                }
            }
            try hooks.didComplete(boundaries.publish)

            // Independent read-back verification of coherent disk truth.
            try hooks.willEnter(.readBackVerify)
            let readBack: Data
            do {
                readBack = try ops.read(url)
            } catch where !(error is any InjectedInterruption) {
                throw PublicationError.acknowledgementUncertain("read-back failed: \(error)")
            }
            guard RevisionFingerprint.digest(readBack) == candidateFingerprint.byteDigest,
                  let decoded = try? coder.decode(readBack), decoded.revision == revision
            else {
                throw PublicationError.acknowledgementUncertain("read-back did not match revision \(revision)")
            }
            try hooks.didComplete(.readBackVerify)
            return (prior, Date())
        }

        try? recovery?.recordLocation(url, for: key)
        var receipt = PublicationReceipt(
            url: url, fingerprint: candidateFingerprint, revision: revision,
            priorCheckpoint: prior, verifiedAt: verifiedAt, followUpIncomplete: isCancelled()
        )
        if let acknowledge, !receipt.followUpIncomplete {
            try hooks.willEnter(.acknowledge)
            do {
                try acknowledge(receipt)
            } catch where !(error is any InjectedInterruption) {
                receipt = receipt.markingFollowUpIncomplete()
            }
            try hooks.didComplete(.acknowledge)
        }
        return receipt
    }

    private func conflict(expected: RevisionFingerprint?, onDisk: RevisionFingerprint?, candidate: Data, key: DocumentKey) -> PublicationError {
        let preserved = try? recovery?.preserveConflictCandidate(candidate, for: key)
        return .conflict(PublicationConflict(expected: expected, onDisk: onDisk, preservedCandidate: preserved))
    }
}

extension PublicationReceipt {
    func markingFollowUpIncomplete() -> PublicationReceipt {
        PublicationReceipt(url: url, fingerprint: fingerprint, revision: revision, priorCheckpoint: priorCheckpoint,
                           verifiedAt: verifiedAt, followUpIncomplete: true)
    }
}

/// Marker for harness-injected process interruptions. Persistence never catches or converts these, so the
/// harness can model the process dying at that exact point (no cleanup runs through dead file operations).
public protocol InjectedInterruption: Error {}
