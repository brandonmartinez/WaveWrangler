import Foundation

// Source availability presentation: five independently observed dimensions (states-and-recovery §3).
//
// These are presentation values that the Setup UI renders with Design's exact wording. Engines map their
// own observations onto them through `SourceSetupEngine`; nothing here performs I/O. A dimension that
// has not been observed yet is `.checking` (ST-01) and is never guessed.

public enum LocationStatus: Hashable, Sendable {
    case checking
    case known
    /// Found at a new location; `newFolder` is a folder *display name*, never a path.
    case moved(newFolder: String?)
    /// `sameNamedFileAtOriginalLocation` adds the ST-20 hint; it never relinks automatically.
    case missing(sameNamedFileAtOriginalLocation: Bool)
    case unknown(reason: String)
}

public enum AccessStatus: Hashable, Sendable {
    case checking
    case granted
    /// A stale grant is being refreshed automatically; it never prompts.
    case refreshing
    case needsPermission
    case denied
    case unknown(reason: String)
}

public enum ResidencyStatus: Hashable, Sendable {
    case checking
    case local
    case cloudOnly
    /// The provider gives no supported signal. No generic provider classifier is invented.
    case unknown
}

public enum TransferStatus: Hashable, Sendable {
    case idle
    case queued
    /// `fraction` is only ever a value the system reported; `nil` means progress unknown.
    case downloading(fraction: Double?)
    case paused
    case cancelled
    case failed(reason: String)
    case noConnection
    case downloadsOff
    /// Downloads were turned off while the provider was mid-transfer and couldn't be cancelled.
    case providerMayFinish
}

public enum IdentityStatus: Hashable, Sendable {
    case checking
    case notChecked
    case detailsMatch
    /// File details changed after the source was added. `acceptedByUser` after an explicit relink/review.
    case changed(differences: String, acceptedByUser: Bool)
    case mismatch(differences: String)
}

public enum SourceDimension: String, Sendable, CaseIterable {
    case location
    case access
    case residency
    case transfer
    case identity

    public var title: String {
        switch self {
        case .location: "Location"
        case .access: "Access"
        case .residency: "Residency"
        case .transfer: "Download"
        case .identity: "Identity"
        }
    }
}

/// One observed snapshot of a source's five dimensions with per-dimension observation times.
public struct SourceStatusSnapshot: Hashable, Sendable {
    public var location: LocationStatus
    public var access: AccessStatus
    public var residency: ResidencyStatus
    public var transfer: TransferStatus
    public var identity: IdentityStatus
    public var checkedAt: [SourceDimension: Date]

    public init(
        location: LocationStatus = .checking,
        access: AccessStatus = .checking,
        residency: ResidencyStatus = .checking,
        transfer: TransferStatus = .idle,
        identity: IdentityStatus = .checking,
        checkedAt: [SourceDimension: Date] = [:]
    ) {
        self.location = location
        self.access = access
        self.residency = residency
        self.transfer = transfer
        self.identity = identity
        self.checkedAt = checkedAt
    }

    /// Not observed yet: every observable dimension reads "Checking…".
    public static let checking = SourceStatusSnapshot()
}

public enum StatusTint: String, Hashable, Sendable {
    case none
    case attention
    case failed
    case secondary
}

/// How one dimension value is shown: inspector text, SF Symbol (or a spinner/bar), the table summary
/// (nil = no issue on its own), the VoiceOver phrase used when listing non-normal dimensions, and its
/// §3.6 priority class.
public struct DimensionPresentation: Hashable, Sendable {
    public enum Indicator: Hashable, Sendable {
        case symbol(String)
        case spinner
        case determinate(Double)
        case indeterminate
        case none
    }

    public var dimension: SourceDimension
    public var inspectorText: String
    public var indicator: Indicator
    public var summaryText: String?
    /// Phrase listed in the status cell's VoiceOver value when the value is not normal; nil when normal.
    public var spokenIssue: String?
    /// §3.6 priority (1–5) when this value can supply the table summary; 6 = checking; nil = normal.
    public var priority: Int?
    public var needsAttention: Bool
    public var tint: StatusTint

