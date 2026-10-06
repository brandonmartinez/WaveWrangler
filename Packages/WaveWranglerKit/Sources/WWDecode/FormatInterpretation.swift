import Foundation
import WWCore
import WWSources

/// How WaveWrangler interpreted one source's encoded audio, and exactly how decoded frames map to source
/// frames. The descriptor is a plain value, so later units (derived assets, time mapping) can key on it.
/// They should key on `source`, `formatInterpretationVersion`, `envelopeVersion` and `sourceFingerprint`.
///
/// **Bump `currentVersion`** whenever a field is added, removed or renamed, or the meaning of any field
/// or of the decoded output changes (for example, priming handling or channel order).
/// `FormatInterpretationSchemaTests` pins the encoded field set to the version.
public struct FormatInterpretation: Sendable, Codable, Hashable {
    public static let currentVersion = 1

    public var formatInterpretationVersion: Int
    public var envelopeVersion: Int
    public var container: ContainerFacts
    public var codec: CodecFacts
    /// The source's own rate, F, in whole hertz. Non-integral rates are outside the envelope.
    public var sourceSampleRate: Int
    public var sampleFormat: SourceSampleFormat
    public var channelCount: Int
    public var channelLayout: ChannelLayoutFacts
    public var frames: FrameAccounting
    public var packets: PacketFacts
    public var output: DecodedOutputFormat
    public var origin: DecodedFrameOrigin
    /// The logical source this descriptor belongs to (the caller's `SourceRecord.id`). The URL that was
    /// opened is a location hint and is not recorded; only its extension is, as `container.fileExtension`.
    public var source: SourceID
    /// Metadata observed (via WWSources' metadata gateway) immediately before decoding.
    public var sourceFingerprint: FileSystemFingerprint

    public init(
        formatInterpretationVersion: Int = FormatInterpretation.currentVersion,
        envelopeVersion: Int,
        container: ContainerFacts,
        codec: CodecFacts,
        sourceSampleRate: Int,
        sampleFormat: SourceSampleFormat,
        channelCount: Int,
        channelLayout: ChannelLayoutFacts,
        frames: FrameAccounting,
        packets: PacketFacts,
        output: DecodedOutputFormat,
        origin: DecodedFrameOrigin,
        source: SourceID,
        sourceFingerprint: FileSystemFingerprint
    ) {
        self.formatInterpretationVersion = formatInterpretationVersion
        self.envelopeVersion = envelopeVersion
        self.container = container
        self.codec = codec
        self.sourceSampleRate = sourceSampleRate
        self.sampleFormat = sampleFormat
        self.channelCount = channelCount
        self.channelLayout = channelLayout
        self.frames = frames
        self.packets = packets
        self.output = output
        self.origin = origin
        self.source = source
        self.sourceFingerprint = sourceFingerprint
    }
}

public enum ContainerKind: String, Sendable, Codable, CaseIterable {
    case wave, aiff, aifc, caf, m4a, flac

    /// AudioFile type code.
    public var typeCode: String {
        switch self {
        case .wave: "WAVE"
        case .aiff: "AIFF"
        case .aifc: "AIFC"
        case .caf: "caff"
        case .m4a: "m4af"
        case .flac: "flac"
        }
    }

    /// File extensions conventionally used for this container (lower case).
    public var conventionalExtensions: Set<String> {
        switch self {
        case .wave: ["wav", "wave", "bwf"]
        case .aiff: ["aif", "aiff"]
        case .aifc: ["aifc", "aif", "aiff"]
        case .caf: ["caf"]
        case .m4a: ["m4a", "mp4", "m4b"]
        case .flac: ["flac"]
        }
    }
}

public enum CodecKind: String, Sendable, Codable, CaseIterable {
    case linearPCM, aac, appleLossless, flac, opus

    /// AudioFormat ID.
    public var formatID: String {
        switch self {
        case .linearPCM: "lpcm"
        case .aac: "aac "
        case .appleLossless: "alac"
        case .flac: "flac"
        case .opus: "opus"
        }
    }

    public var isLossy: Bool { self == .aac || self == .opus }
}

