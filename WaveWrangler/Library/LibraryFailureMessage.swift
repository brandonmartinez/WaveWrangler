import Foundation
import WWOrganizer
import WWPersistence

/// ST-32: the Library window's library read or write failure, shown in its message bar until it's dismissed or no
/// longer describes the library. Also compiled into the unhosted WaveWranglerTests target.
struct LibraryFailureMessage: Equatable {
    private(set) var text: String?

    mutating func readFailed(_ reason: String) {
        text = "Couldn't read the library: \(Self.sentence(reason)) Your shows aren't affected, and the library won't be changed until it can be read."
    }

    mutating func writeFailed(_ reason: String) {
        text = "Couldn't update the library: \(Self.sentence(reason)) Your shows aren't affected."
    }

    mutating func dismiss() { text = nil }

    /// The library loaded after a failed read.
    mutating func libraryLoaded() { text = nil }

    /// After Combine, Use Other Mac's Version, Try Again, a regrant, a move or Use That Library. A failure reported
    /// before it is obsolete only when the action published (or adopted) a library, the library is ready (L1) and
    /// no edits are still waiting (#199: the edit that met an L4 conflict, which Combine then saved). Otherwise
    /// (Combine couldn't publish, a replay was refused and its edits stay queued, a regrant didn't take) it stays.
    mutating func libraryReplaced(published: Bool, libraryState: WWOrganizer.LibraryLevelState, editsWaiting: Bool) {
        if published, libraryState == .ready, !editsWaiting { text = nil }
    }

    /// Whether replaying queued edits (Try Again, or after a regrant) published them.
    static func published(_ replay: PendingEditsOutcome?) -> Bool {
        switch replay {
        case .applied?, .merged?, .alreadyIncluded?: true
        default: false
        }
    }

    /// Whether a regrant took and replayed any queued edits.
    static func published(_ regrant: LibraryRegrantOutcome?) -> Bool {
        guard case .regranted(_, let pending)? = regrant else { return false }
        return pending == nil || published(pending)
    }

    /// Ends `text` with exactly one period.
    static func sentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed + "."
    }
}
