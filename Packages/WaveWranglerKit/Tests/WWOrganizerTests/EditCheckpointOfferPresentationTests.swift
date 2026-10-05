import Foundation
import Testing
@testable import WWOrganizer

/// C2b recovery offer wording, actions and confirmations (contracts C2b; #84).
@Suite("Edit-checkpoint offer presentation")
struct EditCheckpointOfferPresentationTests {
    let time: (Date) -> String = { _ in "10:42 PM" }
    let date = Date(timeIntervalSince1970: 1_000)

    @Test func restoreBasedOnCurrent() {
        let p = EditCheckpointOfferPresentation(.restore(createdAt: date), showName: "The Daily Wrangle", formatTime: time)
        #expect(p.heading == "Restore unsaved changes from 10:42 PM?")
        #expect(p.body.contains("“The Daily Wrangle”") && p.body.contains("never saved") && p.body.contains("unsaved changes"))
        #expect(!p.body.localizedCaseInsensitiveContains("saved to"))
        #expect(p.actions == [.restore, .discard])
        #expect(p.announcement == p.heading && p.accessibilityValue == p.body)
        #expect(EditCheckpointAction.restore.rawValue == "Restore Unsaved Changes")
    }

    @Test func olderRevisionOpensOnlyAsCopy() {
        let p = EditCheckpointOfferPresentation(.olderRevision(createdAt: date), showName: "Show", formatTime: time)
        #expect(p.heading == "Unsaved changes based on an older revision")
        #expect(p.body.contains("10:42 PM") && p.body.contains("separate untitled copy"))
        #expect(p.actions == [.openAsCopy, .discard])
        #expect(!p.actions.contains(.restore))
    }

    @Test func unusableRecordsAreReportedNotApplied() {
        let damaged = EditCheckpointOfferPresentation(.unusable(damaged: 1, newerFormat: 0), showName: "Show")
        let newer = EditCheckpointOfferPresentation(.unusable(damaged: 0, newerFormat: 2), showName: "Show")
        let both = EditCheckpointOfferPresentation(.unusable(damaged: 1, newerFormat: 1), showName: "Show")
        #expect(damaged.heading == "Unsaved changes couldn't be restored")
        #expect(damaged.body.contains("couldn't be read") && damaged.body.contains("weren't applied") && damaged.body.contains("kept"))
        #expect(newer.body.contains("newer version of WaveWrangler"))
        #expect(both.body.contains("couldn't be read") && both.body.contains("newer version"))
        for p in [damaged, newer, both] {
            #expect(p.actions == [.showInFinder, .dismiss])
            #expect(!p.actions.contains(.restore) && !p.actions.contains(.openAsCopy) && !p.actions.contains(.discard))
        }
    }

    @Test func discardAndDismissRequireConfirmationOthersDoNot() {
        let discard = EditCheckpointOfferPresentation.confirmation(for: .discard, state: .restore(createdAt: date), formatTime: time)
        #expect(discard?.message == "Discard unsaved changes from 10:42 PM?")
        #expect(discard?.button == "Discard" && discard?.informative.contains("can't be restored") == true)
        #expect(EditCheckpointOfferPresentation.confirmation(for: .discard, state: .olderRevision(createdAt: date), formatTime: time) != nil)
        let dismiss = EditCheckpointOfferPresentation.confirmation(for: .dismiss, state: .unusable(damaged: 1, newerFormat: 0))
        #expect(dismiss?.button == "Hide" && dismiss?.informative.contains("stay on this Mac") == true)
        for action in [EditCheckpointAction.restore, .openAsCopy, .showInFinder] {
            #expect(EditCheckpointOfferPresentation.confirmation(for: action, state: .restore(createdAt: date)) == nil)
        }
    }

    @Test func symbolsAreCatalogued() {
        for state in [EditCheckpointOfferState.restore(createdAt: date), .olderRevision(createdAt: date), .unusable(damaged: 1, newerFormat: 0)] {
            #expect(SymbolCatalog.all.contains(EditCheckpointOfferPresentation(state, showName: "x").symbolName))
        }
    }
}
