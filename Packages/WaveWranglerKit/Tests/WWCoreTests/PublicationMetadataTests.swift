import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WWCore

@Suite("Reusable publication metadata")
struct PublicationMetadataTests {
    @Test func resolvesDefaultsAndOverridesWithoutLeakingNotesOrInventingPublicationState() throws {
        let show = Show(title: "Album", notes: "PRIVATE show notes", publication: .init(
            creator: "Show artist", publisher: "Publisher", publicDescription: "Show description",
            copyright: "Copyright", genre: "Podcast", language: "en-US",
            website: "https://example.com", explicitContent: true))
        let episode = Episode(title: "Track", number: 7, notes: "PRIVATE episode notes", publication: .init(
            metadata: .init(creator: "", publicDescription: "Episode description", explicitContent: false),
            season: 2, episodeType: .bonus))
        let model = ShowDocumentModel(show: show, episodes: [episode])
        let result = try model.resolvedPublication(for: episode.id)
        #expect(result.title == "Track" && result.album == "Album" && result.episodeNumber == 7)
        #expect(result.publicationDate == nil && result.season == 2 && result.episodeType == .bonus)
        #expect(result.metadata.creator == "")
        #expect(result.metadata.publisher == "Publisher")
        #expect(result.metadata.publicDescription == "Episode description")
        #expect(result.metadata.explicitContent == false)
        #expect(result.metadata.language == "en-US" && result.metadata.website == "https://example.com")
        #expect(result.metadata.copyright == "Copyright" && result.metadata.genre == "Podcast")
        #expect(model.episodes[0].status == .planned && model.episodes[0].publishedOn == nil)
        let reset = try model.settingEpisodePublication(nil, for: episode.id)
        #expect(try reset.resolvedPublication(for: episode.id).metadata == show.publication)
        let absent = ShowDocumentModel(show: .init(title: "Show", notes: "Private"), episodes: [.init(title: "Episode", notes: "Private")])
        #expect(try absent.resolvedPublication(for: absent.episodes[0].id).metadata.publicDescription == nil)
    }

    @Test func inheritanceRemainsLiveAndIntentionalEmptyAndNoArtworkSurviveRoundTrip() throws {
        let image = try PublicationArtwork(data: Self.imageBytes())
        let episode = Episode(title: "Episode", publication: .init(metadata: .init(
            creator: "", artwork: PublicationArtworkSelection.none)))
        var model = ShowDocumentModel(show: .init(title: "Show", publication: .init(
            creator: "Default", publisher: "Old", artwork: .image(image))), episodes: [episode])
        model = try model.settingShowPublication(.init(creator: "Changed", publisher: "New", artwork: .image(image)))
        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ShowDocumentModel.self, from: encoded)
        #expect(decoded == model)
        let resolved = try decoded.resolvedPublication(for: episode.id)
        #expect(resolved.metadata.creator == "" && resolved.metadata.publisher == "New")
        #expect(resolved.metadata.artwork == PublicationArtworkSelection.none)
        let inherited = try decoded.settingEpisodePublication(nil, for: episode.id)
        #expect(try inherited.resolvedPublication(for: episode.id).metadata.artwork?.image?.data == image.data)
        let id = EpisodeID()
        #expect(throws: DomainError.episodeNotFound(id)) { try model.resolvedPublication(for: id) }
    }

    @Test func publicFieldsValidateAtDomainAndDocumentBoundaries() throws {
        let episode = Episode(title: "Episode")
        let model = ShowDocumentModel(show: .init(title: "Show"), episodes: [episode])
        for metadata in [
            PublicationMetadata(creator: String(repeating: "a", count: 4_097)),
            .init(publicDescription: String(repeating: "a", count: 65_537)),
            .init(publisher: "bad\u{0}tag"),
            .init(language: "English language"),
            .init(website: "file:///private/path"),
            .init(website: "https://user:password@example.com"),
        ] {
            #expect(throws: DomainError.self) { try model.settingShowPublication(metadata) }
            #expect(throws: DomainError.self) {
                try model.settingEpisodePublication(.init(metadata: metadata), for: episode.id)
            }
            var invalid = model
            invalid.show.publication = metadata
            #expect(invalid.validationIssues().contains { $0.code == .invalidPublication })
        }
        #expect(throws: DomainError.self) {
            try model.addingEpisode(.init(title: "Bad season", publication: .init(season: 0)))
        }
        #expect(throws: DomainError.self) {
            try model.settingEpisodePublication(.init(season: -1), for: episode.id)
        }
        let day = try #require(CalendarDay(year: 2026, month: 11, day: 12))
        let dated = try model.settingEpisodePublishedOn(day, for: episode.id)
        #expect(dated.episodes[0].status == .planned)
        #expect(try dated.resolvedPublication(for: episode.id).publicationDate == day)
        #expect(try dated.settingShowPublication(.init(publicDescription: "Public")).episodes == dated.episodes)
    }

    @Test(arguments: ["public.png", "public.jpeg"])
    func artworkOwnsExactValidatedBytesAndRejectsTamperedDimensions(_ type: String) throws {
        let bytes = try Self.imageBytes(type: type)
        let image = try PublicationArtwork(data: bytes)
        #expect(image.data == bytes && image.pixelWidth == 2 && image.pixelHeight == 2)
        #expect(image.mediaType == (type == "public.png" ? "image/png" : "image/jpeg"))
        let encoded = try JSONEncoder().encode(image)
        #expect(try JSONDecoder().decode(PublicationArtwork.self, from: encoded) == image)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["pixelWidth"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PublicationArtwork.self, from: tampered) }
    }

    @Test func artworkRejectsNonImagesOtherFormatsTruncationSizeAndDimensionOverflow() throws {
        for bytes in [
            Data(), Data("not an image".utf8),
            try Self.imageBytes(type: "com.compuserve.gif"),
            Data(try Self.imageBytes().prefix(24)),
            Data(repeating: 0, count: PublicationArtwork.maximumBytes + 1),
            try Self.imageBytes(width: PublicationArtwork.maximumDimension + 1, height: 1),
        ] {
            #expect(throws: DomainError.self) { try PublicationArtwork(data: bytes) }
        }
        let boundary = try PublicationArtwork(data: Self.imageBytes(width: PublicationArtwork.maximumDimension, height: 1))
        #expect(boundary.pixelWidth == PublicationArtwork.maximumDimension)
    }

    static func imageBytes(type: String = "public.png", width: Int = 2, height: Int = 2) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
