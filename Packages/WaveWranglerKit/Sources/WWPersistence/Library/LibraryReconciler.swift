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