    public var symbolName: String? {
        if case let .symbol(name) = indicator { return name }
        return nil
    }

    init(_ dimension: SourceDimension, _ inspectorText: String, _ indicator: Indicator, summary: String?, spoken: String?, priority: Int?, attention: Bool = false, tint: StatusTint) {
        self.dimension = dimension
        self.inspectorText = inspectorText
        self.indicator = indicator
        self.summaryText = summary
        self.spokenIssue = spoken
        self.priority = priority
        self.needsAttention = attention
        self.tint = tint
    }
}

extension LocationStatus {
    public var presentation: DimensionPresentation {
        switch self {
        case .checking:
            .init(.location, "Checking…", .spinner, summary: "Checking…", spoken: "checking location", priority: 6, tint: .secondary)
        case .known:
            .init(.location, "At its saved location", .symbol("location"), summary: nil, spoken: nil, priority: nil, tint: .none)
        case let .moved(folder):
            .init(.location, folder.map { "Found at a new location (\($0))" } ?? "Found at a new location", .symbol("arrow.right.doc.on.clipboard"), summary: "Moved", spoken: "moved", priority: 2, attention: true, tint: .attention)
        case let .missing(decoy):
            .init(.location, decoy ? "Not found. A file with the same name is at the original location — choose Relink to check it." : "Not found", .symbol("questionmark.folder"), summary: "Not found", spoken: "not found", priority: 2, attention: true, tint: .attention)
        case let .unknown(reason):
            .init(.location, "Location unknown — \(reason)", .symbol("location.slash"), summary: "Location unknown", spoken: "location unknown", priority: 2, attention: true, tint: .secondary)
        }
    }
}

extension AccessStatus {
    public var presentation: DimensionPresentation {
        switch self {
        case .checking:
            .init(.access, "Checking…", .spinner, summary: "Checking…", spoken: "checking permission", priority: 6, tint: .secondary)
        case .granted:
            .init(.access, "WaveWrangler has permission", .symbol("key"), summary: nil, spoken: nil, priority: nil, tint: .none)
        case .refreshing:
            .init(.access, "Refreshing permission…", .spinner, summary: "Checking…", spoken: "refreshing permission", priority: 6, tint: .secondary)
        case .needsPermission:
            .init(.access, "WaveWrangler needs your permission again", .symbol("key.slash"), summary: "Needs permission", spoken: "needs permission", priority: 1, attention: true, tint: .attention)
        case .denied:
            .init(.access, "macOS or the file's owner denied access", .symbol("hand.raised.slash"), summary: "Access denied", spoken: "access denied", priority: 1, attention: true, tint: .failed)
        case let .unknown(reason):
            .init(.access, "Permission unknown — \(reason)", .symbol("questionmark.circle"), summary: "Permission unknown", spoken: "permission unknown", priority: 1, attention: true, tint: .secondary)
        }
    }
}

extension ResidencyStatus {
    public var presentation: DimensionPresentation {
        switch self {
        case .checking:
            .init(.residency, "Checking…", .spinner, summary: "Checking…", spoken: "checking download state", priority: 6, tint: .secondary)
        case .local:
            .init(.residency, "On this Mac", .symbol("laptopcomputer"), summary: nil, spoken: nil, priority: nil, tint: .none)
        case .cloudOnly:
            .init(.residency, "In the cloud — not downloaded", .symbol("icloud"), summary: "Not downloaded", spoken: "not downloaded", priority: 5, tint: .none)
        case .unknown:
            .init(.residency, "Can't tell if it's downloaded", .symbol("questionmark.diamond"), summary: "Download state unknown", spoken: "download state unknown", priority: 5, tint: .secondary)
        }
    }
}

