import AudioToolbox
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// Planted damaged, unsupported and unreachable sources. Each must fail with its typed error, publish
/// nothing (no `finish`; any appended chunk is abandoned) and leave the file byte-for-byte unchanged.
@Suite("Planted failures")
struct PlantedFailureTests {
    static let signal = LandmarkSignal(frames: 6000, channelCount: 2, seed: 50)

    static func spec(_ container: ContainerKind, _ codec: CodecKind, _ format: SourceSampleFormat, rate: Int = 48_000, channels: Int = 2) -> FixtureSpec {
        FixtureSpec(container: container, codec: codec, sampleFormat: format, sampleRate: rate, channelCount: channels)
    }

    struct Outcome {
        var failure: DecodeFailure?
        var events: [String]
        var opens: Int
        var scopesBalanced: Bool
    }

    /// Decodes `url` through a journaling sink and a counting gateway, checking the file is unchanged.
    static func attempt(_ url: URL, io: AdjustableIO = AdjustableIO(), sourceLocation: SourceLocation = #_sourceLocation) async throws -> Outcome {
        let before = try? FileSnapshot(url)
        let journal = SinkJournal()
        let content = CountingContentIO()
        let ledger = SecurityScopeLedger()
        var failure: DecodeFailure?
        do {
            _ = try await makeDecoder(chunkFrames: 1000, io: io, content: content, ledger: ledger).decode(url, source: SourceID()) { interpretation in
                JournalingSink(inner: CollectingSink(channelCount: interpretation.channelCount, maximumChunk: 1000), journal: journal)
            }
        } catch {
            failure = error
        }
        let after = try? FileSnapshot(url)
        #expect(before == after, "the source changed", sourceLocation: sourceLocation)
        let events = journal.events
        #expect(!events.contains("finish"), "a failed decode published", sourceLocation: sourceLocation)
        if events.contains("append") {
            #expect(events.last == "abandon", "appended chunks were not abandoned", sourceLocation: sourceLocation)
        }
        #expect(content.openReaders == 0, "a reader was left open", sourceLocation: sourceLocation)
        let scopes = ledger.snapshot
        let balance = io.scopeBalance
        return Outcome(failure: failure, events: events, opens: content.opens, scopesBalanced: scopes.openScopes == 0 && balance.starts == balance.stops)
    }

    // MARK: - Truncation

    struct TruncationCase: Sendable, CustomTestStringConvertible {
        var spec: FixtureSpec
        var fraction: Double
        var testDescription: String { "\(spec.container.rawValue)/\(spec.codec.rawValue) cut to \(Int(fraction * 100))%" }
    }

    static let truncationSpecs: [FixtureSpec] = [
        spec(.wave, .linearPCM, .int(16, bigEndian: false)),
        spec(.wave, .linearPCM, .float(32, bigEndian: false)),
        spec(.aiff, .linearPCM, .int(24, bigEndian: true)),
        spec(.aifc, .linearPCM, .float(32, bigEndian: true)),
        spec(.caf, .linearPCM, .int(16, bigEndian: false)),
        spec(.caf, .appleLossless, .lossless(16)),
        spec(.m4a, .appleLossless, .lossless(24)),
        spec(.flac, .flac, .lossless(16)),
        spec(.m4a, .aac, .lossy),
        spec(.caf, .aac, .lossy),
        spec(.caf, .opus, .lossy),
    ]

    static let truncations: [TruncationCase] = truncationSpecs.flatMap { spec in
        [0.05, 0.6, 0.97].map { TruncationCase(spec: spec, fraction: $0) }
    }

