import Foundation
import OSLog
import Synchronization
import WWCore

/// Catalog metadata is not a partial `ShowDocumentModel`. Episode payloads are separate, explicit records.
public struct ShowCatalogHeader: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var show: Show
    public var speakers: [Speaker]
    public var history: EditHistory

    public init(_ model: ShowDocumentModel) {
        schemaVersion = model.schemaVersion
        show = model.show
        speakers = model.speakers
        history = model.history
    }

    public func operationModel(episodes: [Episode]) -> ShowDocumentModel {
        ShowDocumentModel(schemaVersion: schemaVersion, show: show, speakers: speakers, episodes: episodes, history: history)
    }
}

/// Metadata and global identities needed without interpreting an episode's transcript or DSP payload.
public struct CatalogEpisodeSummary: Sendable, Equatable, Codable, Identifiable {
    public let id: EpisodeID
    public let title: String
    public let number: Int?
    public let status: EpisodeStatus
    public let sourceIDs: [SourceID]
    public let recorderGroupIDs: [RecorderGroupID]
    public let epochIDs: [RecordingEpochID]
    public let audioTrackIDs: [AudioTrackID]
    public let audioClipIDs: [AudioClipID]
    public let insertionIDs: [AudioInsertionRegionID]
    public let speakerIDs: [SpeakerID]

    public init(_ episode: Episode) {
        id = episode.id
        title = episode.title
        number = episode.number
        status = episode.status
        sourceIDs = episode.sources.map(\.id)
        recorderGroupIDs = episode.recorderGroups.map(\.id)
        epochIDs = episode.recorderGroups.flatMap { $0.epochs.map(\.id) }
        audioTrackIDs = episode.audioArrangement?.tracks.map(\.id) ?? []
        audioClipIDs = episode.audioArrangement?.clips.map(\.id) ?? []
        insertionIDs = episode.audioArrangement?.insertionRegions.map(\.id) ?? []
        speakerIDs = episode.speakerAssignments.map(\.speakerID)
    }
}

/// Immutable, byte-preserving episode storage. Loading is explicit and can fail; absent is never unloaded.
public struct StoredCatalogEpisode: Sendable, Equatable, Identifiable {
    public var id: EpisodeID { summary.id }
    public let summary: CatalogEpisodeSummary
    let content: ShowPackage.Component
    let artwork: ShowPackage.Component?
    let files: [String: CatalogComponentFile]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary == rhs.summary && lhs.content == rhs.content && lhs.artwork == rhs.artwork
    }

    public func load(in header: ShowCatalogHeader) throws -> Episode {
        var used: Set<String> = []
        var remaining = 512 * 1_024 * 1_024
        let snapshot = try snapshot()
        var episode = try ShowPackage.decodeComponent(Episode.self, content, snapshot: snapshot, used: &used, remaining: &remaining)
        guard episode.id == id else { throw PersistenceError.malformed("Package episode identity mismatch") }
        if let artwork {
            guard episode.publication != nil, episode.publication?.metadata.artwork == nil else {
                throw PersistenceError.malformed("Invalid episode artwork reference")
            }
            episode.publication?.metadata.artwork = .image(try PublicationArtwork(
                data: ShowPackage.bytes(artwork, snapshot: snapshot, used: &used, remaining: &remaining)))
        }
        guard CatalogEpisodeSummary(episode) == summary else {
            throw PersistenceError.malformed("Episode content disagrees with the catalog index")
        }
        let model = header.operationModel(episodes: [episode])
        if let newer = model.newerEmbeddedTimeMapSchema() {
            throw PersistenceError.unknownNewerSchema(found: newer.found, supported: newer.supported)
        }
        let issues = model.validationIssues() + model.embeddedMapIssues()
        guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
        return episode
    }

    private func snapshot() throws -> ShowPackage.Snapshot {
        try ShowPackage.Snapshot(manifest: Data(), files: files.mapValues { try $0.read() })
    }
}

/// The complete catalog authority, including every unloaded episode's exact stored components.
/// Copies share immutable device-local backing files, not decoded transcript graphs or a mutable cache.
public struct ShowCatalog: Sendable, Equatable {
    public var header: ShowCatalogHeader
    public private(set) var episodes: [StoredCatalogEpisode]
    private let storage: CatalogComponentStorage

    public init(_ model: ShowDocumentModel) throws {
        try Self.validate(header: ShowCatalogHeader(model), summaries: model.episodes.map(CatalogEpisodeSummary.init))
        let issues = model.validationIssues() + model.embeddedMapIssues()
        guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
        header = ShowCatalogHeader(model)
        storage = try CatalogComponentStorage()
        episodes = []
        for episode in model.episodes {
            episodes.append(try Self.store(episode, in: storage))
        }
    }