extension TransferStatus {
    public var presentation: DimensionPresentation {
        switch self {
        case .idle:
            .init(.transfer, "No download requested", .none, summary: nil, spoken: nil, priority: nil, tint: .none)
        case .queued:
            .init(.transfer, "Waiting to download", .symbol("clock"), summary: "Waiting", spoken: "waiting to download", priority: 4, tint: .secondary)
        case let .downloading(fraction?):
            .init(.transfer, "Downloading — \(Self.percent(fraction))%", .determinate(Self.clamped(fraction)), summary: "Downloading \(Self.percent(fraction))%", spoken: "downloading \(Self.percent(fraction)) percent", priority: 4, tint: .secondary)
        case .downloading(nil):
            .init(.transfer, "Downloading — progress unknown", .indeterminate, summary: "Downloading…", spoken: "downloading, progress unknown", priority: 4, tint: .secondary)
        case .paused:
            .init(.transfer, "Download paused", .symbol("pause.circle"), summary: "Paused", spoken: "download paused", priority: 4, tint: .secondary)
        case .cancelled:
            .init(.transfer, "Download cancelled", .symbol("xmark.circle"), summary: "Cancelled", spoken: "download cancelled", priority: 4, tint: .secondary)
        case let .failed(reason):
            .init(.transfer, "Download failed: \(reason)", .symbol("exclamationmark.circle"), summary: "Download failed", spoken: "download failed", priority: 4, attention: true, tint: .failed)
        case .noConnection:
            .init(.transfer, "Can't download — no network connection", .symbol("wifi.slash"), summary: "No connection", spoken: "no connection", priority: 4, attention: true, tint: .attention)
        case .downloadsOff:
            .init(.transfer, "Downloads are off", .symbol("slash.circle"), summary: nil, spoken: nil, priority: nil, tint: .none)
        case .providerMayFinish:
            .init(.transfer, "Your cloud service may finish this download on its own", .indeterminate, summary: nil, spoken: "your cloud service may finish this download on its own", priority: nil, tint: .secondary)
        }
    }

    static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    static func percent(_ fraction: Double) -> Int {
        Int((clamped(fraction) * 100).rounded(.down))
    }

    public var isActive: Bool {
        switch self {
        case .queued, .downloading, .paused: true
        default: false
        }
    }
}

extension IdentityStatus {
    public var presentation: DimensionPresentation {
        switch self {
        case .checking:
            .init(.identity, "Checking…", .spinner, summary: "Checking…", spoken: "checking file details", priority: 6, tint: .secondary)
        case .notChecked:
            .init(.identity, "Not checked", .symbol("questionmark.circle"), summary: nil, spoken: "file details not checked", priority: nil, tint: .secondary)
        case .detailsMatch:
            .init(.identity, "File details match what WaveWrangler recorded (audio not compared)", .symbol("checkmark.seal"), summary: nil, spoken: nil, priority: nil, tint: .none)
        case let .changed(differences, true):
            .init(.identity, "Changed (accepted by you): \(differences)", .symbol("checkmark.seal"), summary: nil, spoken: "file changed, accepted by you", priority: nil, tint: .none)
        case let .changed(differences, false):
            .init(.identity, "This file changed after it was added (\(differences))", .symbol("exclamationmark.arrow.triangle.2.circlepath"), summary: "File changed", spoken: "file changed", priority: 3, attention: true, tint: .attention)
        case let .mismatch(differences):
            .init(.identity, "This isn't the file WaveWrangler recorded (\(differences))", .symbol("xmark.seal"), summary: "Different file", spoken: "different file", priority: 3, attention: true, tint: .failed)
        }
    }
}

/// The table summary and accessibility value for a source (states §3.6).
public struct SourceStatusSummary: Hashable, Sendable {
    public var text: String
    public var indicator: DimensionPresentation.Indicator
    public var tint: StatusTint
    /// Count of other dimensions that also have a summary-level issue, shown as "+N more".
    public var additionalIssueCount: Int
    /// VoiceOver value: every non-normal dimension in priority order, e.g.
    /// "Needs permission; not downloaded; file details not checked".
    public var accessibilityValue: String
    /// Header counter / "Show Only Sources Needing Attention": priorities 1–3 and failed/no-connection.
    public var needsAttention: Bool

    public var displayText: String {
        additionalIssueCount > 0 ? "\(text) +\(additionalIssueCount) more" : text
    }
}

extension SourceStatusSnapshot {
    /// Dimension presentations in the inspector's fixed order (all five rows, always).
    public var dimensions: [DimensionPresentation] {
        [location.presentation, access.presentation, residency.presentation, transfer.presentation, identity.presentation]
    }

