import Testing
@testable import WWOrganizer

@Suite("Library load wording")
struct LibraryLoadWordingTests {
    @Test func unavailableShowingPriorSaysReadOnlyLastSavedCopyWithoutInternalTerms() {
        let text = LibraryLoadWording.unavailableShowingPrior("the folder is offline")
        #expect(text == "WaveWrangler can't reach your library folder (the folder is offline), so it's showing the last saved copy, read-only")
        #expect(!text.localizedCaseInsensitiveContains("revision"))
        #expect(!text.localizedCaseInsensitiveContains("checkpoint"))
    }

    @Test func otherReasons() {
        #expect(LibraryLoadWording.damaged("bad checksum") == "the library is damaged (bad checksum)")
        #expect(LibraryLoadWording.newerFormat.contains("newer version of WaveWrangler"))
    }
}
