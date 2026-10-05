import Foundation
import WWCore

// Device-local source availability model.
//
// Everything here is machine-specific and never written into canonical show/library documents. Each
// observation dimension is independent and keeps `unknown` distinct from every negative state: a missing
// grant is not a missing file, an offline cloud placeholder is not "denied", a metadata match is not a
// user-confirmed identity, and so on. M1 never decodes or reads source content, so duration, channel
// count and sample rate stay `unknown` (see `WWCore.SourceObservations`).

/// Whether the app may make the user's referenced originals available locally (provider downloads).
///
/// Product default is ON; users may turn it OFF. The persisted preference lives in the app
/// (`WWDownloadSourcesAutomatically`, Bool, missing key = ON); WWSources only receives the value.
/// OFF/metadata-only paths make zero content, hash, header, preview, decode or download requests. An
/// explicit per-item "Make Available" request from the user is still honored while OFF and is labelled
/// as a content transfer.
public enum SourceAvailabilitySetting: String, Sendable, Codable, Equatable, CaseIterable {
    case on
    case off

    public static let `default`: SourceAvailabilitySetting = .on

    /// Bridges the app preference `WWDownloadSourcesAutomatically` (nil = key missing = ON).
    public init(downloadSourcesAutomatically: Bool?) {
        self = (downloadSourcesAutomatically ?? true) ? .on : .off
    }

    public var downloadsAutomatically: Bool { self == .on }
}

/// Whether a value was observed from a real platform API or produced by a test double.
public enum ObservationProvenance: String, Sendable, Codable, Equatable, CaseIterable {
    case observed
    case simulated
}

/// Which evidence produced a dimension's value. Never "inferred from path or filename".
public enum ObservationEvidence: String, Sendable, Codable, Equatable, CaseIterable {
    case notObserved
    case noAccessRecord
    case bookmarkResolution
    case bookmarkRefreshed
    case resourceValues
    case lastKnownLocationProbe
    case posixError
    case fileSystemDatalessFlag
    case ubiquitousResourceValues
    case providerProgress
    case transferController
    case availabilitySetting
}

/// Location dimension: where (if anywhere) the logical source's file object currently is.
public enum LocationState: Sendable, Codable, Equatable {
    case unknown
    /// The file object is at its last-known location.
    case present
    /// The bookmark resolved to a different path; the hint is updated only after the user accepts it.
    case moved(currentPathHint: String)
    /// Nothing resolvable. `lastKnownPathOccupied` reports whether *something else* sits at the old
    /// path (a same-name candidate that is never substituted automatically).
    case missing(lastKnownPathOccupied: Knowledge<Bool>)
}

/// Permission dimension: can this device currently use its grant for the source?
public enum AccessState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case granted
    /// The bookmark resolved but is stale and could not be safely refreshed (identity evidence did not
    /// match or refresh failed). Never refreshed onto a different file object.
    case staleBookmark
    /// No usable grant on this device (no access record, unresolvable/corrupt bookmark, other machine).
    case needsRegrant
    /// The file system refused access (POSIX permission or sandbox). Never shown as missing.
    case denied
}

/// Residency dimension. Values come only from APIs that report them; there is no generic provider
/// classifier. Non-iCloud File Provider items are `unknown` unless the dataless flag reports otherwise.
public enum ResidencyState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case local
    case cloudPlaceholder
    case downloading
}

/// Why the app did not request a transfer.
public enum TransferHoldReason: String, Sendable, Codable, Equatable, CaseIterable {
    /// Source availability is OFF; no download is requested unless the user asks for this item.
    case availabilityOff
    /// The item is a placeholder reported only by the dataless flag; WaveWrangler has no evidenced
    /// download path for this provider, so it does not guess one.
    case unsupportedLocation
    /// Access must be restored (regrant/relink) before anything can be requested.
    case awaitingAccess
}

/// A platform error reduced to stable, codable facts (no user paths).
public struct SourceErrorDescriptor: Sendable, Codable, Equatable, Hashable {
    public var domain: String
    public var code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    public init(_ error: any Error) {
        let nsError = error as NSError
        self.init(domain: nsError.domain, code: nsError.code)
    }
}

/// Transfer dimension for a provider download.
public enum TransferState: Sendable, Codable, Equatable {
    case unknown
    case idle
    case notRequested(TransferHoldReason)
    /// Download requested; no progress observed yet.
    case requested
    /// `.unknown` fraction means indeterminate ("Progress unknown"); a fraction is shown only when an
    /// API reported it.
    case inProgress(fractionCompleted: Knowledge<Double>)
    /// The app stopped requesting/observing. Originals are never evicted or modified; the provider may
    /// still finish on its own.
    case cancelled
    case failed(SourceErrorDescriptor)
    /// The provider reported a connectivity/unavailable error, or no progress was reported before the
    /// stall timeout. The app cannot tell offline from a silent provider, so it says so.
    case offlineOrUnknown(SourceErrorDescriptor?)

