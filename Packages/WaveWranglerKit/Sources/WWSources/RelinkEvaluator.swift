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
                return RelinkProposal(key: key, candidateFingerprint: metadata.fingerprint, comparison: .unknown(FingerprintField.allCases), availability: .notAFile, alreadyLinkedTo: nil, provenance: context.io.provenance)
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
        if !(proposal.comparison.isExactMatch && updated.recordedIdentity != nil), let fingerprint = proposal.candidateFingerprint {
            updated.recordedIdentity = RecordedIdentity(fingerprint: fingerprint, confirmation: .userConfirmed, recordedAt: now)
        } else if userConfirmed, var identity = updated.recordedIdentity {
            identity.confirmation = .userConfirmed
            updated.recordedIdentity = identity
        }
        updated.latestObservation = nil
        updated.relinkHistory.append(RelinkEvent(at: now, comparison: proposal.comparison, userConfirmed: userConfirmed))
        return updated
    }

    /// Marks the recorded baseline as user-confirmed (the user verified the source is the right one).
    public func confirmIdentity(of record: DeviceAccessRecord) -> DeviceAccessRecord {
        var updated = record
        updated.recordedIdentity?.confirmation = .userConfirmed
        return updated
    }

    private func unavailable(_ key: DeviceAccessKey, _ availability: RelinkProposal.Availability) -> RelinkProposal {
        RelinkProposal(key: key, candidateFingerprint: nil, comparison: .unknown(FingerprintField.allCases), availability: availability, alreadyLinkedTo: nil, provenance: context.io.provenance)
    }
}
