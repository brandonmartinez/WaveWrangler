import Foundation
import WWCore

/// A user-chosen relink candidate compared with the source's recorded identity evidence.
public struct RelinkProposal: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case ready(bookmark: Data, resolvedPath: String)
        case notAFile
        case permissionDenied
        case notFound
        case bookmarkFailed(SourceErrorDescriptor)
        case metadataUnavailable(SourceErrorDescriptor)
    }

    public var key: DeviceAccessKey
    public var candidateFingerprint: FileSystemFingerprint?
    /// No raw witness is captured during evaluation; only explicit confirmation may mint one.
    public var candidateRaw: RawSourceIdentity?
    /// `.unknown` (all fields) when this device has no recorded evidence, e.g. a cross-machine open.
    public var comparison: IdentityComparison
    public var availability: Availability
    /// Another source *in the same show* already linked to the same file object on this device. Other
    /// shows (e.g. a duplicated show) may legitimately reference the same original.
    public var alreadyLinkedTo: SourceID?
    public var provenance: ObservationProvenance

    /// Only an exact metadata match to a recorded baseline, not linked elsewhere, may apply without an
    /// explicit user confirmation. Everything else (differences, unknown evidence, cross-machine,
    /// same-name files) requires the user to confirm.
    public var requiresConfirmation: Bool {
        !(comparison.isExactMatch && alreadyLinkedTo == nil)
    }

    public var canApply: Bool {
        if case .ready = availability { return true }
        return false
    }
}

public enum RelinkError: Error, Equatable, Sendable {
    case confirmationRequired(IdentityComparison)
    case candidateUnavailable(RelinkProposal.Availability)
    case sourceMismatch
}

/// Explicit relink: the user chooses a candidate (native panel), WaveWrangler compares metadata
/// evidence and shows the differences. It never searches for, ranks or auto-substitutes files —
/// including same-name files at the old path.
public struct RelinkEvaluator: Sendable {
    public let context: SourceAccessContext

    public init(context: SourceAccessContext) {
        self.context = context
    }

    public func evaluate(
        candidate: URL,
        for key: DeviceAccessKey,
        record: DeviceAccessRecord?,
        otherRecords: [DeviceAccessRecord] = []
    ) -> RelinkProposal {
        let record = record?.key == key ? record : nil
        return context.withScopedAccess(to: candidate) { url in
            let metadata: SourceMetadata
            switch context.io.metadata(at: url) {
            case let .success(value): metadata = value
            case .failure(.permissionDenied): return unavailable(key, .permissionDenied)
            case .failure(.notFound): return unavailable(key, .notFound)
            case let .failure(.other(error)): return unavailable(key, .metadataUnavailable(error))
            }
            guard metadata.isRegularFile.value == true else {
                return RelinkProposal(key: key, candidateFingerprint: metadata.fingerprint, candidateRaw: nil, comparison: .unknown(FingerprintField.allCases), availability: .notAFile, alreadyLinkedTo: nil, provenance: context.io.provenance)
            }
            let comparison = record?.recordedIdentity?.fingerprint.compare(to: metadata.fingerprint) ?? .unknown(FingerprintField.allCases)
            let objectKey = SourceImporter.objectKey(metadata.fingerprint)
            let linkedElsewhere = objectKey.flatMap { fileObject in
                otherRecords.first { other in
                    other.showID == key.showID && other.sourceID != key.sourceID
                        && other.recordedIdentity.flatMap { SourceImporter.objectKey($0.fingerprint) } == fileObject
                }?.sourceID
            }
            let availability: RelinkProposal.Availability
            do {
                let bookmark = try context.io.makeReadOnlyBookmark(for: url)
                var resolvedPath = url.standardizedFileURL.path
                if case let .resolved(resolved, _) = context.io.resolveBookmark(bookmark) {
                    resolvedPath = resolved.standardizedFileURL.path
                }
                availability = .ready(bookmark: bookmark, resolvedPath: resolvedPath)
            } catch {
                availability = .bookmarkFailed(SourceErrorDescriptor(error))
            }
            return RelinkProposal(
                key: key,
                candidateFingerprint: metadata.fingerprint,
                candidateRaw: nil,
                comparison: comparison,
                availability: availability,
                alreadyLinkedTo: linkedElsewhere,
                provenance: context.io.provenance
            )
        }
    }

    /// Applies a proposal to the device-local record. Throws unless the proposal is an exact match or the
    /// user explicitly confirmed it. A confirmed proposal records the candidate's evidence as a
    /// user-confirmed baseline; an exact match keeps the existing baseline.
    public func apply(
        _ proposal: RelinkProposal,
        to record: DeviceAccessRecord?,
        userConfirmed: Bool
    ) throws(RelinkError) -> DeviceAccessRecord {
        try apply(proposal, to: record, userConfirmed: userConfirmed, rawWitness: nil)
    }