    public var isActive: Bool {
        switch self {
        case .requested, .inProgress: true
        default: false
        }
    }
}

/// Identity-evidence fields (file-system metadata only in M1).
public enum FingerprintField: String, Sendable, Codable, Equatable, Hashable, CaseIterable, Comparable {
    case fileSize
    case creationDate
    case contentModificationDate
    case fileIdentifier
    case volumeUUID
    case contentType

    public static func < (lhs: FingerprintField, rhs: FingerprintField) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum UnverifiedReason: Sendable, Codable, Equatable {
    /// No recorded evidence on this device (new device, cross-machine open, lost access record).
    case noRecordedEvidence
    /// Metadata still matches the recorded evidence, but the user has not confirmed that baseline.
    case baselineNotUserConfirmed
    /// Some evidence could not be observed; listed fields are unknown.
    case insufficientEvidence([FingerprintField])
}

/// Identity dimension: does what we can see still match the logical source's recorded evidence?
/// A path, filename or bookmark match alone never produces `.matchesRecorded`.
public enum IdentityState: Sendable, Codable, Equatable {
    case unknown
    case unverified(UnverifiedReason)
    /// All metadata evidence matches a user-confirmed baseline.
    case matchesRecorded
    /// Same file object (file identifier and volume match) but size/dates/type changed.
    case changed([FingerprintField])
    /// A different file object (different file identifier or volume) — e.g. a same-name substitute or a copy.
    case mismatch([FingerprintField])
}

/// User-facing next step for a source state.
public enum SourceRemedy: String, Sendable, Codable, Equatable, CaseIterable {
    case regrantAccess
    case relink
    case confirmMovedLocation
    case reviewIdentityChange
    case confirmIdentity
    case makeAvailable
    case retryTransfer
    case checkPermissions
}

/// One point-in-time observation of a source on this device. Dimensions are independent.
public struct AvailabilityObservation: Sendable, Codable, Equatable {
    public var observedAt: Date
    public var provenance: ObservationProvenance
    public var location: LocationState
    public var locationEvidence: ObservationEvidence
    public var access: AccessState
    public var accessEvidence: ObservationEvidence
    public var residency: ResidencyState
    public var residencyEvidence: ObservationEvidence
    public var transfer: TransferState
    public var transferEvidence: ObservationEvidence
    public var identity: IdentityState
    public var identityEvidence: ObservationEvidence

    public init(
        observedAt: Date,
        provenance: ObservationProvenance = .observed,
        location: LocationState = .unknown,
        locationEvidence: ObservationEvidence = .notObserved,
        access: AccessState = .unknown,
        accessEvidence: ObservationEvidence = .notObserved,
        residency: ResidencyState = .unknown,
        residencyEvidence: ObservationEvidence = .notObserved,
        transfer: TransferState = .unknown,
        transferEvidence: ObservationEvidence = .notObserved,
        identity: IdentityState = .unknown,
        identityEvidence: ObservationEvidence = .notObserved
    ) {
        self.observedAt = observedAt
        self.provenance = provenance
        self.location = location
        self.locationEvidence = locationEvidence
        self.access = access
        self.accessEvidence = accessEvidence
        self.residency = residency
        self.residencyEvidence = residencyEvidence
        self.transfer = transfer
        self.transferEvidence = transferEvidence
        self.identity = identity
        self.identityEvidence = identityEvidence
    }

    /// Recovery actions implied by the observation, most important first.
    public var remedies: [SourceRemedy] {
        var result: [SourceRemedy] = []
        switch access {
        case .needsRegrant: result.append(.regrantAccess)
        case .denied: result.append(.checkPermissions)
        case .staleBookmark: result.append(.relink)
        case .granted, .unknown: break
        }
        switch location {
        case .missing: result.append(.relink)
        case .moved: result.append(.confirmMovedLocation)
        case .present, .unknown: break
        }
        switch identity {
        case .changed, .mismatch: result.append(.reviewIdentityChange)
        case .unverified(.baselineNotUserConfirmed): result.append(.confirmIdentity)
        case .unverified(.noRecordedEvidence): result.append(.relink)
        case .unverified(.insufficientEvidence), .matchesRecorded, .unknown: break
        }
        switch transfer {
        case .failed, .offlineOrUnknown, .cancelled: result.append(.retryTransfer)
        case .notRequested(.availabilityOff): result.append(.makeAvailable)
        default: break
        }
        var seen = Set<SourceRemedy>()
        return result.filter { seen.insert($0).inserted }
    }
}
