import Foundation

public enum RecoveryChoicePresentation {
    public enum Kind: Sendable, Equatable {
        case savedPrior
        case verifiedCurrent
        case unsavedCheckpoint
        case damagedSaved
        case damagedUnsaved
        case olderSchema
    }

    public enum Disposition: Sendable, Equatable {
        case open
        case reveal
    }

    public struct Record: Sendable, Equatable {
        public let recordID: String
        public let kind: Kind
        public let documentID: String
        public let savedAt: Date?
        public let createdAt: Date?
        public let revision: Int?
        public let disposition: Disposition

        public init(recordID: String, kind: Kind, documentID: String, savedAt: Date?,
                    createdAt: Date?, revision: Int?, disposition: Disposition) {
            self.recordID = recordID
            self.kind = kind
            self.documentID = documentID
            self.savedAt = savedAt
            self.createdAt = createdAt
            self.revision = revision
            self.disposition = disposition
        }
    }

    public struct Choice: Sendable, Equatable {
        public let record: Record
        public let label: String
        public let shortcut: String
    }

    public struct Page: Sendable, Equatable {
        public let choices: [Choice]
        public let previousShortcut: String?
        public let nextShortcut: String?
    }

    public struct Plan: Sendable, Equatable {
        public let choices: [Choice]
        public let pages: [Page]
        public let defaultRecordID: String?
    }

    public static func plan(records: [Record]) -> Plan {
        let ordered = records.sorted { left, right in
            if left.recordedAt != right.recordedAt {
                return left.recordedAt.map { date in right.recordedAt.map { date > $0 } ?? true } ?? false
            }
            // Identity and record ID only stabilize tied/undated display; they never assert recency.
            if left.documentID != right.documentID { return left.documentID < right.documentID }
            return left.recordID < right.recordID
        }
        let choices = ordered.enumerated().map { index, record in
            let shortcut = "⌘\((index % 9) + 1)"
            let provenance = switch record.kind {
            case .unsavedCheckpoint, .damagedUnsaved: "Created"
            case .savedPrior, .verifiedCurrent, .damagedSaved, .olderSchema: "Saved"
            }
            let date = record.recordedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "date unknown"
            let action: String = if record.disposition == .reveal {
                "Show in Finder"
            } else {
                switch record.kind {
                case .unsavedCheckpoint: "Open Unsaved Copy"
                case .verifiedCurrent: "Open Last Verified Copy"
                case .savedPrior, .damagedSaved, .damagedUnsaved, .olderSchema: "Open Recovery Copy"
                }
            }
            let revision = record.revision.map { "; revision \($0)" } ?? ""
            let identity = record.documentID.isEmpty ? "unknown" : record.documentID
            return Choice(record: record,
                          label: "\(shortcut) \(action) (\(provenance) \(date); Show ID \(identity)\(revision))",
                          shortcut: shortcut)
        }
        let pages = stride(from: 0, to: choices.count, by: 9).map { offset in
            Page(choices: Array(choices[offset..<min(offset + 9, choices.count)]),
                 previousShortcut: offset > 0 ? "⌘[" : nil,
                 nextShortcut: offset + 9 < choices.count ? "⌘]" : nil)
        }
        let sole = ordered.count == 1 ? ordered.first : nil
        let defaultRecordID = if let sole, sole.disposition == .open,
                                 sole.kind == .savedPrior || sole.kind == .verifiedCurrent,
                                 sole.savedAt != nil {
            sole.recordID
        } else {
            nil as String?
        }
        return Plan(choices: choices, pages: pages, defaultRecordID: defaultRecordID)
    }
}

private extension RecoveryChoicePresentation.Record {
    var recordedAt: Date? {
        switch kind {
        case .unsavedCheckpoint, .damagedUnsaved: createdAt
        case .savedPrior, .verifiedCurrent, .damagedSaved, .olderSchema: savedAt
        }
    }
}
