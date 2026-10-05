import Foundation
import WWCore

/// File-system details only (name, size, dates, kind-by-extension, folder display name). M1 never reads
/// content, headers or hashes to fill these in; any field may be unknown (`nil`).
public struct FileDetails: Hashable, Sendable {
    public var name: String?
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    /// Type from the file name extension (e.g. "WAV audio"), never sniffed from content.
    public var kind: String?
    /// Folder *display name*, never a path.
    public var folderName: String?

    public init(name: String? = nil, size: Int64? = nil, created: Date? = nil, modified: Date? = nil, kind: String? = nil, folderName: String? = nil) {
        self.name = name
        self.size = size
        self.created = created
        self.modified = modified
        self.kind = kind
        self.folderName = folderName
    }
}

/// Formatting used for user-visible file details; injectable for deterministic tests.
public struct FileDetailFormatter: Sendable {
    public var size: @Sendable (Int64) -> String
    public var date: @Sendable (Date) -> String

    public init(size: @escaping @Sendable (Int64) -> String, date: @escaping @Sendable (Date) -> String) {
        self.size = size
        self.date = date
    }

    public static let standard = FileDetailFormatter(
        size: { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
        date: { $0.formatted(date: .abbreviated, time: .shortened) }
    )
}

/// Relink/regrant comparison of what WaveWrangler recorded against the file the user chose (states §4).
/// It compares file details only — never audio.
public struct RelinkComparison: Hashable, Sendable {
    public enum Result: String, Hashable, Sendable {
        case same = "Same"
        case different = "Different"
        case unknown = "Unknown"
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var field: String
        public var recorded: String
        public var chosen: String
        public var result: Result
        public var id: String { field }

        public var accessibilityLabel: String { "\(field) — Recorded \(recorded) — Chosen \(chosen) — \(result.rawValue)" }
    }

    public enum Outcome: Hashable, Sendable {
        case match
        case different(fields: [String])
        case unknown(reason: String)
        /// The chosen file is already linked to another source in this show; using it needs confirmation.
        case alreadyLinked(otherSource: String)
        /// The chosen file can't be used at all (not a file, not found, permission denied…).
        case unavailable(reason: String)
    }

    public var rows: [Row]
    public var outcome: Outcome

    public var headline: String {
        switch outcome {
        case .match: "File details match. WaveWrangler compared file details, not audio."
        case let .different(fields): "Some file details are different: \(fields.map { $0.lowercased() }.joined(separator: ", "))."
        case let .unknown(reason): "WaveWrangler can't compare some details because \(reason)."
        case let .alreadyLinked(other): "This file is already used for “\(other)” in this show."
        case let .unavailable(reason): "WaveWrangler can't use this file: \(reason). Nothing was changed."
        }
    }

    /// False when the chosen file can't be used at all; only Choose Another… and Cancel remain.
    public var canConfirm: Bool {
        if case .unavailable = outcome { return false }
        return true
    }

    /// Anything but an exact match needs the "I've checked this is the same recording" checkbox and has
    /// no default button.
    public var requiresAcknowledgement: Bool { outcome != .match }

    public var confirmTitle: String { requiresAcknowledgement ? "Use This File Anyway" : "Use This File" }

    public static let acknowledgementTitle = "I've checked this is the same recording"

    /// The identity value that results from confirming this comparison.
    public var acceptedIdentity: IdentityStatus {
        switch outcome {
        case .match: .detailsMatch
        case let .different(fields): .changed(differences: fields.map { $0.lowercased() }.joined(separator: ", ") + " differ", acceptedByUser: true)
        case let .unknown(reason): .changed(differences: "not compared because \(reason)", acceptedByUser: true)
        case .alreadyLinked: .changed(differences: "also used by another source", acceptedByUser: true)
        case .unavailable: .notChecked
        }
    }

    public init(rows: [Row], outcome: Outcome) {
        self.rows = rows
        self.outcome = outcome
    }