    /// Only the explicit confirmation path may call the decoder-owned, read-only descriptor gateway.
    /// An exact device-local candidate is checked again before and after capture; metadata-only
    /// evaluation and unconfirmed relinks never invoke the gateway.
    public func applyConfirmed(
        _ proposal: RelinkProposal,
        to record: DeviceAccessRecord?,
        captureRawIdentity: @Sendable (URL, FileSystemFingerprint) async throws -> RawSourceIdentity
    ) async throws(RelinkError) -> DeviceAccessRecord {
        guard case let .ready(bookmark, resolvedPath) = proposal.availability,
              record?.key == proposal.key,
              proposal.comparison.isExactMatch, proposal.alreadyLinkedTo == nil,
              let fingerprint = proposal.candidateFingerprint,
              case let .resolved(scoped, isStale) = context.io.resolveBookmark(bookmark), !isStale,
              scoped.standardizedFileURL.path == resolvedPath,
              case let .success(before) = context.withScopedAccess(to: scoped, { context.io.metadata(at: $0) }),
              before.isRegularFile.value == true, before.isSymbolicLink.value == false,
              before.isDataless.value == false, before.volumeIsLocal.value == true,
              before.fingerprint == fingerprint
        else { throw .sourceMismatch }
        let raw: RawSourceIdentity
        do {
            raw = try await captureRawIdentity(scoped, fingerprint)
        } catch {
            throw .sourceMismatch
        }
        guard raw.isUsable,
              fingerprint.fileIdentifier.value == raw.inode,
              fingerprint.fileSize.value == raw.sizeBytes,
              fingerprint.volumeUUID.value?.lowercased() == raw.volumeUUID,
              case let .success(after) = context.withScopedAccess(to: scoped, { context.io.metadata(at: $0) }),
              after.isRegularFile.value == true, after.isSymbolicLink.value == false,
              after.isDataless.value == false, after.volumeIsLocal.value == true,
              after.fingerprint == fingerprint
        else { throw .sourceMismatch }
        return try apply(proposal, to: record, userConfirmed: true, rawWitness: raw)
    }

    private func apply(
        _ proposal: RelinkProposal,
        to record: DeviceAccessRecord?,
        userConfirmed: Bool,
        rawWitness: RawSourceIdentity?
    ) throws(RelinkError) -> DeviceAccessRecord {
        guard case let .ready(bookmark, resolvedPath) = proposal.availability else {
            throw .candidateUnavailable(proposal.availability)
        }
        if let record, record.key != proposal.key { throw .sourceMismatch }
        if proposal.requiresConfirmation && !userConfirmed {
            throw .confirmationRequired(proposal.comparison)
        }
        let now = context.now()
        var updated = record ?? DeviceAccessRecord(showID: proposal.key.showID, sourceID: proposal.key.sourceID, createdAt: now)
        updated.bookmark = bookmark
        updated.lastKnownPath = resolvedPath
        updated.lastKnownVolumeUUID = proposal.candidateFingerprint?.volumeUUID.value
        updated.lastBookmarkRefreshAt = now
        if userConfirmed, context.io is SystemSourceIO {
            guard let fingerprint = proposal.candidateFingerprint,
                  let raw = rawWitness, raw.isUsable,
                  fingerprint.fileIdentifier.value == raw.inode,
                  fingerprint.fileSize.value == raw.sizeBytes,
                  fingerprint.volumeUUID.value?.lowercased() == raw.volumeUUID
            else { throw .sourceMismatch }
            updated.recordedIdentity = RecordedIdentity(
                fingerprint: fingerprint, confirmation: .userConfirmed, recordedAt: now, rawWitness: raw
            )
        } else if !(proposal.comparison.isExactMatch && updated.recordedIdentity != nil),
                  let fingerprint = proposal.candidateFingerprint {
            updated.recordedIdentity = RecordedIdentity(fingerprint: fingerprint, confirmation: .userConfirmed, recordedAt: now)
        } else if userConfirmed {
            updated.recordedIdentity?.confirmation = .userConfirmed
        }
        updated.latestObservation = nil
        updated.relinkHistory.append(RelinkEvent(at: now, comparison: proposal.comparison, userConfirmed: userConfirmed))
        return updated
    }

    /// Marks the recorded baseline as user-confirmed (the user verified the source is the right one).
    public func confirmIdentity(of record: DeviceAccessRecord) -> DeviceAccessRecord {
        var updated = record
        if context.io is SystemSourceIO {
            updated.recordedIdentity?.rawWitness = nil
            return updated
        }
        updated.recordedIdentity?.confirmation = .userConfirmed
        return updated
    }

    private func unavailable(_ key: DeviceAccessKey, _ availability: RelinkProposal.Availability) -> RelinkProposal {
        RelinkProposal(key: key, candidateFingerprint: nil, candidateRaw: nil, comparison: .unknown(FingerprintField.allCases), availability: availability, alreadyLinkedTo: nil, provenance: context.io.provenance)
    }
}
