import Testing
@testable import WWOrganizer

@Suite("Library Grant Access… outcomes")
struct LibraryRegrantTests {
    @Test func regrantedSaysAccessGrantedWithoutClaimingIdentity() throws {
        let plain = try #require(LibraryRegrantWording.message(for: .regranted(pendingEditsSaved: false)))
        #expect(plain == "Access granted to the library folder.")
        #expect(!plain.localizedCaseInsensitiveContains("same library"))
        #expect(!plain.localizedCaseInsensitiveContains("verified"))
        #expect(LibraryRegrantWording.message(for: .regranted(pendingEditsSaved: true))?.hasSuffix("Your waiting library changes were saved.") == true)
        #expect(LibraryRegrantWording.followUp(for: .regranted(pendingEditsSaved: false)) == LibraryActionFollowUp.none)
    }

    @Test func differentLibraryOffersChoicesAndChangesNothing() {
        let result = LibraryRegrantResult.differentLibrary(folderDisplayName: "Podcasts")
        #expect(LibraryRegrantWording.message(for: result) == nil)
        #expect(LibraryRegrantWording.followUp(for: result) == .offerDifferentLibrary(folderDisplayName: "Podcasts"))
        let sheet = LibraryRegrantWording.differentLibrarySheet(folderDisplayName: "Podcasts")
        #expect(sheet.title == "“Podcasts” has a different WaveWrangler library")
        #expect(sheet.text.contains("nothing was changed"))
    }

    @Test func noLibraryAndCannotVerifyGiveHonestReasons() {
        #expect(LibraryRegrantWording.message(for: .noLibraryThere(folderDisplayName: "Empty")) == "There's no WaveWrangler library in “Empty”, so nothing was changed. Choose the folder that holds your library.")
        #expect(LibraryRegrantWording.message(for: .cannotVerify(reason: "the folder is offline.")) == "WaveWrangler can't use the library in that folder: the folder is offline. Nothing was changed.")
        #expect(LibraryRegrantWording.followUp(for: .cannotVerify(reason: "x")) == LibraryActionFollowUp.none)
    }
}
