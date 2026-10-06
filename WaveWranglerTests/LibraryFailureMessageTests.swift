import Testing
import WWOrganizer

/// ST-32 message lifecycle (#199): a library replacement clears a write failure that no longer describes the library.
@Suite("Library failure message")
struct LibraryFailureMessageTests {
    @Test func aReplacementClearsTheObsoleteWriteFailure() {
        var failure = LibraryFailureMessage()
        failure.writeFailed("Another version of this document is on disk. Your changes were not saved over it.")
        #expect(failure.text == "Couldn't update the library: Another version of this document is on disk. Your changes were not saved over it. Your shows aren't affected.")
        failure.libraryReplaced(succeeded: true, libraryState: .ready)
        #expect(failure.text == nil, "Combine (or another replacement) saved the change: the failure is obsolete")
    }

    @Test func aFailedReplacementKeepsTheWriteFailure() {
        var failure = LibraryFailureMessage()
        failure.writeFailed("Another version of this document is on disk.")
        let reported = failure.text
        // Combine couldn't publish: the conflict (L4) stays, and so does the failure.
        failure.libraryReplaced(succeeded: true, libraryState: .conflict)
        #expect(failure.text == reported)
        // A regrant that didn't take (L3), a Try Again with the folder still away (L2), a failed Use That Library.
        failure.libraryReplaced(succeeded: true, libraryState: .needsPermission(pendingChanges: 1))
        failure.libraryReplaced(succeeded: true, libraryState: .unreachable(folderDisplayName: "Library", pendingChanges: 1))
        failure.libraryReplaced(succeeded: false, libraryState: .ready)
        #expect(failure.text == reported)
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