    init(header: ShowCatalogHeader, episodes: [StoredCatalogEpisode], storage: CatalogComponentStorage) {
        self.header = header
        self.episodes = episodes
        self.storage = storage
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.header == rhs.header && lhs.episodes == rhs.episodes
    }

    public func episode(_ id: EpisodeID) -> StoredCatalogEpisode? { episodes.first { $0.id == id } }

    public func materializedModel() throws -> ShowDocumentModel {
        try header.operationModel(episodes: episodes.map { try $0.load(in: header) })
    }

    public func replacingEpisode(_ episode: Episode) throws -> Self {
        var result = self
        let stored = try archivingEpisode(episode, validatingWith: header)
        if let index = result.episodes.firstIndex(where: { $0.id == episode.id }) {
            result.episodes[index] = stored
        } else {
            result.episodes.append(stored)
        }
        try result.validateIndex()
        return result
    }

    public func archivingEpisode(_ episode: Episode, validatingWith header: ShowCatalogHeader) throws -> StoredCatalogEpisode {
        let model = header.operationModel(episodes: [episode])
        if let newer = model.newerEmbeddedTimeMapSchema() {
            throw PersistenceError.unknownNewerSchema(found: newer.found, supported: newer.supported)
        }
        let issues = model.validationIssues() + model.embeddedMapIssues()
        guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
        return try Self.store(episode, in: storage)
    }

    public func snapshot(header: ShowCatalogHeader, episodes: [StoredCatalogEpisode]) throws -> Self {
        let result = Self(header: header, episodes: episodes, storage: storage)
        try result.validateIndex()
        return result
    }

    /// Reordering/removal never interprets or rewrites an episode payload.
    public func retainingEpisodes(in order: [EpisodeID]) throws -> Self {
        guard Set(order).count == order.count else { throw PersistenceError.malformed("Duplicate catalog episode") }
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        var result = self
        result.episodes = try order.map {
            guard let episode = byID[$0] else { throw PersistenceError.malformed("Unknown catalog episode") }
            return episode
        }
        return result
    }

    func validateIndex() throws {
        try Self.validate(header: header, summaries: episodes.map(\.summary))
    }

    public static func validate(header: ShowCatalogHeader, summaries: [CatalogEpisodeSummary]) throws {
        guard summaries.count <= 10_000 else { throw PersistenceError.malformed("Package exceeds 10,000 episodes") }
        let issues = header.operationModel(episodes: []).validationIssues()
        guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
        func unique<T: Hashable>(_ ids: [T]) throws {
            guard Set(ids).count == ids.count else { throw PersistenceError.malformed("Duplicate catalog identity") }
        }
        try unique(summaries.map(\.id))
        try unique(summaries.flatMap(\.sourceIDs))
        try unique(summaries.flatMap(\.recorderGroupIDs))
        try unique(summaries.flatMap(\.epochIDs))
        try unique(summaries.flatMap(\.audioTrackIDs))
        try unique(summaries.flatMap(\.audioClipIDs))
        try unique(summaries.flatMap(\.insertionIDs))
        let speakers = Set(header.speakers.map(\.id))
        guard summaries.allSatisfy({ Set($0.speakerIDs).isSubset(of: speakers) }) else {
            throw PersistenceError.malformed("Catalog refers to an absent speaker")
        }
    }

    private static func store(_ episode: Episode, in storage: CatalogComponentStorage) throws -> StoredCatalogEpisode {
        var payload = episode
        var files: [String: Data] = [:]
        var metadata = payload.publication?.metadata
        let artwork = try ShowPackage.detachArtwork(&metadata, files: &files)
        if let metadata { payload.publication?.metadata = metadata }
        let content = try ShowPackage.component(JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(payload), files: &files)
        return try StoredCatalogEpisode(summary: CatalogEpisodeSummary(episode), content: content, artwork: artwork,
            files: files.mapValues { try storage.store($0) })
    }
}

/// A captured save input: all episode slots remain present, but only changed resident episodes need encoding.
public struct ShowCatalogDraft: Sendable {
    public enum EpisodePayload: Sendable {
        case stored(StoredCatalogEpisode)
        case resident(Episode)

        public var summary: CatalogEpisodeSummary {
            switch self {
            case .stored(let episode): episode.summary
            case .resident(let episode): CatalogEpisodeSummary(episode)
            }
        }
    }

    public let header: ShowCatalogHeader
    public let episodes: [EpisodePayload]
    private let archiveOwner: ShowCatalog?

