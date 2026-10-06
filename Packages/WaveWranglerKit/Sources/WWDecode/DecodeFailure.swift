import Foundation
import WWSources

/// Why a decode produced no result. Every failure is typed. No failure publishes partial output or
/// touches the original (the gateway is read-only).
public enum DecodeFailure: Error, Sendable, Equatable, Hashable {
    /// The task was cancelled. Nothing was published and every resource was released.
    case cancelled
    case notFound
    case permissionDenied
    /// A directory, package, symbolic link or other non-regular item.
    case notARegularFile
    /// The opened descriptor's access mode was not read-only. The gateway closes it without reading.
    case notOpenedReadOnly
    /// The file system or provider reports the content is not local (dataless, placeholder or still
    /// downloading). The decoder never requests or triggers a download.
    case notMaterialized
    /// Metadata can't establish residency, so the decoder doesn't risk a download.
    case residencyUnknown
    /// Metadata needed to bound the decode (size, modification date, type) was not reported.
    case metadataUnavailable(SourceErrorDescriptor?)
    case emptyFile
    /// The bytes are not a recognisable audio container, or its header is damaged.
    case unreadableContainer(status: Int32)
    /// Decodable in principle, but outside the evidenced envelope (`DecodeEnvelope`).
    case unsupported(UnsupportedReason)
    /// The container header is present but its audio data chunk is not (typically a file cut short
    /// inside its header). Not the same as a valid source with no frames (`emptyFile`).
    case missingAudioData
    /// The container declares more audio bytes than the file holds.
    case truncated(declaredBytes: Int64, availableBytes: Int64)
    /// Decoding ended before the declared number of frames.
    case incompleteContent(expectedFrames: Int64, decodedFrames: Int64)
    /// The container's own declarations disagree.
    case inconsistentStream(InconsistencyReason)
    /// The platform decoder reported an error at the given codec-stream frame.
    case decodeFailed(status: Int32, atStreamFrame: Int64)
    /// A read-only read failed with this `errno`.
    case readFailed(errno: Int32)
    /// The file that was opened isn't the one whose metadata was checked (it was replaced or swapped).
    case sourceIdentityMismatch
    /// Size, modification date or identity changed while decoding; the result would be stale.
    case sourceChangedDuringDecode
    /// The consumer rejected a chunk.
    case sinkFailed(String)

    /// Failures caused by damaged, truncated or self-contradictory content.
    public var isContentDamage: Bool {
        switch self {
        case .unreadableContainer, .missingAudioData, .truncated, .incompleteContent, .inconsistentStream, .decodeFailed: true
        default: false
        }
    }
}

/// Why a readable source is outside the evidenced decode envelope.
public enum UnsupportedReason: Sendable, Equatable, Hashable, Codable {
    /// Container type code (four-character code) outside the envelope.
    case container(String)
    /// Codec (format ID four-character code) not evidenced in this container.
    case codec(container: String, codec: String)
    /// Sample format not evidenced for this codec and container.
    case sampleFormat(String)
    /// Non-integral or non-standard source rate, or a rate not evidenced for this codec.
    case sampleRate(Double)
    case channelCount(Int)
    /// A packetised lossy stream with no packet table. The encoder delay is unknown, so no exact time
    /// origin can be stated.
    case encoderDelayUnknown
    /// The container's declared audio length can't be checked against the file (for example, a WAV
    /// `data` size of 0 or 0xFFFFFFFF, or a CAF data chunk of unknown size), so truncation would be
    /// undetectable.
    case unverifiableContainerLength
    /// Variable frames per packet, which the envelope does not cover.
    case variableFramesPerPacket
}

public enum InconsistencyReason: Sendable, Equatable, Hashable, Codable {
    /// The packet table's valid-frame count disagrees with the length the platform reader reports.
    case packetTableDisagreesWithLength(packetTableFrames: Int64, readerFrames: Int64)
    /// The decoded stream ran past the declared priming + valid + remainder (+ one packet of slack).
    case streamExceedsDeclaredLength(declaredStreamFrames: Int64, observedAtLeast: Int64)
    /// A negative or otherwise impossible declared count.
    case invalidDeclaredCount(String)
    /// The platform reader returned more frames than requested.
    case readerOverran(requested: Int, returned: Int)
}
