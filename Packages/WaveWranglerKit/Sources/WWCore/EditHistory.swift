import Foundation

/// Skeleton for durable, named edit history (undo names survive save/reopen).
///
/// M1 only records named entries and a cursor; inverse payloads/replay are introduced by later owners.
public struct EditHistory: Sendable, Equatable, Codable {
    public var entries: [EditRecord]
    /// Number of `entries` currently applied (entries at or after the cursor are redo-able).
    public var cursor: Int

    public init(entries: [EditRecord] = [], cursor: Int? = nil) {
        self.entries = entries
        self.cursor = cursor ?? entries.count
    }

    /// Appends a named edit, discarding any redo tail.
    public func recording(_ record: EditRecord) -> EditHistory {
        var copy = self
        copy.entries = Array(entries.prefix(cursor)) + [record]
        copy.cursor = copy.entries.count
        return copy
    }

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < entries.count }
    public var undoActionName: String? { canUndo ? entries[cursor - 1].actionName : nil }
    public var redoActionName: String? { canRedo ? entries[cursor].actionName : nil }
}

public struct EditRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: EditID
    public var actionName: String
    public var timestamp: Date

    public init(id: EditID = EditID(), actionName: String, timestamp: Date) {
        self.id = id
        self.actionName = actionName
        self.timestamp = timestamp
    }
}
