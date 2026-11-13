import Compression
import CryptoKit
import Darwin
import Foundation
import WWCore

/// Package storage is independent of the domain schema. The framed snapshot is used only by the
/// existing publication/recovery protocol; its digest covers every stored byte, not just the model.
public enum ShowPackage {
    public static let manifestName = "Manifest.json"
    public static let componentsName = "Components"
    public static let version = 2
    public static let typeIdentifier = "com.brandonmartinez.wavewrangler.show-package"
    private static let identifier = typeIdentifier
    private static let magic = Data("WWPKG001".utf8)
    private static let componentLimit = 64 * 1_024 * 1_024
    private static let snapshotLimit = 512 * 1_024 * 1_024
    private static let entryLimit = 20_002

    struct Header: Codable {
        var format: String
        var schemaVersion: Int
        var modelSchemaVersion: Int
    }

    struct Component: Codable, Sendable, Equatable {
        var digest: String
        var byteCount: Int
        var encoding: String
    }

    private struct EpisodeEntry: Codable {
        var id: EpisodeID
        var content: Component
        var artwork: Component?
    }

    private struct Manifest: Codable {
        var format = identifier
        var schemaVersion = 1
        var modelSchemaVersion = SchemaVersion.show
        var revision: Int
        var publicationID: UUID
        var checksum: String
        var catalog: Component
        var artwork: Component?
        var episodes: [EpisodeEntry]
    }

    struct Snapshot {
        var manifest: Data
        var files: [String: Data]
    }

    public static func isSnapshot(_ data: Data) -> Bool { data.starts(with: magic) }

    /// Reads the frozen version header before any component or version-specific manifest fields.
    static func checkHeader(_ data: Data) throws {
        try StrictJSON.validate(data)
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == identifier else {
            throw PersistenceError.formatMismatch(expected: identifier, found: header.format)
        }
        guard header.schemaVersion <= version else {
            throw PersistenceError.unknownNewerSchema(found: header.schemaVersion, supported: version)
        }
        guard header.modelSchemaVersion <= SchemaVersion.show else {
            throw PersistenceError.unknownNewerSchema(found: header.modelSchemaVersion, supported: SchemaVersion.show)
        }
        guard (1...version).contains(header.schemaVersion), header.modelSchemaVersion == SchemaVersion.show else {
            throw PersistenceError.malformed("Unsupported package version")
        }
    }

    static func encode(_ document: DecodedDocument<ShowDocumentModel>) throws -> Data {
        guard document.payload.episodes.count <= 10_000 else {
            throw PersistenceError.encodingFailed("Package exceeds 10,000 episodes")
        }
        var remaining = snapshotLimit
        func consume(_ reference: Component?) throws {
            guard let reference else { return }
            guard reference.byteCount <= remaining else {
                throw PersistenceError.encodingFailed("Package expanded content exceeds 512 MiB")
            }
            remaining -= reference.byteCount
        }
        var files: [String: Data] = [:]
        var catalog = document.payload
        let showArtwork = try detachArtwork(&catalog.show.publication, files: &files)
        try consume(showArtwork)
        var entries: [EpisodeEntry] = []
        for var episode in catalog.episodes {
            var metadata = episode.publication?.metadata
            let artwork = try detachArtwork(&metadata, files: &files)
            if let metadata { episode.publication?.metadata = metadata }
            let content = try component(JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(episode), files: &files)
            try consume(content)
            try consume(artwork)
            entries.append(EpisodeEntry(id: episode.id, content: content, artwork: artwork))
        }
        catalog.episodes = []
        let content = try component(JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(catalog), files: &files)
        try consume(content)
        let manifest = Manifest(revision: document.revision, publicationID: document.publication.publicationID,
            checksum: document.publication.checksum, catalog: content,
            artwork: showArtwork, episodes: entries)
        return try frame(Snapshot(manifest: JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(manifest), files: files))
    }

    static func detachArtwork(_ metadata: inout PublicationMetadata?, files: inout [String: Data]) throws -> Component? {
        guard let artwork = metadata?.artwork?.image else { return nil }
        metadata?.artwork = nil
        return try component(artwork.data, compress: false, files: &files)
    }

