import AppKit
import Foundation
import Testing
import WWCore
@testable import WWOrganizer

@Suite("Preferences and text size")
struct PreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ww-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshPreferencesUseProductDefaults() {
        let preferences = AppPreferences(defaults: freshDefaults())
        #expect(preferences.autosaveEnabled == true)
        #expect(preferences.downloadSourcesAutomatically == true)
        #expect(preferences.textSize == .actual)
        #expect(preferences.textSize.percent == 100)
    }

    @Test func preferencesRoundTripThroughDocumentedKeys() {
        let defaults = freshDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.autosaveEnabled = false
        preferences.downloadSourcesAutomatically = false
        preferences.textSize = TextSize(storedPercent: 175)
        #expect(defaults.bool(forKey: "WWAutosaveEnabled") == false)
        #expect(defaults.object(forKey: "WWDownloadSourcesAutomatically") as? Bool == false)
        #expect(defaults.integer(forKey: "WWTextSizePercent") == 175)
        #expect(AppPreferences.registrationDefaults["WWAutosaveEnabled"] as? Bool == true)
        #expect(AppPreferences.registrationDefaults["WWDownloadSourcesAutomatically"] as? Bool == true)
    }

    @Test func textSizeStepsFrom100To200In25PercentSteps() {
        #expect(TextSize.all.map(\.percent) == [100, 125, 150, 175, 200])
        #expect(TextSize.actual.smaller == nil)
        #expect(TextSize(storedPercent: 200).bigger == nil)
        #expect(TextSize.actual.bigger?.percent == 125)
        #expect(TextSize(storedPercent: 160).percent == 150)
        #expect(TextSize(storedPercent: 9_999).percent == 200)
        #expect(TextSize(storedPercent: 200).pointSize(forBase: 13) == 26)
    }

    @Test func settingsCaptionsMatchSpecification() {
        #expect(SettingsWording.autosaveCaption(enabled: true) == "WaveWrangler saves your changes as you work. You can also choose File › Save at any time.")
        #expect(SettingsWording.downloadCaption(enabled: false).hasPrefix("WaveWrangler uses only file names and file details."))
    }
}

@Suite("Save status presentation")
struct SaveStatusTests {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static let allStates: [DocumentSaveState] = [
        .checking, .unknown(reason: "save confirmation isn't available"), .saved(at: date, folderDisplayName: "Podcasts"),
        .edited, .saving(cancellable: false), .notConfirmed, .conflict(changedAt: nil), .locationUnavailable,
        .diskFull(volumeName: "Data"), .failed(reason: "WaveWrangler doesn't have permission to save in this folder"),
        .cancelled, .recovered(incompleteSaveAt: date, openedVersionAt: date), .readOnlyNewerFormat, .readOnlyDamaged,
        .updateNeeded, .updatingFormat, .updateFailed, .readOnlyLocation, .readOnly(reason: "it's a recovered copy"),
    ]

    private func present(_ state: DocumentSaveState, autosave: Bool = true, retrying: Bool = false) -> SaveStatusPresentation {
        SaveStatusPresentation(
            DocumentSaveStatus(state: state, autosaveEnabled: autosave, retryingAutomatically: retrying),
            showName: "The Daily Wrangle",
            formatTime: { _ in "10:42 PM" }
        )
    }

    @Test func onlyCoherentSaveSaysSaved() {
        for state in Self.allStates {
            for autosave in [true, false] {
                let presentation = present(state, autosave: autosave)
                let saysSaved = presentation.itemText == "Saved" || presentation.accessibilityValue.hasPrefix("Saved")
                #expect(saysSaved == state.isCoherentlySaved, "\(state)")
            }
        }
    }

    @Test func onlyD1ClearsDirtyAndEditedSuffix() {
        for state in [DocumentSaveState.edited, .saving(cancellable: true), .notConfirmed, .conflict(changedAt: nil),
                      .locationUnavailable, .diskFull(volumeName: "Data"), .failed(reason: "x"), .cancelled] {
            let presentation = present(state)
            #expect(presentation.showsEditedSuffix, "\(state)")
            #expect(DocumentSaveStatus(state: state, autosaveEnabled: true).hasUnsavedChanges, "\(state)")
        }
        let saved = present(.saved(at: Self.date, folderDisplayName: nil))
        #expect(!saved.showsEditedSuffix)
        #expect(!saved.showsDirtyDot)
    }

