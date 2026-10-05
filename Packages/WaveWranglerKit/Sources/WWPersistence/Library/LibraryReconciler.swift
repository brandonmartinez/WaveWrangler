import Foundation
import WWCore

/// What reconciliation observed about one show document on this Mac.
public enum ShowObservation: Sendable, Equatable {
    /// A validated coherent publication was read at the hinted location.
    case available(title: String, publication: PublicationStamp)
    /// Nothing at the hinted location (moved, deleted, offline or never downloaded — not distinguished).
    case missing
    /// Permission to the hinted location is denied or needs a regrant.
    case accessDenied
    /// Written by a newer WaveWrangler; not opened.
    case newerFormat(found: Int)
    /// The provider reports unresolved conflict versions.
    case conflicted(versionCount: Int)
    /// Present but damaged/unreadable.
    case damaged
    /// The show at the hinted location is a different logical show.
    case identityMismatch

    var unavailableNote: String? {
        switch self {
        case .available: nil
        case .missing: "The show could not be found at its last known location."
        case .accessDenied: "WaveWrangler needs permission to open this show again."
        case let .newerFormat(found): "This show was saved by a newer version of WaveWrangler (format \(found))."
        case let .conflicted(count): "This show has \(count) unresolved conflicting version(s)."
        case .damaged: "This show's file is damaged; recovery may be available."
        case .identityMismatch: "A different show is at this show's last known location."
        }
    }
}

/// Library edits needed by persistence (registration, recents, reconciliation). Collection/alias editing
/// operations live with the library UI lane; all of them return a new value and never drop entries.
public enum LibraryReconciler {
    public static let recentLimit = 50

    /// Applies observations. Entries are never removed: unreachable shows keep their aliases, collection
    /// membership and order and gain (or keep) an unavailable record; available shows clear it.
    public static func reconcile(_ library: LibraryModel, observations: [ShowID: ShowObservation], at date: Date) -> LibraryModel {
        var result = library
        for index in result.entries.indices {
            let entry = result.entries[index]
            guard let observation = observations[entry.showID] else { continue }
            switch observation {
            case let .available(title, publication):
                result.entries[index].lastKnownTitle = title
                result.entries[index].lastKnownPublication = publication
                result.entries[index].unavailable = nil
            default:
                let note = observation.unavailableNote ?? ""
                if entry.unavailable?.note != note {
                    result.entries[index].unavailable = UnavailableRecord(note: note, recordedAt: date)
                }
            }
        }
        return result
    }

    /// Adds a logical show reference if it is not already present.
    public static func registering(_ showID: ShowID, title: String, publication: PublicationStamp?, in library: LibraryModel) -> LibraryModel {
        guard !library.entries.contains(where: { $0.showID == showID }) else { return library }
        var result = library
        result.entries.append(LibraryShowEntry(showID: showID, lastKnownTitle: title, lastKnownPublication: publication))
        return result
    }

    /// Moves `showID` to the front of recents (bounded; recents are a convenience list, not user work).
    public static func recordingRecent(_ showID: ShowID, in library: LibraryModel) -> LibraryModel {
        guard library.entries.contains(where: { $0.showID == showID }) else { return library }
        var result = library
        result.recentShowIDs.removeAll { $0 == showID }
        result.recentShowIDs.insert(showID, at: 0)
        if result.recentShowIDs.count > recentLimit { result.recentShowIDs.removeLast(result.recentShowIDs.count - recentLimit) }
        return result
    }

    /// Records the publication acknowledged after a verified show publication (C3 step 8).
    public static func acknowledging(_ showID: ShowID, title: String, publication: PublicationStamp, in library: LibraryModel, at date: Date = Date()) -> LibraryModel {
        reconcile(registering(showID, title: title, publication: publication, in: library),
                  observations: [showID: .available(title: title, publication: publication)], at: date)
    }

    /// Whether the show on disk is a different publication from the one the library last reconciled
    /// (compared by publication ID and checksum; the revision number is only an ordering hint).
    public static func hasChanged(_ entry: LibraryShowEntry, observed: PublicationStamp) -> Bool {
        entry.lastKnownPublication?.publicationID != observed.publicationID || entry.lastKnownPublication?.checksum != observed.checksum
    }
}

/// What a combine kept/added, for the ST-36 summary message.
public struct LibraryMergeSummary: Sendable, Equatable {
    /// This Mac's collections kept as separate, suffixed copies.
    public var collectionsKeptAsCopies = 0
    /// Collections only this Mac had, added unchanged.
    public var collectionsAdded = 0
    public var showsAdded = 0
    public var recentItemsAdded = 0

    public var message: String {
        "Combined libraries: \(collectionsKeptAsCopies) collections kept as separate copies, \(showsAdded) shows and \(recentItemsAdded) recent items added."
    }
}

