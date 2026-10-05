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
        .updateNeeded, .updateFailed, .readOnlyLocation,
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

    @Test func announcementsOnlyForExplicitSaveAndFailures() {
        let saved = DocumentSaveState.saved(at: Self.date, folderDisplayName: nil)
        #expect(SaveStatusPresentation.announcement(for: saved, showName: "S", explicitSave: false) == nil)
        #expect(SaveStatusPresentation.announcement(for: saved, showName: "S", explicitSave: true) == "Saved")
        #expect(SaveStatusPresentation.announcement(for: .conflict(changedAt: nil), showName: "S", explicitSave: false) == "“S” was changed somewhere else. Your changes are kept.")
    }
}

@Suite("Destinations")
struct DestinationTests {
    @Test func onlySetupIsAvailableAndLaterOnesExplainWhy() {
        #expect(ShowDestination.allCases.map(\.title) == ["Setup", "Alignment", "Review", "Export"])
        #expect(ShowDestination.setup.blockedPanel == nil)
        #expect(ShowDestination.alignment.blockedPanel?.heading == "Alignment isn't available yet")
        #expect(ShowDestination.alignment.blockedPanel?.body.contains("WaveWrangler hasn't read or analysed any audio.") == true)
        #expect(ShowDestination.export.blockedPanel?.body.hasSuffix("Nothing has been exported.") == true)
        for destination in ShowDestination.allCases where destination != .setup {
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
        ])
        #expect(MenuCommand.duplicate.shortcut.description == "⇧⌘S")
        #expect(MenuCommand.toggleInspector.shortcut.description == "⌃⌘I")
    }
}
