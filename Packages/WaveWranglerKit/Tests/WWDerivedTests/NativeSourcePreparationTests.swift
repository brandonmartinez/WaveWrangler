import AudioToolbox
import Foundation
import Testing
import WWCore
import WWPersistence
import WWSources

@testable import WWDecode
@testable import WWDerived

@Suite("Native source preparation", .serialized)
struct NativeSourcePreparationTests {
    private struct Fixture {
        let directory: TemporaryDirectory
        let source: SourceID
        let url: URL
        let format: FormatInterpretation
        let witness: RawSourceIdentity
        let access: SourceAccessContext

        static func make(
            frames: Int = 23_457, channels: Int = 2,
            rate: Int = 44_100, codec: UInt32 = kAudioFormatAppleLossless,
            mp3: Bool = false, declareLayout: Bool = true
        ) async throws -> Self {
            let directory = try TemporaryDirectory("native-pcm")
            let originals = try directory.folder("originals")
            var url = originals.appendingPathComponent("generated.caf")
            try writeCAF(url, frames: frames, channels: channels, rate: rate, codec: codec, declareLayout: declareLayout)
            if mp3 {
                let wave = originals.appendingPathComponent("encoder-input.wav")
                try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", url.path, wave.path])
                url = originals.appendingPathComponent("generated.mp3")
                let encoder = try #require(ProcessInfo.processInfo.environment["WW_MP3_LAME"])
                try run(encoder, ["--silent", "--noreplaygain", "-V", "2", wave.path, url.path])
            }
            let access = SourceAccessContext(io: SystemSourceIO(), ledger: SecurityScopeLedger())
            let decoder = SourceDecoder(access: access)
            let source = SourceID()
            let format = try await decoder.withDecodingCursor(url, source: source) { $0.interpretation }
            let witness = try await decoder.captureRawIdentity(url, matching: format.sourceFingerprint)
            return Fixture(
                directory: directory, source: source, url: url, format: format, witness: witness, access: access)
        }

        static func legacyWave(rate: Int, channels: Int, bits: Int, floating: Bool = false,
                               mutation: String? = nil) async throws -> Self {
            let directory = try TemporaryDirectory("legacy-wave-order")
            let url = try directory.folder("originals").appendingPathComponent("audio.misnamed")
            try waveBytes(rate: rate, channels: channels, bits: bits, floating: floating, mutation: mutation).write(to: url)
            let access = SourceAccessContext(io: SystemSourceIO(), ledger: SecurityScopeLedger())
            let decoder = SourceDecoder(access: access), source = SourceID()
            let format = try await decoder.withDecodingCursor(url, source: source) { $0.interpretation }
            let witness = try await decoder.captureRawIdentity(url, matching: format.sourceFingerprint)
            return Fixture(directory: directory, source: source, url: url, format: format, witness: witness, access: access)
        }