/// Design combine rule ST-36 ("Use That Library", "Combine (Keep Everything)"): nothing is dropped.
public enum LibraryMerge {
    public static let thisMacSuffix = "from this Mac"

    public static func combine(thisMac: LibraryModel, into base: LibraryModel) -> LibraryModel {
        combineWithSummary(thisMac: thisMac, into: base).library
    }

    /// Combines `thisMac` into `base` (the library that stays active):
    /// 1. entries (including unavailable ones) are unioned by show identity; for a shared show the entry with
    ///    the more recent recorded observation wins (`UnavailableRecord.recordedAt`; with no timestamps the
    ///    base entry is kept) and a missing alias is filled from the other side;
    /// 2. recents are unioned (base order first — the model records no last-opened time);
    /// 3. collections match by name: identical members and order → one; otherwise the base collection is
    ///    unchanged and this Mac's is added as "<name> (from this Mac)", "<name> (from this Mac 2)", … (first
    ///    free suffix). Collections only on this Mac are added (suffixed if the name collides).
    public static func combineWithSummary(thisMac: LibraryModel, into base: LibraryModel) -> (library: LibraryModel, summary: LibraryMergeSummary) {
        var result = base
        var summary = LibraryMergeSummary()
        for entry in thisMac.entries {
            if let index = result.entries.firstIndex(where: { $0.showID == entry.showID }) {
                let kept = result.entries[index]
                if let mine = entry.unavailable?.recordedAt, let theirs = kept.unavailable?.recordedAt, mine > theirs {
                    result.entries[index].unavailable = entry.unavailable
                }
                if kept.alias == nil { result.entries[index].alias = entry.alias }
            } else {
                result.entries.append(entry)
                summary.showsAdded += 1
            }
        }
        for collection in thisMac.collections {
            if result.collections.contains(where: { $0.name == collection.name && $0.showIDs == collection.showIDs }) { continue }
            var kept = collection
            let collides = result.collections.contains { $0.name == collection.name }
            if collides {
                kept.name = uniqueName(for: collection.name, existing: Set(result.collections.map(\.name)))
                summary.collectionsKeptAsCopies += 1
            } else {
                summary.collectionsAdded += 1
            }
            if result.collections.contains(where: { $0.id == kept.id }) { kept.id = CollectionID() }
            result.collections.append(kept)
        }
        for showID in thisMac.recentShowIDs where !result.recentShowIDs.contains(showID) {
            result.recentShowIDs.append(showID)
            summary.recentItemsAdded += 1
        }
        return (result, summary)
    }

    static func uniqueName(for name: String, existing: Set<String>) -> String {
        var candidate = "\(name) (\(thisMacSuffix))"
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(name) (\(thisMacSuffix) \(number))"
            number += 1
        }
        return candidate
    }
}

