import Foundation
import WWCore

/// Identity of a row in the Setup Sources outline. Group `nil` is the Ungrouped pseudo-group.
public enum SetupRowID: Hashable, Sendable {
    case group(RecorderGroupID?)
    case source(SourceID)
    case channel(SourceID, SpeakerID)

    public var sourceID: SourceID? {
        switch self {
        case let .source(id), let .channel(id, _): id
        case .group: nil
        }
    }

    /// Stable accessibility identifier (IA §7). Uses logical IDs only, never file names or paths.
    public var accessibilityIdentifier: String {
        switch self {
        case let .group(id?): "ww.setup.group.\(id)"
        case .group(nil): "ww.setup.group.ungrouped"
        case let .source(id): "ww.setup.source.\(id)"
        case let .channel(source, speaker): "ww.setup.source.\(source).speaker.\(speaker)"
        }
    }
}

/// Text shown in a table cell plus its VoiceOver value ("—"/"none" for missing, "?"/"unknown" for unknown).
public struct CellText: Hashable, Sendable {
    public var text: String
    public var accessibilityValue: String

    public init(_ text: String, accessibilityValue: String? = nil) {
        self.text = text
        self.accessibilityValue = accessibilityValue ?? text
    }

    public static let none = CellText("—", accessibilityValue: "none")
    public static let unknown = CellText("?", accessibilityValue: "unknown")
}

public enum SourceSortOrder: String, Sendable, CaseIterable {
    case manual
    case name
    case epoch
    case channel
    case speaker
    case status

    public var title: String {
        switch self {
        case .manual: "Manual Order"
        case .name: "Name"
        case .epoch: "Epoch"
        case .channel: "Channel"
        case .speaker: "Speaker"
        case .status: "Status"
        }
    }
}

public struct SetupSourceRow: Identifiable, Hashable, Sendable {
    public var id: SetupRowID
    public var name: String
    public var epoch: CellText
    public var channel: CellText
    public var speaker: CellText
    public var role: CellText
    public var status: SourceStatusSummary?
    public var children: [SetupSourceRow]?
    /// VoiceOver label for the row (the name, or the group sentence).
    public var accessibilityLabel: String
    /// Durations, channel counts and sample rates stay "Unknown" in M1 (no decode).
    public var recordedFacts: RecordedFacts?
}

public struct RecordedFacts: Hashable, Sendable {
    public var duration: CellText
    public var channelCount: CellText
    public var sampleRate: CellText

    init(_ observations: SourceObservations) {
        duration = observations.durationSeconds.value.map { CellText(Self.format(duration: $0)) } ?? CellText("Unknown")
        channelCount = observations.channelCount.value.map { CellText("\($0)") } ?? CellText("Unknown")
        sampleRate = observations.sampleRate.value.map { CellText("\(Int($0)) Hz") } ?? CellText("Unknown")
    }

    static func format(duration seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

public struct SetupSpeakerRow: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case primaryChosen
        case choosePrimary
        case primaryUnavailable(reason: String)

        public var text: String {
            switch self {
            case .primaryChosen: "Primary chosen"
            case .choosePrimary: "Choose primary"
            case let .primaryUnavailable(reason): "Primary unavailable — \(reason)"
            }
        }

        public var symbolName: String {
            switch self {
            case .primaryChosen: "checkmark.circle"
            case .choosePrimary: "exclamationmark.triangle"
            case .primaryUnavailable: "exclamationmark.triangle"
            }
        }
    }

    public var id: SpeakerID
    public var name: String
    public var primary: CellText
    public var backupCount: Int
    public var backups: [String]
    public var status: Status
    public var accessibilityValue: String

    public var accessibilityIdentifier: String { "ww.setup.speaker.\(id)" }
}

/// Pure projection of one episode into the Setup tables.
public struct SetupPresentation: Sendable {
    public var sourceRows: [SetupSourceRow]
    public var speakerRows: [SetupSpeakerRow]
    public var sourceCount: Int
    public var needingAttentionCount: Int

