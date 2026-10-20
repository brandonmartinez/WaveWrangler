import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWSources
@testable import WWAlignPipeline

@Suite("Bounded high-resolution waveform overview")
struct WaveformOverviewResolutionTests {
    @Test(arguments: [1, 60, 3_600, 86_400], [16_000, 48_000])
    func overviewDetailIsDurationAwareAndCapped(seconds: Int, rate: Int) {
        let frames = Int64(seconds) * Int64(rate)
        let budget = WaveformWindowReader.overviewBinBudget(coveredFrames: frames, rate: rate)
        #expect(budget == min(65_536, max(2_048, seconds * 50)))
        #expect(WaveformWindowReader.maximumBins == 2_048, "Exact-window decode budgets must not grow")
        #expect(budget * MemoryLayout<WaveformBin>.stride < WaveformWindowReader.overviewWorkingSetBytes)
    }

    @Test func hourLongSourceRetainsResolvableSpeechPauseAndRelativeAmplitude() throws {
        let rate = 16_000
        let frames = Int64(rate * 3_600)
        let budget = WaveformWindowReader.overviewBinBudget(coveredFrames: frames, rate: rate)
        var builder = WaveformEnvelopeBuilder(firstFrame: 0, endFrame: frames, maximumBins: budget)
        let samples: [Float] = (0..<(4 * rate)).map { frame in
            let time = Double(frame) / Double(rate)
            let amplitude: Float = time < 1 ? 0.8 : (time >= 1.6 && time < 2.6 ? 0.2 : 0)
            return frame == 17 ? 1 : (frame.isMultiple(of: 2) ? amplitude : -amplitude)
        }
        try builder.append(DecodedChunk(firstSourceFrame: Int64(15 * rate), frameCount: samples.count,
                                        channelCount: 1, samples: samples))
        let bins = builder.bins
        #expect(bins.count <= WaveformWindowReader.maximumOverviewBins)
        #expect(bins.contains { $0.maximum == 1 }, "A one-sample peak survives the overview reduction")
        let pause = bins.filter {
            $0.firstFrame >= Int64(16 * rate) && $0.endFrame <= Int64(16.6 * Double(rate))
        }
        #expect(!pause.isEmpty && pause.allSatisfy { $0.minimum == 0 && $0.maximum == 0 })
        let silentFrames = pause.reduce(Int64(0)) { $0 + $1.endFrame - $1.firstFrame }
        #expect(Double(silentFrames) / Double(rate) > 0.4,
                "Whole-hour bins must not flatten the resolvable 600 ms speech pause")
        #expect(bins.contains {
            $0.firstFrame >= Int64(16.7 * Double(rate)) && $0.endFrame <= Int64(17 * rate)
                && $0.minimum == -0.2 && $0.maximum == 0.2
        }, "Quiet speech remains quieter than the preceding loud phrase")
        for duration in [30.0, 60, 300] {
            #expect(Double(silentFrames) / Double(rate) / duration * 900 >= 1,
                    "This measured pause is resolvable at the tested viewport, not a subpixel promise")
        }
    }

    @Test func oldCoarseOverviewKeysCannotReuseHighResolutionPayloads() {
        let source = SourceRevision(source: SourceID(), token: "synthetic unchanged source")
        for suffix in ["", ".channel.0", ".channel.1"] {
            let legacy = DerivedAssetKey(
                asset: AssetSpec(kind: "ww.waveform.overview\(suffix)", revision: 2),
                sources: [source], format: .current, coverage: "unchanged-source-frame-coverage")
            var current = legacy
            current.asset.revision = WaveformWindowReader.overviewRecipeRevision
            #expect(current.asset.revision == 3)
            #expect(current.digest != legacy.digest)
            #expect(current.sources == legacy.sources && current.coverage == legacy.coverage)
        }
    }

    @Test func cachedPayloadUsesSharedAdmissionAndReleasesItAfterSuccessAndRefusal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let url = sourceFolder.appendingPathComponent("synthetic.wav")
        let original = WaveformTestAudio.wave(rate: 16_000,
            samples: (0..<32_000).map { $0.isMultiple(of: 2) ? Int16(8_192) : -8_192 })
        try original.write(to: url)
        let decoder = SourceDecoder(access: SourceAccessContext())
        guard case let .success(metadata) = decoder.access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let coordinator = DerivedJobCoordinator(
            store: try DerivedAssetStore(root: folder.appendingPathComponent("cache"), sourceLocations: [url]))
        let pipeline = AlignmentPipeline(coordinator: coordinator, decoder: decoder)
        let source = SourceID()
        let payload = try await pipeline.waveformOverviewPayload(sourceURL: url, source: source, matching: witness)
        let envelope = try JSONDecoder().decode(WaveformEnvelope.self, from: payload)
        #expect(envelope.source == source && envelope.totalFrames == 32_000)
        #expect(envelope.bins.allSatisfy { $0.minimum == -0.25 && $0.maximum == 0.25 })
        var admission = await pipeline.gate.snapshot
        #expect(admission.active == 0 && admission.activeBytes == 0 && admission.admitted == 1)
        #expect(admission.peakBytes == WaveformWindowReader.overviewWorkingSetBytes
                + decoder.configuration.chunkFrames * 8 * MemoryLayout<Float>.stride * 2)
        await #expect(throws: DecodeFailure.permissionDenied) {
            _ = try await pipeline.waveformOverviewPayload(sourceURL: url, source: source, matching: witness) { _ in
                throw DecodeFailure.permissionDenied
            }
        }
        admission = await pipeline.gate.snapshot
        #expect(admission.active == 0 && admission.activeBytes == 0 && admission.admitted == 2)
        #expect(try Data(contentsOf: url) == original)
        await coordinator.shutdown()
    }
}
