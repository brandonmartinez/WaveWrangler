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
        let choices = records.enumerated().map { index, record in
            Choice(record: record, label: "Recovery Copy \(index + 1)", shortcut: "")
        }
        return Plan(choices: choices, pages: [Page(choices: choices, previousShortcut: nil, nextShortcut: nil)],
                    defaultRecordID: records.first?.recordID)
    }
}
