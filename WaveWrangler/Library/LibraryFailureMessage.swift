import Foundation
import WWOrganizer

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

    /// After Combine, Use Other Mac's Version, a move, Use That Library or a regrant. Only a confirmed replacement
    /// that left the library ready (L1) makes a failure reported before it obsolete (#199: the edit that met an L4
    /// conflict, which Combine then saved). A failed one (Combine couldn't publish and the conflict stays, the
    /// regrant didn't take) keeps it.
    mutating func libraryReplaced(succeeded: Bool, libraryState: LibraryLevelState) {
        if succeeded, libraryState == .ready { text = nil }
    }

    /// Ends `text` with exactly one period.
    static func sentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed + "."
    }
}