    @Test("Truncated sources fail as content damage and publish nothing", arguments: truncations)
    func truncated(_ planted: TruncationCase) async throws {
        let directory = try FixtureDirectory("truncated")
        let whole = try directory.write(planted.spec, signal: Self.signal)
        let bytes = try Data(contentsOf: whole)
        let cut = try directory.writeBytes(bytes.prefix(Int(Double(bytes.count) * planted.fraction)), as: "cut.\(planted.spec.fileExtension)")
        let outcome = try await Self.attempt(cut)
        let failure = try #require(outcome.failure, "a truncated source decoded")
        print("PLANTED \(planted.testDescription) → \(failure)")
        #expect(failure.isContentDamage, "\(failure)")
        #expect(outcome.scopesBalanced)
        // Linear PCM in chunked containers: WWDecode's own chunk check, independent of the platform.
        if planted.spec.codec == .linearPCM {
            let dataBytes = Int64(Self.signal.frames * planted.spec.channelCount * planted.spec.sampleFormat.bitsPerSample! / 8)
            if planted.fraction < 0.1 {
                #expect(failure == .missingAudioData)
            } else {
                guard case let .truncated(declared, available) = failure else {
                    Issue.record("expected truncated, got \(failure)")
                    return
                }
                #expect(declared == dataBytes)
                #expect(available < declared)
            }
        }
    }

    // MARK: - Not audio, empty, misnamed

    @Test("Zero-length file is refused before opening")
    func zeroLength() async throws {
        let directory = try FixtureDirectory("empty")
        let url = try directory.writeBytes(Data(), as: "empty.wav")
        let outcome = try await Self.attempt(url)
        #expect(outcome.failure == .emptyFile)
        #expect(outcome.opens == 0)
        #expect(outcome.scopesBalanced)
    }

    @Test("Random bytes and text are unreadable containers", arguments: ["wav", "m4a", "caf", "aiff", "flac", "mp3", "bin"])
    func notAudio(_ fileExtension: String) async throws {
        let directory = try FixtureDirectory("not-audio")
        var rng = SplitMix64(state: 99)
        let random = try directory.writeBytes(Data((0..<65_536).map { _ in UInt8(truncatingIfNeeded: rng.next()) }), as: "random.\(fileExtension)")
        let text = try directory.writeBytes(Data(String(repeating: "not audio at all\n", count: 400).utf8), as: "text.\(fileExtension)")
        for url in [random, text] {
            let outcome = try await Self.attempt(url)
            let failure = try #require(outcome.failure)
            print("PLANTED \(url.lastPathComponent) → \(failure)")
            guard case .unreadableContainer = failure else {
                Issue.record("\(url.lastPathComponent): \(failure)")
                continue
            }
            #expect(outcome.events.isEmpty)
        }
    }

    @Test("A damaged header is an unreadable container")
    func damagedHeader() async throws {
        let directory = try FixtureDirectory("damaged-header")
        for planted in [Self.spec(.wave, .linearPCM, .int(16, bigEndian: false)), Self.spec(.aiff, .linearPCM, .int(16, bigEndian: true)), Self.spec(.caf, .linearPCM, .int(16, bigEndian: false))] {
            var bytes = try Data(contentsOf: directory.write(planted, signal: Self.signal))
            bytes.replaceSubrange(0..<4, with: Data("XXXX".utf8))
            let url = try directory.writeBytes(bytes, as: "damaged.\(planted.fileExtension)")
            let outcome = try await Self.attempt(url)
            let failure = try #require(outcome.failure)
            print("PLANTED damaged header \(planted.container) → \(failure)")
            guard case .unreadableContainer = failure else {
                Issue.record("\(planted.container): \(failure)")
                continue
            }
        }
    }

