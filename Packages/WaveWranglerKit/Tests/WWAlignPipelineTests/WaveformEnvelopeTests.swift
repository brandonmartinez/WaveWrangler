import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Bounded measured waveform envelopes")
struct WaveformEnvelopeTests {
    @Test func selectedPrimaryChannelIsIsolatedInWindowAndOverviewWithoutChangingSourceFormat() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stereo.wav")
        try WaveformTestAudio.wave(rate: 16_000,
            samples: (0..<16_000).flatMap { _ in [Int16(8_192), -24_576] }, channels: 2).write(to: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let source = SourceID()
        let overview = try await WaveformWindowReader.readOverview(
            sourceURL: url, source: source, matching: witness, decoder: decoder, decodedChannel: 0)
        #expect(overview.channelCount == 2 && overview.totalFrames == 16_000)
        #expect(!overview.bins.isEmpty && overview.bins.allSatisfy { $0.minimum == 0.25 && $0.maximum == 0.25 })
        let window = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: 0.25, durationSeconds: 0.25, decodedChannel: 1)
        #expect(window.channelCount == 2 && window.bins.first?.firstFrame == 4_000)
        #expect(window.bins.allSatisfy { $0.minimum == -0.75 && $0.maximum == -0.75 })
        let combined = try await WaveformWindowReader.readOverview(
            sourceURL: url, source: source, matching: witness, decoder: decoder)
        #expect(combined.bins.allSatisfy { $0.minimum == -0.75 && $0.maximum == 0.25 })
        for invalid in [-1, 2] {
            await #expect(throws: WaveformWindowError.invalidSamples) {
                _ = try await WaveformWindowReader.readOverview(
                    sourceURL: url, source: source, matching: witness, decoder: decoder, decodedChannel: invalid)
            }
            await #expect(throws: WaveformWindowError.invalidSamples) {
                _ = try await WaveformWindowReader.readWindow(
                    sourceURL: url, source: source, matching: witness, decoder: decoder,
                    startSeconds: 0, durationSeconds: 1, decodedChannel: invalid)
            }
        }
    }

    @Test func channelBuilderRefusesInvalidChannelsEvenWhenTheWindowIsOutsideTheChunk() {
        for channel in [-1, 2] {
            var builder = WaveformEnvelopeBuilder(firstFrame: 8, endFrame: 10, decodedChannel: channel)
            #expect(throws: WaveformWindowError.invalidSamples) {
                try builder.append(DecodedChunk(firstSourceFrame: 0, frameCount: 1, channelCount: 2, samples: [0.1, 0.2]))
            }
            #expect(builder.bins.isEmpty)
        }
    }

    @Test func overviewRefusesAReaderWithoutVerifiedSeekCapability() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("generated.m4a")
        try WaveformTestAudio.compressedAAC(at: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        await #expect(throws: WaveformWindowError.overviewRequiresPCM) {
            _ = try await WaveformWindowReader.readOverview(
                sourceURL: url, source: SourceID(), matching: witness, decoder: decoder
            )
        }
    }

    @Test func completeOverviewRetainsSingleSamplePeaksAndRefusesInterruptedAdmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("overview.wav")
        let frames = 16_000 * 65
        var samples = Array(repeating: Int16(0), count: frames)
        samples[17] = 24_576
        samples[frames / 2 + 13] = -16_384
        samples[frames - 1] = 8_192
        try WaveformTestAudio.wave(rate: 16_000, samples: samples).write(to: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else { throw DecodeFailure.notFound }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let source = SourceID()
        let envelope = try await WaveformWindowReader.readOverview(
            sourceURL: url, source: source, matching: witness, decoder: decoder
        )
        #expect(envelope.bins.count <= WaveformWindowReader.maximumBins)
        #expect(envelope.bins.first?.firstFrame == 0)
        #expect(envelope.bins.last?.endFrame == Int64(frames))
        #expect(envelope.bins.first?.maximum == 0.75)
        #expect(envelope.bins.contains { $0.minimum == -0.5 })
        #expect(envelope.bins.last?.maximum == 0.25)
        for pair in zip(envelope.bins, envelope.bins.dropFirst()) {
            #expect(pair.0.endFrame == pair.1.firstFrame)
        }
        await #expect(throws: DecodeFailure.permissionDenied) {
            _ = try await WaveformWindowReader.readOverview(
                sourceURL: url, source: source, matching: witness, decoder: decoder
            ) { fraction in
                if fraction > 0 { throw DecodeFailure.permissionDenied }
            }
        }
        do {
            _ = try await WaveformWindowReader.readOverview(
                sourceURL: url, source: source, matching: witness, decoder: decoder
            ) { fraction in
                if fraction > 0 { throw CancellationError() }
            }
            Issue.record("Cancellation must not publish a partial overview")
        } catch {
            #expect(error is CancellationError || error as? DecodeFailure == .cancelled)
        }
        let first = RecordingEpochID()
        let restarted = RecordingEpochID()
        let gapMap = try WaveformTestAudio.map(
            source: source, rate: 16_000, frames: Int64(frames), offset: .zero,
            spans: [
                EpochSpan(startFrame: 0, endFrame: 32_000, epoch: first, groupClockOffset: .zero),
                EpochSpan(startFrame: Int64(frames - 32_000), endFrame: Int64(frames),
                          epoch: restarted, groupClockOffset: .zero),
            ]
        )
        let covered = try await WaveformWindowReader.readOverview(
            sourceURL: url, source: source, matching: witness, decoder: decoder, groupMap: gapMap
        )
        let shiftedMap = try WaveformTestAudio.map(
            source: source, rate: 16_000, frames: Int64(frames), offset: ExactRational(-12),
            spans: [
                EpochSpan(startFrame: 0, endFrame: 32_000, epoch: first, groupClockOffset: .zero),
                EpochSpan(startFrame: Int64(frames - 32_000), endFrame: Int64(frames),
                          epoch: restarted, groupClockOffset: .zero),
            ]
        )
        #expect(try WaveformWindowReader.overviewCoverage(source: source, groupMap: gapMap)
                == WaveformWindowReader.overviewCoverage(source: source, groupMap: shiftedMap))
        #expect(try WaveformWindowReader.overviewCoverage(source: source, groupMap: gapMap)
                == [0..<32_000, Int64(frames - 32_000)..<Int64(frames)])
        try WaveformWindowReader.verifyOverviewCoverage(envelope: covered, groupMap: shiftedMap)
        #expect(throws: WaveformWindowError.mapDoesNotMatchSource) {
            try WaveformWindowReader.verifyOverviewCoverage(
                envelope: WaveformEnvelope(
                    source: source, sampleRate: 16_000, channelCount: 1,
                    totalFrames: Int64(frames - 1), bins: covered.bins
                ), groupMap: shiftedMap
            )
        }
        #expect(covered.bins.count <= WaveformWindowReader.maximumBins)
        #expect(covered.bins.allSatisfy { $0.endFrame <= 32_000 || $0.firstFrame >= Int64(frames - 32_000) })
        #expect(!covered.bins.contains { $0.minimum == -0.5 })
        #expect(covered.bins.first?.maximum == 0.75 && covered.bins.last?.maximum == 0.25)
        do {
            _ = try await WaveformWindowReader.readOverview(
                sourceURL: url, source: source, matching: witness, decoder: decoder
            ) { fraction in
                if fraction == 1 {
                    try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("retired.wav"))
                    try Data(repeating: 0, count: 32).write(to: url)
                }
            }
            Issue.record("A changed source must not publish the completed overview")
        } catch {
            #expect(error as? DecodeFailure == .sourceChangedDuringDecode)
        }
    }

    @Test func readsActualWitnessedAudioWindowAndRefusesReplacedSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("generated.wav")
        let data = WaveformTestAudio.wave(rate: 16_000, samples: Array(repeating: 16_384, count: 32_000))
        try data.write(to: url)
        let access = SourceAccessContext()
        guard case let .success(metadata) = access.io.metadata(at: url) else {
            throw DecodeFailure.notFound
        }
        let decoder = SourceDecoder(access: access)
        let witness = try await decoder.captureRawIdentity(url, matching: metadata.fingerprint)
        let envelope = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: SourceID(), matching: witness, decoder: decoder,
            startSeconds: 0.5, durationSeconds: 0.25
        )
        #expect(envelope.totalFrames == 32_000)
        #expect(envelope.bins.first?.firstFrame == 8_000)
        #expect(envelope.bins.last?.endFrame == 12_000)
        #expect(envelope.bins.allSatisfy { $0.minimum == 0.5 && $0.maximum == 0.5 })
        let source = SourceID()
        let map = try WaveformTestAudio.map(
            source: source, rate: 16_000, frames: 32_000, offset: ExactRational(numerator: -18, denominator: 100)
        )
        let aligned = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: 0.5, durationSeconds: 0.25, groupMap: map
        )
        #expect(aligned.bins.first?.firstFrame == 10_880)
        #expect(aligned.bins.last?.endFrame == 14_880)
        let empty = try await WaveformWindowReader.readWindow(
            sourceURL: url, source: source, matching: witness, decoder: decoder,
            startSeconds: 4, durationSeconds: 1, groupMap: map
        )
        #expect(empty.bins.isEmpty)
        let cancelled = Task {
            try Task.checkCancellation()
            return try await WaveformWindowReader.readWindow(
                sourceURL: url, source: source, matching: witness, decoder: decoder,
                startSeconds: 0, durationSeconds: 1
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled read must not publish an envelope")
        } catch {
            #expect(error is CancellationError || (error as? DecodeFailure) == .cancelled)
        }
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("saved.wav"))
        try data.write(to: url)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            _ = try await WaveformWindowReader.readWindow(
                sourceURL: url, source: SourceID(), matching: witness, decoder: decoder,
                startSeconds: 0, durationSeconds: 1
            )
        }

    }

    @Test func retainsPeaksAcrossChunksAndOppositeChannels() throws {
        var builder = WaveformEnvelopeBuilder(firstFrame: 1, endFrame: 4)
        try builder.append(DecodedChunk(
            firstSourceFrame: 0, frameCount: 2, channelCount: 2,
            samples: [0, 0.7, 0, -0.8]
        ))
        try builder.append(DecodedChunk(
            firstSourceFrame: 2, frameCount: 3, channelCount: 2,
            samples: [0.2, 0.9, 1, -0.3, -0.4, -1]
        ))
        #expect(builder.bins.count == 3)
        #expect(builder.bins.map(\.firstFrame) == [1, 2, 3])
        #expect(builder.bins.map(\.endFrame) == [2, 3, 4])
        #expect(builder.bins[0].minimum == -0.8)
        #expect(builder.bins[0].maximum == 0.7)
        #expect(builder.bins[2].minimum == -0.4)
        #expect(builder.bins[2].maximum == 0.9)
    }

    @Test func boundsDisplayMemoryIndependentlyOfWindowFrames() throws {
        var builder = WaveformEnvelopeBuilder(firstFrame: 100, endFrame: 100 + 480_000)
        for first in stride(from: 100, to: 480_100, by: 1_024) {
            let count = min(1_024, 480_100 - first)
            try builder.append(DecodedChunk(
                firstSourceFrame: Int64(first), frameCount: count, channelCount: 1,
                samples: Array(repeating: 0.25, count: count)
            ))
        }
        #expect(builder.bins.count <= WaveformWindowReader.maximumBins)
        #expect(builder.bins.first?.firstFrame == 100)
        #expect(builder.bins.last?.endFrame == 480_100)
        #expect(builder.bins.allSatisfy { $0.minimum == 0.25 && $0.maximum == 0.25 })
    }

    @Test func refusesNonFiniteAudioInsteadOfDrawingInventedAmplitude() {
        var builder = WaveformEnvelopeBuilder(firstFrame: 0, endFrame: 1)
        #expect(throws: WaveformWindowError.self) {
            try builder.append(DecodedChunk(
                firstSourceFrame: 0, frameCount: 1, channelCount: 1, samples: [.nan]
            ))
        }
        #expect(builder.bins.isEmpty)
    }
}
