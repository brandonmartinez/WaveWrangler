import Foundation
import WWCore

/// One file found by a metadata-only import scan (names, folders, extension, size and dates only; the
/// scan never opens, previews, hashes or downloads files — IA-14).
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `typeFromNameOnly`: recognised only by its extension ("Type from file name").
        case recording(typeFromNameOnly: Bool)
        case notRecording
        case hidden
    }

    public var id: UUID
    public var details: FileDetails
    public var kind: Kind
    /// The engine found this exact file already referenced in the episode (not a same-name match).
    public var alreadyInEpisode: Bool
    public var residency: ResidencyStatus

    public init(id: UUID = UUID(), details: FileDetails, kind: Kind, alreadyInEpisode: Bool = false, residency: ResidencyStatus = .unknown) {
        self.id = id
        self.details = details
        self.kind = kind
        self.alreadyInEpisode = alreadyInEpisode
        self.residency = residency
    }

    public var displayName: String { details.name ?? "Unnamed file" }

    public var isRecording: Bool {
        if case .recording = kind { return true }
        return false
    }
}

/// Result of scanning the user's chosen files/folders.
public struct ImportScan: Hashable, Sendable {
    public var candidates: [ImportCandidate]
    /// Display name of what the user chose (one folder name, or "3 items").
    public var chosenDisplayName: String
    public var folderCount: Int
    public var fileCount: Int
    /// Items counted but not listed (engines that never enumerate non-recordings by name).
    public var uncountedSkips: SkipCounts
    /// Engine-provided suggestions by candidate; when nil, `ImportSuggester` derives them from names.
    public var suggestions: [UUID: CandidateSuggestions]?

    public struct SkipCounts: Hashable, Sendable {
        public var notRecordings: Int
        public var hidden: Int
        public var unreadable: Int
        public var duplicates: Int

        public init(notRecordings: Int = 0, hidden: Int = 0, unreadable: Int = 0, duplicates: Int = 0) {
            self.notRecordings = notRecordings
            self.hidden = hidden
            self.unreadable = unreadable
            self.duplicates = duplicates
        }
    }

    public init(candidates: [ImportCandidate], chosenDisplayName: String, folderCount: Int, fileCount: Int, uncountedSkips: SkipCounts = SkipCounts(), suggestions: [UUID: CandidateSuggestions]? = nil) {
        self.candidates = candidates
        self.chosenDisplayName = chosenDisplayName
        self.folderCount = folderCount
        self.fileCount = fileCount
        self.uncountedSkips = uncountedSkips
        self.suggestions = suggestions
    }
}

public struct CandidateSuggestions: Hashable, Sendable {
    public var group: Suggestion?
    public var speaker: Suggestion?

    public init(group: Suggestion? = nil, speaker: Suggestion? = nil) {
        self.group = group
        self.speaker = speaker
    }
}

/// A proposed value derived from folder/file names only, with the reason shown in help and VoiceOver.
public struct Suggestion: Hashable, Sendable {
    public var value: String
    public var reason: String

    public init(value: String, reason: String) {
        self.value = value
        self.reason = reason
    }
}

/// Suggests groupings from names only. Never applied until the user confirms (IA-15).
public enum ImportSuggester {
    public static func suggestions(
        for candidates: [ImportCandidate],
        knownSpeakerNames: [String]
    ) -> [UUID: (group: Suggestion?, speaker: Suggestion?)] {
        let recordings = candidates.filter(\.isRecording)
        let folderCounts = Dictionary(grouping: recordings.compactMap(\.details.folderName), by: { $0 }).mapValues(\.count)
        var result: [UUID: (group: Suggestion?, speaker: Suggestion?)] = [:]
        for candidate in recordings {
            var group: Suggestion?
            if let folder = candidate.details.folderName, !folder.isEmpty {
                let reason = (folderCounts[folder] ?? 0) > 1
                    ? "Suggested because the files share folder \(folder)"
                    : "Suggested because the file is in folder \(folder)"
                group = Suggestion(value: folder, reason: reason)
            }
            var speaker: Suggestion?
            let stem = (candidate.displayName as NSString).deletingPathExtension
            for name in knownSpeakerNames where name.count >= 2 {
                if containsWord(name, in: stem) {
                    speaker = Suggestion(value: name, reason: "Suggested because the file name contains “\(name)”")
                    break
                }
                if let folder = candidate.details.folderName, containsWord(name, in: folder) {
                    speaker = Suggestion(value: name, reason: "Suggested because the folder name contains “\(name)”")
                    break
                }
            }
            result[candidate.id] = (group, speaker)
        }
        return result
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains { $0 == word.lowercased()[...] }
    }
}

