import CryptoKit
import Foundation
import Testing
import WWSources
@testable import WWDecode

/// One test case per envelope entry and sample format. Each case writes and decodes every claimed
/// rate × channel-count combination, so the envelope cannot claim anything these tests don't exercise.
struct EnvelopeCase: Sendable, CustomTestStringConvertible {
    let entry: DecodeEnvelope.Entry
    let sampleFormat: SourceSampleFormat

    var testDescription: String { "\(entry.container.rawValue)/\(entry.codec.rawValue) \(sampleFormat)" }

    static let all: [EnvelopeCase] = DecodeEnvelope.entries.flatMap { entry in
        entry.sampleFormats.map { EnvelopeCase(entry: entry, sampleFormat: $0) }
    }
}

@Suite("Decode envelope evidence")
struct DecodeEnvelopeTests {
    /// Chunk sizes rotated across fixtures so every format is read at odd, small and large sizes.
    static let chunkRotation = [7, 1000, 4096, 65_536, 333]

    @Test("Every claimed combination decodes with exact origin", arguments: EnvelopeCase.all)
    func evidence(_ envelopeCase: EnvelopeCase) async throws {
        let directory = try FixtureDirectory("envelope")
        var exercised = 0
        var maximumLag = 0
        var minimumCorrelation: Float = 1
        var primingSeen = Set<Int64>()
        var nonzeroLags: [String] = []
        var index = 0
        for rate in envelopeCase.entry.sampleRates {
            for channels in envelopeCase.entry.channelCounts {
                let spec = FixtureSpec(container: envelopeCase.entry.container, codec: envelopeCase.entry.codec, sampleFormat: envelopeCase.sampleFormat, sampleRate: rate, channelCount: channels)
                let signal = LandmarkSignal(channelCount: channels, seed: UInt64(rate &* 31 &+ channels))
                let url = try directory.write(spec, signal: signal)
                let before = try FileSnapshot(url)
                let chunk = Self.chunkRotation[index % Self.chunkRotation.count]
                index += 1

                let decoded: DecodedSource<CollectedAudio>
                do {
                    decoded = try await decodeAll(url, chunkFrames: chunk)
                } catch {
                    Issue.record("\(spec.testDescription): \(error)")
                    continue
                }
                let result = try Self.verify(decoded, spec: spec, signal: signal)
                maximumLag = max(maximumLag, result.maximumLag)
                if result.maximumLag != 0 { nonzeroLags.append("\(rate)Hz/\(channels)ch:\(result.maximumLag)") }
                minimumCorrelation = min(minimumCorrelation, result.minimumCorrelation)
                primingSeen.insert(decoded.interpretation.frames.primingFrames)
                #expect(try FileSnapshot(url) == before, "\(spec.testDescription): source changed")
                exercised += 1
            }
        }
        let expected = envelopeCase.entry.sampleRates.count * envelopeCase.entry.channelCounts.count
        #expect(exercised == expected)
        print("ENVELOPE \(envelopeCase.testDescription): \(exercised)/\(expected) fixtures, max |lag| \(maximumLag), min corr \(String(format: "%.3f", minimumCorrelation)), priming \(primingSeen.sorted()), nonzero lags \(nonzeroLags)")
    }

    struct Verification {
        var maximumLag: Int
        var minimumCorrelation: Float
    }

