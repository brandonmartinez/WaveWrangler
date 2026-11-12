import AVFoundation
import AudioToolbox
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WWExport

@Suite("Generated PCM export codecs", .serialized)
struct ExportCodecTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ww-codec-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func pcm(start: Int, count: Int, settings: ExportSettings) -> [Float] {
        (start..<(start + count)).flatMap { frame in
            (0..<settings.channels).map { channel in
                Float(0.3 * sin(2 * .pi * Double(440 + channel * 220) * Double(frame) / Double(settings.sampleRate)))
            }
        }
    }

    private func encode(_ settings: ExportSettings, directory: URL, metadata: ExportMetadata = .init(),
                        frameCount: Int? = nil) async throws -> (ExportEncoder, VerifiedExport) {
        let encoder = try ExportEncoder(stagingDirectory: directory, settings: settings, metadata: metadata)
        let count = frameCount ?? settings.sampleRate / 3
        var start = 0
        while start < count {
            let size = min(997, count - start)
            try await encoder.append(interleaved: pcm(start: start, count: size, settings: settings))
            start += size
        }
        return (encoder, try await encoder.finish())
    }

    private func checkSignal(_ result: VerifiedExport) throws {
        let file = try AVAudioFile(forReading: result.stagingURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var energy = [Double](repeating: 0, count: result.settings.channels)
        var total = 0
        while total < result.decodedFrames {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, result.decodedFrames - Int64(total))))
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<result.settings.channels {
                for frame in 0..<count {
                    let value = channels[channel][frame]
                    energy[channel] += Double(value * value)
                    if case .wave(let representation) = result.settings.codec {
                        let source = pcm(start: total + frame, count: 1, settings: result.settings)[channel]
                        let tolerance: Float = representation == .float32 ? 0 : 1 / pow(2, Float(representation.rawValue - 1))
                        #expect(abs(value - source) <= tolerance)
                    }
                }
            }
            total += count
        }
        for value in energy { #expect(value / Double(total) > 0.02) }
    }

    @Test func allWaveRepresentationsRatesAndChannels() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for representation in ExportPCMEncoding.allCases {
            for rate in [44_100, 48_000, 88_200, 96_000] {
                for channels in [1, 2] {
                    let settings = try ExportSettings(codec: .wave(representation), sampleRate: rate, channels: channels)
                    let (encoder, result) = try await encode(settings, directory: root)
                    #expect(result.decodedFrames == result.inputFrames)
                    try checkSignal(result)
                    try await encoder.cancel()
                }
            }
        }
    }

    @Test func mp3CBRAndVBRRatesAndChannels() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [44_100, 48_000] {
            for channels in [1, 2] {
                let modes = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                    .map { ExportMP3Mode.constantBitrate(kbps: $0) }
                    + (0...9).map { .variableBitrate(quality: $0) }
                for mode in modes {
                    do {
                        let settings = try ExportSettings(codec: .mp3(mode), sampleRate: rate, channels: channels)
                        let (encoder, result) = try await encode(settings, directory: root)
                        #expect(abs(result.decodedFrameDelta) <= 2304)
                        try checkSignal(result)
                        try await encoder.cancel()
                    } catch {
                        Issue.record(error, "MP3 rate=\(rate) channels=\(channels) mode=\(mode)")
                    }
                }
            }
        }
    }

    @Test func aacBitratesRatesAndChannels() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [44_100, 48_000] {
            for channels in [1, 2] {
                for bitrate in [64_000, 96_000, 128_000, 160_000, 192_000, 256_000] {
                    do {
                        let settings = try ExportSettings(codec: .aacLC(bitrate: bitrate), sampleRate: rate, channels: channels)
                        let (encoder, result) = try await encode(settings, directory: root, frameCount: rate * 2)
                        #expect(abs(result.decodedFrameDelta) <= 3072)
                        let actualBitrate = try averageBitrate(result.stagingURL)
                        #expect(abs(actualBitrate - bitrate) <= bitrate / 20,
                                "AAC target \(bitrate), measured \(actualBitrate)")
                        try checkSignal(result)
                        try await encoder.cancel()
                    } catch {
                        Issue.record(error, "AAC rate=\(rate) channels=\(channels) bitrate=\(bitrate)")
                    }
                }
            }
        }
    }

    private func averageBitrate(_ url: URL) throws -> Int {
        var opened: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr)
        let file = try #require(opened)
        defer { #expect(AudioFileClose(file) == noErr) }
        var bitrate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #expect(AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitrate) == noErr)
        return Int(bitrate)
    }

    private func artwork(_ format: ExportArtwork.Format) throws -> ExportArtwork {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try ExportArtwork(data: data as Data, format: format)
    }

    @Test func unicodeMetadataAndArtworkRoundTrip() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for codec in [ExportCodec.mp3(.variableBitrate(quality: 2)), .aacLC(bitrate: 128_000)] {
            for imageFormat in [ExportArtwork.Format.jpeg, .png] {
                let metadata = ExportMetadata(title: "Caf\u{e9} episode", artist: "Host", album: "Show",
                                              publicDescription: "Public summary", copyright: "Copyright 2026",
                                              genre: "Podcast", date: "2026-11-12", episodeNumber: 42,
                                              artwork: try artwork(imageFormat))
                let (encoder, result) = try await encode(ExportSettings(codec: codec), directory: root,
                                                        metadata: metadata)
                let asset = AVURLAsset(url: result.stagingURL)
                let items = try await asset.load(.metadata)
                var strings: [String] = []
                var images: [Data] = []
                var numbers: [Int] = []
                for item in items {
                    if let string = try await item.load(.stringValue) { strings.append(string) }
                    if let data = try await item.load(.dataValue) { images.append(data) }
                    if let number = try await item.load(.numberValue) { numbers.append(number.intValue) }
                }
                for value in ["Caf\u{e9} episode", "Host", "Show", "Public summary",
                              "Copyright 2026", "Podcast", "2026-11-12"] {
                    #expect(strings.contains(value), "Missing metadata: \(value), got \(strings)")
                }
                #expect(images.contains(try #require(metadata.artwork).data))
                #expect(strings.contains("42") || numbers.contains(42))
                try await encoder.cancel()
            }
        }
    }

    @Test func waveTextSubsetRoundTrip() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ExportMetadata(title: "Episode", artist: "Host", album: "Show",
                                      publicDescription: "Public description", copyright: "Copyright 2026",
                                      genre: "Podcast", date: "2026-11-12")
        let (encoder, result) = try await encode(ExportSettings(codec: .wave(.int24)), directory: root,
                                                metadata: metadata)
        let bytes = try Data(contentsOf: result.stagingURL)
        for (key, value) in [("INAM", "Episode"), ("IART", "Host"), ("IPRD", "Show"),
                             ("ICMT", "Public description"), ("ICOP", "Copyright 2026"),
                             ("IGNR", "Podcast"), ("ICRD", "2026-11-12")] {
            let range = try #require(bytes.range(of: Data(key.utf8)))
            let size = bytes[(range.upperBound)..<(range.upperBound + 4)].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let start = range.upperBound + 4
            #expect(String(data: bytes[start..<(start + Int(size) - 1)], encoding: .ascii) == value)
        }
        try checkSignal(result)
        try await encoder.cancel()
    }

    @Test func rejectionAndLifecycle() async throws {
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .mp3(.constantBitrate(kbps: 129))) }
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .mp3(.constantBitrate(kbps: 32))) }
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .mp3(.variableBitrate(quality: -1))) }
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .mp3(.variableBitrate(quality: 2)), sampleRate: 96_000) }
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .aacLC(bitrate: 123_456)) }
        #expect(throws: ExportFailure.self) { try ExportSettings(codec: .aacLC(bitrate: 128_000), sampleRate: 96_000) }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try ExportSettings(codec: .wave(.int16))
        #expect(throws: (any Error).self) {
            try ExportEncoder(stagingDirectory: root.appendingPathComponent("absent"), settings: settings)
        }

        #expect(throws: ExportFailure.self) {
            try ExportEncoder(stagingDirectory: root, settings: settings,
                              metadata: .init(title: "bad\0title"))
        }
        #expect(throws: ExportFailure.self) {
            try ExportEncoder(stagingDirectory: root, settings: settings, metadata: .init(episodeNumber: 1))
        }
        #expect(throws: ExportFailure.self) { try ExportArtwork(data: Data([1, 2]), format: .png) }
        for invalid: [Float] in [[], [0], [.nan, 0], [.infinity, 0], [1.01, 0],
                                 [Float](repeating: 0, count: (ExportEncoder.maximumBlockFrames + 1) * 2)] {
            let encoder = try ExportEncoder(stagingDirectory: root, settings: settings)
            await #expect(throws: ExportFailure.self) { try await encoder.append(interleaved: invalid) }
            await #expect(throws: ExportFailure.invalidState) { try await encoder.finish() }
            try await encoder.cancel()
            try await encoder.cancel()
        }
        let empty = try ExportEncoder(stagingDirectory: root, settings: settings)
        await #expect(throws: ExportFailure.self) { try await empty.finish() }
        try await empty.cancel()
        let (encoder, result) = try await encode(settings, directory: root)
        await #expect(throws: ExportFailure.invalidState) { try await encoder.finish() }
        await #expect(throws: ExportFailure.invalidState) { try await encoder.append(interleaved: [0, 0]) }
        #expect(FileManager.default.fileExists(atPath: result.stagingURL.path))
        try await encoder.cancel()
        #expect(!FileManager.default.fileExists(atPath: result.stagingURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func floatWavePreservesOverRangeButIntegerAndLossyRejectIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples: [Float] = [1.5, -2.25, 0.25, -0.5]
        let encoder = try ExportEncoder(stagingDirectory: root, settings: ExportSettings(codec: .wave(.float32)))
        try await encoder.append(interleaved: samples)
        let result = try await encoder.finish()
        let file = try AVAudioFile(forReading: result.stagingURL, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2))
        try file.read(into: buffer, frameCount: 2)
        let values = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: 4))
        #expect(values == samples)
        try await encoder.cancel()
        for codec in [ExportCodec.wave(.int16), .wave(.int24), .mp3(.constantBitrate(kbps: 128)),
                      .aacLC(bitrate: 128_000)] {
            let bounded = try ExportEncoder(stagingDirectory: root, settings: ExportSettings(codec: codec))
            await #expect(throws: ExportFailure.self) { try await bounded.append(interleaved: samples) }
            try await bounded.cancel()
        }
        let nonfinite = try ExportEncoder(stagingDirectory: root, settings: ExportSettings(codec: .wave(.float32)))
        await #expect(throws: ExportFailure.self) { try await nonfinite.append(interleaved: [.nan, 0]) }
        try await nonfinite.cancel()
    }

    @Test func shortAndMaximumBlocksAndCancellation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for codec in [ExportCodec.wave(.int24), .mp3(.constantBitrate(kbps: 64)), .aacLC(bitrate: 128_000)] {
            let settings = try ExportSettings(codec: codec)
            for frameCount in [1, ExportEncoder.maximumBlockFrames] {
                let encoder = try ExportEncoder(stagingDirectory: root, settings: settings)
                try await encoder.append(interleaved: pcm(start: 0, count: frameCount, settings: settings))
                let result = try await encoder.finish()
                #expect(result.inputFrames == frameCount)
                #expect(result.decodedFrames > 0)
                try await encoder.cancel()
            }
            let partial = try ExportEncoder(stagingDirectory: root, settings: settings)
            try await partial.append(interleaved: pcm(start: 0, count: 100, settings: settings))
            try await partial.cancel()
            await #expect(throws: ExportFailure.invalidState) { try await partial.finish() }

            let canceledAppend = try ExportEncoder(stagingDirectory: root, settings: settings)
            let appendTask = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await canceledAppend.append(interleaved: [0, 0])
            }
            await #expect(throws: CancellationError.self) { try await appendTask.value }
            try await canceledAppend.cancel()

            let canceledFinish = try ExportEncoder(stagingDirectory: root, settings: settings)
            try await canceledFinish.append(interleaved: [0, 0])
            let finishTask = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await canceledFinish.finish()
            }
            await #expect(throws: CancellationError.self) { try await finishTask.value }
            try await canceledFinish.cancel()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func mp3TruncationAndIncorrectGaplessDurationAreRejected() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try ExportSettings(codec: .mp3(.constantBitrate(kbps: 96)), sampleRate: 44_100)
        let (encoder, result) = try await encode(settings, directory: root)
        #expect(throws: ExportFailure.self) {
            try ExportVerifier.verify(url: result.stagingURL, settings: settings, expectedFrames: result.inputFrames + 1)
        }
        let wrongBitrate = try ExportSettings(codec: .mp3(.constantBitrate(kbps: 128)), sampleRate: 44_100)
        #expect(throws: ExportFailure.self) {
            try ExportVerifier.verify(url: result.stagingURL, settings: wrongBitrate, expectedFrames: result.inputFrames)
        }
        let handle = try FileHandle(forWritingTo: result.stagingURL)
        try handle.truncate(atOffset: UInt64(result.byteCount - 1))
        try handle.close()
        #expect(throws: ExportFailure.self) {
            try ExportVerifier.verify(url: result.stagingURL, settings: settings, expectedFrames: result.inputFrames)
        }
        try await encoder.cancel()
    }

    @Test func truncatedOutputsFailVerification() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for codec in [ExportCodec.wave(.int16), .mp3(.constantBitrate(kbps: 128)), .aacLC(bitrate: 128_000)] {
            let settings = try ExportSettings(codec: codec)
            let (encoder, result) = try await encode(settings, directory: root)
            let handle = try FileHandle(forWritingTo: result.stagingURL)
            try handle.truncate(atOffset: 20)
            try handle.close()
            #expect(throws: (any Error).self) {
                try ExportVerifier.verify(url: result.stagingURL, settings: settings, expectedFrames: result.inputFrames)
            }
            try await encoder.cancel()
        }
    }
}