    /// Summary per §3.6: priority 1 access, 2 location, 3 identity, 4 transfer, 5 residency, 6 any
    /// checking, otherwise "Ready". "Ready" never means verified audio.
    public var summary: SourceStatusSummary {
        let ordered = [access.presentation, location.presentation, identity.presentation, transfer.presentation, residency.presentation]
        let issues = ordered.filter { (1...5).contains($0.priority ?? 0) }
        let checking = ordered.filter { $0.priority == 6 }
        let unprioritised = ordered.filter { $0.priority == nil && $0.spokenIssue != nil }

        let lead: (text: String, indicator: DimensionPresentation.Indicator, tint: StatusTint)
        if let first = issues.first, let text = first.summaryText {
            lead = (text, first.indicator, first.tint)
        } else if !checking.isEmpty {
            lead = ("Checking…", .spinner, .secondary)
        } else {
            lead = ("Ready", .symbol("checkmark.circle"), .none)
        }

        var spoken: [String] = []
        if issues.isEmpty && checking.isEmpty { spoken.append("Ready") }
        spoken += issues.compactMap(\.spokenIssue)
        spoken += checking.compactMap(\.spokenIssue)
        spoken += unprioritised.compactMap(\.spokenIssue)
        if let first = spoken.first {
            spoken[0] = first.prefix(1).uppercased() + first.dropFirst()
        }
        return SourceStatusSummary(
            text: lead.text,
            indicator: lead.indicator,
            tint: lead.tint,
            additionalIssueCount: max(issues.count - 1, 0),
            accessibilityValue: spoken.joined(separator: "; "),
            needsAttention: ordered.contains(where: \.needsAttention)
        )
    }
}

/// Every SF Symbol name the Setup UI can show (A-01 symbol-resolution check) and representative values
/// covering every case of every dimension (F-STATES coverage for tests and previews).
public enum SourceStatusCatalog {
    public static let symbolNames: [String] = [
        "location", "arrow.right.doc.on.clipboard", "questionmark.folder", "location.slash",
        "key", "key.slash", "hand.raised.slash", "questionmark.circle",
        "laptopcomputer", "icloud", "questionmark.diamond",
        "clock", "pause.circle", "xmark.circle", "exclamationmark.circle", "wifi.slash", "slash.circle",
        "checkmark.seal", "exclamationmark.arrow.triangle.2.circlepath", "xmark.seal",
        "checkmark.circle", "circle.dashed", "exclamationmark.triangle", "mic", "person.2", "waveform.path",
    ]

    public static let allLocations: [LocationStatus] = [.checking, .known, .moved(newFolder: "Archive"), .moved(newFolder: nil), .missing(sameNamedFileAtOriginalLocation: false), .missing(sameNamedFileAtOriginalLocation: true), .unknown(reason: "the drive isn't connected")]
    public static let allAccess: [AccessStatus] = [.checking, .granted, .refreshing, .needsPermission, .denied, .unknown(reason: "macOS didn't say")]
    public static let allResidency: [ResidencyStatus] = [.checking, .local, .cloudOnly, .unknown]
    public static let allTransfers: [TransferStatus] = [.idle, .queued, .downloading(fraction: 0.42), .downloading(fraction: nil), .paused, .cancelled, .failed(reason: "the cloud service stopped responding"), .noConnection, .downloadsOff, .providerMayFinish]
    public static let allIdentity: [IdentityStatus] = [.checking, .notChecked, .detailsMatch, .changed(differences: "size differs", acceptedByUser: false), .changed(differences: "size differs", acceptedByUser: true), .mismatch(differences: "size and created date differ")]

    public static var allSnapshots: [SourceStatusSnapshot] {
        var result: [SourceStatusSnapshot] = []
        for location in allLocations {
            for access in allAccess {
                for residency in allResidency {
                    for transfer in allTransfers {
                        for identity in allIdentity {
                            result.append(SourceStatusSnapshot(location: location, access: access, residency: residency, transfer: transfer, identity: identity))
                        }
                    }
                }
            }
        }
        return result
    }
}
