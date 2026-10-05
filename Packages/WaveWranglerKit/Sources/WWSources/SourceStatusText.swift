import Foundation

// Plain-language status text for labels, VoiceOver and blocked-reason explanations. Each dimension is
// described on its own so the UI never collapses distinct states (denied vs missing, unknown vs failed).

extension LocationState {
    public var statusText: String {
        switch self {
        case .unknown: "Location unknown"
        case .present: "At its last known location"
        case .moved: "Moved — confirm the new location"
        case .missing(lastKnownPathOccupied: .known(true)): "Missing — a different file is at the old location"
        case .missing: "Missing — relink to find it"
        }
    }
}

extension AccessState {
    public var statusText: String {
        switch self {
        case .unknown: "Access unknown"
        case .granted: "Access granted (read-only)"
        case .staleBookmark: "Saved access is out of date — relink to restore it"
        case .needsRegrant: "Access needed on this Mac — choose the file again"
        case .denied: "Access denied by macOS permissions — this is not a missing file"
        }
    }
}

extension ResidencyState {
    public var statusText: String {
        switch self {
        case .unknown: "Download status unknown"
        case .local: "Stored on this Mac"
        case .cloudPlaceholder: "In the cloud — not downloaded"
        case .downloading: "Downloading"
        }
    }
}

extension TransferState {
    public var statusText: String {
        switch self {
        case .unknown: "Transfer status unknown"
        case .idle: "No transfer needed"
        case .notRequested(.availabilityOff): "Not downloaded because source downloads are off — use Make Available to download this file"
        case .notRequested(.unsupportedLocation): "In the cloud; WaveWrangler cannot download from this location yet"
        case .notRequested(.awaitingAccess): "Waiting for access before downloading"
        case .requested: "Download requested — progress unknown"
        case let .inProgress(fraction):
            if let value = fraction.value {
                "Downloading \(Int((value * 100).rounded())) percent"
            } else {
                "Downloading — progress unknown"
            }
        case .cancelled: "Download stopped — the original was not changed"
        case .failed: "Download failed — try again"
        case .offlineOrUnknown: "Download not progressing — you may be offline. Try again later"
        }
    }

    /// Fraction for a determinate progress indicator, only when an API reported it.
    public var reportedFraction: Double? {
        if case let .inProgress(fraction) = self { return fraction.value }
        return nil
    }
}

extension IdentityState {
    public var statusText: String {
        switch self {
        case .unknown: "Identity not checked"
        case .unverified(.noRecordedEvidence): "Not verified on this Mac — relink to confirm"
        case .unverified(.baselineNotUserConfirmed): "Unchanged since added; not yet confirmed by you"
        case .unverified(.insufficientEvidence): "Not verified — some file details are unavailable"
        case .matchesRecorded: "Matches the file you confirmed"
        case .changed: "File details changed since you added it — review before use"
        case .mismatch: "A different file — review before use"
        }
    }
}

extension FingerprintField {
    public var displayName: String {
        switch self {
        case .fileSize: "Size"
        case .creationDate: "Created"
        case .contentModificationDate: "Modified"
        case .fileIdentifier: "File identity"
        case .volumeUUID: "Volume"
        case .contentType: "File type"
        }
    }
}
