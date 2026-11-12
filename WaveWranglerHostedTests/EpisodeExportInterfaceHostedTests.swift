import AppKit
import Foundation
import Testing
import WWCore
import WWExport
import WWOrganizer
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Native episode export interface", .serialized)
struct EpisodeExportInterfaceHostedTests {
    private func document() throws -> (ShowDocument, EpisodeID) {
        let episode = Episode(title: "Synthetic episode", number: 7)
        let model = ShowDocumentModel(show: .init(title: "Synthetic show",
            publication: .init(creator: "Show artist", publisher: "Publisher")), episodes: [episode])
        let document = ShowDocument()
        try document.read(from: JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            model, revision: 1, publicationID: UUID()).data, ofType: "com.brandonmartinez.wavewrangler.show")
        return (document, episode.id)
    }

    @Test func legacyMenuToolbarStateSharesOneDocumentPresentationWithoutNavigation() throws {
        let (document, episode) = try document()
        defer { document.close() }
        let first = ShowWindowState(store: document.store, episodeID: episode)
        let second = ShowWindowState(store: document.store, episodeID: episode)
        let original = document.store.model
        #expect(first.exportUnavailableReason == nil)
        let destination = first.destination
        first.select(.export)
        let presentation = document.exportInterface
        let firstPresented = first.exportPresented
        #expect(firstPresented && presentation.episodeID == episode)
        #expect(first.destination == destination)
        #expect(second.exportUnavailableReason?.contains("another window") == true)
        second.requestExport()
        #expect(!second.exportPresented && first.exportPresented)
        let (other, otherEpisode) = try self.document()
        defer { other.close() }
        let otherState = ShowWindowState(store: other.store, episodeID: otherEpisode)
        #expect(otherState.exportUnavailableReason == nil)
        otherState.requestExport()
        #expect(otherState.exportPresented)
        presentation.dismiss()
        #expect(!first.exportPresented && second.exportUnavailableReason == nil)
        #expect(document.store.model == original)
        second.recordingsPresented = true
        #expect(second.exportUnavailableReason?.contains("Recordings") == true)
    }

    @Test func editsRevokeOmissionConsentSynchronouslyAndNeverEditTheShow() throws {
        let (document, episode) = try document()
        defer { document.close() }
        let state = ShowWindowState(store: document.store, episodeID: episode)
        state.requestExport()
        let presentation = document.exportInterface
        let original = document.store.model
        let omissions = try presentation.allOmissions
        #expect(!omissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.titleOverride = "Export title"
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.overrides.creator = ""
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.acceptedOmissions = omissions
        presentation.options.formats.insert(.mp3)
        #expect(presentation.acceptedOmissions.isEmpty)
        presentation.episodeNumberOverride = ""
        let selections = try presentation.selections()
        let preview = try #require(try presentation.previews.first { $0.format == .mp3 })
        #expect(preview.preview.metadata.title == "Export title")
        #expect(preview.preview.metadata.artist == nil && preview.preview.metadata.episodeNumber == nil)
        #expect(selections.count == 2 && document.store.model == original)
    }

    @Test func nativeMenuRoutesExportOnlyFromFileAndKeepsStandardAboutAndLicenses() throws {
        let windows = NSApp.windowsMenu, help = NSApp.helpMenu, services = NSApp.servicesMenu
        defer { NSApp.windowsMenu = windows; NSApp.helpMenu = help; NSApp.servicesMenu = services }
        let menu = MainMenu.make()
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
        let export = try #require(file.items.first { $0.action == #selector(CommandRouter.exportEpisode(_:)) })
        #expect(export.keyEquivalent == "4" && export.keyEquivalentModifierMask == .command)
        #expect(export.target === CommandRouter.shared)
        #expect(!view.items.contains { $0.title == "Export" || $0.keyEquivalent == "4" })
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items.contains { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) })
        let helpMenu = try #require(menu.items.first { $0.title == "Help" }?.submenu)
        #expect(helpMenu.items.contains { $0.action == #selector(CommandRouter.showSoftwareLicenses(_:)) })
    }

    @Test func actualAppAndPackageBundlesResolveAllSoftwareNotices() throws {
        let notices = try SoftwareLicenses.notices()
        #expect(notices.count == 6 && notices.allSatisfy { !$0.text.isEmpty })
        let whisperURL = try #require(Bundle.main.url(forResource: "WhisperCPULICENSE", withExtension: "txt"))
        #expect(notices.last?.text == (try String(contentsOf: whisperURL, encoding: .utf8)))
        #expect(notices.last?.text.contains("Jeffrey Quesnelle") == true)
        SoftwareLicensesWindowController.show()
        let window = try #require(NSApp.windows.first { $0.accessibilityIdentifier() == "ww.licenses.window" })
        #expect(window.contentMinSize.width >= 540 && window.title == "Software Licenses")
        window.close()
    }
}
