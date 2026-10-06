import CryptoKit
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

@Suite("Format interpretation")
struct FormatInterpretationTests {
    static let url = URL(fileURLWithPath: "/nonexistent/source.m4a")
    static let opened = OpenedFileState(fileNumber: 42, sizeBytes: 4096, modificationSeconds: 1_700_000_000, modificationNanoseconds: 5)
    static let fingerprint = FileSystemFingerprint(
        fileSize: .known(4096),
        creationDate: .known(Date(timeIntervalSince1970: 1_600_000_000)),
        contentModificationDate: .known(Date(timeIntervalSince1970: 1_700_000_000)),
        fileIdentifier: .known(42),
        volumeUUID: .known("00000000-0000-0000-0000-000000000001"),
        contentType: .known("com.apple.m4a-audio")
    )

    static let source = SourceID(UUID(uuidString: "5E1F0000-0000-4000-8000-000000000050")!)

    static func aac(priming: Int64 = 2112, valid: Int64 = 10_000, remainder: Int64 = 176, readerLength: Int64? = nil, table: Bool = true) -> EncodedStreamFacts {
        EncodedStreamFacts(
            containerTypeCode: FourCharacterCode.code("m4af"), formatID: FourCharacterCode.code("aac "), formatFlags: 0,
            sampleRate: 48_000, bytesPerPacket: 0, framesPerPacket: 1024, bytesPerFrame: 0, channelsPerFrame: 2, bitsPerChannel: 0,
            packetCount: 12, maximumPacketSize: 600, audioDataByteCount: 3000, dataOffset: 100, averageBitRate: 128_000,
            packetTable: table ? PacketTableFacts(validFrames: valid, primingFrames: priming, remainderFrames: remainder) : nil,
            readerLengthFrames: readerLength ?? valid,
            channelLayout: ChannelLayoutFacts(isDeclaredBySource: true, layoutTag: 101 << 16 | 2, channelBitmap: 3, channelLabels: [1, 2]),
            containerLength: .notChecked, openedFile: opened
        )
    }

    static func pcm(container: String = "WAVE", bits: UInt32 = 24, flags: UInt32 = 0b1100, rate: Double = 48_000, channels: UInt32 = 2, frames: Int64 = 1000, length: ContainerLengthEvidence? = nil) -> EncodedStreamFacts {
        EncodedStreamFacts(
            containerTypeCode: FourCharacterCode.code(container), formatID: FourCharacterCode.code("lpcm"), formatFlags: flags,
            sampleRate: rate, bytesPerPacket: bits / 8 * channels, framesPerPacket: 1, bytesPerFrame: bits / 8 * channels, channelsPerFrame: channels, bitsPerChannel: bits,
            packetCount: frames, readerLengthFrames: frames,
            containerLength: length ?? .consistent(declaredBytes: frames * Int64(bits / 8 * channels)), openedFile: opened
        )
    }

    static func interpret(_ facts: EncodedStreamFacts, url: URL = url) -> Result<FormatInterpretation, DecodeFailure> {
        Result { () throws(DecodeFailure) in try DecodeEnvelope.interpret(facts, url: url, source: source, fingerprint: fingerprint) }
    }

    // MARK: - Schema