    static func component(_ data: Data, compress: Bool = true, files: inout [String: Data]) throws -> Component {
        guard data.count <= componentLimit else { throw PersistenceError.encodingFailed("Package component exceeds 64 MiB") }
        var stored = data
        var encoding = "raw"
        if compress, data.count >= 1_024 {
            var buffer = Data(count: data.count)
            let count = buffer.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
                }
            }
            if count > 0, count < data.count {
                stored = buffer.prefix(count)
                encoding = "lzfse"
            }
        }
        let digest = RevisionFingerprint.digest(stored)
        files[digest] = stored
        return Component(digest: digest, byteCount: data.count, encoding: encoding)
    }

    static func decode(_ data: Data) throws -> DecodedDocument<ShowDocumentModel> {
        if try storageVersion(of: data) == 2 {
            let document = try ShowCatalogCoder().decode(data)
            return DecodedDocument(payload: try document.payload.materializedModel(), publication: document.publication)
        }
        let snapshot = try unframe(data)
        try checkHeader(snapshot.manifest)
        let decoder = JSONEnvelopeCoder<ShowDocumentModel>.makeDecoder()
        let manifest = try decoder.decode(Manifest.self, from: snapshot.manifest)
        try requireRecognized(snapshot.manifest, value: manifest)
        guard manifest.episodes.count <= 10_000,
              Set(manifest.episodes.map(\.id)).count == manifest.episodes.count else {
            throw PersistenceError.malformed("Invalid package episode index")
        }
        var used: Set<String> = []
        var remaining = snapshotLimit
        var model = try decodeComponent(ShowDocumentModel.self, manifest.catalog, snapshot: snapshot, used: &used, remaining: &remaining)
        guard model.episodes.isEmpty else { throw PersistenceError.malformed("Catalog contains embedded episodes") }
        if let reference = manifest.artwork {
            guard model.show.publication != nil, model.show.publication?.artwork == nil else {
                throw PersistenceError.malformed("Invalid show artwork reference")
            }
            model.show.publication?.artwork = .image(try PublicationArtwork(data: bytes(reference, snapshot: snapshot, used: &used, remaining: &remaining)))
        }
        for entry in manifest.episodes {
            var episode = try decodeComponent(Episode.self, entry.content, snapshot: snapshot, used: &used, remaining: &remaining)
            guard episode.id == entry.id else { throw PersistenceError.malformed("Package episode identity mismatch") }
            if let reference = entry.artwork {
                guard episode.publication != nil, episode.publication?.metadata.artwork == nil else {
                    throw PersistenceError.malformed("Invalid episode artwork reference")
                }
                episode.publication?.metadata.artwork = .image(try PublicationArtwork(data: bytes(reference, snapshot: snapshot, used: &used, remaining: &remaining)))
            }
            model.episodes.append(episode)
        }
        guard used == Set(snapshot.files.keys) else { throw PersistenceError.unrecognizedContent }
        if let newer = model.newerEmbeddedTimeMapSchema() {
            throw PersistenceError.unknownNewerSchema(found: newer.found, supported: newer.supported)
        }
        guard manifest.revision >= 1 else { throw PersistenceError.invalidRevision(manifest.revision) }
        guard try canonicalChecksum(model) == manifest.checksum else { throw PersistenceError.checksumMismatch }
        let issues = model.validationIssues() + model.embeddedMapIssues()
        guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
        return DecodedDocument(payload: model, publication: PublicationStamp(revision: manifest.revision,
            publicationID: manifest.publicationID, checksum: manifest.checksum))
    }

    /// Match the legacy canonical payload without retaining a whole-catalog JSON allocation.
    static func canonicalChecksum(_ model: ShowDocumentModel) throws -> String {
        var hash = SHA256()
        let encoder = JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder()
        func append(_ bytes: Data) { hash.update(data: bytes) }
        append(Data("{\"episodes\":[".utf8))
        for (index, episode) in model.episodes.enumerated() {
            if index > 0 { append(Data([44])) }
            try autoreleasepool { append(try encoder.encode(episode)) }
        }
        append(Data("],\"history\":".utf8))
        append(try encoder.encode(model.history))
        append(Data(",\"schemaVersion\":".utf8))
        append(try encoder.encode(model.schemaVersion))
        append(Data(",\"show\":".utf8))
        append(try encoder.encode(model.show))
        append(Data(",\"speakers\":".utf8))
        append(try encoder.encode(model.speakers))
        append(Data([125]))
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func decodeComponent<T: Codable>(_ type: T.Type, _ reference: Component,
        snapshot: Snapshot, used: inout Set<String>, remaining: inout Int) throws -> T {
        let data = try bytes(reference, snapshot: snapshot, used: &used, remaining: &remaining)
        try StrictJSON.validate(data)
        let value = try JSONEnvelopeCoder<ShowDocumentModel>.makeDecoder().decode(type, from: data)
        try requireRecognized(data, value: value)
        return value
    }

    static func requireRecognized<T: Encodable>(_ data: Data, value: T) throws {
        let decoder = JSONDecoder()
        let encoded = try JSONEnvelopeCoder<ShowDocumentModel>.makeEncoder().encode(value)
        guard try decoder.decode(JSONValue.self, from: data) == decoder.decode(JSONValue.self, from: encoded) else {
            throw PersistenceError.unrecognizedContent
        }
    }

    static func bytes(_ reference: Component, snapshot: Snapshot, used: inout Set<String>, remaining: inout Int) throws -> Data {
        guard (0...componentLimit).contains(reference.byteCount),
              reference.byteCount <= remaining,
              let stored = snapshot.files[reference.digest],
              RevisionFingerprint.digest(stored) == reference.digest else { throw PersistenceError.checksumMismatch }
        remaining -= reference.byteCount
        used.insert(reference.digest)
        switch reference.encoding {
        case "raw":
            guard stored.count == reference.byteCount else { throw PersistenceError.checksumMismatch }
            return stored
        case "lzfse":
            guard !stored.isEmpty, reference.byteCount > 0 else {
                throw PersistenceError.malformed("Empty compressed package component")
            }
            // One extra byte detects streams expanding past the declared size without an unbounded allocation.
            var decoded = Data(count: reference.byteCount + 1)
            let count = decoded.withUnsafeMutableBytes { destination in
                stored.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == reference.byteCount else { throw PersistenceError.malformed("Invalid compressed package component") }
            return decoded.prefix(count)
        default: throw PersistenceError.unrecognizedContent
        }
    }

    /// Snapshot header inspection is metadata only; it does not decode components or validate payloads.
    static func envelopeHeader(_ data: Data) -> Data? {
        guard isSnapshot(data), data.count >= 16 else { return nil }
        let size = data[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard size <= UInt64(componentLimit), size <= UInt64(data.count - 16) else { return nil }
        return data.subdata(in: 16..<(16 + Int(size)))
    }

    public static func storageVersion(of data: Data) throws -> Int? {
        guard isSnapshot(data) else { return nil }
        guard let header = envelopeHeader(data) else { throw PersistenceError.malformed("Invalid package snapshot") }
        try checkHeader(header)
        return try JSONDecoder().decode(Header.self, from: header).schemaVersion
    }

    static func frame(_ snapshot: Snapshot) throws -> Data {
        guard snapshot.manifest.count <= componentLimit, snapshot.files.count <= entryLimit else {
            throw PersistenceError.malformed("Package exceeds storage limits")
        }
        var data = magic
        appendLength(snapshot.manifest.count, to: &data)
        data.append(snapshot.manifest)
        appendLength(snapshot.files.count, to: &data)
        for name in snapshot.files.keys.sorted() {
            guard validName(name), let bytes = snapshot.files[name], bytes.count <= componentLimit,
                  data.count <= snapshotLimit - bytes.count - 72 else {
                throw PersistenceError.malformed("Package exceeds storage limits")
            }
            data.append(Data(name.utf8))
            appendLength(bytes.count, to: &data)
            data.append(bytes)
        }
        return data
    }

    private static func appendLength(_ count: Int, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: UInt64(count) >> shift)) }
    }

    static func unframe(_ data: Data) throws -> Snapshot {
        guard data.count <= snapshotLimit, let manifest = envelopeHeader(data) else {
            throw PersistenceError.malformed("Invalid package snapshot")
        }
        try checkHeader(manifest)
        var offset = 16 + manifest.count
        func length() throws -> Int {
            guard offset <= data.count - 8 else { throw PersistenceError.malformed("Truncated package snapshot") }
            let value = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            offset += 8
            guard value <= UInt64(snapshotLimit) else { throw PersistenceError.malformed("Oversized package entry") }
            return Int(value)
        }
        let count = try length()
        guard count <= entryLimit else { throw PersistenceError.malformed("Too many package entries") }
        var files: [String: Data] = [:]
        var previous = ""
        for _ in 0..<count {
            guard offset <= data.count - 64 else { throw PersistenceError.malformed("Truncated package name") }
            let name = String(decoding: data[offset..<(offset + 64)], as: UTF8.self)
            offset += 64
            let size = try length()
            guard validName(name), name > previous, size <= componentLimit, size <= data.count - offset else {
                throw PersistenceError.malformed("Invalid package entry")
            }
            files[name] = data.subdata(in: offset..<(offset + size))
            offset += size
            previous = name
        }
        guard offset == data.count else { throw PersistenceError.unrecognizedContent }
        return Snapshot(manifest: manifest, files: files)
    }

    private static func validName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The caller coordinates access to the package root. Refuse links and unrecognized children.
    public static func read(from url: URL) throws -> Data {
        let root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError.current() }
        defer { close(root) }
        let manifest = try readRegular(manifestName, in: root, limit: componentLimit)
        do { try checkHeader(manifest) }
        catch PersistenceError.unknownNewerSchema {
            // Return enough evidence for the opener's refusal, without reading any newer payload.
            return try frame(Snapshot(manifest: manifest, files: [:]))
        }
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard Set(rootNames) == [manifestName, componentsName] else { throw PersistenceError.unrecognizedContent }
        let directory = url.appending(path: componentsName)
        let components = openat(root, componentsName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard components >= 0 else { throw POSIXError.current() }
        defer { close(components) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= entryLimit else { throw PersistenceError.malformed("Too many package components") }
        var files: [String: Data] = [:]
        var total = manifest.count
        for name in names {
            guard validName(name) else { throw PersistenceError.unrecognizedContent }
            let bytes = try readRegular(name, in: components, limit: min(componentLimit, snapshotLimit - total))
            total += bytes.count
            files[name] = bytes
        }
        return try frame(Snapshot(manifest: manifest, files: files))
    }

    private static func readRegular(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError.current() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0, metadata.st_size <= limit else {
            throw PersistenceError.malformed("Invalid or oversized package file")
        }
        let size = Int(metadata.st_size)
        var data = Data(count: size + 1)
        let count = try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        guard count == size else { throw PersistenceError.malformed("Package file changed while reading") }
        return data.prefix(count)
    }

    /// Reuse unchanged children so AppKit can preserve unmodified component wrappers on safe saves.
    public static func fileWrapper(for data: Data, reusing prior: FileWrapper? = nil) throws -> FileWrapper {
        let snapshot = try unframe(data)
        func file(_ bytes: Data, old: FileWrapper?) -> FileWrapper {
            if old?.regularFileContents == bytes { return old! }
            return FileWrapper(regularFileWithContents: bytes)
        }
        let old = prior?.fileWrappers
        let oldComponents = old?[componentsName]?.fileWrappers
        var reused: [String: FileWrapper] = [:]
        for (name, bytes) in snapshot.files { reused[name] = file(bytes, old: oldComponents?[name]) }
        return FileWrapper(directoryWithFileWrappers: [
            manifestName: file(snapshot.manifest, old: old?[manifestName]),
            componentsName: FileWrapper(directoryWithFileWrappers: reused),
        ])
    }

    static func writeNew(_ data: Data, to url: URL, ops: LocalFileOperations) throws {
        let snapshot = try unframe(data)
        guard !ops.exists(url) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try ops.writeNew(snapshot.manifest, to: url.appending(path: manifestName))
        let directory = url.appending(path: componentsName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (name, bytes) in snapshot.files { try ops.writeNew(bytes, to: directory.appending(path: name)) }
        for folder in [directory, url] {
            let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError.current() }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw POSIXError.current() }
        }
    }
}

/// Writes packages; reads packages and all still-supported legacy envelopes. No migration is implicit.
public struct ShowPackageCoder: CanonicalDocumentCoding {
    public let format = DocumentFormat.show
    public init() {}

    public func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<ShowDocumentModel> {
        try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(data)
    }

    public func encodeDocument(_ payload: ShowDocumentModel, revision: Int, publicationID: UUID) throws(PersistenceError) -> EncodedDocument {
        do {
            guard revision >= 1 else { throw PersistenceError.invalidRevision(revision) }
            let issues = payload.validationIssues() + payload.embeddedMapIssues()
            guard issues.isEmpty else { throw PersistenceError.invalidPayload(issues) }
            let publication = PublicationStamp(revision: revision, publicationID: publicationID,
                checksum: try ShowPackage.canonicalChecksum(payload))
            let data = try ShowPackage.encode(DecodedDocument(payload: payload, publication: publication))
            return EncodedDocument(data: data, publication: publication)
        } catch let error as PersistenceError { throw error }
        catch { throw .encodingFailed(error.localizedDescription) }
    }
}
