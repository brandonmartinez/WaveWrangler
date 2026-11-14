import AppKit
import Foundation
import ImageIO
import Testing
import WWCore
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Publication document transactions", .serialized)
struct PublicationMetadataHostedTests {
    @Test func liveEditingCoalescesAndUndoRedoRestoresInheritedDefaultsAcrossWindows() throws {
        let document = ShowDocument()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let episode = Episode(title: "Synthetic episode", number: 7)
        let original = ShowDocumentModel(show: .init(title: "Synthetic show",
            publication: .init(creator: "Show artist", publicDescription: "Public show")), episodes: [episode])
        document.store.replaceLoadedModel(original)
        let first = ShowWindowState(store: document.store, episodeID: episode.id)
        let second = ShowWindowState(store: document.store, episodeID: episode.id)
        let store = document.store
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        for text in ["E", "Episode description"] {
            #expect(store.apply("Edit Publication Metadata", coalescing: "publication-description") { model throws(DomainError) in
                try model.settingEpisodePublication(.init(metadata: .init(publicDescription: text)), for: episode.id)
            })
        }
        store.endCoalescing()
        let liveDescription = second.store.residentModel.episode(episode.id)?.publication?.metadata.publicDescription
        #expect(liveDescription == "Episode description")
        let liveCreator = try first.store.residentModel.resolvedPublication(for: episode.id).metadata.creator
        #expect(liveCreator == "Show artist")
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            store.residentModel, revision: 1, publicationID: UUID()).data
        let savedDescription = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes)
            .payload.episode(episode.id)?.publication?.metadata.publicDescription
        #expect(savedDescription == "Episode description")
        undo.undo()
        let undone = first.store.residentModel.episode(episode.id)?.publication
        #expect(undone == nil)
        undo.redo()
        let redone = second.store.residentModel.episode(episode.id)?.publication?.metadata.publicDescription
        #expect(redone == "Episode description")
        let unchangedStatus = store.residentModel.episode(episode.id)?.status
        let unchangedDate = store.residentModel.episode(episode.id)?.publishedOn
        #expect(unchangedStatus == .planned && unchangedDate == nil)
    }

    @Test func artworkOmissionUndoRestoresInheritedOriginalBytes() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let artwork = try PublicationArtwork(data: bytes as Data)
        let episode = Episode(title: "Synthetic episode")
        let document = ShowDocument()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let store = document.store
        store.replaceLoadedModel(.init(show: .init(title: "Synthetic show",
            publication: .init(artwork: .image(artwork))), episodes: [episode]))
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        #expect(store.apply("Remove Publication Artwork") { model throws(DomainError) in
            try model.settingEpisodePublication(.init(metadata: .init(
                artwork: PublicationArtworkSelection.none)), for: episode.id)
        })
        let removed = try store.residentModel.resolvedPublication(for: episode.id).metadata.artwork
        #expect(removed == PublicationArtworkSelection.none)
        undo.undo()
        let restored = try store.residentModel.resolvedPublication(for: episode.id).metadata.artwork?.image?.data
        #expect(restored == artwork.data)
        undo.redo()
        let redone = try store.residentModel.resolvedPublication(for: episode.id).metadata.artwork
        #expect(redone == PublicationArtworkSelection.none)
    }

    @Test func invalidEditLeavesLiveAndSavedValuesUntouched() throws {
        let store = ShowDocumentStore(model: .untitled())
        let original = store.residentModel
        #expect(!store.apply("Edit Publication Metadata") { model throws(DomainError) in
            try model.settingShowPublication(.init(website: "file:///private"))
        })
        let live = store.residentModel
        #expect(live == original)
        let error = store.lastError
        #expect(error != nil)
    }
}
