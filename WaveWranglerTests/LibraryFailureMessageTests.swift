import Foundation
import Testing
import WWOrganizer
import WWPersistence

/// ST-32 message lifecycle (#199): only a replacement that published a library, left it ready and left no edits
/// waiting makes a write failure obsolete.
@Suite("Library failure message")
struct LibraryFailureMessageTests {
    private static let conflict = "Another version of this document is on disk. Your changes were not saved over it."

    @Test func aPublishedReplacementClearsTheObsoleteWriteFailure() {
        var failure = LibraryFailureMessage()
        failure.writeFailed(Self.conflict)
        #expect(failure.text == "Couldn't update the library: Another version of this document is on disk. Your changes were not saved over it. Your shows aren't affected.")
        failure.libraryReplaced(published: true, libraryState: .ready, editsWaiting: false)
        #expect(failure.text == nil, "Combine (or another replacement) saved the change: the failure is obsolete")
    }

    @Test func aFailedReplacementKeepsTheWriteFailure() {
        var failure = LibraryFailureMessage()
        failure.writeFailed(Self.conflict)
        let reported = failure.text
        // Combine couldn't publish: nothing published, the conflict (L4) stays.
        failure.libraryReplaced(published: false, libraryState: .conflict, editsWaiting: false)
        // A regrant that didn't take (L3), a failed Use That Library (still ready).
        failure.libraryReplaced(published: false, libraryState: .needsPermission(pendingChanges: 1), editsWaiting: true)
        failure.libraryReplaced(published: false, libraryState: .ready, editsWaiting: false)
        #expect(failure.text == reported)
    }

    /// Try Again whose replay is refused: the journal is kept and the state can read ready; the failure stays.
    @Test func tryAgainWithARefusedReplayKeepsTheWriteFailure() {
        var failure = LibraryFailureMessage()
        failure.writeFailed(Self.conflict)
        let refused = PendingEditsOutcome.refused(.readOnly("The library can't be changed right now."))
        #expect(!LibraryFailureMessage.published(refused))
        failure.libraryReplaced(published: LibraryFailureMessage.published(refused), libraryState: .ready, editsWaiting: true)
        #expect(failure.text != nil)
        // Even a published replay leaves it while edits are still waiting.
        failure.libraryReplaced(published: true, libraryState: .ready, editsWaiting: true)
        #expect(failure.text != nil)
        #expect(LibraryFailureMessage.published(PendingEditsOutcome.alreadyIncluded))
        #expect(!LibraryFailureMessage.published(PendingEditsOutcome.stillWaiting(reason: "away")))
        #expect(!LibraryFailureMessage.published(LibraryRegrantOutcome.cannotVerify(reason: "no permission")))
    }

    @Test func aReadFailureLastsUntilTheLibraryLoadsOrItIsDismissed() {
        var failure = LibraryFailureMessage()
        failure.readFailed("The file couldn't be opened")
        #expect(failure.text == "Couldn't read the library: The file couldn't be opened. Your shows aren't affected, and the library won't be changed until it can be read.")
        failure.libraryLoaded()
        #expect(failure.text == nil)
        failure.writeFailed("Disk full..")
        #expect(failure.text == "Couldn't update the library: Disk full. Your shows aren't affected.")
        failure.dismiss()
        #expect(failure.text == nil)
    }
}
