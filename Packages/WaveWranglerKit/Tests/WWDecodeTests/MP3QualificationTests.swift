import Foundation
import Testing
import WWCore

@testable import WWDecode

/// Opt-in generation uses an already-installed LAME, never downloaded media or an encoder dependency.
enum MP3Fixture {
    static var encoder: String? { ProcessInfo.processInfo.environment["WW_MP3_LAME"] }

    static func write(
        in directory: FixtureDirectory, signal: LandmarkSignal, rate: Int, vbr: Bool,
        frameCount: Int? = nil, options: [String] = []
    ) throws -> URL {
        let input: URL
        if let frameCount {
            var data = Data("RIFF".utf8)
            let channels = signal.channels.count
            func u32(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            func u16(_ value: UInt16) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            u32(UInt32(36 + frameCount * channels * 2))
            data.append(contentsOf: "WAVEfmt ".utf8)
            u32(16)
            u16(1)
            u16(UInt16(channels))
            u32(UInt32(rate))
            u32(UInt32(rate * channels * 2))
            u16(UInt16(channels * 2))
            u16(16)
            data.append(contentsOf: "data".utf8)
            u32(UInt32(frameCount * channels * 2))
            for frame in 0..<frameCount {
                for channel in signal.channels {
                    u16(UInt16(bitPattern: Int16((channel[frame] * 32768).rounded())))
                }
            }
            input = try directory.writeBytes(data, as: "\(UUID().uuidString).wav")
        } else {
            input = try directory.write(
                FixtureSpec(
                    container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false),
                    sampleRate: rate, channelCount: signal.channels.count), signal: signal)
        }
        let output = directory.file("\(UUID().uuidString).mp3")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(encoder))
        process.arguments =
            ["--silent", "--noreplaygain", "--add-id3v2", "--tt", "Generated qualification"]
            + (vbr ? ["-V", "2"] : ["-b", "128"])
            + options + [input.path, output.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return output
    }
}

