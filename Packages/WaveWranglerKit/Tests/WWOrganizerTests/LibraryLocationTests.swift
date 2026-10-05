import Foundation
import Testing
import WWCore
@testable import WWOrganizer

@Suite("Library location and combine (ST-33–ST-36)")
struct LibraryLocationTests {
    @Test func defaultLocationAndCaptions() {
        #expect(LibraryLocationChoice.default == .inWaveWrangler)
        #expect(LibraryLocationChoice.inWaveWrangler.title == "In WaveWrangler")
        #expect(LibraryLocationChoice.inWaveWrangler.caption == "Your library (collections, recent items and unavailable shows) is stored inside WaveWrangler on this Mac. Your shows stay wherever you saved them.")
        #expect(LibraryLocationChoice.folder(displayName: "Podcasts").caption.hasPrefix("Your library is stored in “Podcasts”."))
        #expect(LibraryLocationChoice.folder(displayName: "Podcasts").moveConfirmation.message == "Move your library to “Podcasts”?")
        #expect(LibraryLocationChoice.inWaveWrangler.moveConfirmation.message == "Move your library back into WaveWrangler?")
        #expect(LibraryMovePhase.checking.text == "Moving library — checking copy…")
    }

    @Test func libraryLevelStatesWordingAndEditability() {
        #expect(LibraryLevelPresentation(.ready) == nil)
        let unreachable = LibraryLevelPresentation(.unreachable(folderDisplayName: "Cloud", pendingChanges: 2))
        #expect(unreachable?.heading == "Can't reach your library")
        #expect(unreachable?.pendingText == "2 library changes not saved yet")
        #expect(unreachable?.actions == [.tryAgain, .librarySettings])
        #expect(LibraryLevelPresentation(.needsPermission(pendingChanges: 0))?.heading == "WaveWrangler needs permission to use your library folder")
        #expect(LibraryLevelPresentation(.conflict)?.actions.first == .combine)
        #expect(LibraryLevelPresentation(.newerFormat(folderDisplayName: "Cloud"))?.heading == "Your library needs a newer WaveWrangler")
        #expect(LibraryLevelState.conflict.allowsEdits == false)
        let hidden = LibraryLevelPresentation(.newerFormatNotViewable(folderDisplayName: "Cloud"))
        #expect(hidden?.body.contains("can't show or change it") == true)
        #expect(hidden?.body.contains("You can see it") == false)
        #expect(LibraryLevelState.newerFormatNotViewable(folderDisplayName: "x").allowsEdits == false)
        #expect(LibraryLevelState.newerFormat(folderDisplayName: "x").allowsEdits == false)
        #expect(LibraryLevelState.unreachable(folderDisplayName: "x", pendingChanges: 1).allowsEdits)
        #expect(LibraryLevelPresentation.quitWarning(pendingChanges: 0) == nil)
        #expect(LibraryLevelPresentation.quitWarning(pendingChanges: 3)?.message == "WaveWrangler couldn't save 3 library changes.")
        #expect(LibraryMoveWording.existingLibraryBlockedReason(.newerFormat(folderDisplayName: "x"))?.contains("can't add to it") == true)
        #expect(LibraryMoveWording.existingLibraryBlockedReason(.ready) == nil)
    }

    @Test func identityCollisionIsVisibleAndNeedsAttention() {
        let presentation = LibraryEntryStatePresentation(.identityCollision(otherLocationDisplayName: "Desktop"), showName: "S")
        #expect(presentation.statusText == "Same show in two files")
        #expect(presentation.needsAttention)
        #expect(presentation.explanation?.contains("hasn't merged or removed either") == true)
    }

    @Test func combineKeepsEverythingAndSuffixesDifferingCollections() throws {
        let shared = ShowID(), baseOnly = ShowID(), macOnly = ShowID(), other = ShowID()
        let entries = [shared, baseOnly, macOnly, other].map { LibraryShowEntry(showID: $0, lastKnownTitle: "\($0)") }
        let base = LibraryModel(
            entries: [entries[0], entries[1], entries[3]],
            collections: [
                LibraryCollection(name: "Same", showIDs: [shared, baseOnly]),
                LibraryCollection(name: "Order", showIDs: [shared, other]),
                LibraryCollection(name: "Members", showIDs: [shared]),
                LibraryCollection(name: "Members (from this Mac)", showIDs: [other]),
            ],
            recentShowIDs: [baseOnly, shared]
        )
        var unavailableShared = entries[0]
        unavailableShared.unavailable = UnavailableRecord(note: "Not found", recordedAt: Date())
        let mac = LibraryModel(
            entries: [unavailableShared, entries[2]],
            collections: [
                LibraryCollection(name: "Same", showIDs: [shared, baseOnly]),
                LibraryCollection(name: "Order", showIDs: [other, shared]),
                LibraryCollection(name: "Members", showIDs: [shared, macOnly]),
                LibraryCollection(name: "Only Here", showIDs: [macOnly]),
            ],
            recentShowIDs: [macOnly, shared]
        )
        let now = Date()
        let (combined, summary) = base.combining(thisMac: mac, lastOpened: [macOnly: now, baseOnly: now.addingTimeInterval(-60)])
        #expect(Set(combined.entries.map(\.showID)) == [shared, baseOnly, macOnly, other])
        #expect(combined.collections.map(\.name) == [
            "Same", "Order", "Members", "Members (from this Mac)",
            "Order (from this Mac)", "Members (from this Mac 2)", "Only Here",
        ])
        #expect(combined.collections.first { $0.name == "Order" }?.showIDs == [shared, other])
        #expect(combined.collections.first { $0.name == "Order (from this Mac)" }?.showIDs == [other, shared])
        #expect(Set(combined.collections.map(\.id)).count == combined.collections.count)
        #expect(combined.recentShowIDs == [macOnly, baseOnly, shared])
        #expect(summary == LibraryCombineSummary(collectionsKeptAsSeparateCopies: 2, showsAdded: 1, recentItemsAdded: 1))
        #expect(summary.message == "Combined libraries: 2 collections kept as separate copies, 1 shows and 1 recent items added.")
    }

    @Test func combiningIdenticalLibrariesChangesNothing() {
        let fixture = SyntheticLibraryFixture.make(shows: 20, sourceReferences: 100)
        let (combined, summary) = fixture.library.combining(thisMac: fixture.library)
        #expect(combined == fixture.library)
        #expect(summary == LibraryCombineSummary(collectionsKeptAsSeparateCopies: 0, showsAdded: 0, recentItemsAdded: 0))
    }
}
