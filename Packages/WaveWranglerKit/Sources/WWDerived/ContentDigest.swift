import CryptoKit
import Foundation
import WWCore
import WWDecode
import WWSources

/// Proof that the user explicitly asked for content work on one source (e.g. "Align this source"). Content
/// digests are never computed for metadata-only work, imports, relinks, availability refreshes or background
/// passes — those have no authorization to pass.
public struct ContentWorkAuthorization: Sendable, Equatable {
    public let source: SourceID

    private init(source: SourceID) { self.source = source }

    public static func explicitUserRequest(for source: SourceID) -> ContentWorkAuthorization {
        ContentWorkAuthorization(source: source)
    }
}

/// A SHA-256 over a source's *decoded* audio under one format interpretation: channel count, sample rate,
/// frame count and every decoded sample (interleaved, IEEE-754 little-endian). It identifies decoded content
/// for derived-asset keys; it is not a hash of the file's bytes and makes no claim about container metadata.
public struct DecodedContentDigest: Sendable, Codable, Hashable {
    public var source: SourceID
    /// `decoded-pcm-sha256:<64 hex>`.
    public var value: String
    public var format: FormatRevision
    public var frameCount: Int64

    public static let scheme = "decoded-pcm-sha256:"
}

public enum ContentDigestRefusal: Error, Sendable, Equatable {
    /// No explicit user request for this source.
    case notExplicitlyRequested
    /// Source availability is OFF: no content, hash or decode requests. The user must make the source
    /// available first (an explicit, separately labelled transfer).
    case sourceAvailabilityOff
    /// The decoder refused or failed (not local/materialized, unsupported envelope, changed, cancelled…).
    case decode(DecodeFailure)
}

/// Computes `DecodedContentDigest`s through the single read-only content gateway (`SourceDecoder`). It never
/// requests downloads; a non-local, dataless or residency-unknown source is refused by the decoder's
/// metadata preflight before anything is opened.
public struct DecodedContentDigester: Sendable {
    let decoder: SourceDecoder

    public init(access: SourceAccessContext) {
        decoder = SourceDecoder(access: access)
    }

    package init(decoder: SourceDecoder) {
        self.decoder = decoder
    }

    public func digest(
        source: SourceID,
        at location: URL,
        authorization: ContentWorkAuthorization?,
        availability: SourceAvailabilitySetting
    ) async throws(ContentDigestRefusal) -> DecodedContentDigest {
        guard let authorization, authorization.source == source else { throw .notExplicitlyRequested }
        guard availability == .on else { throw .sourceAvailabilityOff }
        let decoded: DecodedSource<HashingSink.Digest>
        do {
            decoded = try await decoder.decode(location, source: source) { interpretation in
                HashingSink(channelCount: interpretation.channelCount, sampleRate: interpretation.sourceSampleRate)
            }
        } catch {
            throw .decode(error)
        }
        return DecodedContentDigest(
            source: source,
            value: DecodedContentDigest.scheme + decoded.product.hex,
            format: FormatRevision(
                interpretationVersion: decoded.interpretation.formatInterpretationVersion,
                envelopeVersion: decoded.interpretation.envelopeVersion
            ),
            frameCount: decoded.product.frames
        )
    }
}

/// Hashes decoded frames independently of chunk boundaries.
struct HashingSink: DecodedAudioSink {
    struct Digest: Sendable {
        var hex: String
        var frames: Int64
    }

    struct ChannelMismatch: Error {}

    private var hasher = SHA256()
    private let channelCount: Int
    private let sampleRate: Int
    private var frames: Int64 = 0

    init(channelCount: Int, sampleRate: Int) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        hasher.update(data: Data("WWDecodedPCM1".utf8))
        Self.update(&hasher, Int64(channelCount))
        Self.update(&hasher, Int64(sampleRate))
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        guard chunk.channelCount == channelCount else { throw ChannelMismatch() }
        var interleaved = [UInt32]()
        interleaved.reserveCapacity(chunk.samples.count)
        for frame in 0..<chunk.frameCount {
            for channel in 0..<channelCount {
                interleaved.append(chunk.samples[channel * chunk.frameCount + frame].bitPattern.littleEndian)
            }
        }
        interleaved.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        frames += Int64(chunk.frameCount)
    }

    mutating func finish() throws -> Digest {
        Self.update(&hasher, frames)
        return Digest(hex: hasher.finalize().map { String(format: "%02x", $0) }.joined(), frames: frames)
    }

    private static func update(_ hasher: inout SHA256, _ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
    }
}
