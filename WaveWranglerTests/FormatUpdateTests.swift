import Foundation
import Testing
import WWOrganizer
import WWPersistence

/// #159 (D14/D15): an older-format show is read-only until its update has published; nothing writes its file or adopts
/// another one before then, and the failure bar only claims "The original is unchanged" when the bytes on disk are
/// exactly the original. The ShowDocument wiring itself is exercised by `FormatUpdateUITests` (GUI lane).
@MainActor
@Suite("Format update (#159)", .timeLimit(.minutes(1)))
struct FormatUpdateTests {
    private static let awaiting: [FormatUpdateState] = [
        .needed, .updating, .failed(detail: "x"), .interrupted(reason: "y"),
    ]

    @Test func editsAreRefusedUntilTheUpdatePublishes() {
        #expect(FormatUpdatePolicy.allowsEdits(nil))
        for state in Self.awaiting {
            #expect(!FormatUpdatePolicy.allowsEdits(state), "\(state)")
        }
    }

    @Test func savesToTheShowOrAdoptingAnotherFileAreRefusedWhileAwaiting() {
        for state in Self.awaiting {
            // Save, autosave in place: the show's own file.
            #expect(!FormatUpdatePolicy.allowsSave(state, adoptsPublication: true, toOwnFile: true), "\(state)")
            // Save As: another file would become this document's revision.
            #expect(!FormatUpdatePolicy.allowsSave(state, adoptsPublication: true, toOwnFile: false), "\(state)")
            // Any non-adopting write that still targets the show's file.
            #expect(!FormatUpdatePolicy.allowsSave(state, adoptsPublication: false, toOwnFile: true), "\(state)")
            // Duplicate / Save To elsewhere: a separate current-format file; the original isn't touched.
            #expect(FormatUpdatePolicy.allowsSave(state, adoptsPublication: false, toOwnFile: false), "\(state)")
        }
        for adopts in [true, false] {
            for own in [true, false] {
                #expect(FormatUpdatePolicy.allowsSave(nil, adoptsPublication: adopts, toOwnFile: own))
            }
        }
    }

    @Test func onlyAWaitingOrFailedUpdateCanStartAnAttempt() {
        #expect(FormatUpdatePolicy.allowsUpdateAttempt(.needed))
        #expect(FormatUpdatePolicy.allowsUpdateAttempt(.failed(detail: "x")))
        #expect(!FormatUpdatePolicy.allowsUpdateAttempt(.updating))
        #expect(!FormatUpdatePolicy.allowsUpdateAttempt(.interrupted(reason: "y")))
        #expect(!FormatUpdatePolicy.allowsUpdateAttempt(nil))
    }

    @Test func outcomeIsDecidedFromWhatIsOnDisk() {
        let original = Data("v1".utf8)
        let updated = Data("v2".utf8)
        #expect(FormatUpdateOutcome.classify(errorDetail: nil, original: original, onDiskNow: updated,
                                             onDiskIsCurrentFormatOfThisShow: true) == .updated)
        // Published, then something after publication failed: still adopted (never re-migrated or misreported).
        #expect(FormatUpdateOutcome.classify(errorDetail: "late", original: original, onDiskNow: updated,
                                             onDiskIsCurrentFormatOfThisShow: true) == .updated)
        #expect(FormatUpdateOutcome.classify(errorDetail: "simulated", original: original, onDiskNow: original,
                                             onDiskIsCurrentFormatOfThisShow: false) == .unchanged(detail: "simulated"))
        // No error yet the original is still there (e.g. cancelled): D15 with a generic reason.
        guard case .unchanged = FormatUpdateOutcome.classify(errorDetail: nil, original: original, onDiskNow: original,
                                                             onDiskIsCurrentFormatOfThisShow: false) else {
            Issue.record("expected unchanged")
            return
        }
        // Different bytes that aren't a valid update of this show, or an unreadable file: never "unchanged".
        #expect(FormatUpdateOutcome.classify(errorDetail: "x", original: original, onDiskNow: Data("other".utf8),
                                             onDiskIsCurrentFormatOfThisShow: false) == .changedElsewhere)
        #expect(FormatUpdateOutcome.classify(errorDetail: "x", original: original, onDiskNow: nil,
                                             onDiskIsCurrentFormatOfThisShow: false) == .changedElsewhere)
    }

    @Test func statusMapsToD14D15AndOverridesThePersistenceState() {
        func map(_ update: FormatUpdateState?, _ state: WWPersistence.DocumentSaveState = .clean(revision: 1)) -> WWOrganizer.DocumentSaveStatus {
            ShowDocumentStatusMapping.map(state, readOnlyReason: nil, autosaveEnabled: true, folderDisplayName: "Shows",
                                          formatUpdate: update)
        }
        #expect(map(.needed).state == .updateNeeded)
        #expect(map(.updating).state == .updateNeeded)
        #expect(map(.failed(detail: "x")).state == .updateFailed)
        #expect(map(.interrupted(reason: "it changed")).state == .readOnly(reason: "it changed"))
        for update in Self.awaiting {
            #expect(map(update).state.isReadOnly, "\(update)")
            #expect(!map(update, .edited(autosaveEnabled: true)).hasUnsavedChanges, "\(update)")
        }
        #expect(!map(nil).state.isReadOnly)
        #expect(map(nil, .edited(autosaveEnabled: true)).hasUnsavedChanges)

        let failed = SaveStatusPresentation(map(.failed(detail: "x")), showName: "S", formatTime: { _ in "" })
        #expect(failed.messageBar?.heading == "Couldn't update this show")
        #expect(failed.messageBar?.body.contains("The original is unchanged") == true)
        #expect(failed.messageBar?.actions == [.tryAgain, .showDetails])
    }

    @Test func promptOffersUpdateByDefaultThenReadOnlyThenCancel() {
        let prompt = FormatUpdatePrompt(showName: "Episode 12")
        #expect(prompt.title == "Update “Episode 12” to the current format?")
        #expect(prompt.buttons == [.update, .openReadOnly, .cancel])
    }

    @Test func promptWaitsForAWindowTheUserCanSee() {
        let front = FormatUpdatePromptWindow(isVisible: true, isMiniaturized: false, isSelectedTab: true)
        #expect(FormatUpdatePolicy.shouldPresentPrompt(pending: true, state: .needed, window: front))
        // Not shown (and so not consumed) for a background tab, a minimized window, a hidden window or no window:
        // the document keeps it pending and asks again when one of its windows becomes key or is shown.
        var backgroundTab = front
        backgroundTab.isSelectedTab = false
        var minimized = front
        minimized.isMiniaturized = true
        var hidden = front
        hidden.isVisible = false
        for window in [backgroundTab, minimized, hidden] {
            #expect(!window.canShowPrompt)
            #expect(!FormatUpdatePolicy.shouldPresentPrompt(pending: true, state: .needed, window: window))
        }
        #expect(!FormatUpdatePolicy.shouldPresentPrompt(pending: true, state: .needed, window: nil))
        // Asked once: never again after it was shown (Open Read-Only), and never once the update has started or ended.
        #expect(!FormatUpdatePolicy.shouldPresentPrompt(pending: false, state: .needed, window: front))
        for state: FormatUpdateState? in [.updating, .failed(detail: "x"), .interrupted(reason: "y"), nil] {
            #expect(!FormatUpdatePolicy.shouldPresentPrompt(pending: true, state: state, window: front))
        }
    }
}