@Suite("MP3 qualification", .serialized)
struct MP3QualificationTests {
    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func cbrVbrAccountingAndAudibleOrigin() async throws {
        let directory = try FixtureDirectory("mp3-probe")
        for rate in [32_000, 44_100, 48_000] {
            for channels in [1, 2] {
                for vbr in [false, true] {
                    for mode in channels == 1 ? ["m"] : ["s", "j"] {
                        let signal = LandmarkSignal(channelCount: channels, seed: 469)
                        let url = try MP3Fixture.write(
                            in: directory, signal: signal, rate: rate, vbr: vbr,
                            options: ["-m", mode])
                        let before = try FileSnapshot(url)
                        let decoded = try await decodeAll(url, chunkFrames: 1000)
                        let format = decoded.interpretation
                        #expect(format.container.kind == .mp3 && format.codec.kind == .mp3)
                        #expect(format.sourceSampleRate == rate && format.channelCount == channels)
                        #expect(format.frames.validFrames == Int64(signal.frames))
                        #expect(format.origin.sourceFrameOfFirstDecodedFrame == 0)
                        #expect(format.frames.primingFrames == 576 && format.frames.hasPacketTable)
                        #expect(format.packets.isVariableBitRate == vbr)
                        #expect(format.channelLayout.channelLabels == (channels == 1 ? [42] : [1, 2]))
                        #expect(decoded.product.channels.allSatisfy { $0.count == signal.frames })
                        #expect(decoded.report.codecStreamFramesRead == format.packets.packetCount! * 1152)
                        for channel in 0..<channels {
                            for (index, landmark) in signal.landmarks[channel].enumerated() {
                                let found = LandmarkSignal.locate(
                                    signal.bursts[channel][index],
                                    in: decoded.product.channels[channel], near: landmark)
                                #expect(found.lag == 0 && found.correlation > 0.95)
                            }
                        }
                        #expect(try FileSnapshot(url) == before)
                        print(
                            "MP3 \(rate)Hz \(channels)ch mode=\(mode) \(vbr ? "VBR" : "CBR"): valid=\(format.frames.validFrames), delay=\(format.frames.primingFrames), padding=\(format.frames.remainderFrames)"
                        )
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func shortCountsAndChunkBoundaries() async throws {
        let directory = try FixtureDirectory("mp3-short")
        let signal = LandmarkSignal(channelCount: 2, seed: 470)
        for frames in [1, 47, 575, 576, 1151, 1152, 1153, 2345] {
            for vbr in [false, true] {
                let url = try MP3Fixture.write(
                    in: directory, signal: signal, rate: 44_100, vbr: vbr, frameCount: frames)
                let a = try await decodeAll(url, chunkFrames: 7)
                let b = try await decodeAll(url, chunkFrames: 4096)
                #expect(a.interpretation.frames.validFrames == Int64(frames))
                #expect(a.product.channels.allSatisfy { $0.count == frames })
                #expect(a.product.channels == b.product.channels)
            }
        }
    }

    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func longAccountingAndAsymmetricStereo() async throws {
        let directory = try FixtureDirectory("mp3-long")
        let signal = LandmarkSignal(frames: 48_000 * 90 + 123, channelCount: 2, seed: 471)
        let url = try MP3Fixture.write(in: directory, signal: signal, rate: 48_000, vbr: true)
        let decoded = try await decodeAll(url, chunkFrames: 16_384)
        #expect(decoded.interpretation.frames.validFrames == Int64(signal.frames))
        #expect(decoded.product.channels.allSatisfy { $0.count == signal.frames })
        for channel in 0..<2 {
            let found = LandmarkSignal.locate(
                signal.bursts[channel][2],
                in: decoded.product.channels[channel], near: signal.landmarks[channel][2])
            #expect(found.lag == 0 && found.correlation > 0.95)
        }
    }

    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func refusesUnknownAccountingTruncationAndCorruption() async throws {
        let directory = try FixtureDirectory("mp3-failures")
        let signal = LandmarkSignal(channelCount: 2, seed: 472)
        let url = try MP3Fixture.write(in: directory, signal: signal, rate: 48_000, vbr: true)
        let bytes = try Data(contentsOf: url)
        let reader = try SystemSourceContentIO().openForDecoding(url)
        let evidence = try #require(reader.facts.mp3Accounting)
        reader.close()
        for removed in [129, 300, bytes.count / 2] {
            let cut = try directory.writeBytes(bytes.dropLast(removed), as: "cut-\(removed).mp3")
            let failure = try #require(await decodeFailure(cut))
            #expect(failure.isContentDamage)
        }
        var damaged = bytes
        damaged[Int(evidence.firstAudioByte) + 100] ^= 0x40
        let corrupt = try directory.writeBytes(damaged, as: "corrupt.mp3")
        let failure = try #require(await decodeFailure(corrupt))
        #expect(failure.isContentDamage)
        let noTag = try MP3Fixture.write(
            in: directory, signal: signal, rate: 48_000, vbr: false, options: ["-t"])
        #expect(await decodeFailure(noTag) == .unsupported(.encoderDelayUnknown))
        let lowRate = try MP3Fixture.write(in: directory, signal: signal, rate: 22_050, vbr: false)
        if case .unsupported(.mp3Accounting)? = await decodeFailure(lowRate) {
        } else {
            Issue.record("MPEG-2 must not be admitted")
        }
        let renamed = try directory.copy(url, as: "qualified.wav")
        let decoded = try await decodeAll(renamed)
        #expect(decoded.interpretation.container.kind == .mp3)
        #expect(!decoded.interpretation.container.extensionMatchesContainer)
    }

    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func cancellationAndSourceMutationAbandon() async throws {
        let directory = try FixtureDirectory("mp3-abandon")
        let signal = LandmarkSignal(channelCount: 2, seed: 473)
        let url = try MP3Fixture.write(in: directory, signal: signal, rate: 48_000, vbr: false)
        let canceled = SinkJournal()
        let task = Task {
            try await makeDecoder(chunkFrames: 257).decode(url, source: SourceID()) { format in
                JournalingSink(
                    inner: CollectingSink(channelCount: format.channelCount), journal: canceled,
                    onAppend: { _ in withUnsafeCurrentTask { $0?.cancel() } })
            }
        }
        do {
            _ = try await task.value
            Issue.record("canceled decode published")
        } catch { #expect(error as? DecodeFailure == .canceled) }
        #expect(canceled.events.last == "abandon" && !canceled.events.contains("finish"))
        let changed = SinkJournal()
        let io = AdjustableIO { result, call in
            if call > 0 { result.modify { $0.fingerprint.fileSize = .known(1) } }
        }
        do {
            _ = try await makeDecoder(io: io).decode(url, source: SourceID()) { format in
                JournalingSink(inner: CollectingSink(channelCount: format.channelCount), journal: changed)
            }
            Issue.record("stale decode published")
        } catch { #expect(error == .sourceChangedDuringDecode) }
        #expect(changed.events.last == "abandon" && !changed.events.contains("finish"))
    }

    @Test(.enabled(if: MP3Fixture.encoder != nil, "set WW_MP3_LAME to an installed LAME encoder"))
    func leadingMetadataIsNotTheDecodedOrigin() async throws {
        let directory = try FixtureDirectory("mp3-leading-metadata")
        let signal = LandmarkSignal(channelCount: 2, seed: 474)
        let url = try MP3Fixture.write(in: directory, signal: signal, rate: 44_100, vbr: true)
        let bytes = try Data(contentsOf: url)
        try #require(bytes.prefix(3) == Data("ID3".utf8))
        let size = bytes[6..<10].reduce(0) { $0 << 7 | Int($1) }
        let audio = bytes.dropFirst(10 + size)
        let untagged = try directory.writeBytes(Data(audio), as: "no-leading-tag.mp3")
        var id3v4 = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 1, 0, 0])
        id3v4.append(Data(count: 16_384))
        id3v4.append(audio)
        let padded = try directory.writeBytes(id3v4, as: "id3v4-padding.mp3")
        let expected = try await decodeAll(url)
        #expect(try await decodeAll(untagged).product.channels == expected.product.channels)
        #expect(try await decodeAll(padded).product.channels == expected.product.channels)
    }

    @Test func profileRefusalsDoNotNeedAnEncoder() {
        for header: [UInt8] in [
            [0xff, 0xf3, 0x90, 0], [0xff, 0xfa, 0x90, 0], [0xff, 0xfb, 0, 0],
            [0xff, 0xfb, 0x90, 0x80], [0, 0, 0, 0],
        ] {
            #expect(throws: DecodeFailure.self) { try MP3FrameHeader(header[...]) }
        }
        var frame = [UInt8](repeating: 0, count: 417)
        frame.replaceSubrange(0..<4, with: [0xff, 0xfb, 0x90, 0])
        #expect(throws: DecodeFailure.unsupported(.encoderDelayUnknown)) {
            try MP3Qualification.firstFrame(frame, at: 0)
        }
    }
}