    public init(header: ShowCatalogHeader, episodes: [EpisodePayload], archiveOwner: ShowCatalog? = nil) {
        self.header = header
        self.episodes = episodes
        self.archiveOwner = archiveOwner
    }

    /// Performs serialization and backing-file I/O; callers run this on their bounded persistence lane.
    public func resolved() throws -> ShowCatalog {
        try ShowCatalog.validate(header: header, summaries: episodes.map(\.summary))
        let owner = try archiveOwner ?? ShowCatalog(header.operationModel(episodes: []))
        let stored = try episodes.map { payload in
            switch payload {
            case .stored(let episode): episode
            case .resident(let episode): try owner.archivingEpisode(episode, validatingWith: header)
            }
        }
        return try owner.snapshot(header: header, episodes: stored)
    }
}

/// Indexed package publications hash the canonical component index, not a reconstructed whole-model JSON.
/// Legacy package/envelope upgrades remain explicit; this coder never silently upgrades either input.
public struct ShowCatalogCoder: CanonicalDocumentCoding {
    public let format = DocumentFormat.show
    public init() {}

    private struct EpisodeEntry: Codable {
        var summary: CatalogEpisodeSummary
        var content: ShowPackage.Component
        var artwork: ShowPackage.Component?
    }

    private struct Index: Codable {
        var catalog: ShowPackage.Component
        var artwork: ShowPackage.Component?
        var episodes: [EpisodeEntry]
    }

    private struct Manifest: Codable {
        var format = ShowPackage.typeIdentifier
        var schemaVersion = 2
        var modelSchemaVersion = SchemaVersion.show
        var revision: Int
        var publicationID: UUID
        var checksum: String
        var index: Index
    }

    public func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<ShowCatalog> {
        do {
            guard try ShowPackage.storageVersion(of: data) == 2 else {
                throw PersistenceError.unsupportedOlderSchema(found: 1, minimum: 2)
            }
            let snapshot = try ShowPackage.unframe(data)
            let manifest = try JSONEnvelopeCoder<ShowDocumentModel>.makeDecoder().decode(Manifest.self, from: snapshot.manifest)
            try ShowPackage.requireRecognized(snapshot.manifest, value: manifest)
            guard manifest.revision >= 1 else { throw PersistenceError.invalidRevision(manifest.revision) }
            guard try checksum(manifest.index) == manifest.checksum else { throw PersistenceError.checksumMismatch }
            var used: Set<String> = []
            var remaining = 512 * 1_024 * 1_024
            var header = try ShowPackage.decodeComponent(ShowCatalogHeader.self, manifest.index.catalog,
                snapshot: snapshot, used: &used, remaining: &remaining)
            if let artwork = manifest.index.artwork {
                guard header.show.publication != nil, header.show.publication?.artwork == nil else {
                    throw PersistenceError.malformed("Invalid show artwork reference")
                }
                header.show.publication?.artwork = .image(try PublicationArtwork(
                    data: ShowPackage.bytes(artwork, snapshot: snapshot, used: &used, remaining: &remaining)))
            }
            let storage = try CatalogComponentStorage()
            guard manifest.index.episodes.count <= 10_000 else {
                throw PersistenceError.malformed("Package exceeds 10,000 episodes")
            }
            var storedFiles: [String: CatalogComponentFile] = [:]
            func file(_ reference: ShowPackage.Component) throws -> CatalogComponentFile {
                guard (0...(64 * 1_024 * 1_024)).contains(reference.byteCount),
                      reference.byteCount <= remaining,
                      reference.encoding == "raw" || reference.encoding == "lzfse",
                      let bytes = snapshot.files[reference.digest],
                      bytes.count <= 64 * 1_024 * 1_024,
                      !bytes.isEmpty || reference.encoding == "raw",
                      reference.encoding != "lzfse" || reference.byteCount > 0,
                      reference.encoding != "raw" || bytes.count == reference.byteCount,
                      RevisionFingerprint.digest(bytes) == reference.digest else {
                    throw PersistenceError.checksumMismatch
                }
                remaining -= reference.byteCount
                used.insert(reference.digest)
                if let existing = storedFiles[reference.digest] { return existing }
                let result = try storage.store(bytes)
                storedFiles[reference.digest] = result
                return result
            }
            var episodes: [StoredCatalogEpisode] = []
            for entry in manifest.index.episodes {
                var files = [entry.content.digest: try file(entry.content)]
                if let artwork = entry.artwork { files[artwork.digest] = try file(artwork) }
                episodes.append(StoredCatalogEpisode(summary: entry.summary, content: entry.content, artwork: entry.artwork, files: files))
            }
            guard used == Set(snapshot.files.keys) else { throw PersistenceError.unrecognizedContent }
            let catalog = ShowCatalog(header: header, episodes: episodes, storage: storage)
            try catalog.validateIndex()
            return DecodedDocument(payload: catalog, publication: .init(revision: manifest.revision,
                publicationID: manifest.publicationID, checksum: manifest.checksum))
        } catch let error as PersistenceError { throw error }
        catch DomainError.unsupportedPublicationArtworkSchema(let found, let supported) {
            throw .unknownNewerSchema(found: found, supported: supported)
        }
        catch { throw .malformed("Unreadable indexed show package: \(error.localizedDescription)") }
    }