public struct ContainerFacts: Sendable, Codable, Hashable {
    public var kind: ContainerKind
    /// Identified from the bytes, never from the name.
    public var typeCode: String
    public var fileExtension: String
    /// False when the name's extension isn't conventional for the container that was found. The
    /// content still decodes as what it is; the mismatch is recorded, not corrected.
    public var extensionMatchesContainer: Bool

    public init(kind: ContainerKind, typeCode: String, fileExtension: String, extensionMatchesContainer: Bool) {
        self.kind = kind
        self.typeCode = typeCode
        self.fileExtension = fileExtension
        self.extensionMatchesContainer = extensionMatchesContainer
    }
}

public struct CodecFacts: Sendable, Codable, Hashable {
    public var kind: CodecKind
    public var formatID: String
    public var formatFlags: UInt32

    public init(kind: CodecKind, formatID: String, formatFlags: UInt32) {
        self.kind = kind
        self.formatID = formatID
        self.formatFlags = formatFlags
    }
}

public enum SampleEncoding: String, Sendable, Codable, CaseIterable {
    case signedInteger, floatingPoint, lossless, lossy
}

public struct SourceSampleFormat: Sendable, Codable, Hashable, CustomStringConvertible {
    public var encoding: SampleEncoding
    /// PCM bits per sample, or a lossless codec's declared source bit depth; `nil` for lossy codecs.
    public var bitsPerSample: Int?
    /// PCM byte order; `nil` for compressed codecs.
    public var isBigEndian: Bool?

    public init(encoding: SampleEncoding, bitsPerSample: Int?, isBigEndian: Bool?) {
        self.encoding = encoding
        self.bitsPerSample = bitsPerSample
        self.isBigEndian = isBigEndian
    }

    public static func int(_ bits: Int, bigEndian: Bool) -> Self { Self(encoding: .signedInteger, bitsPerSample: bits, isBigEndian: bigEndian) }
    public static func float(_ bits: Int, bigEndian: Bool) -> Self { Self(encoding: .floatingPoint, bitsPerSample: bits, isBigEndian: bigEndian) }
    public static func lossless(_ bits: Int) -> Self { Self(encoding: .lossless, bitsPerSample: bits, isBigEndian: nil) }
    public static let lossy = Self(encoding: .lossy, bitsPerSample: nil, isBigEndian: nil)

    public var description: String {
        let bits = bitsPerSample.map { "\($0)" } ?? ""
        let order = isBigEndian.map { $0 ? "BE" : "LE" } ?? ""
        return [encoding.rawValue + bits, order].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether 32-bit float output holds every source sample value exactly.
    public var isExactInFloat32: Bool {
        switch encoding {
        case .signedInteger, .lossless: (bitsPerSample ?? 99) <= 24
        case .floatingPoint: bitsPerSample == 32
        case .lossy: false
        }
    }
}

/// Frame counts as the container declares them. `validFrames` is the source's length.
public struct FrameAccounting: Sendable, Codable, Hashable {
    public var validFrames: Int64
    /// Encoder delay at the start of the codec stream (removed before publication).
    public var primingFrames: Int64
    /// Padding at the end of the codec stream (removed before publication).
    public var remainderFrames: Int64
    public var hasPacketTable: Bool

    public init(validFrames: Int64, primingFrames: Int64, remainderFrames: Int64, hasPacketTable: Bool) {
        self.validFrames = validFrames
        self.primingFrames = primingFrames
        self.remainderFrames = remainderFrames
        self.hasPacketTable = hasPacketTable
    }
}

public struct PacketFacts: Sendable, Codable, Hashable {
    public var framesPerPacket: Int
    /// 0 means packets vary in size (variable bit rate).
    public var bytesPerPacket: Int
    public var packetCount: Int64?
    public var maximumPacketSize: Int64?
    public var averageBitRate: Int64?
    public var isVariableBitRate: Bool

