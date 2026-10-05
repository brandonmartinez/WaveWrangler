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

/// Design's "Use That Library" combine rules: nothing is dropped.
public enum LibraryMerge {
    public static let thisMacSuffix = "from this Mac"

    /// Combines `thisMac` into `target`:
    /// - entries: every target entry, plus this Mac's entries for shows the target lacks (including
    ///   unavailable ones); for shared shows the target's entry wins but a missing alias is filled in;
    /// - collections: target collections first; this Mac's collections follow unless an identical one
    ///   (same name, same members in the same order) exists. A same-named collection that differs in members
    ///   or order is kept as "<name> (from this Mac)", "<name> (from this Mac 2)", …;
    /// - recents: target recents, then this Mac's recents not already present.
    public static func combine(thisMac: LibraryModel, into target: LibraryModel) -> LibraryModel {
        var result = target
        for entry in thisMac.entries {
            if let index = result.entries.firstIndex(where: { $0.showID == entry.showID }) {
                if result.entries[index].alias == nil { result.entries[index].alias = entry.alias }
            } else {
                result.entries.append(entry)
            }
        }
        for collection in thisMac.collections {
            if result.collections.contains(where: { $0.name == collection.name && $0.showIDs == collection.showIDs }) { continue }
            var kept = collection
            if result.collections.contains(where: { $0.name == collection.name }) {
                kept.name = uniqueName(for: collection.name, existing: Set(result.collections.map(\.name)))
            }
            if result.collections.contains(where: { $0.id == kept.id }) { kept.id = CollectionID() }
            result.collections.append(kept)
        }
        for showID in thisMac.recentShowIDs where !result.recentShowIDs.contains(showID) {
            result.recentShowIDs.append(showID)
        }
        return result
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
