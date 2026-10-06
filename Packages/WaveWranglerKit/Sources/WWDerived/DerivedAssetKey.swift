import CryptoKit
import Foundation
import WWCore
import WWDecode
import WWSources
import WWTimeMap

/// One revision of a source as seen by a derived job. `token` changes whenever the source may have changed.
public struct SourceRevision: Sendable, Hashable, Codable {
    public var source: SourceID
    public var token: String

    public init(source: SourceID, token: String) {
        self.source = source
        self.token = token
    }

    /// A metadata-only revision (size, dates, file identifier, volume, type from WWSources' metadata gateway).
    /// Computing it reads no content.
    public static func metadata(_ source: SourceID, fingerprint: FileSystemFingerprint) -> SourceRevision {
        SourceRevision(source: source, token: "metadata:" + CanonicalDigest.hex(of: fingerprint))
    }

    /// A revision pinned to a consent-gated decoded-content digest.
    public static func decodedContent(_ digest: DecodedContentDigest) -> SourceRevision {
        SourceRevision(source: digest.source, token: "decoded-content:" + digest.value)
    }
}

/// Format revision of the decode a job used (M2-C2). Bumping either version invalidates dependent jobs.
public struct FormatRevision: Sendable, Hashable, Codable {
    public var interpretationVersion: Int
    public var envelopeVersion: Int

    public init(interpretationVersion: Int, envelopeVersion: Int) {
        self.interpretationVersion = interpretationVersion
        self.envelopeVersion = envelopeVersion
    }

    public static let current = FormatRevision(
        interpretationVersion: FormatInterpretation.currentVersion,
        envelopeVersion: DecodeEnvelope.version
    )
}

/// What kind of asset and which revision of its own encoding.
public struct AssetSpec: Sendable, Hashable, Codable {
    public var kind: String
    public var revision: Int

    public init(kind: String, revision: Int) {
        self.kind = kind
        self.revision = revision
    }
}

/// The complete M2-C5 invalidation key of one derived result: asset, source, format, epoch, occurrence,
/// channel, map, recipe and upstream revisions. Two results are interchangeable only if their keys are equal;
/// any component change makes a result stale. `digest` (SHA-256 of the canonical encoding) names the cached
/// asset file.
public struct DerivedAssetKey: Sendable, Hashable, Codable {
    public var asset: AssetSpec
    /// Sorted by source ID so equal inputs give equal keys.
    public private(set) var sources: [SourceRevision]
    public var format: FormatRevision?
    public var epoch: RecordingEpochID?
    public var occurrence: SourceOccurrenceID?
    public var channel: Int?
    public var map: MapRevisionReference?
    public var recipe: RecipeReference?
    /// Digests of the keys this result was computed from; sorted and de-duplicated.
    public private(set) var upstream: [String]

    public init(
        asset: AssetSpec,
        sources: [SourceRevision] = [],
        format: FormatRevision? = nil,
        epoch: RecordingEpochID? = nil,
        occurrence: SourceOccurrenceID? = nil,
        channel: Int? = nil,
        map: MapRevisionReference? = nil,
        recipe: RecipeReference? = nil,
        upstream: [DerivedAssetKey] = []
    ) {
        self.asset = asset
        self.sources = sources.sorted { $0.source.description < $1.source.description }
        self.format = format
        self.epoch = epoch
        self.occurrence = occurrence
        self.channel = channel
        self.map = map
        self.recipe = recipe
        self.upstream = Array(Set(upstream.map(\.digest))).sorted()
    }

    public mutating func setSources(_ sources: [SourceRevision]) {
        self.sources = sources.sorted { $0.source.description < $1.source.description }
    }

    public mutating func setUpstream(_ keys: [DerivedAssetKey]) {
        upstream = Array(Set(keys.map(\.digest))).sorted()
    }

    public var digest: String { CanonicalDigest.hex(of: self) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            asset: try c.decode(AssetSpec.self, forKey: .asset),
            format: try c.decodeIfPresent(FormatRevision.self, forKey: .format),
            epoch: try c.decodeIfPresent(RecordingEpochID.self, forKey: .epoch),
            occurrence: try c.decodeIfPresent(SourceOccurrenceID.self, forKey: .occurrence),
            channel: try c.decodeIfPresent(Int.self, forKey: .channel),
            map: try c.decodeIfPresent(MapRevisionReference.self, forKey: .map),
            recipe: try c.decodeIfPresent(RecipeReference.self, forKey: .recipe)
        )
        setSources(try c.decode([SourceRevision].self, forKey: .sources))
        upstream = Array(Set(try c.decode([String].self, forKey: .upstream))).sorted()
    }
}

/// SHA-256 over the canonical (sorted-key) JSON encoding. Used for keys and metadata tokens only; never for
/// source content (see `DecodedContentDigest`).
enum CanonicalDigest {
    static func hex<T: Encodable>(of value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        // Encoding these plain value types cannot fail; a failure would be a programming error.
        let data = try! encoder.encode(value)
        return hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func isDigest(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