    @Test("A misnamed source decodes as what it is, and the mismatch is recorded")
    func wrongExtension() async throws {
        let directory = try FixtureDirectory("misnamed")
        let wave = try directory.write(Self.spec(.wave, .linearPCM, .int(16, bigEndian: false)), signal: Self.signal, name: "really-a-wave.m4a")
        let caf = try directory.write(Self.spec(.caf, .aac, .lossy), signal: Self.signal, name: "really-a-caf.wav")
        let decodedWave = try await decodeAll(wave)
        #expect(decodedWave.interpretation.container.kind == .wave)
        #expect(decodedWave.interpretation.container.fileExtension == "m4a")
        #expect(decodedWave.interpretation.container.extensionMatchesContainer == false)
        #expect(decodedWave.product.channels == Self.signal.channels)
        let decodedCaf = try await decodeAll(caf)
        #expect(decodedCaf.interpretation.container.kind == .caf)
        #expect(decodedCaf.interpretation.codec.kind == .aac)
        #expect(decodedCaf.interpretation.container.extensionMatchesContainer == false)
        let matching = try await decodeAll(directory.write(Self.spec(.aiff, .linearPCM, .int(16, bigEndian: true)), signal: Self.signal))
        #expect(matching.interpretation.container.extensionMatchesContainer)
    }

    // MARK: - Outside the envelope

    struct UnsupportedCase: Sendable, CustomTestStringConvertible {
        var name: String
        var spec: FixtureSpec
        var expected: UnsupportedReason
        var testDescription: String { name }
    }

    static func lpcm(_ bits: UInt32, flags: AudioFormatFlags, rate: Double = 48_000, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
    }

    static func coded(_ formatID: AudioFormatID, rate: Double = 48_000, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    }

    static let float32 = SourceSampleFormat.float(32, bigEndian: false)