    /// Compares field by field. A field missing on either side is Unknown, never Same.
    public static func compare(recorded: FileDetails, chosen: FileDetails, unknownReason: String? = nil, formatter: FileDetailFormatter = .standard) -> RelinkComparison {
        func row<T: Equatable>(_ field: String, _ lhs: T?, _ rhs: T?, _ format: (T) -> String) -> Row {
            let result: Result
            if let lhs, let rhs { result = lhs == rhs ? .same : .different } else { result = .unknown }
            return Row(field: field, recorded: lhs.map(format) ?? "Unknown", chosen: rhs.map(format) ?? "Unknown", result: result)
        }
        let seconds: (Date?) -> Int64? = { $0.map { Int64($0.timeIntervalSince1970.rounded(.down)) } }
        let rows = [
            row("Name", recorded.name, chosen.name) { $0 },
            row("Size", recorded.size, chosen.size, formatter.size),
            Row(field: "Created", recorded: recorded.created.map(formatter.date) ?? "Unknown", chosen: chosen.created.map(formatter.date) ?? "Unknown", result: row("", seconds(recorded.created), seconds(chosen.created)) { "\($0)" }.result),
            Row(field: "Modified", recorded: recorded.modified.map(formatter.date) ?? "Unknown", chosen: chosen.modified.map(formatter.date) ?? "Unknown", result: row("", seconds(recorded.modified), seconds(chosen.modified)) { "\($0)" }.result),
            row("Kind", recorded.kind, chosen.kind) { $0 },
        ]
        let different = rows.filter { $0.result == .different }.map(\.field)
        let outcome: Outcome
        if !different.isEmpty {
            outcome = .different(fields: different)
        } else if rows.contains(where: { $0.result == .unknown }) {
            let unknownFields = rows.filter { $0.result == .unknown }.map { $0.field.lowercased() }.joined(separator: ", ")
            outcome = .unknown(reason: unknownReason ?? "these details aren't available: \(unknownFields)")
        } else {
            outcome = .match
        }
        return RelinkComparison(rows: rows, outcome: outcome)
    }

    /// Open-panel message: "WaveWrangler recorded: 1.21 GB, created 3 Oct 2026 at 10:02 AM, from folder ZOOM0001."
    public static func panelMessage(for recorded: FileDetails?, formatter: FileDetailFormatter = .standard) -> String {
        guard let recorded else { return "WaveWrangler has no recorded file details for this source." }
        var parts: [String] = []
        if let size = recorded.size { parts.append(formatter.size(size)) }
        if let created = recorded.created { parts.append("created \(formatter.date(created))") }
        if let folder = recorded.folderName { parts.append("from folder \(folder)") }
        guard !parts.isEmpty else { return "WaveWrangler has no recorded file details for this source." }
        return "WaveWrangler recorded: \(parts.joined(separator: ", "))."
    }

    public static func panelPrompt(for displayName: String) -> String {
        "Choose the recording to use for “\(displayName)”"
    }
}

/// Download commands per the Transfer catalog (states §3.4, commands Source menu).
public enum TransferAction: String, Hashable, Sendable, CaseIterable {
    case download
    case pause
    case resume
    case cancel
    case retry

    public var menuTitle: String {
        switch self {
        case .download: "Download"
        case .pause: "Pause Download"
        case .resume: "Resume Download"
        case .cancel: "Cancel Download"
        case .retry: "Retry Download"
        }
    }

    /// Short inspector button title for a given transfer state.
    public func buttonTitle(for transfer: TransferStatus) -> String {
        switch (self, transfer) {
        case (.download, .cancelled): "Download Again"
        case (.download, _): "Download"
        case (.pause, _): "Pause"
        case (.resume, _): "Resume"
        case (.cancel, _): "Cancel"
        case (.retry, _): "Retry"
        }
    }

    /// Actions offered for one source. Pause/Resume appear only when the engine can genuinely pause.
    public static func available(transfer: TransferStatus, residency: ResidencyStatus, pauseSupported: Bool) -> [TransferAction] {
        let notLocal = residency == .cloudOnly || residency == .unknown
        switch transfer {
        case .idle, .downloadsOff: return notLocal ? [.download] : []
        case .unsupportedLocation: return []
        case .queued: return [.cancel]
        case .downloading: return pauseSupported ? [.pause, .cancel] : [.cancel]
        case .paused: return pauseSupported ? [.resume, .cancel] : [.cancel]
        case .cancelled: return [.download]
        case .failed, .noConnection: return [.retry]
        case .providerMayFinish: return []
        }
    }

    /// Cancel asks first when downloaded progress may be discarded.
    public static func cancelNeedsConfirmation(_ transfer: TransferStatus) -> Bool {
        switch transfer {
        case .downloading, .paused: true
        default: false
        }
    }