    /// Every key path in the encoded descriptor (all optionals present).
    static func keyPaths(_ value: Any, prefix: String = "") -> [String] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key -> [String] in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                return [path] + keyPaths(object[key]!, prefix: path)
            }
        }
        if let array = value as? [Any], let first = array.first { return keyPaths(first, prefix: prefix + "[]") }
        return []
    }

    @Test("The encoded field set is pinned to formatInterpretationVersion 1")
    func schemaPin() throws {
        let interpretation = try Self.interpret(Self.aac()).get()
        #expect(interpretation.formatInterpretationVersion == FormatInterpretation.currentVersion)
        #expect(FormatInterpretation.currentVersion == 1)
        #expect(interpretation.envelopeVersion == DecodeEnvelope.version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(interpretation)
        let paths = Self.keyPaths(try JSONSerialization.jsonObject(with: data))
        let pinned = [
            "channelCount", "channelLayout", "channelLayout.channelBitmap", "channelLayout.channelLabels", "channelLayout.isDeclaredBySource", "channelLayout.layoutTag",
            "codec", "codec.formatFlags", "codec.formatID", "codec.kind",
            "container", "container.extensionMatchesContainer", "container.fileExtension", "container.kind", "container.typeCode",
            "envelopeVersion", "formatInterpretationVersion",
            "frames", "frames.hasPacketTable", "frames.primingFrames", "frames.remainderFrames", "frames.validFrames",
            "origin", "origin.decodedFrameCount", "origin.declaredTrailingStreamFrames", "origin.discardedLeadingStreamFrames", "origin.sourceFrameOfFirstDecodedFrame", "origin.sourceSampleRate",
            "output", "output.channelCount", "output.channelOrder", "output.isPlanar", "output.representsSourceSamplesExactly", "output.sampleRate", "output.sampleType",
            "packets", "packets.averageBitRate", "packets.bytesPerPacket", "packets.framesPerPacket", "packets.isVariableBitRate", "packets.maximumPacketSize", "packets.packetCount",
            "sampleFormat", "sampleFormat.encoding",
            "source",
            "sourceFingerprint",
            "sourceFingerprint.contentModificationDate", "sourceFingerprint.contentModificationDate.state", "sourceFingerprint.contentModificationDate.value",
            "sourceFingerprint.contentType", "sourceFingerprint.contentType.state", "sourceFingerprint.contentType.value",
            "sourceFingerprint.creationDate", "sourceFingerprint.creationDate.state", "sourceFingerprint.creationDate.value",
            "sourceFingerprint.fileIdentifier", "sourceFingerprint.fileIdentifier.state", "sourceFingerprint.fileIdentifier.value",
            "sourceFingerprint.fileSize", "sourceFingerprint.fileSize.state", "sourceFingerprint.fileSize.value",
            "sourceFingerprint.volumeUUID", "sourceFingerprint.volumeUUID.state", "sourceFingerprint.volumeUUID.value",
            "sourceSampleRate",
        ]
        #expect(paths == pinned.sorted(), "descriptor schema changed: bump FormatInterpretation.currentVersion and update the pin\n\(paths)")
        let pcm = try Self.interpret(Self.pcm()).get()
        let pcmPaths = Self.keyPaths(try JSONSerialization.jsonObject(with: encoder.encode(pcm)))
        #expect(pcmPaths.contains("sampleFormat.bitsPerSample") && pcmPaths.contains("sampleFormat.isBigEndian"))
        // The opened path is a location hint, never part of the descriptor.
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("nonexistent") && !json.contains("source.m4a"))
        // Round trip.
        #expect(try JSONDecoder().decode(FormatInterpretation.self, from: data) == interpretation)
    }

    // MARK: - Descriptor content

    @Test("AAC: priming, remainder, packets and VBR facts are carried exactly")
    func aacDescriptor() throws {
        let interpretation = try Self.interpret(Self.aac()).get()
        #expect(interpretation.container == ContainerFacts(kind: .m4a, typeCode: "m4af", fileExtension: "m4a", extensionMatchesContainer: true))
        #expect(interpretation.codec == CodecFacts(kind: .aac, formatID: "aac ", formatFlags: 0))
        #expect(interpretation.source == Self.source)
        #expect(interpretation.sourceSampleRate == 48_000)
        #expect(interpretation.sampleFormat == .lossy)
        #expect(interpretation.channelCount == 2)
        #expect(interpretation.channelLayout.channelLabels == [1, 2])
        #expect(interpretation.frames == FrameAccounting(validFrames: 10_000, primingFrames: 2112, remainderFrames: 176, hasPacketTable: true))
        #expect(interpretation.packets == PacketFacts(framesPerPacket: 1024, bytesPerPacket: 0, packetCount: 12, maximumPacketSize: 600, averageBitRate: 128_000, isVariableBitRate: true))
        #expect(interpretation.output == DecodedOutputFormat(sampleRate: 48_000, channelCount: 2, representsSourceSamplesExactly: false))
        #expect(interpretation.origin == DecodedFrameOrigin(sourceSampleRate: 48_000, decodedFrameCount: 10_000, discardedLeadingStreamFrames: 2112, declaredTrailingStreamFrames: 176))
        #expect(interpretation.sourceFingerprint == Self.fingerprint)
    }

    @Test("PCM: sample format, byte order and exactness")
    func pcmDescriptor() throws {
        let cases: [(String, UInt32, UInt32, SourceSampleFormat, Bool)] = [
            ("WAVE", 16, 0b1100, .int(16, bigEndian: false), true),
            ("WAVE", 24, 0b1100, .int(24, bigEndian: false), true),
            ("WAVE", 32, 0b1100, .int(32, bigEndian: false), false),
            ("WAVE", 32, 0b1001, .float(32, bigEndian: false), true),
            ("WAVE", 64, 0b1001, .float(64, bigEndian: false), false),
            ("AIFF", 24, 0b1110, .int(24, bigEndian: true), true),
            ("AIFC", 32, 0b1011, .float(32, bigEndian: true), true),
            ("caff", 16, 0b1110, .int(16, bigEndian: true), true),
        ]
        for (container, bits, flags, format, exact) in cases {
            let interpretation = try Self.interpret(Self.pcm(container: container, bits: bits, flags: flags)).get()
            #expect(interpretation.sampleFormat == format)
            #expect(interpretation.output.representsSourceSamplesExactly == exact)
            #expect(interpretation.frames == FrameAccounting(validFrames: 1000, primingFrames: 0, remainderFrames: 0, hasPacketTable: false))
            #expect(interpretation.packets.isVariableBitRate == false)
        }
    }

    // MARK: - Origin

    @Test("Decoded frame d is source frame d at rate F, produced by codec-stream frame d + priming")
    func originMapping() {
        let origin = DecodedFrameOrigin(sourceSampleRate: 44_100, decodedFrameCount: 441_000, discardedLeadingStreamFrames: 2112, declaredTrailingStreamFrames: 600)
        #expect(origin.sourceFrameOfFirstDecodedFrame == 0)
        for d: Int64 in [0, 1, 2111, 2112, 44_099, 44_100, 440_999] {
            #expect(origin.sourceFrame(forDecodedFrame: d) == d)
            #expect(origin.decodedFrame(forSourceFrame: d) == d)
            #expect(origin.codecStreamFrame(forDecodedFrame: d) == d + 2112)
            #expect(origin.sourcePosition(forDecodedFrame: d) == SourceFramePosition(frame: d, sampleRate: 44_100))
        }
        for outside: Int64 in [-1, 441_000, .max, .min] {
            #expect(origin.sourceFrame(forDecodedFrame: outside) == nil)
            #expect(origin.decodedFrame(forSourceFrame: outside) == nil)
            #expect(origin.codecStreamFrame(forDecodedFrame: outside) == nil)
        }
        #expect(origin.sourceDuration == SourceFramePosition(frame: 441_000, sampleRate: 44_100))
        #expect(origin.sourceDuration.seconds == 10)
        #expect(SourceFramePosition(frame: 44_100, sampleRate: 44_100).seconds == 1)
    }

    // MARK: - Interpretation refusals

    @Test("Each refusal reason is typed")
    func refusals() {
        var adts = Self.aac()
        adts.containerTypeCode = FourCharacterCode.code("adts")
        var mp3 = Self.aac()
        mp3.formatID = FourCharacterCode.code(".mp3")
        var opusInM4A = Self.aac()
        opusInM4A.formatID = FourCharacterCode.code("opus")
        var fractionalRate = Self.pcm()
        fractionalRate.sampleRate = 44_100.5
        var aac96 = Self.aac()
        aac96.sampleRate = 96_000
        var aacThree = Self.aac()
        aacThree.channelsPerFrame = 3
        var variable = Self.aac()
        variable.framesPerPacket = 0
        var nonInterleaved = Self.pcm(flags: 0b101100)
        nonInterleaved.bytesPerFrame = 3
        var alacOddDepth = Self.aac()
        alacOddDepth.formatID = FourCharacterCode.code("alac")
        alacOddDepth.formatFlags = 9
        var flac20 = Self.aac()
        flac20.containerTypeCode = FourCharacterCode.code("flac")
        flac20.formatID = FourCharacterCode.code("flac")
        flac20.formatFlags = 2
        flac20.packetTable = nil

        let cases: [(String, EncodedStreamFacts, DecodeFailure)] = [
            ("ADTS container", adts, .unsupported(.container("adts"))),
            ("MP3 in M4A", mp3, .unsupported(.codec(container: "m4af", codec: ".mp3"))),
            ("Opus in M4A", opusInM4A, .unsupported(.codec(container: "m4af", codec: "opus"))),
            ("fractional rate", fractionalRate, .unsupported(.sampleRate(44_100.5))),
            ("non-standard rate", Self.pcm(rate: 12_345), .unsupported(.sampleRate(12_345))),
            ("AAC above 48 kHz", aac96, .unsupported(.sampleRate(96_000))),
            ("three-channel AAC", aacThree, .unsupported(.channelCount(3))),
            ("nine-channel PCM", Self.pcm(channels: 9), .unsupported(.channelCount(9))),
            ("variable frames per packet", variable, .unsupported(.variableFramesPerPacket)),
            ("AAC without packet table", Self.aac(table: false), .unsupported(.encoderDelayUnknown)),
            ("unsigned PCM", Self.pcm(bits: 8, flags: 0b1000), .unsupported(.sampleFormat("unsigned 8-bit integer"))),
            ("20-bit packed PCM", Self.pcm(bits: 20, flags: 0b1100), .unsupported(.sampleFormat("lpcm 20-bit flags 12 bytes/frame 4"))),
            ("non-interleaved PCM", nonInterleaved, .unsupported(.sampleFormat("lpcm 24-bit flags 44 bytes/frame 3"))),
            ("big-endian WAVE", Self.pcm(flags: 0b1110), .unsupported(.sampleFormat("signedInteger24 BE"))),
            ("ALAC unknown depth", alacOddDepth, .unsupported(.sampleFormat("appleLossless source depth flags 9"))),
            ("FLAC 20-bit", flac20, .unsupported(.sampleFormat("lossless20"))),
            ("WAVE length unchecked", Self.pcm(length: .notChecked), .unsupported(.unverifiableContainerLength)),
            ("length unverifiable", Self.pcm(container: "caff", length: .unverifiable("test")), .unsupported(.unverifiableContainerLength)),
            ("data chunk exceeds file", Self.pcm(length: .exceedsFile(declaredBytes: 6000, availableBytes: 10)), .truncated(declaredBytes: 6000, availableBytes: 10)),
            ("data chunk missing", Self.pcm(container: "AIFF", flags: 0b1110, length: .audioDataChunkMissing), .missingAudioData),
            ("negative priming", Self.aac(priming: -1), .inconsistentStream(.invalidDeclaredCount("valid 10000, priming -1, remainder 176"))),
            ("negative remainder", Self.aac(remainder: -1), .inconsistentStream(.invalidDeclaredCount("valid 10000, priming 2112, remainder -1"))),
            ("negative length", Self.pcm(frames: -1), .inconsistentStream(.invalidDeclaredCount("valid -1, priming 0, remainder 0"))),
            ("packet table disagrees", Self.aac(readerLength: 9999), .inconsistentStream(.packetTableDisagreesWithLength(packetTableFrames: 10_000, readerFrames: 9999))),
            ("no frames", Self.pcm(frames: 0), .emptyFile),
            ("no valid frames", Self.aac(valid: 0), .emptyFile),
        ]
        for (name, facts, expected) in cases {
            guard case let .failure(failure) = Self.interpret(facts) else {
                Issue.record("\(name): interpreted")
                continue
            }
            #expect(failure == expected, "\(name)")
        }
    }

    @Test("The extension is recorded, never trusted")
    func extensionRecorded() throws {
        for (name, matches) in [("a.WAV", true), ("a.wave", true), ("a.bwf", true), ("a.m4a", false), ("a", false), ("a.wav.tmp", false)] {
            let interpretation = try Self.interpret(Self.pcm(), url: URL(fileURLWithPath: "/x/\(name)")).get()
            #expect(interpretation.container.kind == .wave)
            #expect(interpretation.container.extensionMatchesContainer == matches, "\(name)")
        }
    }

    // MARK: - Layout facts from real files

    @Test("Declared multichannel layouts are reported in file channel order")
    func channelLayouts() async throws {
        let directory = try FixtureDirectory("layouts")
        let cases: [(FixtureSpec, Bool)] = [
            (FixtureSpec(container: .caf, codec: .appleLossless, sampleFormat: .lossless(24), sampleRate: 48_000, channelCount: 6), true),
            (FixtureSpec(container: .m4a, codec: .aac, sampleFormat: .lossy, sampleRate: 48_000, channelCount: 8), true),
            (FixtureSpec(container: .caf, codec: .appleLossless, sampleFormat: .lossless(16), sampleRate: 44_100, channelCount: 2), true),
            // The platform M4A writer stores no layout for stereo ALAC: reported as undeclared, never invented.
            (FixtureSpec(container: .m4a, codec: .appleLossless, sampleFormat: .lossless(16), sampleRate: 44_100, channelCount: 2), false),
            (FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false), sampleRate: 48_000, channelCount: 1), false),
        ]
        for (spec, declared) in cases {
            let url = try directory.write(spec, signal: LandmarkSignal(channelCount: spec.channelCount, seed: 53))
            let decoded = try await decodeAll(url)
            let layout = decoded.interpretation.channelLayout
            print("LAYOUT \(spec.testDescription): \(layout)")
            #expect(layout.isDeclaredBySource == declared, "\(spec.testDescription)")
            if declared {
                #expect(layout.channelLabels.count == spec.channelCount, "\(spec.testDescription)")
                #expect(Set(layout.channelLabels).count == spec.channelCount, "labels must be distinct")
            }
            #expect(decoded.interpretation.output.channelOrder == "file")
        }
    }
}