    @Test func savedWithoutKnownTimeAndGenericReadOnly() {
        let saved = present(.saved(at: nil, folderDisplayName: "Podcasts"))
        #expect(saved.popoverText.hasPrefix("Saved to “The Daily Wrangle” in Podcasts."))
        let readOnly = present(.readOnly(reason: "it's a recovered copy"))
        #expect(readOnly.isReadOnly)
        #expect(readOnly.messageBar?.heading == "This show is read-only")
    }

    @Test func dirtyDotOnlyWithAutosaveOff() {
        #expect(present(.edited, autosave: true).showsDirtyDot == false)
        #expect(present(.edited, autosave: false).showsDirtyDot == true)
        #expect(present(.edited, autosave: true).itemText == "Edited")
        #expect(present(.edited, autosave: false).itemText == "Not saved")
    }

    @Test func exactWordingForKeyStates() {
        let saved = present(.saved(at: Self.date, folderDisplayName: "Podcasts"))
        #expect(saved.popoverText == "Saved at 10:42 PM to “The Daily Wrangle” in Podcasts. WaveWrangler saved this Mac's copy. If this folder syncs, your cloud service uploads it separately.")
        #expect(saved.symbolName == "checkmark.circle")

        let notConfirmed = present(.notConfirmed)
        #expect(notConfirmed.itemText == "Not confirmed")
        #expect(notConfirmed.accessibilityValue == "Not confirmed. WaveWrangler wrote your changes but couldn't confirm the saved show is complete.")

        let conflict = present(.conflict(changedAt: nil))
        #expect(conflict.itemText == "Conflict")
        #expect(conflict.symbolName == "arrow.triangle.branch")
        #expect(conflict.actions == [.resolve])

        let newer = present(.readOnlyNewerFormat)
        #expect(newer.messageBar?.heading == "This show needs a newer WaveWrangler")
        #expect(newer.isReadOnly)
        #expect(DocumentSaveState.readOnlyNewerFormat.allowsDuplicateOrSaveAs == false)

        let offline = present(.locationUnavailable, retrying: true)
        #expect(offline.itemText == "Can't reach")
        #expect(offline.popoverText.hasSuffix("WaveWrangler will try again automatically."))
        #expect(present(.saving(cancellable: false)).symbolName == nil)
        #expect(present(.saving(cancellable: false)).itemText == "Saving…")
    }

    @Test func everyStateHasTextAndNeverSaysOffline() {
        for state in Self.allStates {
            let presentation = present(state)
            #expect(!presentation.itemText.isEmpty)
            #expect(!presentation.popoverText.isEmpty)
            #expect(presentation.accessibilityValue.hasPrefix(presentation.itemText))
            #expect(!presentation.itemText.localizedCaseInsensitiveContains("offline"))
        }
    }

    @Test func firstSentenceIgnoresPeriodsInsideQuotes() {
        #expect(SaveStatusPresentation.firstSentence(of: "Saved to “A.B”. Next.") == "Saved to “A.B”.")
    }

    @Test func announcementsOnlyForExplicitSaveFirstFailureAndRetrySuccess() {
        let saved = DocumentSaveState.saved(at: Self.date, folderDisplayName: nil)
        #expect(SaveStatusPresentation.announcement(from: .saving(cancellable: false), to: saved, showName: "S", explicitSave: false) == nil)
        #expect(SaveStatusPresentation.announcement(from: .saving(cancellable: false), to: saved, showName: "S", explicitSave: true) == "Saved")
        #expect(SaveStatusPresentation.announcement(from: .edited, to: .locationUnavailable, showName: "S", explicitSave: false) == "Couldn't save “S”. The folder can't be reached.")
        #expect(SaveStatusPresentation.announcement(from: .locationUnavailable, to: .locationUnavailable, showName: "S", explicitSave: false) == nil)
        #expect(SaveStatusPresentation.announcement(from: .locationUnavailable, to: saved, showName: "S", explicitSave: false) == "Saved")
        #expect(SaveStatusPresentation.announcement(from: .edited, to: .conflict(changedAt: nil), showName: "S", explicitSave: false) == "“S” was changed somewhere else. Your changes are kept.")
        #expect(SaveStatusPresentation.announcement(from: nil, to: .readOnlyNewerFormat, showName: "S", explicitSave: false) == "This show needs a newer WaveWrangler")
    }

