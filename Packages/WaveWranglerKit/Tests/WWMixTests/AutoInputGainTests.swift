import Foundation
import Synchronization
import Testing
import WWCore
import WWDecode
import WWDerived
import WWMix
import WWSources

@Suite("Opt-in automatic input gain measurements")
struct AutoInputGainTests {
    private func sine(amplitude: Double, frames: Int = 48_000) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * .pi * 1000 * Double($0) / 48_000)) }
    }

    private func analyze(_ samples: [Float], target: Double = -20, chunk: Int = 16_384) throws -> AutoInputGainResult {
        var analyzer = try AutoInputGainAnalyzer(sampleRate: 48_000, targetDBFS: target)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            try analyzer.append(samples[start..<min(samples.count, start + chunk)])
        }
        return try analyzer.finish()
    }

    @Test func pausesDoNotIncreaseTheRecommendedGainAndTargetsRemainAbsolute() throws {
        let voice = sine(amplitude: 0.05, frames: 38_400)
        let uninterrupted = try analyze(voice)
        let paused = try analyze([Float](repeating: 0, count: 96_000) + voice
            + [Float](repeating: 0, count: 96_000))
        #expect(abs(uninterrupted.activeRMSDBFS - paused.activeRMSDBFS) < 0.0001)
        #expect(abs(paused.activeRMSDBFS + paused.gainDB - paused.targetDBFS) < 0.0001)
        #expect(abs(paused.activeSeconds - 0.8) < 0.0001)
        let lowerTarget = try analyze(voice, target: -26)
        #expect(abs(uninterrupted.gainDB - lowerTarget.gainDB - 6) < 0.0001)
        #expect(!paused.peakLimited && !paused.gainLimited)
    }

    @Test func fullFilePeaksConstrainGainEvenOutsideTheActiveWindows() throws {
        var audio = sine(amplitude: 0.02, frames: 96_000)
        audio += [Float](repeating: 0, count: 48_000)
        audio[audio.count - 1] = 0.95
        let measured = try analyze(audio)
        #expect(measured.peakLimited && measured.gainDB < 0)
        #expect(measured.predictedTruePeakDBFS <= AutoInputGainAnalyzer.peakCeilingDBFS - 0.49)
        #expect(abs(measured.samplePeakDBFS - 20 * log10(0.95)) < 0.001)
        #expect(measured.activeRMSDBFS + measured.gainDB < measured.targetDBFS)
    }

    @Test func intersamplePeaksAndChunkEdgesAreMeasured() throws {
        // A quarter-rate sinusoid sampled 45 degrees off its peaks has a 3.01 dB intersample rise.
        let audio = (0..<48_000).map { index in Float([0.6, 0.6, -0.6, -0.6][index % 4]) }
        let whole = try analyze(audio, chunk: audio.count)
        let split = try analyze(audio, chunk: 997)
        let tinyChunks = try analyze(Array(audio.prefix(19_200)), chunk: 13)
        #expect(whole.estimatedTruePeakDBFS - whole.samplePeakDBFS > 2.9)
        #expect(abs(whole.estimatedTruePeakDBFS - split.estimatedTruePeakDBFS) < 0.000001)
        #expect(abs(whole.gainDB - split.gainDB) < 0.000001)
        #expect(tinyChunks.estimatedTruePeakDBFS - tinyChunks.samplePeakDBFS > 2.9)
        #expect(split.predictedTruePeakDBFS <= AutoInputGainAnalyzer.peakCeilingDBFS)
    }

    @Test func silenceShortAudioNonfiniteSamplesAndInvalidTargetsAreRefused() throws {
        for samples in [[Float](repeating: 0, count: 48_000), sine(amplitude: 0.05, frames: 100),
                        sine(amplitude: 0.00001)] {
            #expect(throws: AutoInputGainFailure.self) { try analyze(samples) }
        }
        for bad in [Float.nan, .infinity, -.infinity] {
            #expect(throws: AutoInputGainFailure.self) { try analyze([bad]) }
        }
        for target in [Double.nan, .infinity, -60, 0] {
            #expect(throws: AutoInputGainFailure.self) { try analyze(sine(amplitude: 0.05), target: target) }
        }
    }

    @Test func gainCapIsReportedAndHotFloatAudioIsAttenuatedWithoutClampingSamples() throws {
        let quiet = try analyze(sine(amplitude: 0.002), target: -12)
        #expect(quiet.gainLimited && quiet.gainDB == EpisodeMixState.gainRangeDB.upperBound)
        let hot = try analyze(sine(amplitude: 2))
        #expect(hot.samplePeakDBFS > 0 && hot.gainDB < 0)
        #expect(hot.predictedTruePeakDBFS <= AutoInputGainAnalyzer.peakCeilingDBFS)
    }

    @Test func witnessedReaderMeasuresOnlyTheSelectedChannelWithoutChangingOriginalBytes() async throws {
        let fixture = try await GainReadFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let left = try await AutoInputGainAnalysis.analyze(
            fixture.admission(), decoder: fixture.decoder, channel: 0, targetDBFS: -20)
        let right = try await AutoInputGainAnalysis.analyze(
            fixture.admission(), decoder: fixture.decoder, channel: 1, targetDBFS: -20)
        #expect(abs(left.activeRMSDBFS - 20 * log10(0.03 / sqrt(2))) < 0.01)
        #expect(abs(right.activeRMSDBFS - 20 * log10(0.2 / sqrt(2))) < 0.01)
        #expect(abs(left.activeSeconds - 2) < 0.001 && abs(right.activeSeconds - 2) < 0.001)
        #expect(left.gainDB > right.gainDB + 10)
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func readerRefusesMissingRevokedAndChangedSourcesAndPropagatesCancellation() async throws {
        let fixture = try await GainReadFixture()
        defer { fixture.remove() }
        await #expect(throws: AutoInputGainFailure.self) {
            try await AutoInputGainAnalysis.analyze(
                fixture.admission(authorized: false), decoder: fixture.decoder, channel: 0, targetDBFS: -20)
        }
        await #expect(throws: CancellationError.self) {
            try await AutoInputGainAnalysis.analyze(
                fixture.admission(), decoder: fixture.decoder, channel: 0, targetDBFS: -20,
                progress: { _ in throw CancellationError() })
        }
        await #expect(throws: AutoInputGainFailure.self) {
            try await AutoInputGainAnalysis.analyze(
                fixture.admission(), decoder: fixture.decoder, channel: 0, targetDBFS: -20,
                progress: { _ in fixture.access.revoke() })
        }
        let changed = try await GainReadFixture()
        defer { changed.remove() }
        await #expect(throws: (any Error).self) {
            try await AutoInputGainAnalysis.analyze(
                changed.admission(), decoder: changed.decoder, channel: 0, targetDBFS: -20,
                progress: { _ in
                    var bytes = try Data(contentsOf: changed.url)
                    bytes[bytes.count - 1] ^= 1
                    try bytes.write(to: changed.url)
                })
        }
    }
}