    public func encodeDocument(_ payload: ShowCatalog, revision: Int, publicationID: UUID) throws(PersistenceError) -> EncodedDocument {
        do {
            guard revision >= 1 else { throw PersistenceError.invalidRevision(revision) }
            try payload.validateIndex()
            var header = payload.header
            var files: [String: Data] = [:]
            let artwork = try ShowPackage.detachArtwork(&header.show.publication, files: &files)
            let content = try ShowPackage.component(JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(header), files: &files)
            var entries: [EpisodeEntry] = []
            var remaining = 512 * 1_024 * 1_024 - content.byteCount - (artwork?.byteCount ?? 0)
            for episode in payload.episodes {
                remaining -= episode.content.byteCount + (episode.artwork?.byteCount ?? 0)
                guard remaining >= 0 else { throw PersistenceError.encodingFailed("Package expanded content exceeds 512 MiB") }
                for (digest, file) in episode.files where files[digest] == nil { files[digest] = try file.read() }
                entries.append(EpisodeEntry(summary: episode.summary, content: episode.content, artwork: episode.artwork))
            }
            let index = Index(catalog: content, artwork: artwork, episodes: entries)
            let checksum = try checksum(index)
            let manifest = Manifest(revision: revision, publicationID: publicationID, checksum: checksum, index: index)
            let data = try ShowPackage.frame(.init(manifest: JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(manifest), files: files))
            return EncodedDocument(data: data, publication: .init(revision: revision, publicationID: publicationID, checksum: checksum))
        } catch let error as PersistenceError { throw error }
        catch { throw .encodingFailed(error.localizedDescription) }
    }

    private func checksum(_ index: Index) throws -> String {
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(index)
        return "sha256:" + RevisionFingerprint.digest(Data("WWShowCatalog2\0".utf8) + bytes)
    }
}

/// Backing files outlive package replacement and are shared by catalog/Undo snapshots.
/// The budget includes all still-referenced revisions, not just the current document.
final class CatalogComponentStorage: Sendable {
    private static let log = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "catalog.storage")
    let root: URL
    private static let allocated = Mutex(0)
    private static let limit = 1_024 * 1_024 * 1_024

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "WaveWranglerCatalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func store(_ data: Data) throws -> CatalogComponentFile {
        let admitted = Self.allocated.withLock { bytes in
            guard data.count <= Self.limit - bytes else { return false }
            bytes += data.count
            return true
        }
        guard admitted else { throw PersistenceError.encodingFailed("Catalog and Undo backing storage exceeds 1 GiB") }
        let url = root.appending(path: UUID().uuidString)
        do {
            try data.write(to: url, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return CatalogComponentFile(url: url, digest: RevisionFingerprint.digest(data), byteCount: data.count, storage: self)
        } catch {
            Self.allocated.withLock { $0 -= data.count }
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { Self.log.error("Could not remove a failed catalog staging file: \(error.localizedDescription)") }
            }
            throw error
        }
    }

    func release(_ byteCount: Int) { Self.allocated.withLock { $0 -= byteCount } }

    deinit {
        do { try FileManager.default.removeItem(at: root) }
        catch { Self.log.error("Could not remove owned catalog backing storage: \(error.localizedDescription)") }
    }
}

final class CatalogComponentFile: Sendable {
    private static let log = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "catalog.storage")
    let url: URL
    let digest: String
    let byteCount: Int
    let storage: CatalogComponentStorage

    init(url: URL, digest: String, byteCount: Int, storage: CatalogComponentStorage) {
        self.url = url
        self.digest = digest
        self.byteCount = byteCount
        self.storage = storage
    }

    func read() throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == byteCount else {
            throw PersistenceError.checksumMismatch
        }
        let data = try Data(contentsOf: url)
        guard data.count == byteCount, RevisionFingerprint.digest(data) == digest else { throw PersistenceError.checksumMismatch }
        return data
    }

    deinit {
        do { try FileManager.default.removeItem(at: url) }
        catch { Self.log.error("Could not remove an owned catalog component: \(error.localizedDescription)") }
        storage.release(byteCount)
    }
}
