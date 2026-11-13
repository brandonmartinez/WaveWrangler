import Foundation

/// One shared schema for show defaults and episode overrides. `nil` means unspecified at show level
/// and inherit at episode level. An empty string explicitly suppresses an inherited text field.
/// Internal Show/Episode notes are never publication metadata.
public struct PublicationMetadata: Sendable, Equatable, Codable {
    public var creator: String?
    public var publisher: String?
    public var publicDescription: String?
    public var copyright: String?
    public var genre: String?
    public var language: String?
    public var website: String?
    public var explicitContent: Bool?
    /// `nil` inherits; `.none` deliberately omits artwork; `.image` embeds original bytes.
    public var artwork: PublicationArtworkSelection?

    public init(creator: String? = nil, publisher: String? = nil, publicDescription: String? = nil,
                copyright: String? = nil, genre: String? = nil, language: String? = nil,
                website: String? = nil, explicitContent: Bool? = nil,
                artwork: PublicationArtworkSelection? = nil) {
        self.creator = creator
        self.publisher = publisher
        self.publicDescription = publicDescription
        self.copyright = copyright
        self.genre = genre
        self.language = language
        self.website = website
        self.explicitContent = explicitContent
        self.artwork = artwork
    }

    public func inheriting(from defaults: Self) -> Self {
        Self(creator: creator ?? defaults.creator, publisher: publisher ?? defaults.publisher,
             publicDescription: publicDescription ?? defaults.publicDescription,
             copyright: copyright ?? defaults.copyright, genre: genre ?? defaults.genre,
             language: language ?? defaults.language, website: website ?? defaults.website,
             explicitContent: explicitContent ?? defaults.explicitContent, artwork: artwork ?? defaults.artwork)
    }

    public var validationMessage: String? {
        let shortFields = [creator, publisher, copyright, genre, language, website]
        if shortFields.compactMap({ $0 }).contains(where: { $0.utf8.count > 4_096 }) {
            return "Publication fields must be no longer than 4,096 UTF-8 bytes."
        }
        if let publicDescription, publicDescription.utf8.count > 65_536 {
            return "The public description must be no longer than 65,536 UTF-8 bytes."
        }
        if (shortFields + [publicDescription]).compactMap({ $0 }).contains(where: {
            $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }
        }) {
            return "Publication text cannot contain control characters."
        }
        if let website, !website.isEmpty {
            guard let url = URLComponents(string: website), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  !website.contains(where: \.isWhitespace) else {
                return "Enter a complete HTTP or HTTPS website without credentials, or leave it empty."
            }
        }
        if let language, !language.isEmpty {
            let parts = language.split(separator: "-", omittingEmptySubsequences: false)
            let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            let alphanumeric = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            guard let first = parts.first, (2...8).contains(first.count),
                  first.unicodeScalars.allSatisfy(letters.contains),
                  parts.dropFirst().allSatisfy({ part in
                      (1...8).contains(part.count) && part.unicodeScalars.allSatisfy(alphanumeric.contains)
                  }) else {
                return "Use a language tag such as en or en-US, or leave it empty."
            }
        }
        if let artwork, case .image(let image) = artwork, image.schemaVersion != PublicationArtwork.currentSchemaVersion {
            return "This artwork version is not supported."
        }
        return nil
    }
}

public enum PublicationEpisodeType: String, Sendable, Equatable, Codable, CaseIterable {
    case full, trailer, bonus
}

public struct EpisodePublication: Sendable, Equatable, Codable {
    public var metadata: PublicationMetadata
    public var season: Int?
    public var episodeType: PublicationEpisodeType?

    public init(metadata: PublicationMetadata = .init(), season: Int? = nil,
                episodeType: PublicationEpisodeType? = nil) {
        self.metadata = metadata
        self.season = season
        self.episodeType = episodeType
    }
}

/// Codec-independent publication values. Title maps to the episode/track title and album to show title.
/// `publicationDate` is only the existing user-stated date; resolving never publishes or dates an episode.
public struct ResolvedPublicationMetadata: Sendable, Equatable {
    public let title: String
    public let album: String
    public let episodeNumber: Int?
    public let publicationDate: CalendarDay?
    public let season: Int?
    public let episodeType: PublicationEpisodeType?
    public let metadata: PublicationMetadata
}

extension ShowDocumentModel {
    public func resolvedPublication(for id: EpisodeID) throws(DomainError) -> ResolvedPublicationMetadata {
        guard let episode = episode(id) else { throw .episodeNotFound(id) }
        return ResolvedPublicationMetadata(title: episode.title, album: show.title, episodeNumber: episode.number,
            publicationDate: episode.publishedOn, season: episode.publication?.season,
            episodeType: episode.publication?.episodeType,
            metadata: (episode.publication?.metadata ?? .init()).inheriting(from: show.publication ?? .init()))
    }

    public func settingShowPublication(_ publication: PublicationMetadata?) throws(DomainError) -> Self {
        var result = self
        result.show.publication = publication
        try result.validatePublicationEdit()
        return result
    }

    public func settingEpisodePublication(_ publication: EpisodePublication?, for id: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var result = self
        result.episodes[index].publication = publication
        try result.validatePublicationEdit()
        return result
    }

    public func settingEpisodePublishedOn(_ day: CalendarDay?, for id: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var result = self
        result.episodes[index].publishedOn = day
        return result
    }

    private func validatePublicationEdit() throws(DomainError) {
        if let issue = publicationValidationIssues(expectedSchemaVersion: schemaVersion).first {
            throw .invalidPublication(issue.detail)
        }
    }

    public func publicationValidationIssues(expectedSchemaVersion: Int) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if expectedSchemaVersion < 14, show.publication != nil || episodes.contains(where: { $0.publication != nil }) {
            issues.append(.init(.invalidPublication, "schemas before 14 cannot contain publication metadata or artwork"))
        }
        if let message = show.publication?.validationMessage {
            issues.append(.init(.invalidPublication, "Show: \(message)"))
        }
        for episode in episodes {
            if let message = episode.publication?.metadata.validationMessage {
                issues.append(.init(.invalidPublication, "Episode \(episode.id): \(message)"))
            }
            if let season = episode.publication?.season, season < 1 {
                issues.append(.init(.invalidPublication, "Season must be a whole number of 1 or more."))
            }
        }
        return issues
    }
}