/// Replays edits queued while the library was unreachable (Design L2/L3) onto the library found on disk.
///
/// A field-level three-way merge: `base` is the library the queued edits were made on, `mine` the queued
/// result and `theirs` what is on disk now. Every change this Mac made (base → mine) is applied and wins over
/// a concurrent change to the same field; changes made elsewhere to other fields, entries, collections or
/// recents are kept. Anything that cannot be carried (for example a removal here of something changed
/// elsewhere) is reported instead of being silently dropped; the caller then keeps the journal and raises L4.
public enum QueuedLibraryEdits {
    public static func apply(base: LibraryModel, mine: LibraryModel, onto theirs: LibraryModel) -> (library: LibraryModel, uncarried: [String]) {
        var result = theirs
        var uncarried: [String] = []
        let baseEntries = Dictionary(base.entries.map { ($0.showID, $0) }, uniquingKeysWith: { first, _ in first })
        let mineEntries = Dictionary(mine.entries.map { ($0.showID, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in mine.entries {
            let original = baseEntries[entry.showID]
            guard let index = result.entries.firstIndex(where: { $0.showID == entry.showID }) else {
                // Added here, or removed elsewhere while kept here: keep it (nothing dropped).
                if original == nil || entry != original { result.entries.append(entry) }
                continue
            }
            if let original {
                if entry.alias != original.alias { result.entries[index].alias = entry.alias }
                if entry.lastKnownTitle != original.lastKnownTitle { result.entries[index].lastKnownTitle = entry.lastKnownTitle }
                if entry.lastKnownPublication != original.lastKnownPublication { result.entries[index].lastKnownPublication = entry.lastKnownPublication }
                if entry.unavailable != original.unavailable { result.entries[index].unavailable = entry.unavailable }
            } else if let alias = entry.alias, result.entries[index].alias != alias {
                result.entries[index].alias = alias
            }
        }
        for (id, original) in baseEntries where mineEntries[id] == nil {
            guard let index = result.entries.firstIndex(where: { $0.showID == id }) else { continue }
            if result.entries[index] == original {
                result.entries.remove(at: index)
            } else {
                uncarried.append("“\(original.alias ?? original.lastKnownTitle)” was removed on this Mac but changed elsewhere")
            }
        }

        let baseCollections = Dictionary(base.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mineCollections = Dictionary(mine.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for collection in mine.collections {
            let original = baseCollections[collection.id]
            if let index = result.collections.firstIndex(where: { $0.id == collection.id }) {
                if collection.name != original?.name { result.collections[index].name = collection.name }
                if collection.showIDs != original?.showIDs { result.collections[index].showIDs = collection.showIDs }
            } else if let original {
                // Removed elsewhere: keep it only if this Mac changed it.
                if collection != original { result.collections.append(collection) }
            } else {
                if result.collections.contains(where: { $0.name == collection.name && $0.showIDs == collection.showIDs }) { continue }
                var kept = collection
                if result.collections.contains(where: { $0.name == collection.name }) {
                    kept.name = LibraryMerge.uniqueName(for: collection.name, existing: Set(result.collections.map(\.name)))
                }
                result.collections.append(kept)
            }
        }
        for (id, original) in baseCollections where mineCollections[id] == nil {
            guard let index = result.collections.firstIndex(where: { $0.id == id }) else { continue }
            if result.collections[index] == original {
                result.collections.remove(at: index)
            } else {
                uncarried.append("Collection “\(original.name)” was removed on this Mac but changed elsewhere")
            }
        }
        // This Mac reordered collections: its order wins for the collections it has.
        if mine.collections.map(\.id) != base.collections.map(\.id) {
            let order = Dictionary(mine.collections.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            let indexed = result.collections.enumerated().map { ($0, $1) }
            result.collections = indexed.sorted { lhs, rhs in
                (order[lhs.1.id] ?? Int.max, lhs.0) < (order[rhs.1.id] ?? Int.max, rhs.0)
            }.map(\.1)
        }

        if mine.recentShowIDs != base.recentShowIDs {
            let addedElsewhere = theirs.recentShowIDs.filter { !base.recentShowIDs.contains($0) && !mine.recentShowIDs.contains($0) }
            result.recentShowIDs = mine.recentShowIDs + addedElsewhere
        }
        return (result, uncarried)
    }

    /// Queued changes (base → mine) that are not present in `result`. Empty means every queued edit is carried.
    public static func missingChanges(base: LibraryModel, mine: LibraryModel, in result: LibraryModel) -> [String] {
        var missing: [String] = []
        let baseEntries = Dictionary(base.entries.map { ($0.showID, $0) }, uniquingKeysWith: { first, _ in first })
        let resultEntries = Dictionary(result.entries.map { ($0.showID, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in mine.entries {
            guard let carried = resultEntries[entry.showID] else { missing.append("entry \(entry.showID)"); continue }
            let original = baseEntries[entry.showID]
            if entry.alias != original?.alias, carried.alias != entry.alias { missing.append("alias of \(entry.showID)") }
            if let original {
                if entry.lastKnownTitle != original.lastKnownTitle, carried.lastKnownTitle != entry.lastKnownTitle { missing.append("title of \(entry.showID)") }
                if entry.lastKnownPublication != original.lastKnownPublication, carried.lastKnownPublication != entry.lastKnownPublication {
                    missing.append("publication of \(entry.showID)")
                }
                if entry.unavailable != original.unavailable, carried.unavailable != entry.unavailable { missing.append("status of \(entry.showID)") }
            }
        }
        for id in baseEntries.keys where !mine.entries.contains(where: { $0.showID == id }) && resultEntries[id] != nil {
            missing.append("removal of entry \(id)")
        }
        let baseCollections = Dictionary(base.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for collection in mine.collections where collection != baseCollections[collection.id] {
            let carried = result.collections.first { $0.id == collection.id }
                ?? result.collections.first { $0.showIDs == collection.showIDs && $0.name.hasPrefix(collection.name) }
            guard let carried, carried.showIDs == collection.showIDs else { missing.append("collection “\(collection.name)”"); continue }
            if baseCollections[collection.id] != nil, collection.name != baseCollections[collection.id]?.name, carried.name != collection.name {
                missing.append("name of collection “\(collection.name)”")
            }
        }
        for (id, original) in baseCollections where !mine.collections.contains(where: { $0.id == id }) && result.collections.contains(where: { $0.id == id }) {
            missing.append("removal of collection “\(original.name)”")
        }
        if mine.recentShowIDs != base.recentShowIDs {
            for id in mine.recentShowIDs where !result.recentShowIDs.contains(id) { missing.append("recent \(id)") }
            for id in base.recentShowIDs where !mine.recentShowIDs.contains(id) && result.recentShowIDs.contains(id) {
                missing.append("removal of recent \(id)")
            }
        }
        return missing
    }
}