    static func verify(_ decoded: DecodedSource<CollectedAudio>, spec: FixtureSpec, signal: LandmarkSignal) throws -> Verification {
        let label = spec.testDescription
        let interpretation = decoded.interpretation
        #expect(interpretation.formatInterpretationVersion == FormatInterpretation.currentVersion)
        #expect(interpretation.envelopeVersion == DecodeEnvelope.version)
        #expect(interpretation.container.kind == spec.container, "\(label)")
        #expect(interpretation.container.extensionMatchesContainer, "\(label)")
        #expect(interpretation.codec.kind == spec.codec, "\(label)")
        #expect(interpretation.sampleFormat == spec.sampleFormat, "\(label)")
        #expect(interpretation.sourceSampleRate == spec.sampleRate, "\(label)")
        #expect(interpretation.channelCount == spec.channelCount, "\(label)")
        #expect(interpretation.output.sampleRate == spec.sampleRate)
        #expect(interpretation.output.representsSourceSamplesExactly == spec.sampleFormat.isExactInFloat32)
        #expect(interpretation.frames.validFrames == Int64(signal.frames), "\(label): declared length")
        #expect(interpretation.origin.decodedFrameCount == Int64(signal.frames))
        #expect(interpretation.origin.sourceSampleRate == spec.sampleRate)
        #expect(interpretation.packets.isVariableBitRate == (spec.codec != .linearPCM), "\(label)")
        if spec.codec.isLossy {
            #expect(interpretation.frames.hasPacketTable && interpretation.frames.primingFrames > 0, "\(label): lossy priming must be declared")
        }
        #expect(decoded.report.leadingStreamFramesDiscarded == interpretation.frames.primingFrames)
        #expect(decoded.report.codecStreamFramesRead >= interpretation.frames.primingFrames + interpretation.frames.validFrames)

        let channels = decoded.product.channels
        try #require(channels.count == spec.channelCount, "\(label)")
        for c in channels.indices {
            try #require(channels[c].count == signal.frames, "\(label): channel \(c) has \(channels[c].count) frames")
        }
        if spec.isExact {
            for c in channels.indices where channels[c] != signal.channels[c] {
                let first = zip(channels[c], signal.channels[c]).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                Issue.record("\(label): channel \(c) is not bit-exact (first difference at source frame \(first))")
            }
        }
        var maximumLag = 0
        var minimumCorrelation: Float = 1
        for c in channels.indices {
            for (k, truth) in signal.landmarks[c].enumerated() {
                let found = LandmarkSignal.locate(signal.bursts[c][k], in: channels[c], near: truth)
                maximumLag = max(maximumLag, abs(found.lag))
                minimumCorrelation = min(minimumCorrelation, found.correlation)
                if spec.isExact {
                    #expect(found.lag == 0 && found.correlation > 0.999, "\(label): ch \(c) landmark \(k) lag \(found.lag) corr \(found.correlation)")
                } else {
                    #expect(abs(found.lag) <= 1 && found.correlation >= 0.5, "\(label): ch \(c) landmark \(k) at \(truth) lag \(found.lag) corr \(found.correlation)")
                }
            }
        }
        return Verification(maximumLag: maximumLag, minimumCorrelation: minimumCorrelation)
    }

    @Test("The envelope's claims are pinned to its version")
    func envelopePinnedToVersion() {
        // Changing any entry must bump `DecodeEnvelope.version` and update this pin.
        let canonical = DecodeEnvelope.entries.map { entry in
            "\(entry.container.rawValue)/\(entry.codec.rawValue):\(entry.sampleFormats.map(\.description).joined(separator: ","))"
                + ":\(entry.sampleRates.map(String.init).joined(separator: ","))"
                + ":\(entry.channelCounts.map(String.init).joined(separator: ","))"
        }.joined(separator: "\n")
        #expect(DecodeEnvelope.version == 1)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "0ad289ecae57d7a1d3e9a4779f556f63e3b3be6625f8f05995b800acd0ebb7fa", "envelope changed: bump DecodeEnvelope.version and update the pin\n\(canonical)")
        #expect(EnvelopeCase.all.count == 34)
    }

    @Test("Chunk size never changes the decoded output", arguments: [
        FixtureSpec(container: .m4a, codec: .aac, sampleFormat: .lossy, sampleRate: 44_100, channelCount: 2),
        FixtureSpec(container: .caf, codec: .opus, sampleFormat: .lossy, sampleRate: 48_000, channelCount: 1),
        FixtureSpec(container: .m4a, codec: .appleLossless, sampleFormat: .lossless(24), sampleRate: 96_000, channelCount: 2),
        FixtureSpec(container: .flac, codec: .flac, sampleFormat: .lossless(16), sampleRate: 48_000, channelCount: 1),
        FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(24, bigEndian: false), sampleRate: 48_000, channelCount: 3),
    ])
    func chunkSizeInvariance(_ spec: FixtureSpec) async throws {
        let directory = try FixtureDirectory("chunks")
        let signal = LandmarkSignal(frames: 8_000, channelCount: spec.channelCount, seed: 7)
        let url = try directory.write(spec, signal: signal)
        var outputs: [[[Float]]] = []
        for chunk in [1, 2, 7, 1023, 1024, 1025, 5_999, 6_000, 6_001, 1 << 20] {
            let decoded = try await decodeAll(url, chunkFrames: chunk)
            #expect(decoded.report.chunkCapacityFrames == chunk)
            #expect(decoded.product.chunkSizes.allSatisfy { $0 <= chunk })
            #expect(decoded.product.chunkSizes.reduce(0, +) == signal.frames)
            outputs.append(decoded.product.channels)
        }
        #expect(outputs.dropFirst().allSatisfy { $0 == outputs[0] }, "\(spec.testDescription): output depends on chunk size")
        if spec.isExact { #expect(outputs[0] == signal.channels) }
    }
}