        static func waveBytes(rate: Int, channels: Int, bits: Int, floating: Bool = false,
                              mutation: String? = nil) -> Data {
            let frames = 441
            var fmt = Data()
            func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            let alignment = channels * (bits / 8)
            let extensible = mutation == "explicit-mask" || mutation == "extensible-unknown"
            append(UInt16(extensible ? 0xfffe : floating ? 3 : 1), to: &fmt); append(UInt16(channels), to: &fmt)
            append(UInt32(rate), to: &fmt)
            append(UInt32(rate * alignment + (mutation == "byte-rate" ? 1 : 0)), to: &fmt)
            append(UInt16(alignment), to: &fmt); append(UInt16(bits), to: &fmt)
            if extensible {
                append(UInt16(22), to: &fmt); append(UInt16(bits), to: &fmt)
                append(UInt32(mutation == "explicit-mask" ? 3 : 0), to: &fmt)
                fmt.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
            }
            if mutation == "extra-format" { append(UInt16(2), to: &fmt) }
            var payload = Data()
            for frame in 0..<frames {
                for channel in 0..<channels {
                    if floating { append(sample(frame, channel).bitPattern, to: &payload) }
                    else {
                        let value = Int32(sample(frame, channel) * Float(Int64(1) << (bits - 1)))
                        let raw = UInt32(bitPattern: value)
                        for byte in 0..<(bits / 8) { payload.append(UInt8(truncatingIfNeeded: raw >> (byte * 8))) }
                    }
                }
            }
            func chunk(_ tag: String, _ bytes: Data) -> Data {
                var data = Data(tag.utf8)
                append(UInt32(bytes.count), to: &data); data.append(bytes)
                if bytes.count % 2 == 1 { data.append(0) }
                return data
            }
            var body = Data("WAVE".utf8)
            body.append(chunk("fmt ", fmt))
            if mutation == "chunk-budget" {
                for _ in 0..<4095 { body.append(chunk("JUNK", Data())) }
            }
            if mutation == "duplicate-format" { body.append(chunk("fmt ", fmt)) }
            if mutation == "custom-layout" { body.append(chunk("chna", Data(repeating: 0, count: 8))) }
            if let mutation, mutation.hasPrefix("list-") {
                var list = Data((mutation == "list-info" ? "INFO" : mutation == "list-adtl" ? "adtl"
                    : mutation == "list-short" ? "IN" : mutation == "list-custom" ? "cust" : "ZZZZ").utf8)
                if mutation == "list-info" { list.append(chunk("INAM", Data("Synthetic\0".utf8))) }
                if mutation == "list-custom" { list.append(chunk("chna", Data(repeating: 0, count: 8))) }
                body.append(chunk("LIST", list))
            }
            if mutation == "wrong-fact" || mutation == "duplicate-fact" {
                var fact = Data()
                append(UInt32(frames + (mutation == "wrong-fact" ? 1 : 0)), to: &fact)
                body.append(chunk("fact", fact))
                if mutation == "duplicate-fact" { body.append(chunk("fact", fact)) }
            }
            body.append(chunk("data", payload))
            if mutation == "duplicate-data" { body.append(chunk("data", payload)) }
            var result = Data("RIFF".utf8)
            append(mutation == "overflow-length" ? UInt32.max : UInt32(body.count), to: &result)
            result.append(body)
            if mutation == "truncated" { result.removeLast() }
            return result
        }

        private init(
            directory: TemporaryDirectory, source: SourceID, url: URL,
            format: FormatInterpretation, witness: RawSourceIdentity, access: SourceAccessContext
        ) {
            self.directory = directory
            self.source = source
            self.url = url
            self.format = format
            self.witness = witness
            self.access = access
        }

        func admission(validate: @escaping @Sendable () async throws -> Void = {}) -> SourceReadAdmission {
            SourceReadAdmission(
                source: source, location: url, witness: witness,
                authorization: .explicitUserRequest(for: source), availability: .on, validateCurrentAccess: validate)
        }

        func preparation(storage: Int64 = 1 << 26) throws -> NativeSourcePreparation {
            try NativeSourcePreparation(
                root: directory.file("cache"), sourceLocations: [url], access: access,
                configuration: .init(tileFrames: 4096, maximumWindowFrames: 16_384, maximumStorageBytes: storage))
        }

        var assets: URL { directory.file("cache/native-source-pcm-v1/assets") }
        var staging: URL { directory.file("cache/native-source-pcm-v1/staging") }

        static func sample(_ frame: Int, _ channel: Int) -> Float {
            // Distinct deterministic channels, exactly representable in integer and Float32 PCM.
            Float((frame &* (channel == 0 ? 13 : 31) + channel * 997) % 20_000 - 10_000) / 32768
        }

