import Foundation
import WWCore

/// The outcome of observing one source.
public struct SourceEvaluation: Sendable, Equatable {
    public var key: DeviceAccessKey
    public var observation: AvailabilityObservation
    /// Set only when the bookmark was safely refreshed (stale, accessible and identity evidence matched).
    /// Location hints and identity baselines are never changed here; that requires an explicit relink.
    public var refreshedRecord: DeviceAccessRecord?
    /// The URL the bookmark currently resolves to, for follow-up operations. Never a substitute.
    public var resolvedURL: URL?
    /// Residency metadata needed for transfer decisions.
    public var supportsDownloadRequest: Bool
}

/// Observes a source's independent dimensions from its device-local record using metadata only.
///
/// - Bookmark resolution never confirms identity (it can resolve a same-name replacement).
/// - "Denied" is derived from permission errors and never reported as "missing".
/// - A stale bookmark is re-created only while access is valid *and* identity evidence matches;
///   otherwise the source needs regrant/relink.
public struct SourceAvailabilityEvaluator: Sendable {
    public let context: SourceAccessContext

    public init(context: SourceAccessContext) {
        self.context = context
    }

    /// - Precondition: `record`, when present, belongs to `key` (records from another show are ignored).
    public func evaluate(
        key: DeviceAccessKey,
        record: DeviceAccessRecord?,
        setting: SourceAvailabilitySetting,
        transfer: TransferState? = nil
    ) -> SourceEvaluation {
        var observation = AvailabilityObservation(observedAt: context.now(), provenance: context.io.provenance)
        guard let record, record.key == key, let bookmark = record.bookmark else {
            observation.location = .unknown
            observation.locationEvidence = .noAccessRecord
            observation.access = .needsRegrant
            observation.accessEvidence = .noAccessRecord
            observation.identity = .unverified(.noRecordedEvidence)
            observation.identityEvidence = .noAccessRecord
            observation.transfer = .notRequested(.awaitingAccess)
            observation.transferEvidence = .noAccessRecord
            return SourceEvaluation(key: key, observation: observation, refreshedRecord: nil, resolvedURL: nil, supportsDownloadRequest: false)
        }

        switch context.io.resolveBookmark(bookmark) {
        case let .failed(failure):
            observeUnresolved(failure, record: record, into: &observation)
            return SourceEvaluation(key: key, observation: observation, refreshedRecord: nil, resolvedURL: nil, supportsDownloadRequest: false)
        case let .resolved(url, isStale):
            return context.withScopedAccess(to: url) { scopedURL in
                observeResolved(key: key, url: scopedURL, isStale: isStale, record: record, setting: setting, transfer: transfer, into: &observation)
            }
        }
    }

    private func observeUnresolved(_ failure: BookmarkFailure, record: DeviceAccessRecord, into observation: inout AvailabilityObservation) {
        observation.access = .needsRegrant
        observation.accessEvidence = .bookmarkResolution
        observation.transfer = .notRequested(.awaitingAccess)
        observation.transferEvidence = .bookmarkResolution
        observation.identity = .unknown
        observation.identityEvidence = .notObserved
        guard let path = record.lastKnownPath else {
            observation.location = .unknown
            observation.locationEvidence = .bookmarkResolution
            return
        }
        // Metadata-only probe of the last-known path to tell "missing" from "denied". Whatever is there is
        // only ever a *candidate*; nothing is substituted.
        switch context.io.metadata(at: URL(fileURLWithPath: path)) {
        case .failure(.notFound):
            observation.location = .missing(lastKnownPathOccupied: .known(false))
            observation.locationEvidence = .lastKnownLocationProbe
        case .failure(.permissionDenied):
            observation.location = .unknown
            observation.locationEvidence = .lastKnownLocationProbe
            observation.access = .denied
            observation.accessEvidence = .posixError
        case .failure(.other):
            observation.location = .unknown
            observation.locationEvidence = .lastKnownLocationProbe
        case let .success(metadata):
            let comparison = record.recordedIdentity.map { $0.fingerprint.compare(to: metadata.fingerprint) }
            if let comparison, let recorded = record.recordedIdentity, comparison.isExactMatch {
                // The original is still there but the grant is unusable: regrant, never silent refresh.
                observation.location = .present
                observation.identity = recorded.identityState(for: comparison)
            } else {
                observation.location = .missing(lastKnownPathOccupied: .known(true))
                observation.identity = comparison.flatMap { c in record.recordedIdentity.map { $0.identityState(for: c) } } ?? .unverified(.noRecordedEvidence)
            }
            observation.locationEvidence = .lastKnownLocationProbe
            observation.identityEvidence = .resourceValues
        }
    }

