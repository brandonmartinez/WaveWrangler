import Foundation
import WWCore

/// What reconciliation observed about one show document on this Mac.
public enum ShowObservation: Sendable, Equatable {
    /// A validated coherent revision was read at the hinted location.
    case available(title: String, revision: Int)
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
            case let .available(title, revision):
                result.entries[index].lastKnownTitle = title
                result.entries[index].lastKnownRevision = revision
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
    public static func registering(_ showID: ShowID, title: String, revision: Int?, in library: LibraryModel) -> LibraryModel {
        guard !library.entries.contains(where: { $0.showID == showID }) else { return library }
        var result = library
        result.entries.append(LibraryShowEntry(showID: showID, lastKnownTitle: title, lastKnownRevision: revision))
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

    /// Records the last coherent revision acknowledged after a verified show publication.
    public static func acknowledging(_ showID: ShowID, title: String, revision: Int, in library: LibraryModel, at date: Date = Date()) -> LibraryModel {
        reconcile(registering(showID, title: title, revision: revision, in: library),
                  observations: [showID: .available(title: title, revision: revision)], at: date)
    }
}
