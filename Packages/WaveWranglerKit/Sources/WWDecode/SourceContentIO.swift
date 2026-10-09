import Foundation
import WWSources

/// The only gateway allowed to open referenced originals for content (decoding).
///
/// It opens read-only and nothing else. There is no requirement to write, rename, move, copy, trash,
/// delete, truncate or set attributes, so no WWDecode component can do so. `SystemSourceContentIO` is
/// the single production implementation. A source scan (`ForbiddenAPITests` in WWSourcesTests) fails
/// if any other file in WWDecode, or any file in another module, uses a content-opening or decoding API,
/// or if the gateway uses a writing one. WWSources' metadata-only `SourceIO` stays content-free.
///
/// Callers hold the security scope (`SourceAccessContext.withScopedAccess`) and run the metadata
/// preflight before opening. `SourceDecoder` does both.
public protocol SourceContentIO: Sendable {
    /// Opens `url` read-only and reports what the container declares. It reads only header and
    /// container structure; it decodes nothing until `DecodingContentReader.readRawFrames(into:)` is
    /// called.
    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader
}

/// A separate gateway requirement: selected reads cannot silently use an unchecked content opener.
package protocol CheckedSourceContentIO: SourceContentIO {
    func openForDecoding(
        _ url: URL, expectedIdentity: FileSystemFingerprint
    ) throws(DecodeFailure) -> any DecodingContentReader
}

/// One open, read-only decode of one source. A reader belongs to a single task. It is not shared and
/// not `Sendable`.
public protocol DecodingContentReader: AnyObject {
    var facts: EncodedStreamFacts { get }

    /// Decodes the next frames of the **codec stream** (priming and remainder frames are *not* removed)
    /// as 32-bit float planar samples at the source rate, into `buffer` starting at frame 0. Returns the
    /// number of frames written (at most `buffer.capacityFrames`); 0 means end of stream.
    func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int

    /// The opened file's current state (from the open descriptor, not the path), for staleness checks.
    func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState

    /// Releases the file and decoder. Idempotent.
    func close()
}

/// The decoder's reusable planar sample buffer: `channelCount` channels of `capacityFrames` floats each,
/// allocated once per decode. This bounds the decoder's working memory.
public final class RawDecodeBuffer {
    public let channelCount: Int
    public let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>

    public init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0 && capacityFrames > 0)
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit { storage.deallocate() }

    public func channel(_ index: Int) -> UnsafeMutableBufferPointer<Float> {
        precondition(index >= 0 && index < channelCount)
        return UnsafeMutableBufferPointer(start: storage + index * capacityFrames, count: capacityFrames)
    }
}

/// The opened file's state from `fstat` on the open descriptor.
public struct OpenedFileState: Sendable, Equatable, Hashable, Codable {
    public var fileNumber: UInt64
    public var sizeBytes: Int64
    public var modificationSeconds: Int64
    public var modificationNanoseconds: Int64

    public init(fileNumber: UInt64, sizeBytes: Int64, modificationSeconds: Int64, modificationNanoseconds: Int64) {
        self.fileNumber = fileNumber
        self.sizeBytes = sizeBytes
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }
}

/// The packet table (`pakt`) as the container declares it.
public struct PacketTableFacts: Sendable, Equatable, Hashable, Codable {
    public var validFrames: Int64
    public var primingFrames: Int64
    public var remainderFrames: Int64

    public init(validFrames: Int64, primingFrames: Int64, remainderFrames: Int64) {
        self.validFrames = validFrames
        self.primingFrames = primingFrames
        self.remainderFrames = remainderFrames
    }
}

/// Whether the declared audio length fits in the file. Checked from the container's own chunk header.
public enum ContainerLengthEvidence: Sendable, Equatable, Hashable {
    /// No chunk-level check for this container. Truncation is caught as a frame shortfall or a decoder
    /// error instead.
    case notChecked
    case consistent(declaredBytes: Int64)
    case exceedsFile(declaredBytes: Int64, availableBytes: Int64)
    /// A chunked container (WAVE, CAF, AIFF/AIFC) whose audio data chunk wasn't found: the platform
    /// reports data offset 0 and no packets for a file cut inside its header.
    case audioDataChunkMissing
    /// The size field can't be checked (unknown/streaming size, or an unexpected chunk tag).
    case unverifiable(String)
}

/// Channel layout as the container declares it. Labels are `AudioChannelLabel` values in file channel
/// order. Decoded channel `i` is file channel `i`.
public struct ChannelLayoutFacts: Sendable, Equatable, Hashable, Codable {
    public var isDeclaredBySource: Bool
    public var layoutTag: UInt32?
    public var channelBitmap: UInt32?
    public var channelLabels: [UInt32]

    public init(isDeclaredBySource: Bool, layoutTag: UInt32? = nil, channelBitmap: UInt32? = nil, channelLabels: [UInt32] = []) {
        self.isDeclaredBySource = isDeclaredBySource
        self.layoutTag = layoutTag
        self.channelBitmap = channelBitmap
        self.channelLabels = channelLabels
    }

    public static let undeclared = ChannelLayoutFacts(isDeclaredBySource: false)
}

/// What an open source declares, before any interpretation. Field meanings follow
/// `AudioStreamBasicDescription` and the AudioFile properties of the same names.
public struct EncodedStreamFacts: Sendable, Equatable {
    public var containerTypeCode: UInt32
    public var formatID: UInt32
    public var formatFlags: UInt32
    public var sampleRate: Double
    public var bytesPerPacket: UInt32
    public var framesPerPacket: UInt32
    public var bytesPerFrame: UInt32
    public var channelsPerFrame: UInt32
    public var bitsPerChannel: UInt32
    public var packetCount: Int64?
    public var maximumPacketSize: Int64?
    public var audioDataByteCount: Int64?
    public var dataOffset: Int64?
    public var averageBitRate: Int64?
    public var packetTable: PacketTableFacts?
    /// The platform reader's frame length with the container's own priming/remainder applied.
    public var readerLengthFrames: Int64
    public var channelLayout: ChannelLayoutFacts
    public var containerLength: ContainerLengthEvidence
    public var openedFile: OpenedFileState

    public init(
        containerTypeCode: UInt32,
        formatID: UInt32,
        formatFlags: UInt32,
        sampleRate: Double,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32,
        packetCount: Int64? = nil,
        maximumPacketSize: Int64? = nil,
        audioDataByteCount: Int64? = nil,
        dataOffset: Int64? = nil,
        averageBitRate: Int64? = nil,
        packetTable: PacketTableFacts? = nil,
        readerLengthFrames: Int64,
        channelLayout: ChannelLayoutFacts = .undeclared,
        containerLength: ContainerLengthEvidence = .notChecked,
        openedFile: OpenedFileState
    ) {
        self.containerTypeCode = containerTypeCode
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.sampleRate = sampleRate
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
        self.packetCount = packetCount
        self.maximumPacketSize = maximumPacketSize
        self.audioDataByteCount = audioDataByteCount
        self.dataOffset = dataOffset
        self.averageBitRate = averageBitRate
        self.packetTable = packetTable
        self.readerLengthFrames = readerLengthFrames
        self.channelLayout = channelLayout
        self.containerLength = containerLength
        self.openedFile = openedFile
    }
}

/// Four-character codes as printable strings (hex when not printable ASCII).
public enum FourCharacterCode {
    public static func string(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(format: "0x%08X", code)
    }

    public static func code(_ text: String) -> UInt32 {
        precondition(text.utf8.count == 4)
        return text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