/// The Import Review sheet's state (IA §5). Nothing here copies or changes any file.
public struct ImportReview: Hashable, Sendable {
    public enum Choice: Hashable, Sendable {
        case none
        case suggested(Suggestion)
        /// User-confirmed value; `nil` = Ungrouped / Unassigned.
        case confirmed(String?)

        public var isUnconfirmedSuggestion: Bool {
            if case .suggested = self { return true }
            return false
        }

        /// The value applied on Import: only confirmed values ever apply.
        public var appliedValue: String? {
            if case let .confirmed(value) = self { return value }
            return nil
        }

        public func displayText(none: String) -> String {
            switch self {
            case .none, .confirmed(nil): none
            case let .suggested(suggestion): "\(suggestion.value) (suggested)"
            case let .confirmed(value?): value
            }
        }

        public func accessibilityValue(none: String) -> String {
            switch self {
            case .none, .confirmed(nil): none
            case let .suggested(suggestion): "\(suggestion.value), suggested"
            case let .confirmed(value?): value
            }
        }
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public var candidate: ImportCandidate
        public var include: Bool
        public var group: Choice
        public var speaker: Choice
        public var id: UUID { candidate.id }

        public var caption: String? {
            if candidate.alreadyInEpisode { return "Already in this episode" }
            if case .recording(true) = candidate.kind { return "Type from file name" }
            return nil
        }
    }

    public var episodeTitle: String
    public var rows: [Row]
    public var skipped: [ImportCandidate]
    public var chosenDisplayName: String
    public var folderCount: Int
    public var fileCount: Int
    public var uncountedSkips: ImportScan.SkipCounts

    public init(scan: ImportScan, episodeTitle: String, knownSpeakerNames: [String]) {
        self.episodeTitle = episodeTitle
        chosenDisplayName = scan.chosenDisplayName
        folderCount = scan.folderCount
        fileCount = scan.fileCount
        uncountedSkips = scan.uncountedSkips
        let derived = ImportSuggester.suggestions(for: scan.candidates, knownSpeakerNames: knownSpeakerNames)
        rows = scan.candidates.filter(\.isRecording).map { candidate in
            let engine = scan.suggestions?[candidate.id]
            let names = derived[candidate.id]
            let group = scan.suggestions == nil ? names?.group : engine?.group
            let speaker = engine?.speaker ?? names?.speaker
            return Row(
                candidate: candidate,
                include: !candidate.alreadyInEpisode,
                group: group.map(Choice.suggested) ?? .none,
                speaker: speaker.map(Choice.suggested) ?? .none
            )
        }
        skipped = scan.candidates.filter { !$0.isRecording }
    }

    public var includedRows: [Row] { rows.filter(\.include) }
    public var includedCount: Int { includedRows.count }

    /// "Import 9 Sources into “Interview with Ana”"
    public var title: String {
        let noun = includedCount == 1 ? "Source" : "Sources"
        return "Import \(includedCount) \(noun) into “\(episodeTitle)”"
    }

    /// "From: Ana Interview (2 folders, 11 files; 2 not recordings, skipped)"
    public var fromLine: String {
        var parts = [Self.count(folderCount, "folder"), Self.count(fileCount, "file")]
        if folderCount == 0 { parts.removeFirst() }
        var line = "From: \(chosenDisplayName) (\(parts.joined(separator: ", "))"
        let notRecordings = skipped.filter { $0.kind == .notRecording }.count + uncountedSkips.notRecordings
        let hidden = skipped.filter { $0.kind == .hidden }.count + uncountedSkips.hidden
        var skips: [String] = []
        if notRecordings > 0 { skips.append(notRecordings == 1 ? "1 not a recording" : "\(notRecordings) not recordings") }
        if hidden > 0 { skips.append(hidden == 1 ? "1 hidden item" : "\(hidden) hidden items") }
        if uncountedSkips.duplicates > 0 { skips.append(uncountedSkips.duplicates == 1 ? "1 chosen twice" : "\(uncountedSkips.duplicates) chosen twice") }
        if uncountedSkips.unreadable > 0 { skips.append(uncountedSkips.unreadable == 1 ? "1 couldn't be read" : "\(uncountedSkips.unreadable) couldn't be read") }
        if !skips.isEmpty { line += "; \(skips.joined(separator: ", ")), skipped" }
        return line + ")"
    }

