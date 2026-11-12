import CoreGraphics
import Foundation
import ImageIO
import Testing
import WWCore
import WWExport

@Suite("Export publication metadata adaptation")
struct ExportMetadataAdapterTests {
    @Test func exportOnlyDateNumberAndTextPreserveInheritVersusOmit() throws {
        let episode = Episode(title: "Episode", number: 7)
        let model = ShowDocumentModel(show: .init(title: "Show"), episodes: [episode])
        let resolved = try model.resolvedPublication(for: episode.id)
        var selection = try EpisodeExportOptions().delivery(.mp3, baseName: "Episode")
        #expect(try ExportMetadataAdapter.delivery(resolved, selection: selection).metadata.episodeNumber == 7)
        selection.titleOverride = ""; selection.albumOverride = ""
        selection.dateOverride = "2026-11-12"; selection.episodeNumberOverride = "8"
        let changed = try ExportMetadataAdapter.delivery(resolved, selection: selection).metadata
        #expect(changed.title == nil && changed.album == nil)
        #expect(changed.date == "2026-11-12" && changed.episodeNumber == 8)
        selection.dateOverride = ""; selection.episodeNumberOverride = ""
        let omitted = try ExportMetadataAdapter.delivery(resolved, selection: selection).metadata
        #expect(omitted.date == nil && omitted.episodeNumber == nil)
        for invalid in ["0", "-1", "2147483648", "one", "1.5"] {
            selection.episodeNumberOverride = invalid
            #expect(throws: ExportFailure.self) { try ExportMetadataAdapter.delivery(resolved, selection: selection) }
        }
        selection.episodeNumberOverride = nil
        selection.dateOverride = "not-a-date"
        #expect(throws: ExportFailure.self) { try ExportMetadataAdapter.delivery(resolved, selection: selection) }
        #expect(model.episodes[0].number == 7 && model.episodes[0].publishedOn == nil)
    }

    @Test func newlyRequiredOmissionsCannotReuseEarlierConsent() throws {
        let episode = Episode(title: "Episode", number: 7)
        let model = ShowDocumentModel(show: .init(title: "Show"), episodes: [episode])
        var selection = try EpisodeExportOptions().delivery(.wave, baseName: "Episode")
        let resolved = try model.resolvedPublication(for: episode.id)
        selection.confirmedOmissions = try ExportMetadataAdapter.preview(resolved, delivery: selection).omissions
        _ = try ExportMetadataAdapter.delivery(resolved, selection: selection)
        let changed = try model.settingShowPublication(.init(publisher: "New publisher"))
        let refreshed = try changed.resolvedPublication(for: episode.id)
        #expect(throws: ExportFailure.self) { try ExportMetadataAdapter.delivery(refreshed, selection: selection) }
        selection.confirmedOmissions = try ExportMetadataAdapter.preview(refreshed, delivery: selection).omissions
        _ = try ExportMetadataAdapter.delivery(refreshed, selection: selection)
    }
    @Test func inheritedDefaultsAndExportOverridesNeverMutateDocumentOrCopyNotes() throws {
        let episode = Episode(title: "Episode", number: 7, notes: "PRIVATE episode notes")
        let model = ShowDocumentModel(show: .init(title: "Show", notes: "PRIVATE show notes",
            publication: .init(creator: "Artist", publicDescription: "Public")), episodes: [episode])
        let original = model
        let resolved = try model.resolvedPublication(for: episode.id)
        var selection = EpisodeExportDelivery(filename: "out.mp3",
            settings: try .init(codec: .mp3(.constantBitrate(kbps: 128)), sampleRate: 48_000, channels: 2))
        selection.overrides = .init(creator: "", publicDescription: "Delivery only")
        selection.titleOverride = "Export title"
        selection.normalization = .custom(targetLUFS: -18, ceilingDBTP: -2)
        let output = try ExportMetadataAdapter.delivery(resolved, selection: selection)
        #expect(output.metadata.title == "Export title" && output.metadata.album == "Show")
        #expect(output.metadata.artist == nil && output.metadata.publicDescription == "Delivery only")
        #expect(output.metadata.date == nil && output.metadata.episodeNumber == 7)
        #expect(output.normalization == .custom(targetLUFS: -18, ceilingDBTP: -2))
        #expect(model == original && model.episodes[0].status == .planned)
    }

    @Test func waveRequiresExplicitOmissionsButArtworkNeverMakesWaveImpossible() throws {
        let artwork = try PublicationArtwork(data: image())
        let episode = Episode(title: "Caf\u{e9}", number: 8)
        let model = ShowDocumentModel(show: .init(title: "Show", publication: .init(artwork: .image(artwork))),
                                      episodes: [episode])
        let resolved = try model.resolvedPublication(for: episode.id)
        var selection = EpisodeExportDelivery(filename: "out.wav",
            settings: try .init(codec: .wave(.int24), sampleRate: 48_000, channels: 2))
        let preview = try ExportMetadataAdapter.preview(resolved, delivery: selection)
        #expect(Set(preview.omissions.map(\.field)) == ["title", "episodeNumber", "artwork"])
        #expect(throws: ExportFailure.self) { try ExportMetadataAdapter.delivery(resolved, selection: selection) }
        selection.confirmedOmissions = preview.omissions
        let delivery = try ExportMetadataAdapter.delivery(resolved, selection: selection)
        #expect(delivery.metadata.title == nil && delivery.metadata.artwork == nil && delivery.metadata.episodeNumber == nil)
        #expect(delivery.metadata.album == "Show")
    }

    @Test func unsupportedFieldsAndOversizedOriginalArtworkHaveActionableOmissions() throws {
        var bytes = try image()
        bytes.append(Data(repeating: 0, count: 8 * 1_024 * 1_024))
        let artwork = try PublicationArtwork(data: bytes)
        let episode = Episode(title: "Episode", publication: .init(season: 2, episodeType: .bonus))
        let model = ShowDocumentModel(show: .init(title: "Show", publication: .init(
            publisher: "Publisher", language: "en-US", website: "https://example.com",
            explicitContent: false, artwork: .image(artwork))), episodes: [episode])
        let resolved = try model.resolvedPublication(for: episode.id)
        var selection = EpisodeExportDelivery(filename: "out.m4a",
            settings: try .init(codec: .aacLC(bitrate: 128_000), sampleRate: 48_000, channels: 2))
        let preview = try ExportMetadataAdapter.preview(resolved, delivery: selection)
        #expect(Set(preview.omissions.map(\.field)) ==
            ["publisher", "language", "website", "explicitContent", "season", "episodeType", "artwork"])
        #expect(preview.omissions.contains { $0.field == "artwork" && $0.reason.contains("8 MiB") })
        selection.overrides.artwork = PublicationArtworkSelection.none
        let suppressed = try ExportMetadataAdapter.preview(resolved, delivery: selection)
        #expect(!suppressed.omissions.contains { $0.field == "artwork" })
        selection.confirmedOmissions = suppressed.omissions
        #expect(try ExportMetadataAdapter.delivery(resolved, selection: selection).metadata.artwork == nil)
    }

    private func image() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