private final class GainReadAccess: Sendable {
    private let allowed = Mutex(true)
    func revoke() { allowed.withLock { $0 = false } }
    func validate() throws {
        guard allowed.withLock({ $0 }) else { throw AutoInputGainFailure.notAuthorized }
    }
}

private struct GainReadFixture: Sendable {
    let url: URL
    let decoder: SourceDecoder
    let witness: RawSourceIdentity
    let source = SourceID()
    let access = GainReadAccess()

    init() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ww-gain-\(UUID()).wav")
        let rate = 48_000, frames = rate * 2
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(rate)); put(UInt32(rate * 4)); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(frames * 4))
        for frame in 0..<frames {
            let value = sin(2 * .pi * 1000 * Double(frame) / Double(rate))
            for amplitude in [0.03, 0.2] { put(Int16((amplitude * value * 32767).rounded())) }
        }
        try data.write(to: url)
        let io = SystemSourceIO()
        decoder = SourceDecoder(access: .init(io: io))
        guard case let .success(metadata) = io.metadata(at: url) else { throw AutoInputGainFailure.invalidAudio }
        witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
    }

    func admission(authorized: Bool = true) -> SourceReadAdmission {
        .init(source: source, location: url, witness: witness,
              authorization: authorized ? .explicitUserRequest(for: source) : nil, availability: .on,
              validateCurrentAccess: { try access.validate() })
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