    @Test func locationUnavailableWordingDependsOnAutosave() {
        #expect(present(.locationUnavailable, autosave: true, retrying: true).popoverText.hasSuffix("WaveWrangler will try again automatically."))
        // The promise is made only while a retry is really pending (#157 review).
        #expect(present(.locationUnavailable, autosave: true).popoverText.hasSuffix("Choose Try Again when the folder is available."))
        let off = present(.locationUnavailable, autosave: false)
        #expect(off.popoverText.hasSuffix("Choose Try Again when the folder is available."))
        #expect(off.showsDirtyDot)
        #expect(off.accessibilityValue == "Can't reach. WaveWrangler can't reach the folder where this show is saved.")
        #expect(SaveStatusPresentation.copyMessage(copyName: "S copy", folder: "Desk", originalFolder: "Cloud") == "You're now editing “S copy” in Desk. The original at Cloud wasn't changed.")
        #expect(SaveStatusPresentation.copyName(for: "S") == "S copy")
    }

    @Test func closeDecisionsFollowStateTable() {
        #expect(CloseDecision(state: .saved(at: Self.date, folderDisplayName: nil), autosaveEnabled: true, showName: "S") == .closeImmediately)
        #expect(CloseDecision(state: .edited, autosaveEnabled: true, showName: "S") == .saveFirst)
        #expect(CloseDecision(state: .saving(cancellable: true), autosaveEnabled: false, showName: "S") == .waitForSave)
        guard case .sheet(let plain) = CloseDecision(state: .edited, autosaveEnabled: false, showName: "S") else { Issue.record("expected sheet"); return }
        #expect(plain.message == "Do you want to save the changes you made to “S”?")
        #expect(plain.buttons == [.save, .cancel, .dontSave])
        guard case .sheet(let failed) = CloseDecision(state: .locationUnavailable, autosaveEnabled: true, showName: "S") else { Issue.record("expected sheet"); return }
        #expect(failed.message == "“S” couldn't be saved: the folder can't be reached.")
        #expect(failed.buttons.first == .saveACopyElsewhere)
        guard case .sheet(let conflict) = CloseDecision(state: .conflict(changedAt: nil), autosaveEnabled: true, showName: "S") else { Issue.record("expected sheet"); return }
        #expect(!conflict.buttons.contains(.save))
        #expect(conflict.buttons.first == .saveMineAsACopy)
    }
}

@Suite("Destinations")
struct DestinationTests {
    @Test func setupAndAlignmentAreAvailableAndLaterOnesExplainWhy() {
        #expect(ShowDestination.allCases.map(\.title) == ["Setup", "Alignment", "Review", "Export"])
        #expect(ShowDestination.setup.blockedPanel == nil)
        #expect(ShowDestination.alignment.blockedPanel == nil)
        #expect(ShowDestination.alignment.isAvailableInThisVersion)
        #expect(ShowDestination.alignment.helpText == "Inspect and correct recorder alignment")
        #expect(ShowDestination.export.blockedPanel?.body.hasSuffix("Nothing has been exported.") == true)
        for destination in [ShowDestination.review, .export] {
            #expect(destination.unavailableValue == "Not available in this version")
            #expect(destination.blockedPanel?.buttonTitle == "Go to Setup")
        }
    }
}

@Suite("Symbols and menu register")
struct SymbolAndMenuTests {
    @Test @MainActor func everyCatalogSymbolResolves() {
        for name in SymbolCatalog.all.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func shortcutsAreUniqueAndCustomRegisterMatchesSpecification() {
        let shortcuts = MenuCommand.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        let register = Dictionary(uniqueKeysWithValues: MenuCommand.customRegister.map { ($0, $0.shortcut.description) })
        #expect(register == [
            .newEpisode: "⇧⌘N", .importSources: "⇧⌘I", .saveAs: "⌥⇧⌘S", .library: "⇧⌘L",
            .destinationSetup: "⌘1", .destinationAlignment: "⌘2", .destinationReview: "⌘3", .destinationExport: "⌘4",
            .moveUp: "⌥⌘↑", .moveDown: "⌥⌘↓", .textBigger: "⌘+", .textSmaller: "⌘-", .textActual: "⌘0", .episodeInfo: "⌘I",
            .auditionSelection: "⌘⏎", .stopAudition: "Esc",
        ])
        #expect(MenuCommand.duplicate.shortcut.description == "⇧⌘S")
        #expect(MenuCommand.toggleInspector.shortcut.description == "⌃⌘I")
    }
}