    static let unsupported: [UnsupportedCase] = [
        UnsupportedCase(
            name: "AAC in ADTS (no packet table)",
            spec: FixtureSpec(container: .m4a, codec: .aac, sampleFormat: .lossy, sampleRate: 48_000, channelCount: 2, fileTypeOverride: kAudioFileAAC_ADTSType, extensionOverride: "aac"),
            expected: .container("adts")
        ),
        UnsupportedCase(
            name: "µ-law in WAVE",
            spec: FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: float32, sampleRate: 8000, channelCount: 1, formatOverride: coded(kAudioFormatULaw, rate: 8000, channels: 1)),
            expected: .codec(container: "WAVE", codec: "ulaw")
        ),
        UnsupportedCase(
            name: "IMA4 in CAF",
            spec: FixtureSpec(container: .caf, codec: .linearPCM, sampleFormat: float32, sampleRate: 48_000, channelCount: 2, formatOverride: coded(kAudioFormatAppleIMA4)),
            expected: .codec(container: "caff", codec: "ima4")
        ),
        UnsupportedCase(
            name: "Unsigned 8-bit WAVE",
            spec: FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: float32, sampleRate: 48_000, channelCount: 2, formatOverride: lpcm(8, flags: 0)),
            expected: .sampleFormat("unsigned 8-bit integer")
        ),
        UnsupportedCase(
            name: "Signed 8-bit AIFF",
            spec: FixtureSpec(container: .aiff, codec: .linearPCM, sampleFormat: float32, sampleRate: 48_000, channelCount: 2, formatOverride: lpcm(8, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian)),
            expected: .sampleFormat("signedInteger8 BE")
        ),
        UnsupportedCase(
            name: "Non-standard rate 12345 Hz WAVE",
            spec: FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false), sampleRate: 12_345, channelCount: 2),
            expected: .sampleRate(12_345)
        ),
        UnsupportedCase(
            name: "Nine-channel WAVE",
            spec: FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false), sampleRate: 48_000, channelCount: 9),
            expected: .channelCount(9)
        ),
        UnsupportedCase(
            name: "Three-channel ALAC",
            spec: FixtureSpec(container: .caf, codec: .appleLossless, sampleFormat: .lossless(16), sampleRate: 48_000, channelCount: 3),
            expected: .channelCount(3)
        ),
    ]

    @Test("Sources outside the evidenced envelope are refused with their reason", arguments: unsupported)
    func outsideEnvelope(_ planted: UnsupportedCase) async throws {
        let directory = try FixtureDirectory("unsupported")
        let signal = LandmarkSignal(frames: 8000, channelCount: planted.spec.channelCount, seed: 51)
        let url = try directory.write(planted.spec, signal: signal)
        let outcome = try await Self.attempt(url)
        print("PLANTED \(planted.name) → \(String(describing: outcome.failure))")
        #expect(outcome.failure == .unsupported(planted.expected))
        #expect(outcome.events.isEmpty, "no sink is made for an unsupported source")
        #expect(outcome.scopesBalanced)
    }

    @Test("A WAVE with an unverifiable data size (streaming 0xFFFFFFFF) is refused")
    func streamingWaveSize() async throws {
        let directory = try FixtureDirectory("streaming-wave")
        var bytes = try Data(contentsOf: directory.write(Self.spec(.wave, .linearPCM, .int(16, bigEndian: false)), signal: Self.signal))
        let dataTag = try #require(bytes.range(of: Data("data".utf8)))
        bytes.replaceSubrange(dataTag.upperBound ..< dataTag.upperBound + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let url = try directory.writeBytes(bytes, as: "streaming.wav")
        let outcome = try await Self.attempt(url)
        print("PLANTED streaming WAVE → \(String(describing: outcome.failure))")
        #expect(outcome.failure == .unsupported(.unverifiableContainerLength))
    }

    // MARK: - Unreachable

    @Test("Missing, unreadable, directory and symbolic-link sources fail before any content is opened")
    func unreachable() async throws {
        let directory = try FixtureDirectory("unreachable")
        let real = try directory.write(Self.spec(.wave, .linearPCM, .int(16, bigEndian: false)), signal: Self.signal)

        let missing = try await Self.attempt(directory.file("missing.wav"))
        #expect(missing.failure == .notFound)
        #expect(missing.opens == 0)

        let folder = directory.file("folder.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderOutcome = try await Self.attempt(folder)
        #expect(folderOutcome.failure == .notARegularFile)
        #expect(folderOutcome.opens == 0)

        let link = directory.file("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linkOutcome = try await Self.attempt(link)
        #expect(linkOutcome.failure == .notARegularFile)
        #expect(linkOutcome.opens == 0)

        let locked = try directory.copy(real, as: "locked.wav")
        chmod(locked.path, 0)
        var before = stat()
        lstat(locked.path, &before)
        let lockedOutcome = try await Self.attempt(locked)
        var after = stat()
        lstat(locked.path, &after)
        #expect(lockedOutcome.failure == .permissionDenied)
        #expect(lockedOutcome.opens == 0)
        #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_size == after.st_size && before.st_mode == after.st_mode)
        for outcome in [missing, folderOutcome, linkOutcome, lockedOutcome] { #expect(outcome.scopesBalanced) }
    }
}

/// Wraps the system gateway, counting opens and readers still open.
final class CountingContentIO: SourceContentIO, @unchecked Sendable {
    private let base = SystemSourceContentIO()
    private let lock = NSLock()
    private var _opens = 0
    private var _open = 0

    var opens: Int { lock.withLock { _opens } }
    var openReaders: Int { lock.withLock { _open } }

    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        lock.withLock { _opens += 1 }
        let reader = try base.openForDecoding(url)
        lock.withLock { _open += 1 }
        return ClosingReader(reader) { [weak self] in self?.lock.withLock { self?._open -= 1 } }
    }

    private final class ClosingReader: DecodingContentReader {
        let inner: any DecodingContentReader
        let onClose: () -> Void
        var closed = false
        init(_ inner: any DecodingContentReader, onClose: @escaping () -> Void) {
            self.inner = inner
            self.onClose = onClose
        }
        var facts: EncodedStreamFacts { inner.facts }
        func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int { try inner.readRawFrames(into: buffer) }
        func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState { try inner.currentOpenedFileState() }
        func close() {
            inner.close()
            if !closed {
                closed = true
                onClose()
            }
        }
    }
}