    public static func cancelConfirmation(for displayName: String) -> (message: String, confirm: String, keep: String) {
        ("Cancel downloading “\(displayName)”? The part already downloaded may be discarded.", "Cancel Download", "Keep Downloading")
    }
}

/// Episode-level download progress shown in the Sources header.
public struct EpisodeDownloadProgress: Hashable, Sendable {
    public var activeCount: Int
    /// Mean of system-reported fractions when *every* active download reported one; otherwise nil.
    public var fraction: Double?
    public var text: String

    public init?(statuses: [SourceStatusSnapshot]) {
        let active = statuses.map(\.transfer).filter(\.isActive)
        guard !active.isEmpty else { return nil }
        activeCount = active.count
        let fractions = active.compactMap { transfer -> Double? in
            if case let .downloading(fraction?) = transfer { return TransferStatus.clamped(fraction) }
            return nil
        }
        let sources = active.count == 1 ? "1 source" : "\(active.count) sources"
        if fractions.count == active.count {
            let mean = fractions.reduce(0, +) / Double(fractions.count)
            fraction = mean
            text = "Downloading \(sources) — \(Int((mean * 100).rounded(.down)))%"
        } else {
            fraction = nil
            text = "Downloading \(sources) — progress unknown"
        }
    }

    /// Explanation shown when downloads are Off and some sources aren't on this Mac.
    public static func offExplanation(notDownloadedCount: Int) -> String? {
        guard notDownloadedCount > 0 else { return nil }
        let lead = notDownloadedCount == 1 ? "1 source isn't downloaded." : "\(notDownloadedCount) sources aren't downloaded."
        return "\(lead) Downloads are Off: WaveWrangler will use file details only and won't download them."
    }
}

/// Exact undo action names (commands-keyboard §3).
public enum SetupUndoName {
    public static func importSources(_ count: Int) -> String { count == 1 ? "Import 1 Source" : "Import \(count) Sources" }
    public static let removeSource = "Remove Source"
    public static func assignToGroup(_ name: String) -> String { "Assign to Group “\(name)”" }
    public static let newRecorderGroup = "New Recorder Group"
    public static let renameRecorderGroup = "Rename Recorder Group"
    public static let deleteRecorderGroup = "Delete Recorder Group"
    public static let setEpoch = "Set Epoch"
    public static let startNewEpoch = "Start New Epoch"
    public static let setChannel = "Set Channel"
    public static func assignSpeaker(_ name: String) -> String { "Assign Speaker “\(name)”" }
    public static let newSpeaker = "New Speaker"
    public static let renameSpeaker = "Rename Speaker"
    public static let deleteSpeaker = "Delete Speaker"
    public static func changePrimary(_ speaker: String) -> String { "Change Primary for “\(speaker)”" }
    public static func changeBackup(_ speaker: String) -> String { "Change Backup for “\(speaker)”" }
    public static let moveSource = "Move Source"
    public static let moveSpeaker = "Move Speaker"
    public static func relink(_ file: String) -> String { "Relink “\(file)”" }
}

/// What to announce when the focused source's transfer changes (states §7). Pure; the caller throttles
/// progress (at most every 10 s) and only calls this for the focused source.
public enum TransferAnnouncement: Equatable, Sendable {
    case started
    case progress(percent: Int)
    case downloaded
    case failed(reason: String)
    case noConnection

    public static func decide(from old: SourceStatusSnapshot?, to new: SourceStatusSnapshot) -> TransferAnnouncement? {
        let before = old?.transfer
        guard before != new.transfer else { return nil }
        let wasActive = before?.isActive == true
        switch new.transfer {
        case let .downloading(fraction?):
            let bucket = Int(TransferStatus.clamped(fraction) * 4)
            if !wasActive { return .started }
            if case let .downloading(previous?) = before, Int(TransferStatus.clamped(previous) * 4) == bucket { return nil }
            return (1...3).contains(bucket) ? .progress(percent: bucket * 25) : nil
        case .downloading(nil), .queued:
            return wasActive ? nil : .started
        case let .failed(reason):
            return .failed(reason: reason)
        case .noConnection:
            if case .noConnection? = before { return nil }
            return .noConnection
        case .idle:
            // Only a transfer WaveWrangler was running that ended with the file on this Mac.
            return wasActive && new.residency == .local ? .downloaded : nil
        default:
            return nil
        }
    }

    public func text(for name: String) -> String {
        switch self {
        case .started: "Downloading \(name)"
        case let .progress(percent): "\(percent) percent downloaded, \(name)"
        case .downloaded: "Downloaded \(name)"
        case let .failed(reason): "Download failed for \(name): \(reason)"
        case .noConnection: "Download failed for \(name): no network connection"
        }
    }
}
