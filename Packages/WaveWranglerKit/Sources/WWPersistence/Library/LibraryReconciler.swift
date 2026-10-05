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
    /// Changes queued on this Mac that the combine could not carry (they remain in the backup copy).
    public var queuedChangesNotCarried: [String] = []
    /// Collections only this Mac had, added unchanged.
    public var collectionsAdded = 0
    public var showsAdded = 0
    public var recentItemsAdded = 0
    /// Same-entry changes from the combined-in library that Combine can't carry (for example a show renamed
    /// differently on each Mac). They are listed for the user and stay in the backup copy (#117).
    public var entryChangesNotCarried: [String] = []

    mutating func add(_ other: LibraryMergeSummary) {
        entryChangesNotCarried += other.entryChangesNotCarried
        collectionsKeptAsCopies += other.collectionsKeptAsCopies
        collectionsAdded += other.collectionsAdded
        showsAdded += other.showsAdded
        recentItemsAdded += other.recentItemsAdded
        queuedChangesNotCarried += other.queuedChangesNotCarried
    }

    public var message: String {
        let combined = "Combined libraries: \(collectionsKeptAsCopies) collections kept as separate copies, \(showsAdded) shows and \(recentItemsAdded) recent items added."
        guard !entryChangesNotCarried.isEmpty else { return combined }
        let count = entryChangesNotCarried.count
        return combined + " \(count) change\(count == 1 ? "" : "s") from the other copy couldn't be combined and \(count == 1 ? "was" : "were") kept in a backup copy: "
            + entryChangesNotCarried.joined(separator: "; ") + "."
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
                if kept.alias == nil {
                    result.entries[index].alias = entry.alias
                } else if let alias = entry.alias, alias != kept.alias {
                    // Renamed differently on each side: the kept name stays; the other is reported, never dropped silently.
                    summary.entryChangesNotCarried.append("“\(kept.alias ?? kept.lastKnownTitle)” is named “\(alias)” in the other copy")
                }
                // A newer verified show publication recorded in the other copy is carried (with its title).
                if let theirs = entry.lastKnownPublication, theirs != kept.lastKnownPublication {
                    if let mine = kept.lastKnownPublication, mine.revision >= theirs.revision {
                        if mine.revision == theirs.revision {
                            summary.entryChangesNotCarried.append("“\(kept.alias ?? kept.lastKnownTitle)” has a different save of revision \(theirs.revision) recorded in the other copy")
                        }
                    } else {
                        result.entries[index].lastKnownPublication = theirs
                        result.entries[index].lastKnownTitle = entry.lastKnownTitle
                    }
                }
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

    /// Whether everything in `version` is already in `current`, field for field (#117): every entry (alias,
    /// recorded title and publication, unavailable record), every collection (name and exact member order) and
    /// every recent item. Only then may a provider conflict version be resolved without asking (after a backup).
    /// Anything else, including a version that is merely *older* in some field, goes to L4.
    public static func isContained(_ version: LibraryModel, in current: LibraryModel) -> Bool {
        for entry in version.entries {
            guard let kept = current.entries.first(where: { $0.showID == entry.showID }) else { return false }
            if let alias = entry.alias, alias != kept.alias { return false }
            if entry.lastKnownPublication != kept.lastKnownPublication {
                guard let theirs = entry.lastKnownPublication else { continue }   // never reconciled there
                guard let mine = kept.lastKnownPublication, mine.revision > theirs.revision else { return false }
            } else if entry.lastKnownTitle != kept.lastKnownTitle {
                return false
            }
            if let unavailable = entry.unavailable, unavailable != kept.unavailable {
                guard let recorded = kept.unavailable?.recordedAt, recorded >= unavailable.recordedAt else { return false }
            }
        }
        for collection in version.collections where !current.collections.contains(where: { $0.name == collection.name && $0.showIDs == collection.showIDs }) {
            return false
        }
        return version.recentShowIDs.allSatisfy(current.recentShowIDs.contains)
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
/// A three-way merge against `base` (the library the queued edits were made on): `mine` is the queued result,
/// `theirs` is what is on disk now. Both sides' changes since `base` are kept:
/// - collection membership, collections and recents merge as add/remove sets;
/// - order: the side that reordered wins; if both reordered differently, it is a conflict;
/// - user fields (alias, collection name) changed differently on both sides are a conflict;
/// - automatic observations (last-known publication/title, unavailable status) take the newest observation;
/// - a removal on one side of something the other side changed is a conflict.
/// Conflicts are reported (`uncarried`) instead of guessed; the caller keeps the journal and raises L4.
public enum QueuedLibraryEdits {
    public static func apply(base: LibraryModel, mine: LibraryModel, onto theirs: LibraryModel) -> (library: LibraryModel, uncarried: [String]) {
        var result = theirs
        var conflicts: [String] = []

        // Entries.
        let baseEntries = index(base.entries, by: \.showID)
        let theirEntries = index(theirs.entries, by: \.showID)
        for entry in mine.entries {
            let original = baseEntries[entry.showID]
            guard let resultIndex = result.entries.firstIndex(where: { $0.showID == entry.showID }) else {
                if original == nil { result.entries.append(entry) }        // added here
                else if entry != original {                               // removed there, changed here
                    conflicts.append("“\(entry.alias ?? entry.lastKnownTitle)” was removed on another Mac but changed here")
                }
                continue
            }
            let other = result.entries[resultIndex]
            var merged = other
            merged.alias = mergeUserField(base: original?.alias, mine: entry.alias, theirs: other.alias,
                                          label: "the name of “\(entry.lastKnownTitle)”", conflicts: &conflicts)
            let mineObserved = original == nil || entry.lastKnownPublication != original?.lastKnownPublication
            let theirsObserved = original == nil || other.lastKnownPublication != original?.lastKnownPublication
            if mineObserved, !theirsObserved || (entry.lastKnownPublication?.revision ?? -1) > (other.lastKnownPublication?.revision ?? -1) {
                merged.lastKnownPublication = entry.lastKnownPublication
                merged.lastKnownTitle = entry.lastKnownTitle
            } else if original != nil, entry.lastKnownTitle != original?.lastKnownTitle, other.lastKnownTitle == original?.lastKnownTitle {
                merged.lastKnownTitle = entry.lastKnownTitle
            }
            if entry.unavailable != original?.unavailable {
                if other.unavailable == original?.unavailable || (entry.unavailable?.recordedAt ?? .distantPast) > (other.unavailable?.recordedAt ?? .distantPast) {
                    merged.unavailable = entry.unavailable
                }
            }
            result.entries[resultIndex] = merged
        }
        for (id, original) in baseEntries where !mine.entries.contains(where: { $0.showID == id }) {
            guard let resultIndex = result.entries.firstIndex(where: { $0.showID == id }) else { continue }
            if theirEntries[id] == original { result.entries.remove(at: resultIndex) }
            else { conflicts.append("“\(original.alias ?? original.lastKnownTitle)” was removed here but changed on another Mac") }
        }

        // Collections: membership as add/remove sets, name as a user field, collection order.
        let baseCollections = index(base.collections, by: \.id)
        let theirCollections = index(theirs.collections, by: \.id)
        for collection in mine.collections {
            let original = baseCollections[collection.id]
            guard let resultIndex = result.collections.firstIndex(where: { $0.id == collection.id }) else {
                if let original {
                    if collection != original { conflicts.append("Collection “\(collection.name)” was removed on another Mac but changed here") }
                } else if !result.collections.contains(where: { $0.name == collection.name && $0.showIDs == collection.showIDs }) {
                    var kept = collection
                    if result.collections.contains(where: { $0.name == collection.name }) {
                        kept.name = LibraryMerge.uniqueName(for: collection.name, existing: Set(result.collections.map(\.name)))
                    }
                    result.collections.append(kept)
                }
                continue
            }
            let other = result.collections[resultIndex]
            result.collections[resultIndex].name = mergeUserField(base: original?.name, mine: collection.name, theirs: other.name,
                                                                  label: "the name of collection “\(collection.name)”", conflicts: &conflicts)
            switch mergeSequence(base: original?.showIDs ?? [], mine: collection.showIDs, theirs: other.showIDs) {
            case let .merged(ids): result.collections[resultIndex].showIDs = ids
            case .conflict: conflicts.append("Collection “\(collection.name)” was reordered differently here and on another Mac")
            }
        }
        for (id, original) in baseCollections where !mine.collections.contains(where: { $0.id == id }) {
            guard let resultIndex = result.collections.firstIndex(where: { $0.id == id }) else { continue }
            if theirCollections[id] == original { result.collections.remove(at: resultIndex) }
            else { conflicts.append("Collection “\(original.name)” was removed here but changed on another Mac") }
        }
        switch mergeSequence(base: base.collections.map(\.id), mine: mine.collections.map(\.id), theirs: theirs.collections.map(\.id)) {
        case let .merged(order):
            let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            result.collections = result.collections.enumerated()
                .sorted { (position[$0.1.id] ?? Int.max, $0.0) < (position[$1.1.id] ?? Int.max, $1.0) }
                .map(\.1)
        case .conflict:
            conflicts.append("Collections were reordered differently here and on another Mac")
        }

        // Recents (a convenience list): this Mac's additions first, then theirs; removals on either side apply.
        let removedHere = Set(base.recentShowIDs).subtracting(mine.recentShowIDs)
        let addedHere = mine.recentShowIDs.filter { !base.recentShowIDs.contains($0) }
        result.recentShowIDs = addedHere + theirs.recentShowIDs.filter { !removedHere.contains($0) && !addedHere.contains($0) }

        return (result, conflicts)
    }

    /// Changes `side` made since `base` that are not present in `result` (empty = every change carried).
    /// Used for both sides: this Mac's queued edits and the other Mac's publication.
    public static func missingChanges(base: LibraryModel, mine side: LibraryModel, in result: LibraryModel) -> [String] {
        var missing: [String] = []
        let baseEntries = index(base.entries, by: \.showID)
        let resultEntries = index(result.entries, by: \.showID)
        for entry in side.entries {
            let original = baseEntries[entry.showID]
            guard original == nil || entry != original else { continue }
            guard let carried = resultEntries[entry.showID] else { missing.append("entry “\(entry.lastKnownTitle)”"); continue }
            if entry.alias != original?.alias, carried.alias != entry.alias { missing.append("the name of “\(entry.lastKnownTitle)”") }
        }
        for (id, original) in baseEntries where !side.entries.contains(where: { $0.showID == id }) && resultEntries[id] != nil {
            missing.append("removal of “\(original.lastKnownTitle)”")
        }
        let baseCollections = index(base.collections, by: \.id)
        for collection in side.collections {
            let original = baseCollections[collection.id]
            guard original == nil || collection != original else { continue }
            let carried = result.collections.first { $0.id == collection.id }
                ?? result.collections.first { $0.name.hasPrefix(collection.name) && Set($0.showIDs) == Set(collection.showIDs) }
            guard let carried else { missing.append("collection “\(collection.name)”"); continue }
            let before = Set(original?.showIDs ?? [])
            let after = Set(collection.showIDs)
            if !after.subtracting(before).isSubset(of: Set(carried.showIDs)) { missing.append("members added to “\(collection.name)”") }
            if !before.subtracting(after).isDisjoint(with: Set(carried.showIDs)) { missing.append("members removed from “\(collection.name)”") }
            if let original, collection.name != original.name, carried.name != collection.name { missing.append("the name of collection “\(collection.name)”") }
            // Order: only if this side reordered members that are still present in the result.
            let kept = after.intersection(before).intersection(Set(carried.showIDs))
            if let original, relativeOrder(original.showIDs, of: kept) != relativeOrder(collection.showIDs, of: kept),
               relativeOrder(carried.showIDs, of: kept) != relativeOrder(collection.showIDs, of: kept) {
                missing.append("the order of “\(collection.name)”")
            }
        }
        for (id, original) in baseCollections where !side.collections.contains(where: { $0.id == id }) && result.collections.contains(where: { $0.id == id }) {
            missing.append("removal of collection “\(original.name)”")
        }
        let addedRecents = side.recentShowIDs.filter { !base.recentShowIDs.contains($0) }
        let removedRecents = base.recentShowIDs.filter { !side.recentShowIDs.contains($0) }
        if addedRecents.contains(where: { !result.recentShowIDs.contains($0) }) { missing.append("recent items added") }
        if removedRecents.contains(where: { result.recentShowIDs.contains($0) }) { missing.append("recent items removed") }
        return missing
    }

    // MARK: - Helpers

    enum SequenceMerge<Element: Hashable> { case merged([Element]), conflict }

    /// Three-way merge of an ordered list of unique elements: adds/removes from both sides apply; if exactly
    /// one side reordered the shared elements its order wins; if both reordered differently it's a conflict.
    static func mergeSequence<Element: Hashable>(base: [Element], mine: [Element], theirs: [Element]) -> SequenceMerge<Element> {
        let baseSet = Set(base), mineSet = Set(mine), theirSet = Set(theirs)
        let removed = baseSet.subtracting(mineSet).union(baseSet.subtracting(theirSet))
        let shared = baseSet.subtracting(removed)
        let baseOrder = relativeOrder(base, of: shared)
        let mineOrder = relativeOrder(mine, of: shared)
        let theirOrder = relativeOrder(theirs, of: shared)
        let mineMoved = mineOrder != baseOrder, theirsMoved = theirOrder != baseOrder
        if mineMoved, theirsMoved, mineOrder != theirOrder { return .conflict }
        // Start from the reordering side (theirs by default), then insert the other side's additions.
        let primary = mineMoved ? mine : theirs
        let secondary = mineMoved ? theirs : mine
        var result = primary.filter { !removed.contains($0) }
        for (offset, element) in secondary.enumerated() where !baseSet.contains(element) && !result.contains(element) {
            // Insert after the nearest preceding element that is already placed.
            let anchor = secondary[..<offset].last { result.contains($0) }
            if let anchor, let position = result.firstIndex(of: anchor) { result.insert(element, at: position + 1) }
            else { result.insert(element, at: 0) }
        }
        return .merged(result)
    }

    static func relativeOrder<Element: Hashable>(_ list: [Element], of subset: Set<Element>) -> [Element] {
        list.filter { subset.contains($0) }
    }

    static func mergeUserField<Value: Equatable>(base: Value?, mine: Value?, theirs: Value?, label: String, conflicts: inout [String]) -> Value? {
        if mine == base { return theirs }
        if theirs == base || theirs == mine { return mine }
        conflicts.append("\(label) was changed differently here and on another Mac")
        return theirs
    }

    static func mergeUserField(base: String?, mine: String, theirs: String, label: String, conflicts: inout [String]) -> String {
        guard let base else { return theirs }
        if mine == base { return theirs }
        if theirs == base || theirs == mine { return mine }
        conflicts.append("\(label) was changed differently here and on another Mac")
        return theirs
    }

    static func index<Element, Key: Hashable>(_ elements: [Element], by key: KeyPath<Element, Key>) -> [Key: Element] {
        Dictionary(elements.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
    }
}