    /// "Sources 14 · 2 need attention" (IA §4.3).
    public var sourcesHeader: String {
        guard needingAttentionCount > 0 else { return "Sources \(sourceCount)" }
        return "Sources \(sourceCount) · \(Self.attentionText(needingAttentionCount))"
    }

    public static func attentionText(_ count: Int) -> String {
        count == 1 ? "1 needs attention" : "\(count) need attention"
    }

    public init(
        model: ShowDocumentModel,
        episodeID: EpisodeID,
        statuses: [SourceID: SourceStatusSnapshot],
        onlyNeedingAttention: Bool = false,
        sortOrder: SourceSortOrder = .manual
    ) {
        guard let episode = model.episode(episodeID) else {
            self.init(sourceRows: [], speakerRows: [], sourceCount: 0, needingAttentionCount: 0)
            return
        }
        let speakerNames = Dictionary(model.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let status: (SourceID) -> SourceStatusSnapshot = { statuses[$0] ?? .checking }
        let attention = episode.sources.filter { status($0.id).summary.needsAttention }.count

        func sourceRow(_ source: SourceRecord) -> SetupSourceRow {
            let refs = episode.references(to: source.id)
            let channel = Self.channelText(episode.statedChannel(of: source.id))
            let summary = status(source.id).summary
            var row = SetupSourceRow(
                id: .source(source.id),
                name: source.displayNameHint,
                epoch: source.placement.recorderGroupID == nil ? .none : (episode.epochNumber(of: source.id).map { CellText("\($0)") } ?? .unknown),
                channel: channel,
                speaker: .none,
                role: .none,
                status: summary,
                children: nil,
                accessibilityLabel: source.displayNameHint,
                recordedFacts: RecordedFacts(source.observations)
            )
            if refs.count == 1, let ref = refs.first {
                row.speaker = CellText(speakerNames[ref.speakerID] ?? "Unknown speaker")
                row.role = Self.roleText(ref, source: source, assignment: episode.assignment(for: ref.speakerID))
            } else if refs.count > 1 {
                row.speaker = CellText("\(refs.count) speakers")
                row.role = CellText("—", accessibilityValue: "see channel rows")
                row.children = refs.map { ref in
                    SetupSourceRow(
                        id: .channel(source.id, ref.speakerID),
                        name: "Channel assignment",
                        epoch: .none,
                        channel: channel,
                        speaker: CellText(speakerNames[ref.speakerID] ?? "Unknown speaker"),
                        role: Self.roleText(ref, source: source, assignment: episode.assignment(for: ref.speakerID)),
                        status: nil,
                        children: nil,
                        accessibilityLabel: "\(source.displayNameHint), \(speakerNames[ref.speakerID] ?? "unknown speaker")",
                        recordedFacts: nil
                    )
                }
            }
            return row
        }

        func sorted(_ sources: [SourceRecord]) -> [SourceRecord] {
            let base = onlyNeedingAttention ? sources.filter { status($0.id).summary.needsAttention } : sources
            switch sortOrder {
            case .manual:
                return base
            case .name:
                return base.sorted { $0.displayNameHint.localizedStandardCompare($1.displayNameHint) == .orderedAscending }
            case .epoch:
                return base.sorted { (episode.epochNumber(of: $0.id) ?? .max) < (episode.epochNumber(of: $1.id) ?? .max) }
            case .channel:
                return base.sorted { (episode.statedChannel(of: $0.id) ?? .max) < (episode.statedChannel(of: $1.id) ?? .max) }
            case .speaker:
                let name: (SourceRecord) -> String = { episode.references(to: $0.id).first.flatMap { speakerNames[$0.speakerID] } ?? "\u{10FFFF}" }
                return base.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            case .status:
                let rank: (SourceRecord) -> Int = { status($0.id).summary.needsAttention ? 0 : 1 }
                return base.sorted { rank($0) < rank($1) }
            }
        }

        var rows: [SetupSourceRow] = []
        for group in episode.recorderGroups {
            let members = episode.sources(inRecorderGroup: group.id)
            let shown = sorted(members)
            if onlyNeedingAttention && shown.isEmpty { continue }
            let sentence = "\(group.name) — recorder group · \(Self.count(members.count, "source"))"
            rows.append(SetupSourceRow(id: .group(group.id), name: sentence, epoch: .none, channel: .none, speaker: .none, role: .none, status: nil, children: shown.map(sourceRow), accessibilityLabel: sentence, recordedFacts: nil))
        }
        let ungrouped = episode.sources(inRecorderGroup: nil)
        let shownUngrouped = sorted(ungrouped)
        if !(onlyNeedingAttention && shownUngrouped.isEmpty) {
            let sentence = "Ungrouped · \(Self.count(ungrouped.count, "source"))"
            rows.append(SetupSourceRow(id: .group(nil), name: sentence, epoch: .none, channel: .none, speaker: .none, role: .none, status: nil, children: shownUngrouped.map(sourceRow), accessibilityLabel: sentence, recordedFacts: nil))
        }

        let speakers = episode.speakerAssignments.map { assignment -> SetupSpeakerRow in
            let name = speakerNames[assignment.speakerID] ?? "Unknown speaker"
            let primaryText: CellText
            let rowStatus: SetupSpeakerRow.Status
            if let primary = assignment.primary, let source = episode.source(primary.sourceID) {
                let channelWords = episode.statedChannel(of: source.id).map { "channel \($0 + 1)" } ?? "channel unknown"
                let confirmed = assignment.primaryConfirmation == .userConfirmed
                let text = "\(source.displayNameHint) · \(channelWords)" + (confirmed ? "" : " (not confirmed)")
                primaryText = CellText(text, accessibilityValue: text.replacingOccurrences(of: " · ", with: " "))
                let summary = status(source.id).summary
                if !confirmed {
                    rowStatus = .choosePrimary
                } else if summary.needsAttention {
                    rowStatus = .primaryUnavailable(reason: summary.text)
                } else {
                    rowStatus = .primaryChosen
                }
            } else {
                primaryText = CellText("None")
                rowStatus = .choosePrimary
            }
            let backups = assignment.backups.compactMap { episode.source($0.sourceID)?.displayNameHint }
            let backupWords = Self.count(backups.count, "backup")
            let value = assignment.primary == nil
                ? "No primary, \(backupWords), \(rowStatus.text)"
                : "Primary \(primaryText.accessibilityValue), \(backupWords), \(rowStatus.text)"
            return SetupSpeakerRow(id: assignment.speakerID, name: name, primary: primaryText, backupCount: backups.count, backups: backups, status: rowStatus, accessibilityValue: value)
        }

        self.init(sourceRows: rows, speakerRows: speakers, sourceCount: episode.sources.count, needingAttentionCount: attention)
    }

    public init(sourceRows: [SetupSourceRow], speakerRows: [SetupSpeakerRow], sourceCount: Int, needingAttentionCount: Int) {
        self.sourceRows = sourceRows
        self.speakerRows = speakerRows
        self.sourceCount = sourceCount
        self.needingAttentionCount = needingAttentionCount
    }

    public static func recordedFacts(for source: SourceRecord) -> RecordedFacts {
        RecordedFacts(source.observations)
    }

    public static func channelText(_ statedChannel: Int?) -> CellText {
        guard let statedChannel else { return .unknown }
        return CellText("\(statedChannel + 1)", accessibilityValue: "\(statedChannel + 1), not checked against the file")
    }

    static func roleText(_ ref: SpeakerChannelReference, source: SourceRecord, assignment: SpeakerAssignment?) -> CellText {
        let confirmed = ref.isPrimary
            ? assignment?.primaryConfirmation == .userConfirmed
            : source.roleConfirmation == .userConfirmed && source.role == .backup
        let word = ref.isPrimary ? "Primary" : "Backup"
        return confirmed ? CellText(word) : CellText("\(word) (not confirmed)", accessibilityValue: "\(word), not confirmed")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// All source IDs in display order (for selection after filtering/sorting).
    public var orderedSourceIDs: [SourceID] {
        sourceRows.flatMap { $0.children ?? [] }.compactMap {
            if case let .source(id) = $0.id { return id }
            return nil
        }
    }
}
