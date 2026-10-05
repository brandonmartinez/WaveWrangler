import Testing
@testable import WWOrganizer

@Suite("Library load wording")
struct LibraryLoadWordingTests {
    @Test func unreachableStatesOnlyTheReason() {
        let text = LibraryLoadWording.unreachable("the folder is offline")
        #expect(text == "WaveWrangler can't reach your library folder (the folder is offline)")
        // L2/L3 queue edits: no read-only, copy or internal-term claims.
        for word in ["read-only", "copy", "revision", "checkpoint"] {
            #expect(!text.localizedCaseInsensitiveContains(word), "\(word)")
        }
    }

    @Test func otherReasons() {
        #expect(LibraryLoadWording.damaged("bad checksum") == "the library is damaged (bad checksum)")
        #expect(LibraryLoadWording.newerFormat.contains("newer version of WaveWrangler"))
    }
}