    private func observeResolved(
        key: DeviceAccessKey,
        url: URL,
        isStale: Bool,
        record: DeviceAccessRecord,
        setting: SourceAvailabilitySetting,
        transfer: TransferState?,
        into observation: inout AvailabilityObservation
    ) -> SourceEvaluation {
        let metadata: SourceMetadata
        switch context.io.metadata(at: url) {
        case .failure(.notFound):
            observation.location = .missing(lastKnownPathOccupied: .unknown)
            observation.locationEvidence = .resourceValues
            observation.access = .unknown
            observation.accessEvidence = .notObserved
            observation.transfer = .notRequested(.awaitingAccess)
            observation.transferEvidence = .resourceValues
            return SourceEvaluation(key: key, observation: observation, refreshedRecord: nil, resolvedURL: nil, supportsDownloadRequest: false)
        case .failure(.permissionDenied):
            observation.access = .denied
            observation.accessEvidence = .posixError
            observation.location = .unknown
            observation.locationEvidence = .posixError
            observation.transfer = .notRequested(.awaitingAccess)
            observation.transferEvidence = .posixError
            return SourceEvaluation(key: key, observation: observation, refreshedRecord: nil, resolvedURL: nil, supportsDownloadRequest: false)
        case .failure(.other):
            observation.access = .unknown
            observation.location = .unknown
            observation.locationEvidence = .resourceValues
            return SourceEvaluation(key: key, observation: observation, refreshedRecord: nil, resolvedURL: nil, supportsDownloadRequest: false)
        case let .success(value):
            metadata = value
        }

        // Identity (metadata only).
        let comparison = record.recordedIdentity.map { $0.fingerprint.compare(to: metadata.fingerprint) }
        if let comparison, let recorded = record.recordedIdentity {
            observation.identity = recorded.identityState(for: comparison)
        } else {
            observation.identity = .unverified(.noRecordedEvidence)
        }
        observation.identityEvidence = .resourceValues

        // Location.
        if let lastKnown = record.lastKnownPath, Self.samePath(lastKnown, url.path) {
            observation.location = .present
        } else {
            observation.location = .moved(currentPathHint: Self.canonicalPath(url.path))
        }
        observation.locationEvidence = .bookmarkResolution

        // Access, including the guarded stale refresh.
        var refreshed: DeviceAccessRecord?
        if metadata.isReadable.value == false {
            observation.access = .denied
            observation.accessEvidence = .resourceValues
        } else if isStale {
            if comparison?.isExactMatch == true, metadata.isReadable.value == true,
               let data = try? context.io.makeReadOnlyBookmark(for: url) {
                var updated = record
                updated.bookmark = data
                updated.lastBookmarkRefreshAt = observation.observedAt
                refreshed = updated
                observation.access = .granted
                observation.accessEvidence = .bookmarkRefreshed
            } else {
                observation.access = .staleBookmark
                observation.accessEvidence = .bookmarkResolution
            }
        } else {
            observation.access = metadata.isReadable.value == true ? .granted : .unknown
            observation.accessEvidence = .resourceValues
        }

        // Residency and transfer.
        let (residency, residencyEvidence) = metadata.residency
        observation.residency = residency
        observation.residencyEvidence = residencyEvidence
        if let transfer, Self.transferStillApplies(transfer, residency: residency) {
            observation.transfer = transfer
            observation.transferEvidence = .transferController
        } else {
            switch residency {
            case .cloudPlaceholder where !metadata.supportsDownloadRequest:
                observation.transfer = .notRequested(.unsupportedLocation)
                observation.transferEvidence = residencyEvidence
            case .cloudPlaceholder where setting == .off:
                observation.transfer = .notRequested(.availabilityOff)
                observation.transferEvidence = .availabilitySetting
            case .downloading:
                observation.transfer = .inProgress(fractionCompleted: .unknown)
                observation.transferEvidence = .ubiquitousResourceValues
            case .local:
                observation.transfer = .idle
                observation.transferEvidence = residencyEvidence
            case .cloudPlaceholder, .unknown:
                observation.transfer = .unknown
                observation.transferEvidence = .notObserved
            }
        }
        if let error = metadata.ubiquitous.downloadingError, observation.transferEvidence != .transferController {
            observation.transfer = TransferErrorClassifier.state(for: error)
            observation.transferEvidence = .ubiquitousResourceValues
        }

        if var refreshedRecord = refreshed {
            refreshedRecord.latestObservation = observation
            refreshed = refreshedRecord
        }
        return SourceEvaluation(
            key: key,
            observation: observation,
            refreshedRecord: refreshed,
            resolvedURL: url,
            supportsDownloadRequest: metadata.supportsDownloadRequest
        )
    }

    /// A controller transfer state overrides fresh evidence only while it is still meaningful: active
    /// transfers always; cancel/failure/offline only while the item is still not local. Terminal `idle`,
    /// `notRequested` and `unknown` states are history and never mask fresh residency/setting evidence.
    static func transferStillApplies(_ transfer: TransferState, residency: ResidencyState) -> Bool {
        switch transfer {
        case .requested, .inProgress:
            true
        case .cancelled, .failed, .offlineOrUnknown:
            residency == .cloudPlaceholder || residency == .downloading
        case .idle, .notRequested, .unknown:
            false
        }
    }

    /// Lexical comparison only. Stored paths come from bookmark resolution, which already reports the
    /// canonical form, so no extra file-system calls are made here.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }
}

/// Classifies provider download errors without inventing certainty.
public enum TransferErrorClassifier {
    static let offlineURLCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
    ]
    static let offlineCocoaCodes: Set<Int> = [
        NSUbiquitousFileUnavailableError, NSUbiquitousFileUbiquityServerNotAvailable,
    ]

    public static func state(for error: SourceErrorDescriptor) -> TransferState {
        switch error.domain {
        case NSURLErrorDomain where offlineURLCodes.contains(error.code):
            .offlineOrUnknown(error)
        case NSCocoaErrorDomain where offlineCocoaCodes.contains(error.code):
            .offlineOrUnknown(error)
        default:
            .failed(error)
        }
    }
}
