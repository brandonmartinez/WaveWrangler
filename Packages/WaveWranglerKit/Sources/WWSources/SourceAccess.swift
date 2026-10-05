import Foundation
import WWCore

// Device-local source access model (stub for M1 foundation; the source owner implements behavior).
//
// These records are machine-specific and are never written into canonical show/library documents.
// Each observation dimension is independent and keeps `unknown` distinct from every negative state:
// a missing grant is not "missing file", an offline cloud placeholder is not "denied", and so on.

/// Whether the app may make the user's referenced originals available locally (e.g. trigger provider
/// downloads). Product default is ON; users may turn it OFF. OFF/metadata-only paths must make zero
/// content, hash, header, preview, decode or download requests.
public enum SourceAvailabilitySetting: String, Sendable, Codable, Equatable, CaseIterable {
    case on
    case off

    public static let `default`: SourceAvailabilitySetting = .on
}

/// Permission dimension: can this device currently use its location hint for the source?
public enum AccessState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case granted
    case denied
    case staleGrant
}

/// Location dimension: is anything present at the hinted location?
public enum PresenceState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case present
    case missing
}

/// Residency dimension for provider-backed folders.
public enum ResidencyState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case local
    case cloudOnly
}

/// Transfer dimension for an in-flight or failed provider download.
public enum TransferState: Sendable, Codable, Equatable {
    case unknown
    case idle
    case inProgress(fractionCompleted: Knowledge<Double>)
    case offline
    case cancelled
    case failed(reason: String)
}

/// Identity dimension: does whatever is at the location still match the logical source? A path or
/// filename match alone is never sufficient to report `.verified`.
public enum IdentityState: String, Sendable, Codable, Equatable, CaseIterable {
    case unknown
    case unverified
    case verified
    case changed
}

/// One point-in-time observation of a source on this device.
public struct AvailabilityObservation: Sendable, Codable, Equatable {
    public var observedAt: Date
    public var access: AccessState
    public var presence: PresenceState
    public var residency: ResidencyState
    public var transfer: TransferState
    public var identity: IdentityState

    public init(
        observedAt: Date,
        access: AccessState = .unknown,
        presence: PresenceState = .unknown,
        residency: ResidencyState = .unknown,
        transfer: TransferState = .unknown,
        identity: IdentityState = .unknown
    ) {
        self.observedAt = observedAt
        self.access = access
        self.presence = presence
        self.residency = residency
        self.transfer = transfer
        self.identity = identity
    }
}

/// Device-local mapping from a logical source to this machine's location hint and grant.
public struct SourceAccessRecord: Sendable, Codable, Equatable, Identifiable {
    public var sourceID: SourceID
    /// Security-scoped bookmark data: a permission/location hint, never identity.
    public var bookmark: Data?
    /// Human-readable last-known location, for relink UI only.
    public var locationHint: String?
    public var latestObservation: AvailabilityObservation?

    public var id: SourceID { sourceID }

    public init(sourceID: SourceID, bookmark: Data? = nil, locationHint: String? = nil, latestObservation: AvailabilityObservation? = nil) {
        self.sourceID = sourceID
        self.bookmark = bookmark
        self.locationHint = locationHint
        self.latestObservation = latestObservation
    }
}

/// Storage seam for device-local access records (implementation owned by the source owner).
public protocol SourceAccessRecordStore: Sendable {
    func record(for sourceID: SourceID) async throws -> SourceAccessRecord?
    func save(_ record: SourceAccessRecord) async throws
    func removeRecord(for sourceID: SourceID) async throws
}