    public static let suggestionsCaption = "Suggestions are based only on folder and file names. Review them before importing."

    public var importButtonTitle: String { "Import \(includedCount)" }
    public var canImport: Bool { includedCount > 0 }

    public func skipReason(_ candidate: ImportCandidate) -> String {
        switch candidate.kind {
        case .notRecording: "not a recording (skipped)"
        case .hidden: "hidden file (skipped)"
        case .recording: ""
        }
    }

    /// IA-17 download line; nil when every included file is on this Mac.
    public func downloadLine(downloadsOn: Bool) -> String? {
        let count = includedRows.filter { $0.candidate.residency == .cloudOnly }.count
        guard count > 0 else { return nil }
        let lead = count == 1 ? "1 file isn't downloaded." : "\(count) files aren't downloaded."
        return downloadsOn
            ? "\(lead) Downloads are On: they'll download after import."
            : "\(lead) Downloads are Off: WaveWrangler will use file details only and won't download them."
    }

    /// Number of unconfirmed suggestions among included rows; they are discarded on Import.
    public var unappliedSuggestionCount: Int {
        includedRows.reduce(0) { $0 + ($1.group.isUnconfirmedSuggestion ? 1 : 0) + ($1.speaker.isUnconfirmedSuggestion ? 1 : 0) }
    }

    /// "2 suggestions weren't accepted and won't be applied."
    public var confirmationLine: String? {
        switch unappliedSuggestionCount {
        case 0: nil
        case 1: "1 suggestion wasn't accepted and won't be applied."
        case let n: "\(n) suggestions weren't accepted and won't be applied."
        }
    }

    public var hasSuggestions: Bool {
        rows.contains { $0.group.isUnconfirmedSuggestion || $0.speaker.isUnconfirmedSuggestion }
    }

    public mutating func toggleInclude(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].include.toggle()
    }

    public mutating func setInclude(_ id: UUID, _ include: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].include = include
    }

    public mutating func setGroup(_ id: UUID, _ value: String?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].group = .confirmed(value)
    }

    public mutating func setSpeaker(_ id: UUID, _ value: String?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].speaker = .confirmed(value)
    }

    public mutating func acceptAllSuggestions() {
        for index in rows.indices {
            if case let .suggested(suggestion) = rows[index].group { rows[index].group = .confirmed(suggestion.value) }
            if case let .suggested(suggestion) = rows[index].speaker { rows[index].speaker = .confirmed(suggestion.value) }
        }
    }

    public mutating func clearSuggestions() {
        for index in rows.indices {
            if rows[index].group.isUnconfirmedSuggestion { rows[index].group = .none }
            if rows[index].speaker.isUnconfirmedSuggestion { rows[index].speaker = .none }
        }
    }

    /// Group names offered in the row pop-ups: existing groups, then suggested/confirmed names.
    public func groupOptions(existing: [String]) -> [String] {
        var names = existing
        for row in rows {
            for choice in [row.group] {
                switch choice {
                case let .suggested(s): names.append(s.value)
                case let .confirmed(v?): names.append(v)
                default: break
                }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The import batch: only included rows, only confirmed values. Each source's logical ID is the
    /// candidate's ID, so the engine's device-local record (made at scan time) refers to the same source.
    public func importItems() -> [(candidateID: UUID, item: SourceImportItem)] {
        includedRows.map { row in
            let source = SourceRecord(id: SourceID(row.candidate.id), displayNameHint: row.candidate.displayName)
            return (row.id, SourceImportItem(source: source, recorderGroupName: row.group.appliedValue, speakerName: row.speaker.appliedValue))
        }
    }

    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