        static func writeCAF(_ url: URL, frames: Int, channels: Int, rate: Int, codec: UInt32,
                             declareLayout: Bool = true) throws {
            var format = AudioStreamBasicDescription()
            format.mFormatID = codec
            format.mSampleRate = Double(rate)
            format.mChannelsPerFrame = UInt32(channels)
            if codec == kAudioFormatAppleLossless { format.mFormatFlags = 1 }
            if codec == kAudioFormatLinearPCM {
                format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                format.mBitsPerChannel = 16
                format.mFramesPerPacket = 1
                format.mBytesPerFrame = UInt32(channels * 2)
                format.mBytesPerPacket = format.mBytesPerFrame
            }
            var created: ExtAudioFileRef?
            try requireStatus(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil, 0, &created))
            let file = try #require(created)
            defer { ExtAudioFileDispose(file) }
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            if declareLayout {
                try requireStatus(
                    ExtAudioFileSetProperty(
                        file, kExtAudioFileProperty_FileChannelLayout,
                        UInt32(MemoryLayout.size(ofValue: layout)), &layout))
            }
            var client = AudioStreamBasicDescription(
                mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try requireStatus(
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout.size(ofValue: client)), &client))
            let block = 4096
            let buffer = RawDecodeBuffer(channelCount: channels, capacityFrames: block)
            let list = AudioBufferList.allocate(maximumBuffers: channels)
            defer { free(list.unsafeMutablePointer) }
            for start in stride(from: 0, to: frames, by: block) {
                let count = min(block, frames - start)
                for channel in 0..<channels {
                    for frame in 0..<count { buffer.channel(channel)[frame] = sample(start + frame, channel) }
                    list[channel] = AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(count * 4),
                        mData: buffer.channel(channel).baseAddress)
                }
                try requireStatus(ExtAudioFileWrite(file, UInt32(count), list.unsafeMutablePointer))
            }
        }

        private static func requireStatus(_ status: OSStatus) throws {
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }

        private static func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }

    @Test(arguments: [32_000, 44_100, 48_000], [1, 2])
    func legacyPCMOrderUsesHeaderEvidenceWithoutInventingDeclaredLabels(rate: Int, channels: Int) async throws {
        for (bits, floating) in [(16, false), (24, false), (32, false), (32, true)] {
            let f = try await Fixture.legacyWave(rate: rate, channels: channels, bits: bits, floating: floating)
            #expect(f.format.container.kind == .wave && !f.format.container.extensionMatchesContainer)
            #expect(f.format.channelLayout == .undeclared)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(f.format)
            let preparation = try f.preparation()
            let audio = try await preparation.prepare(f.admission(), expectedFormat: f.format)
            #expect(audio.sourceFrameCount == 441 && audio.sampleRate == rate && audio.channelCount == channels)
            #expect(try encoder.encode(audio.interpretation) == before)
            let window = try await preparation.readWindow(400..<441, from: audio, admission: f.admission())
            for channel in 0..<channels {
                #expect(Array(window.samples[(channel * 41)..<((channel + 1) * 41)])
                    == (400..<441).map { Fixture.sample($0, channel) })
            }
            let warm = try await preparation.prepare(f.admission(), expectedFormat: f.format)
            #expect(warm.sourceFrameCount == audio.sourceFrameCount && warm.interpretation == f.format)
        }
    }

    @Test(arguments: ["byte-rate", "extra-format", "duplicate-format", "duplicate-data",
                      "custom-layout", "overflow-length", "truncated", "extensible-unknown",
                      "wrong-fact", "duplicate-fact", "chunk-budget", "list-custom", "list-unknown", "list-short"])
    func ambiguousLegacyWaveNeverReceivesImplicitChannelOrder(_ mutation: String) async throws {
        do {
            let f = try await Fixture.legacyWave(rate: 44_100, channels: 2, bits: 16, mutation: mutation)
            let evidence = try await SourceDecoder(access: f.access).withDecodingCursor(f.url, source: f.source) {
                $0.legacyWavePCMChannelOrder
            }

            #expect(evidence == nil)
            let preparation = try f.preparation()
            await #expect(throws: (any Error).self) {
                try await preparation.prepare(f.admission(), expectedFormat: f.format)
            }
        } catch let failure as DecodeFailure {
            if !failure.isContentDamage {
                guard case .unsupported = failure else { throw failure }
            }
        }
    }

    @Test(arguments: ["list-info", "list-adtl"])
    func ordinaryWaveAnnotationsKeepUndeclaredRawLayoutAndQualifiedChannelOrder(_ annotation: String) async throws {
        let f = try await Fixture.legacyWave(rate: 44_100, channels: 2, bits: 16, mutation: annotation)
        #expect(f.format.channelLayout == .undeclared)
        let evidence = try await SourceDecoder(access: f.access).withDecodingCursor(f.url, source: f.source) {
            $0.legacyWavePCMChannelOrder
        }
        #expect(evidence != nil)
        let preparation = try f.preparation()
        let audio = try await preparation.prepare(f.admission(), expectedFormat: f.format)
        #expect(audio.interpretation == f.format && audio.sourceFrameCount == 441)
        let window = try await preparation.readWindow(400..<441, from: audio, admission: f.admission())
        #expect(Array(window.samples.prefix(41)) == (400..<441).map { Fixture.sample($0, 0) })
        #expect(Array(window.samples.suffix(41)) == (400..<441).map { Fixture.sample($0, 1) })
    }

    @Test func explicitWaveMaskKeepsItsRawDeclaredFactsWithoutLegacyEvidence() async throws {
        let f = try await Fixture.legacyWave(rate: 44_100, channels: 2, bits: 16, mutation: "explicit-mask")
        #expect(f.format.channelLayout.isDeclaredBySource && f.format.channelLayout.channelLabels == [1, 2])
        let evidence = try await SourceDecoder(access: f.access).withDecodingCursor(f.url, source: f.source) {
            $0.legacyWavePCMChannelOrder
        }
        #expect(evidence == nil)
        let preparation = try f.preparation()
        let audio = try await preparation.prepare(f.admission(), expectedFormat: f.format)
        #expect(audio.interpretation == f.format)
        let window = try await preparation.readWindow(400..<441, from: audio, admission: f.admission())
        #expect(Array(window.samples.prefix(41)) == (400..<441).map { Fixture.sample($0, 0) })
        #expect(Array(window.samples.suffix(41)) == (400..<441).map { Fixture.sample($0, 1) })
    }

    @Test func legacyWaveWarmReadStillRefusesChangedOriginalAndUndeclaredMultichannel() async throws {
        let f = try await Fixture.legacyWave(rate: 48_000, channels: 2, bits: 16)
        let preparation = try f.preparation()
        let audio = try await preparation.prepare(f.admission(), expectedFormat: f.format)
        var changed = try Data(contentsOf: f.url)
        changed[changed.count - 2] ^= 1
        try changed.write(to: f.url)
        await #expect(throws: (any Error).self) {
            try await preparation.readWindow(0..<10, from: audio, admission: f.admission())
        }
        let multi = try await Fixture.legacyWave(rate: 48_000, channels: 3, bits: 16)
        let other = try multi.preparation()
        await #expect(throws: NativeSourcePreparationFailure.unsupportedChannelLayout) {
            try await other.prepare(multi.admission(), expectedFormat: multi.format)
        }
    }

    @Test func exactStereoWindowsBoundariesEOFAndCacheReuse() async throws {
        let fixture = try await Fixture.make()
        let preparation = try fixture.preparation()
        let before = try FileSnapshot(fixture.url)
        let validations = Counter()
        let admission = fixture.admission { validations.increment() }
        let audio = try await preparation.prepare(admission, expectedFormat: fixture.format)
        #expect(audio.sampleRate == 44_100 && audio.channelCount == 2 && audio.sourceFrameCount == 23_457)
        let ranges: [Range<Int64>] = [0..<1, 4095..<4098, 8000..<16_100, 23_456..<23_457, 23_457..<23_457]
        for range in ranges {
            let window = try await preparation.readWindow(range, from: audio, admission: admission)
            #expect(window.samples.count == range.count * 2)
            #expect(window.sampleRate == 44_100)
            #expect(window.isAtEndOfSource == (range.upperBound == audio.sourceFrameCount))
            for channel in 0..<2 {
                let expected = range.map { Fixture.sample(Int($0), channel) }
                #expect(Array(window.samples[channel * range.count..<(channel + 1) * range.count]) == expected)
            }
        }
        let full = try await preparation.readWindow(4090..<8200, from: audio, admission: admission)
        let a = try await preparation.readWindow(4090..<5000, from: audio, admission: admission)
        let b = try await preparation.readWindow(5000..<8200, from: audio, admission: admission)
        for channel in 0..<2 {
            #expect(
                Array(full.samples[channel * 4110..<(channel + 1) * 4110])
                    == Array(a.samples[channel * 910..<(channel + 1) * 910])
                    + Array(b.samples[channel * 3200..<(channel + 1) * 3200]))
        }
        let progress = Counter()
        let reused = try await preparation.prepare(admission, expectedFormat: fixture.format) { _, _ in
            progress.increment()
        }
        #expect(reused.sourceFrameCount == audio.sourceFrameCount)
        #expect(progress.value == 0, "a warm preparation must not decode a prefix")
        #expect(validations.value >= 20, "even cache hits must revalidate current access")
        #expect(try FileSnapshot(fixture.url) == before)
    }

    @Test func lateWindowIsBoundedAndDoesNotDecodeOriginal() async throws {
        let fixture = try await Fixture.make(frames: 2_000_123)
        let decodeReads = Counter()
        var gateway = SystemSourceContentIO()
        gateway.rawFrameReadObserver = { decodeReads.increment() }
        let store = try DerivedAssetStore(
            root: fixture.directory.file("cache/native-source-pcm-v1"),
            sourceLocations: [fixture.url])
        let decoder = SourceDecoder(access: fixture.access, content: gateway, configuration: .init(chunkFrames: 4096))
        let preparation = try NativeSourcePreparation(
            store: store, decoder: decoder,
            configuration: .init(tileFrames: 4096, maximumWindowFrames: 16_384))
        let audio = try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format)
        let afterPreparation = decodeReads.value
        #expect(afterPreparation > 400)
        let start = ContinuousClock.now
        let window = try await preparation.readWindow(
            1_999_900..<2_000_100, from: audio, admission: fixture.admission())
        let elapsed = start.duration(to: .now)
        #expect(window.tilesRead == 1)
        #expect(window.samples.count == 400)
        #expect(decodeReads.value == afterPreparation, "a late prepared window must not decode the original")
        #expect(Array(window.samples.prefix(200)) == (1_999_900..<2_000_100).map { Fixture.sample($0, 0) })
        print("PREPARED late source frame 1999900: \(elapsed), 1 tile, 200 native frames, 0 decode reads")
    }

    @Test func cancellationAndFinalAccessRefusalRemoveUnpublishedTiles() async throws {
        let fixture = try await Fixture.make()
        let preparation = try fixture.preparation()
        let task = Task {
            try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            Issue.record("canceled preparation published")
        } catch { #expect(error is CancellationError || error as? DecodeFailure == .canceled) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.assets.path).isEmpty)
        let validations = Counter()
        let admission = fixture.admission {
            validations.increment()
            if validations.value > 1 { throw NativeSourcePreparationFailure.notAuthorized }
        }
        await #expect(throws: NativeSourcePreparationFailure.notAuthorized) {
            try await preparation.prepare(admission, expectedFormat: fixture.format)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.assets.path).isEmpty)
    }

    @Test func cacheHitsRejectRevokedAccessChangedWitnessFormatAndDamagedTiles() async throws {
        let fixture = try await Fixture.make()
        let preparation = try fixture.preparation()
        let audio = try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format)
        let revoked = fixture.admission { throw NativeSourcePreparationFailure.notAuthorized }
        await #expect(throws: NativeSourcePreparationFailure.notAuthorized) {
            try await preparation.readWindow(0..<10, from: audio, admission: revoked)
        }
        var wrong = fixture.format
        wrong.channelLayout.channelLabels = [2, 1]
        await #expect(throws: NativeSourcePreparationFailure.formatMismatch) {
            try await preparation.prepare(fixture.admission(), expectedFormat: wrong)
        }
        let tiles = try FileManager.default.contentsOfDirectory(at: fixture.assets, includingPropertiesForKeys: nil)
        var damaged = 0
        for tile in tiles {
            var bytes = try Data(contentsOf: tile)
            if bytes.count > 10_000 {
                bytes[bytes.count - 1] ^= 1
                try bytes.write(to: tile)
                damaged += 1
            }
        }
        #expect(damaged > 0)
        await #expect(throws: NativeSourcePreparationFailure.cacheMissingOrDamaged) {
            try await preparation.readWindow(0..<16_000, from: audio, admission: fixture.admission())
        }
        // A live full witness, not saved-review/remount equivalence, is mandatory on reuse.
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: 32)
        try handle.close()
        await #expect(throws: DecodeFailure.self) {
            try await preparation.readWindow(0..<10, from: audio, admission: fixture.admission())
        }
    }

    @Test func storageLimitAndUnknownLayoutAreExplicit() async throws {
        let fixture = try await Fixture.make()
        let preparation = try fixture.preparation(storage: 1000)
        await #expect(throws: NativeSourcePreparationFailure.storageBudgetExceeded) {
            try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format)
        }
        // CAF has no standard legacy-WAVE channel-order contract. Its absent layout remains unknown.
        let unknown = try await Fixture.make(codec: kAudioFormatLinearPCM, declareLayout: false)
        #expect(unknown.format.channelLayout == .undeclared)
        let other = try unknown.preparation()
        await #expect(throws: NativeSourcePreparationFailure.unsupportedChannelLayout) {
            try await other.prepare(unknown.admission(), expectedFormat: unknown.format)
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["WW_MP3_LAME"] != nil,
            "set WW_MP3_LAME to an installed LAME encoder"))
    func mp3PreparedWindowsEqualOneContinuousDecodeAndNeverRestartDecoder() async throws {
        let fixture = try await Fixture.make(frames: 441_123, mp3: true)
        let decodeReads = Counter()
        var gateway = SystemSourceContentIO()
        gateway.rawFrameReadObserver = { decodeReads.increment() }
        let store = try DerivedAssetStore(
            root: fixture.directory.file("cache/native-source-pcm-v1"),
            sourceLocations: [fixture.url])
        let decoder = SourceDecoder(access: fixture.access, content: gateway, configuration: .init(chunkFrames: 4096))
        let preparation = try NativeSourcePreparation(
            store: store, decoder: decoder,
            configuration: .init(tileFrames: 4096, maximumWindowFrames: 16_384))
        let audio = try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format)
        let afterPreparation = decodeReads.value
        let ranges: [Range<Int64>] = [0..<20, 4090..<8200, 430_000..<441_123]
        let reference = try await SourceDecoder(access: fixture.access).withDecodingCursor(
            fixture.url, source: fixture.source
        ) { cursor in
            var channels = Array(repeating: [Float](), count: 2)
            while let chunk = try await cursor.next() {
                for channel in 0..<2 { channels[channel].append(contentsOf: chunk.channel(channel)) }
            }
            return channels
        }
        for range in ranges {
            let actual = try await preparation.readWindow(range, from: audio, admission: fixture.admission())
            for channel in 0..<2 {
                #expect(
                    Array(actual.samples[channel * range.count..<(channel + 1) * range.count])
                        == Array(reference[channel][Int(range.lowerBound)..<Int(range.upperBound)]))
            }
        }
        let progress = Counter()
        _ = try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format) { _, _ in
            progress.increment()
        }
        #expect(progress.value == 0 && decodeReads.value == afterPreparation)
        print("MP3 prepared 441123-frame stereo: 3 exact windows including EOF, 0 warm native decode calls")
    }

    @Test func partialPublicationFailurePreservesPriorVerifiedPreparation() async throws {
        let first = try await Fixture.make()
        let second = try await Fixture.make(frames: 30_001)
        let files = PublicationFaultFiles()
        let store = try DerivedAssetStore(
            root: first.directory.file("cache/native-source-pcm-v1"),
            sourceLocations: [first.url, second.url], files: files)
        let preparation = try NativeSourcePreparation(
            store: store, decoder: SourceDecoder(access: first.access),
            configuration: .init(tileFrames: 4096))
        let prior = try await preparation.prepare(first.admission(), expectedFormat: first.format)
        let before = try FileManager.default.contentsOfDirectory(atPath: first.assets.path).sorted()
        files.failAfterSuccessfulMoves(2)
        await #expect(throws: DerivedAssetStoreError.self) {
            try await preparation.prepare(second.admission(), expectedFormat: second.format)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.assets.path).sorted() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.staging.path).isEmpty)
        let window = try await preparation.readWindow(100..<200, from: prior, admission: first.admission())
        #expect(Array(window.samples.prefix(100)) == (100..<200).map { Fixture.sample($0, 0) })
    }

    @Test func cancellationDuringManifestPublicationCleansCommittedTiles() async throws {
        let fixture = try await Fixture.make()
        let files = PublicationFaultFiles()
        let store = try DerivedAssetStore(
            root: fixture.directory.file("cache/native-source-pcm-v1"),
            sourceLocations: [fixture.url], files: files)
        let preparation = try NativeSourcePreparation(
            store: store, decoder: SourceDecoder(access: fixture.access), configuration: .init(tileFrames: 4096))
        files.cancelOnManifestStage()
        let task = Task {
            try await preparation.prepare(fixture.admission(), expectedFormat: fixture.format)
        }
        do {
            _ = try await task.value
            Issue.record("cancellation during manifest write published a preparation")
        } catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.assets.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    @Test func sourceMutationBeforeFinalCheckCannotPublishTiles() async throws {
        let fixture = try await Fixture.make()
        let preparation = try fixture.preparation()
        let validations = Counter()
        let admission = fixture.admission {
            validations.increment()
            if validations.value == 2 {
                let handle = try FileHandle(forWritingTo: fixture.url)
                try handle.truncate(atOffset: 32)
                try handle.close()
            }
        }
        await #expect(throws: DecodeFailure.sourceChangedDuringDecode) {
            try await preparation.prepare(admission, expectedFormat: fixture.format)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.assets.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    @Test func storageEvictionKeepsTotalBoundAndOldHandlesFail() async throws {
        let first = try await Fixture.make()
        let second = try await Fixture.make()
        let preparation = try first.preparation(storage: 260_000)
        let old = try await preparation.prepare(first.admission(), expectedFormat: first.format)
        let current = try await preparation.prepare(second.admission(), expectedFormat: second.format)
        await #expect(throws: NativeSourcePreparationFailure.cacheMissingOrDamaged) {
            try await preparation.readWindow(0..<10, from: old, admission: first.admission())
        }
        _ = try await preparation.readWindow(0..<10, from: current, admission: second.admission())
        let bytes = try FileManager.default.contentsOfDirectory(
            at: first.assets, includingPropertiesForKeys: [.fileSizeKey]
        )
        .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(bytes <= 260_000)
    }
}

private final class PublicationFaultFiles: FileOperations, @unchecked Sendable {
    private let base = LocalFileOperations()
    private let lock = NSLock()
    private var movesBeforeFailure: Int?
    private var cancelManifest = false

    func failAfterSuccessfulMoves(_ count: Int) { lock.withLock { movesBeforeFailure = count } }
    func cancelOnManifestStage() { lock.withLock { cancelManifest = true } }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws {
        try base.writeNew(data, to: url)
        if lock.withLock({ cancelManifest }),
            String(decoding: data, as: UTF8.self).contains("native-source-pcm-manifest")
        {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    func replace(_ destination: URL, withStaged staged: URL) throws {
        try base.replace(destination, withStaged: staged)
    }
    func moveNew(_ source: URL, to destination: URL) throws {
        let fail = lock.withLock {
            guard let remaining = movesBeforeFailure else { return false }
            if remaining == 0 {
                movesBeforeFailure = nil
                return true
            }
            movesBeforeFailure = remaining - 1
            return false
        }
        if fail { throw CocoaError(.fileWriteUnknown) }
        try base.moveNew(source, to: destination)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try base.makeStagingDirectory(appropriateFor: destination)
    }
}