    public init(framesPerPacket: Int, bytesPerPacket: Int, packetCount: Int64?, maximumPacketSize: Int64?, averageBitRate: Int64?, isVariableBitRate: Bool) {
        self.framesPerPacket = framesPerPacket
        self.bytesPerPacket = bytesPerPacket
        self.packetCount = packetCount
        self.maximumPacketSize = maximumPacketSize
        self.averageBitRate = averageBitRate
        self.isVariableBitRate = isVariableBitRate
    }
}

/// What the decoder publishes: 32-bit float, planar, at the source rate (no resampling), channels in
/// file order (decoded channel `i` is file channel `i`; see `ChannelLayoutFacts.channelLabels`).
public struct DecodedOutputFormat: Sendable, Codable, Hashable {
    public var sampleType: String
    public var isPlanar: Bool
    public var sampleRate: Int
    public var channelCount: Int
    public var channelOrder: String
    /// False for 32-bit integer, 64-bit float and lossy sources.
    public var representsSourceSamplesExactly: Bool

    public init(sampleRate: Int, channelCount: Int, representsSourceSamplesExactly: Bool) {
        sampleType = "float32"
        isPlanar = true
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        channelOrder = "file"
        self.representsSourceSamplesExactly = representsSourceSamplesExactly
    }
}

/// A position on a source's own clock: frame `frame` at rate `sampleRate` (time `frame / sampleRate`).
public struct SourceFramePosition: Sendable, Codable, Hashable {
    public var frame: Int64
    public var sampleRate: Int

    public init(frame: Int64, sampleRate: Int) {
        self.frame = frame
        self.sampleRate = sampleRate
    }

    public var seconds: Double { Double(frame) / Double(sampleRate) }
}

/// The exact mapping from decoded output frames to source frames.
///
/// Source frame `n` is the `n`th frame the source presents to a listener: the first frame after the
/// encoder's priming. Its source time is `n / F`. Decoded frame `d` is source frame `d`
/// (`sourceFrameOfFirstDecodedFrame` is 0). Codec-stream frame `d + discardedLeadingStreamFrames`
/// produced it.
public struct DecodedFrameOrigin: Sendable, Codable, Hashable {
    public var sourceSampleRate: Int
    public var decodedFrameCount: Int64
    public var sourceFrameOfFirstDecodedFrame: Int64
    /// Codec-stream frames discarded before decoded frame 0 (the declared priming).
    public var discardedLeadingStreamFrames: Int64
    /// Codec-stream frames declared after the last valid frame (the declared remainder).
    public var declaredTrailingStreamFrames: Int64

    public init(sourceSampleRate: Int, decodedFrameCount: Int64, discardedLeadingStreamFrames: Int64, declaredTrailingStreamFrames: Int64) {
        self.sourceSampleRate = sourceSampleRate
        self.decodedFrameCount = decodedFrameCount
        sourceFrameOfFirstDecodedFrame = 0
        self.discardedLeadingStreamFrames = discardedLeadingStreamFrames
        self.declaredTrailingStreamFrames = declaredTrailingStreamFrames
    }

    public func sourceFrame(forDecodedFrame decoded: Int64) -> Int64? {
        guard decoded >= 0, decoded < decodedFrameCount else { return nil }
        return sourceFrameOfFirstDecodedFrame + decoded
    }

    public func decodedFrame(forSourceFrame source: Int64) -> Int64? {
        let decoded = source - sourceFrameOfFirstDecodedFrame
        guard decoded >= 0, decoded < decodedFrameCount else { return nil }
        return decoded
    }

    public func codecStreamFrame(forDecodedFrame decoded: Int64) -> Int64? {
        guard decoded >= 0, decoded < decodedFrameCount else { return nil }
        return discardedLeadingStreamFrames + decoded
    }

    public func sourcePosition(forDecodedFrame decoded: Int64) -> SourceFramePosition? {
        sourceFrame(forDecodedFrame: decoded).map { SourceFramePosition(frame: $0, sampleRate: sourceSampleRate) }
    }

    /// The source's duration: the position one frame past its last frame.
    public var sourceDuration: SourceFramePosition {
        SourceFramePosition(frame: sourceFrameOfFirstDecodedFrame + decodedFrameCount, sampleRate: sourceSampleRate)
    }
}
