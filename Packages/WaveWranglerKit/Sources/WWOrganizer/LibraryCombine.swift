import Foundation
import WWCore

/// Result counts for the combine message bar (ST-36 step 5).
public struct LibraryCombineSummary: Sendable, Equatable {
    public var collectionsKeptAsSeparateCopies: Int
    public var showsAdded: Int
    public var recentItemsAdded: Int

    public var message: String {
        "Combined libraries: \(collectionsKeptAsSeparateCopies) collections kept as separate copies, \(showsAdded) shows and \(recentItemsAdded) recent items added."
    }
}

extension LibraryModel {
    /// Combine rule ST-36. `self` is the **base** (the library kept active: the folder's library or the
    /// other Mac's version); `thisMac` is the other one. Never drops anything: entries are unioned by show
    /// identity (never name or path), recents are unioned by identity, and collections are matched by name
    /// with differing same-named collections kept as "<name> (from this Mac)" (then "… 2", "… 3").
    ///
    /// - Parameter lastOpened: last-opened times for ordering recents newest first; shows without a time
    ///   keep their relative order (base first) after the dated ones.
    public func combining(
        thisMac: LibraryModel,
        lastOpened: [ShowID: Date] = [:]
    ) -> (library: LibraryModel, summary: LibraryCombineSummary) {
        var combined = self
        var summary = LibraryCombineSummary(collectionsKeptAsSeparateCopies: 0, showsAdded: 0, recentItemsAdded: 0)

        // 1. Entries by identity; keep the most recently observed status when both know the show.
        for entry in thisMac.entries {
            if let index = combined.entries.firstIndex(where: { $0.showID == entry.showID }) {
                combined.entries[index] = Self.newerObservation(combined.entries[index], entry)
            } else {
                combined.entries.append(entry)
                summary.showsAdded += 1
            }
        }

        // 2. Recents: union by identity, newest first by last-opened time.
        let baseRecents = Set(recentShowIDs)
        var union = recentShowIDs
        for id in thisMac.recentShowIDs where !baseRecents.contains(id) && !union.contains(id) {
            union.append(id)
            summary.recentItemsAdded += 1
        }
        let order = Dictionary(uniqueKeysWithValues: union.enumerated().map { ($1, $0) })
        combined.recentShowIDs = union.sorted { lhs, rhs in
            switch (lastOpened[lhs], lastOpened[rhs]) {
            case let (l?, r?) where l != r: l > r
            case (_?, nil): true
            case (nil, _?): false
            default: order[lhs]! < order[rhs]!
            }
        }

        // 3. Collections matched by name.
        var usedIDs = Set(combined.collections.map(\.id))
        for collection in thisMac.collections {
            let sameName = combined.collections.first { $0.name == collection.name }
            if let sameName, sameName.showIDs == collection.showIDs { continue }
            var added = collection
            if sameName != nil {
                added.name = Self.freeName(for: collection.name, in: combined.collections)
                summary.collectionsKeptAsSeparateCopies += 1
            }
            if usedIDs.contains(added.id) { added.id = CollectionID() }
            usedIDs.insert(added.id)
            combined.collections.append(added)
        }
        return (combined, summary)
    }

    static func freeName(for name: String, in collections: [LibraryCollection]) -> String {
        let names = Set(collections.map(\.name))
        var candidate = "\(name) (from this Mac)"
        var number = 2
        while names.contains(candidate) {
            candidate = "\(name) (from this Mac \(number))"
            number += 1
        }
        return candidate
    }

    /// Prefers the side with the more recent unavailable observation; otherwise keeps the base entry and
    /// fills in anything only the other side knows.
    static func newerObservation(_ base: LibraryShowEntry, _ other: LibraryShowEntry) -> LibraryShowEntry {
        var result = base
        if let otherRecord = other.unavailable, otherRecord.recordedAt > (base.unavailable?.recordedAt ?? .distantPast), base.unavailable != nil {
            result.unavailable = otherRecord
        }
        if result.alias == nil { result.alias = other.alias }
        if result.lastKnownPublication == nil { result.lastKnownPublication = other.lastKnownPublication }
        return result
    }
}

/// ST-33 step 4/6 wording.
public enum LibraryMoveWording {
    /// After a combine that couldn't carry some queued edits (they stay in the backup copy on this Mac).
    public static func queuedChangesNotCarried(_ descriptions: [String]) -> String? {
        guard !descriptions.isEmpty else { return nil }
        let count = descriptions.count == 1 ? "1 change you made" : "\(descriptions.count) changes you made"
        return "\(count) while the library was unavailable couldn't be combined. A backup copy with them was kept on this Mac: \(descriptions.joined(separator: "; "))."
    }

    public static func moved(to folder: String, previous: String) -> String {
        "Your library is now stored in “\(folder)”. The previous copy was kept in \(previous) as a backup."
    }

    public static func existingLibraryTitle(_ folder: String) -> String {
        "“\(folder)” already has a WaveWrangler library"
    }

    public static let existingLibraryCombineText =
        "WaveWrangler can combine your library with the one in this folder. All collections, recent items and library entries from both are kept, including unavailable shows. Your current library is kept as a backup."

    /// Reason shown instead of the combine text when Use That Library is disabled.
    public static func existingLibraryBlockedReason(_ state: LibraryLevelState) -> String? {
        switch state {
        case .ready, .conflict: nil
        case .damaged: "The library in this folder can't be read, so this version can't add to it."
        case .unreachable: "WaveWrangler can't reach the library in this folder right now."
        case .needsPermission: "WaveWrangler needs permission to use the library in this folder."
        case .newerFormat, .newerFormatNotViewable: "The library in this folder was saved by a newer version of WaveWrangler, so this version can't add to it."
        }
    }
}
