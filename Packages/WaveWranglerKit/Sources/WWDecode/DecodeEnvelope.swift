import Foundation
import WWCore
import WWSources

/// The evidenced decode envelope: the only container, codec, sample-format, rate and channel-count
/// combinations WWDecode accepts. Anything else fails with `DecodeFailure.unsupported`, even when the
/// platform could decode it. An entry belongs here only when `DecodeEnvelopeTests` exercises every
/// combination it claims, with planted landmarks, on generated fixtures.
///
/// **Bump `version`** whenever an entry is added, removed or narrowed.
public enum DecodeEnvelope {
    public static let version = 1

    public static let standardSampleRates = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
    /// Rates the platform AAC encoder produces (it has no encoder above 48 kHz).
    public static let aacSampleRates = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000]
    public static let opusSampleRates = [8000, 16000, 24000, 48000]

    public struct Entry: Sendable, Hashable {
        public var container: ContainerKind
        public var codec: CodecKind
        public var sampleFormats: [SourceSampleFormat]
        public var sampleRates: [Int]
        public var channelCounts: [Int]
    }

    public static let entries: [Entry] = {
        let pcmChannels = Array(1...8)
        let codedChannels = [1, 2, 6, 8]
        return [
            Entry(container: .wave, codec: .linearPCM, sampleFormats: [.int(16, bigEndian: false), .int(24, bigEndian: false), .int(32, bigEndian: false), .float(32, bigEndian: false), .float(64, bigEndian: false)], sampleRates: standardSampleRates, channelCounts: pcmChannels),
            Entry(container: .aiff, codec: .linearPCM, sampleFormats: [.int(16, bigEndian: true), .int(24, bigEndian: true), .int(32, bigEndian: true)], sampleRates: standardSampleRates, channelCounts: pcmChannels),
            Entry(container: .aifc, codec: .linearPCM, sampleFormats: [.int(16, bigEndian: true), .int(24, bigEndian: true), .int(32, bigEndian: true), .float(32, bigEndian: true), .float(64, bigEndian: true)], sampleRates: standardSampleRates, channelCounts: pcmChannels),
            Entry(container: .caf, codec: .linearPCM, sampleFormats: [.int(16, bigEndian: false), .int(24, bigEndian: false), .int(32, bigEndian: false), .float(32, bigEndian: false), .float(64, bigEndian: false), .int(16, bigEndian: true), .int(24, bigEndian: true), .float(32, bigEndian: true)], sampleRates: standardSampleRates, channelCounts: pcmChannels),
            Entry(container: .m4a, codec: .aac, sampleFormats: [.lossy], sampleRates: aacSampleRates, channelCounts: codedChannels),
            Entry(container: .caf, codec: .aac, sampleFormats: [.lossy], sampleRates: aacSampleRates, channelCounts: codedChannels),
            Entry(container: .m4a, codec: .appleLossless, sampleFormats: [.lossless(16), .lossless(20), .lossless(24), .lossless(32)], sampleRates: standardSampleRates, channelCounts: codedChannels),
            Entry(container: .caf, codec: .appleLossless, sampleFormats: [.lossless(16), .lossless(20), .lossless(24), .lossless(32)], sampleRates: standardSampleRates, channelCounts: codedChannels),
            Entry(container: .flac, codec: .flac, sampleFormats: [.lossless(16), .lossless(24)], sampleRates: standardSampleRates, channelCounts: codedChannels),
            Entry(container: .caf, codec: .opus, sampleFormats: [.lossy], sampleRates: opusSampleRates, channelCounts: [1, 2]),
        ]
    }()

    /// Interprets what an open source declares, against the envelope. Throws `unsupported`, `truncated`, `missingAudioData`,
    /// `inconsistentStream` or `emptyFile`; never reads content.
    public static func interpret(_ facts: EncodedStreamFacts, url: URL, source: SourceID, fingerprint: FileSystemFingerprint) throws(DecodeFailure) -> FormatInterpretation {
        let containerCode = FourCharacterCode.string(facts.containerTypeCode)
        let codecCode = FourCharacterCode.string(facts.formatID)
        guard let container = ContainerKind.allCases.first(where: { $0.typeCode == containerCode }) else {
            throw .unsupported(.container(containerCode))
        }
        guard let codec = CodecKind.allCases.first(where: { $0.formatID == codecCode }),
              let entry = entries.first(where: { $0.container == container && $0.codec == codec })
        else { throw .unsupported(.codec(container: containerCode, codec: codecCode)) }

        let sampleFormat = try sampleFormat(facts, codec: codec)
        guard entry.sampleFormats.contains(sampleFormat) else { throw .unsupported(.sampleFormat(sampleFormat.description)) }
        guard facts.sampleRate.isFinite, facts.sampleRate.rounded() == facts.sampleRate,
              entry.sampleRates.contains(Int(facts.sampleRate))
        else { throw .unsupported(.sampleRate(facts.sampleRate)) }
        let rate = Int(facts.sampleRate)
        let channels = Int(facts.channelsPerFrame)
        guard entry.channelCounts.contains(channels) else { throw .unsupported(.channelCount(channels)) }
        guard facts.framesPerPacket > 0 else { throw .unsupported(.variableFramesPerPacket) }
        if codec.isLossy, facts.packetTable == nil { throw .unsupported(.encoderDelayUnknown) }

        switch facts.containerLength {
        case let .exceedsFile(declared, available):
            throw .truncated(declaredBytes: declared, availableBytes: available)
        case .audioDataChunkMissing:
            throw .missingAudioData
        case .unverifiable:
            throw .unsupported(.unverifiableContainerLength)
        case .notChecked where container == .wave:
            // WAVE readers clamp a short data chunk silently, so the chunk check is mandatory.
            throw .unsupported(.unverifiableContainerLength)
        case .notChecked, .consistent:
            break
        }

        let valid = facts.packetTable?.validFrames ?? facts.readerLengthFrames
        let priming = facts.packetTable?.primingFrames ?? 0
        let remainder = facts.packetTable?.remainderFrames ?? 0
        guard valid >= 0, priming >= 0, remainder >= 0 else {
            throw .inconsistentStream(.invalidDeclaredCount("valid \(valid), priming \(priming), remainder \(remainder)"))
        }
        if let table = facts.packetTable, table.validFrames != facts.readerLengthFrames {
            throw .inconsistentStream(.packetTableDisagreesWithLength(packetTableFrames: table.validFrames, readerFrames: facts.readerLengthFrames))
        }
        guard valid > 0 else { throw .emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        return FormatInterpretation(
            envelopeVersion: version,
            container: ContainerFacts(
                kind: container,
                typeCode: containerCode,
                fileExtension: fileExtension,
                extensionMatchesContainer: container.conventionalExtensions.contains(fileExtension)
            ),
            codec: CodecFacts(kind: codec, formatID: codecCode, formatFlags: facts.formatFlags),
            sourceSampleRate: rate,
            sampleFormat: sampleFormat,
            channelCount: channels,
            channelLayout: facts.channelLayout,
            frames: FrameAccounting(validFrames: valid, primingFrames: priming, remainderFrames: remainder, hasPacketTable: facts.packetTable != nil),
            packets: PacketFacts(
                framesPerPacket: Int(facts.framesPerPacket),
                bytesPerPacket: Int(facts.bytesPerPacket),
                packetCount: facts.packetCount,
                maximumPacketSize: facts.maximumPacketSize,
                averageBitRate: facts.averageBitRate,
                isVariableBitRate: facts.bytesPerPacket == 0
            ),
            output: DecodedOutputFormat(sampleRate: rate, channelCount: channels, representsSourceSamplesExactly: sampleFormat.isExactInFloat32),
            origin: DecodedFrameOrigin(sourceSampleRate: rate, decodedFrameCount: valid, discardedLeadingStreamFrames: priming, declaredTrailingStreamFrames: remainder),
            source: source,
            sourceFingerprint: fingerprint
        )
    }

    // AudioFormat flag values (CoreAudioBaseTypes), restated so this file needs no platform import.
    static let flagIsFloat: UInt32 = 1 << 0
    static let flagIsBigEndian: UInt32 = 1 << 1
    static let flagIsSignedInteger: UInt32 = 1 << 2
    static let flagIsNonInterleaved: UInt32 = 1 << 5

    static func sampleFormat(_ facts: EncodedStreamFacts, codec: CodecKind) throws(DecodeFailure) -> SourceSampleFormat {
        switch codec {
        case .linearPCM:
            let bits = Int(facts.bitsPerChannel)
            let flags = facts.formatFlags
            let bigEndian = flags & flagIsBigEndian != 0
            // Packed and interleaved: every frame is exactly `channels × bits / 8` bytes.
            guard bits % 8 == 0, bits > 0, flags & flagIsNonInterleaved == 0,
                  Int(facts.bytesPerFrame) == bits / 8 * Int(facts.channelsPerFrame),
                  facts.framesPerPacket == 1, facts.bytesPerPacket == facts.bytesPerFrame
            else { throw .unsupported(.sampleFormat("lpcm \(bits)-bit flags \(flags) bytes/frame \(facts.bytesPerFrame)")) }
            if flags & flagIsFloat != 0 { return .float(bits, bigEndian: bigEndian) }
            guard flags & flagIsSignedInteger != 0 else { throw .unsupported(.sampleFormat("unsigned \(bits)-bit integer")) }
            return .int(bits, bigEndian: bigEndian)
        case .appleLossless, .flac:
            // kAppleLosslessFormatFlag_{16,20,24,32}BitSourceData = 1...4; FLAC uses the same values.
            switch facts.formatFlags {
            case 1: return .lossless(16)
            case 2: return .lossless(20)
            case 3: return .lossless(24)
            case 4: return .lossless(32)
            default: throw .unsupported(.sampleFormat("\(codec.rawValue) source depth flags \(facts.formatFlags)"))
            }
        case .aac, .opus:
            return .lossy
        }
    }
}