/// WW-009 C4 / #117: provider conflict versions of a show are evidence only, but always visible.
@Suite("Provider conflict versions in show status")
struct ProviderConflictStatusTests {
    @Test func countReachesPopoverAndVoiceOverValueInEveryState() {
        let date = Date(timeIntervalSince1970: 0)
        for state in [DocumentSaveState.saved(at: date, folderDisplayName: "Shows"), .edited, .conflict(changedAt: nil), .readOnlyNewerFormat] {
            let one = SaveStatusPresentation(DocumentSaveStatus(state: state, autosaveEnabled: true, providerConflictVersions: 1), showName: "Show")
            #expect(one.popoverText.hasSuffix("Your cloud service also kept 1 other version of this show from another Mac or app. WaveWrangler hasn't changed or removed it."))
            #expect(one.accessibilityValue.contains("kept 1 other version"))
            let two = SaveStatusPresentation(DocumentSaveStatus(state: state, autosaveEnabled: true, providerConflictVersions: 2), showName: "Show")
            #expect(two.accessibilityValue.contains("kept 2 other versions") && two.accessibilityValue.contains("removed them"))
            let none = SaveStatusPresentation(DocumentSaveStatus(state: state, autosaveEnabled: true), showName: "Show")
            #expect(!none.popoverText.contains("cloud service also kept") && !none.accessibilityValue.contains("other version"))
        }
    }
}

@Suite("Format update prompt (D14/D15, #159)")
struct FormatUpdatePromptTests {
    @Test func promptWordingAndButtonOrder() {
        let prompt = FormatUpdatePrompt(showName: "The Daily Wrangle")
        #expect(prompt.title == "Update “The Daily Wrangle” to the current format?")
        #expect(prompt.buttons == [.update, .openReadOnly, .cancel])
        #expect(prompt.buttons.map(\.rawValue) == ["Update", "Open Read-Only", "Cancel"])
        // The C5 backup is in this Mac's recovery store: never claim it's next to the show.
        #expect(prompt.body.contains("backup on this Mac") && !prompt.body.contains("next to it"))
    }

    @Test func updateNeededAndFailedAreReadOnlyAndHonest() {
        let needed = SaveStatusPresentation(DocumentSaveStatus(state: .updateNeeded, autosaveEnabled: true), showName: "Show")
        #expect(DocumentSaveState.updateNeeded.isReadOnly && DocumentSaveState.updateFailed.isReadOnly)
        #expect(needed.itemText == "Read-only" && needed.popoverText.hasPrefix(FormatUpdatePrompt.body))
        // The D14 sheet stays reachable from the status item if its first presentation didn't happen or was dismissed.
        #expect(needed.actions == [.updateFormat] && SaveStatusAction.updateFormat.rawValue == "Update…")
        #expect(needed.messageBar == nil)
        // While the update runs there's nothing to choose: no dead Update… button, still read-only, not dirty.
        let updating = SaveStatusPresentation(DocumentSaveStatus(state: .updatingFormat, autosaveEnabled: true), showName: "Show")
        #expect(DocumentSaveState.updatingFormat.isReadOnly && !DocumentSaveState.updatingFormat.impliesUnsavedChanges)
        #expect(updating.actions.isEmpty && updating.messageBar == nil && updating.isReadOnly)
        #expect(updating.itemText == "Updating…" && updating.symbolName == nil)
        #expect(updating.accessibilityValue == "Updating…. WaveWrangler is updating “Show” to the current format.")
        #expect(CloseDecision(state: .updatingFormat, autosaveEnabled: true, showName: "Show") == .closeImmediately)
        let failed = SaveStatusPresentation(DocumentSaveStatus(state: .updateFailed, autosaveEnabled: true), showName: "Show")
        #expect(failed.itemText == "Read-only")
        #expect(failed.messageBar?.heading == "Couldn't update this show")
        #expect(failed.messageBar?.body == "The original is unchanged. You can view it read-only.")
        #expect(failed.messageBar?.actions == [.tryAgain, .showDetails])
        // Not colour-only: a distinct symbol and text accompany the tint.
        #expect(failed.symbolName == "xmark.octagon" && failed.accessibilityValue.contains("Read-only"))
    }
}
