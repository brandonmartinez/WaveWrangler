import AVFoundation
import Foundation
import Testing
import WWCore
import WWMix
@testable import WWExport

@Suite("Verified production export jobs", .serialized)
struct ExportJobTests {
    @Test func productionRendererUsesPersistentTrackMixAndRefusesMissingEffect() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = AudioTrack(name: "Music")
        let episode = Episode(title: "Production",
            mix: .init(master: .init(gainDB: -6),
                       audioTracks: [.init(track: track.id, gainDB: -6, balance: 1)]),
            audioArrangement: .init(tracks: [track]))
        let recipe = try MixerRecipe(episode: episode, sources: [],
            programFrames: -731..<4_272, policy: .init(tail: .truncate))
        let result = try await ExportJob().run(request(root, frames: recipe.programFrames), isCurrent: { true }) { sink in
            try await MixerOfflineRenderer.render(recipe: recipe, isCurrent: { true }, input: { frames in
                MixerPCMWindow(frames: frames, channels: [:], audioTracks: [
                    track.id: [[Float](repeating: 0.5, count: frames.count),
                               [Float](repeating: 0.5, count: frames.count)]])
            }, sink: { try await sink($0.firstFrame, $0.channels) })
        }
        #expect(result.succeeded, "\(String(describing: result.problem))")
        let output = try decode(root.appendingPathComponent("out.wav"))
        #expect(output[0].count == 5_003 && output[0].allSatisfy { $0 == 0 })
        let expected = Float(0.5 * pow(10, -12.0 / 20))
        #expect(output[1].allSatisfy { abs($0 - expected) < 0.00001 })

        var broken = episode
        broken.mix?.master.inserts = [.init(component: .init(
            type: 0x61756678, subtype: 0x57574E4F, manufacturer: 0x57574E4F))]
        let unavailable = try MixerRecipe(episode: broken, sources: [],
            programFrames: -731..<4_272, policy: .init(tail: .truncate))
        let failure = try await ExportJob().run(request(root, frames: unavailable.programFrames,
            deliveries: [delivery("missing.wav")]), isCurrent: { true }) { sink in
            try await MixerOfflineRenderer.render(recipe: unavailable, isCurrent: { true }, input: { frames in
                MixerPCMWindow(frames: frames, channels: [:])
            }, sink: { try await sink($0.firstFrame, $0.channels) })
        }
        #expect(failure.problem?.kind == .rendering && failure.published.isEmpty)
        #expect(try entries(root) == ["out.wav"])
    }

    @Test func cleanupPreservesReplacedStagingAndReportsFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: 0..<100)
        let result = try await ExportJob().run(request, isCurrent: { true }, render: render(request), progress: { value in
            guard value.phase == .cleaning else { return }
            do {
                let staging = try #require(FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".ww-export-job-") })
                try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent("moved-owned"))
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                try Data("external".utf8).write(to: staging.appendingPathComponent("external"))
            } catch { Issue.record(error) }
        })
        #expect(!result.succeeded && result.problem?.kind == .cleanup)
        #expect(!result.cleanupErrors.isEmpty && result.published.count == 1)
        let replacement = try #require(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".ww-export-job-") })
        #expect(try String(contentsOf: replacement.appendingPathComponent("external"), encoding: .utf8) == "external")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("moved-owned/production.f32").path))
    }

    @Test func publicationNeverFollowsReplacedEncoderDirectoryOrMovesExternalFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let original = external.appendingPathComponent("encoded.wav")
        try Data("immutable original".utf8).write(to: original)
        let request = try request(root, frames: 0..<100)
        let result = try await ExportJob().run(request, isCurrent: { true }, render: render(request), progress: { value in
            guard value.phase == .publishing else { return }
            do {
                let staging = try #require(FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".ww-export-job-") })
                let encoder = try #require(FileManager.default.contentsOfDirectory(at: staging,
                    includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("ww-export-") })
                try FileManager.default.moveItem(at: encoder, to: root.appendingPathComponent("moved-encoder"))
                try FileManager.default.createSymbolicLink(at: encoder, withDestinationURL: external)
            } catch { Issue.record(error) }
        })
        #expect(result.problem?.kind == .destination && result.published.isEmpty)
        #expect(!result.cleanupErrors.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "immutable original")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out.wav").path))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ww-job-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func delivery(_ name: String = "out.wav", codec: ExportCodec = .wave(.float32),
                          rate: Int = 48_000, channels: Int = 2,
                          dither: ExportDither = .none) throws -> ExportDelivery {
        try .init(filename: name, settings: .init(codec: codec, sampleRate: rate, channels: channels), dither: dither)
    }

    private func request(_ directory: URL, frames: Range<Int64> = -731..<47_272,
                         deliveries: [ExportDelivery]? = nil, protected: [URL] = []) throws -> ExportJobRequest {
        try .init(userSelectedDirectory: directory, protectedLocations: protected, productionFrames: frames,
                  deliveries: deliveries ?? [delivery()])
    }

    private func render(_ request: ExportJobRequest, left: Float = 0.6, right: Float = -0.2) -> ExportJob.Renderer {
        { sink in
            var first = request.productionFrames.lowerBound
            while first < request.productionFrames.upperBound {
                let count = Int(min(997, request.productionFrames.upperBound - first))
                try await sink(first, [[Float](repeating: left, count: count), [Float](repeating: right, count: count)])
                first += Int64(count)
            }
        }
    }

    private func decode(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        let data = try #require(buffer.floatChannelData)
        var result = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in result.indices {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }

    private func entries(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func oneRenderFeedsRealWaveMP3AndAACWithExactNegativeOriginRange() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, deliveries: [
            delivery("stereo.wav"), delivery("mono.wav", rate: 44_100, channels: 1),
            delivery("out.mp3", codec: .mp3(.constantBitrate(kbps: 128)), rate: 44_100),
            delivery("out.m4a", codec: .aacLC(bitrate: 128_000), channels: 1),
        ])
        let counter = Counter()
        let renderer = render(request)
        let result = try await ExportJob().run(request, isCurrent: { true }, render: { sink in
            await counter.increment()
            try await renderer(sink)
        })
        #expect(result.succeeded, "\(String(describing: result.problem)) \(result.cleanupErrors)")
        #expect(await counter.value == 1)
        #expect(result.published.count == 4)
        let stereo = try decode(root.appendingPathComponent("stereo.wav"))
        #expect(stereo.count == 2 && stereo[0].count == 48_003)
        #expect(stereo[0].allSatisfy { $0 == 0.6 })
        #expect(stereo[1].allSatisfy { $0 == -0.2 })
        let mono = try decode(root.appendingPathComponent("mono.wav"))
        #expect(mono.count == 1)
        #expect(mono[0].count == 44_103)
        #expect(mono[0].dropFirst(100).dropLast(100).allSatisfy { abs($0 - 0.2) < 0.0001 })
        #expect(try entries(root) == ["mono.wav", "out.m4a", "out.mp3", "stereo.wav"])
        #expect(result.published[2].inputFrames == 44_103)
        #expect(abs(result.published[2].decodedFrames - 44_103) <= 2_304)
        #expect(abs(result.published[3].decodedFrames - 48_003) <= 3_072)
    }

    @Test(arguments: [44_100, 48_000, 88_200, 96_000])
    func fractionalDurationAndStereoToMonoAverage(rate: Int) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: 123..<5_126,
                                  deliveries: [delivery(rate: rate, channels: 1)])
        let result = try await ExportJob().run(request, isCurrent: { true }, render: render(request, left: 1, right: -1))
        #expect(result.succeeded, "\(String(describing: result.problem))")
        let pcm = try decode(root.appendingPathComponent("out.wav"))[0]
        #expect(pcm.count == Int((5_003 * Double(rate) / 48_000).rounded()))
        #expect(pcm.allSatisfy { abs($0) < 0.000001 })
    }

    @Test func cancellationAndFinalStalenessDiscardAllProvisionalOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: 8..<5_011)
        let job = ExportJob()
        let renderer = render(request)
        let canceled = try await job.run(request, isCurrent: { true }, render: renderer, progress: { value in
            if value.phase == .rendering, value.completedFrames > 0 { await job.cancel() }
        })
        #expect(canceled.problem?.kind == .canceled)
        #expect(canceled.published.isEmpty && canceled.cleanupErrors.isEmpty)
        #expect(try entries(root).isEmpty)
        let currency = Currency()
        let stale = try await job.run(request, isCurrent: { await currency.current }, render: { sink in
            try await renderer(sink)
            await currency.invalidate()
        })
        #expect(stale.problem?.kind == .stale)
        #expect(stale.published.isEmpty && stale.cleanupErrors.isEmpty)
        #expect(try entries(root).isEmpty)
    }

    @Test func rendererFailureAndWrongBoundariesNeverPublishSilenceOrPartialAudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: -123..<5_003)
        for variant in 0..<4 {
            let result = try await ExportJob().run(request, isCurrent: { true }, render: { sink in
                if variant == 0 { throw ExportFailure.encoder("Missing Audio Unit; no bypass") }
                if variant == 1 { throw ExportFailure.destination("Source authorization revoked") }
                try await sink(variant == 2 ? 0 : -123, [[Float](repeating: 0.2, count: 100),
                                                       [Float](repeating: 0.2, count: 100)])
            })
            #expect(result.problem?.kind == .rendering)
            #expect(result.published.isEmpty && result.cleanupErrors.isEmpty)
            #expect(try entries(root).isEmpty)
        }
    }

    @Test func collisionPreflightAndPublicationRaceNeverOverwrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("out.wav")
        try Data("external".utf8).write(to: existing)
        let request = try request(root, frames: 0..<4_800)
        let counter = Counter()
        let refused = try await ExportJob().run(request, isCurrent: { true }, render: { _ in await counter.increment() })
        #expect(refused.problem?.kind == .destination)
        #expect(await counter.value == 0)
        #expect(try Data(contentsOf: existing) == Data("external".utf8))
        try FileManager.default.removeItem(at: existing)
        let raced = try await ExportJob().run(request, isCurrent: { true }, render: render(request), progress: { value in
            if value.phase == .publishing {
                do { try Data("racer".utf8).write(to: existing, options: .withoutOverwriting) }
                catch { Issue.record(error) }
            }
        })
        #expect(raced.problem?.kind == .destination)
        #expect(raced.published.isEmpty && raced.cleanupErrors.isEmpty)
        #expect(try Data(contentsOf: existing) == Data("racer".utf8))
        #expect(try entries(root) == ["out.wav"])
    }

    @Test func partialPublicationReportsOnlyCommittedFilesAndNeverRollsBackExternalChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: 0..<4_800, deliveries: [delivery("first.wav"), delivery("second.wav")])
        let result = try await ExportJob().run(request, isCurrent: { true }, render: render(request), progress: { value in
            if value.phase == .publishing {
                do { try Data("external".utf8).write(to: root.appendingPathComponent("second.wav")) }
                catch { Issue.record(error) }
            }
        })
        #expect(result.problem?.kind == .destination)
        #expect(result.published.map(\.url.lastPathComponent) == ["first.wav"])
        #expect(result.cleanupErrors.isEmpty)
        #expect(try entries(root) == ["first.wav", "second.wav"])
        #expect(try Data(contentsOf: root.appendingPathComponent("second.wav")) == Data("external".utf8))
    }

    @Test func protectedSymlinkAndHardlinkDestinationsAreRefused() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = try request(root, frames: 0..<4_800, protected: [root])
        let result = try await ExportJob().run(protected, isCurrent: { true }, render: render(protected))
        #expect(result.problem?.kind == .destination)
        #expect(try entries(root).isEmpty)
        let symlink = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        let linked = try request(symlink, frames: 0..<4_800)
        let symlinkResult = try await ExportJob().run(linked, isCurrent: { true }, render: render(linked))
        #expect(symlinkResult.problem?.kind == .destination)
        let source = root.appendingPathComponent("original")
        try Data("immutable".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("out.wav"))
        let hardlink = try request(root, frames: 0..<4_800)
        let hardlinkResult = try await ExportJob().run(hardlink, isCurrent: { true }, render: render(hardlink))
        #expect(hardlinkResult.problem?.kind == .destination)
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("production.f32"))
        #expect(throws: ExportFailure.self) { try ExportIntermediate(directory: root, frames: 0..<100) }
        #expect(try Data(contentsOf: source) == Data("immutable".utf8))
    }

    @Test func floatHeadroomPreservedAndIntegerLossyOverloadFailsWithoutAdjustment() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, frames: 0..<4_800)
        let float = try await ExportJob().run(request, isCurrent: { true }, render: render(request, left: 1.25, right: -1.5))
        #expect(float.succeeded)
        let pcm = try decode(root.appendingPathComponent("out.wav"))
        #expect(pcm[0].allSatisfy { $0 == 1.25 } && pcm[1].allSatisfy { $0 == -1.5 })
        for (name, codec) in [("integer.wav", ExportCodec.wave(.int16)),
                              ("lossy.mp3", .mp3(.constantBitrate(kbps: 128)))] {
            let clipped = try self.request(root, frames: 0..<4_800, deliveries: [delivery(name, codec: codec)])
            let result = try await ExportJob().run(clipped, isCurrent: { true }, render: render(clipped, left: 1.25))
            #expect(result.problem?.kind == .encoding)
            #expect(result.published.isEmpty && result.cleanupErrors.isEmpty)
        }
        #expect(try entries(root) == ["out.wav"])
    }

    @Test(arguments: [ExportPCMEncoding.int16, .int24])
    func tpdfQuantizationIsBoundedAndUnbiasedAndNonePreservesSilence(pcm: ExportPCMEncoding) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, deliveries: [
            delivery("none.wav", codec: .wave(pcm), channels: 1),
            delivery("tpdf.wav", codec: .wave(pcm), channels: 1, dither: .tpdf),
        ])
        let result = try await ExportJob().run(request, isCurrent: { true }, render: render(request, left: 0, right: 0))
        #expect(result.succeeded, "\(String(describing: result.problem))")
        #expect(try decode(root.appendingPathComponent("none.wav"))[0].allSatisfy { $0 == 0 })
        let noise = try decode(root.appendingPathComponent("tpdf.wav"))[0]
        let lsb = 1 / Float(1 << (pcm.rawValue - 1))
        #expect(noise.allSatisfy { abs($0) <= lsb })
        #expect(noise.contains { $0 != 0 })
        #expect(abs(noise.reduce(0, +) / Float(noise.count)) < 0.02 * lsb)
    }

    @Test func nameCollisionsRiffLimitAndSingleActiveJob() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ExportFailure.self) { try request(root, deliveries: [delivery("a.wav"), delivery("A.wav")]) }
        #expect(throws: ExportFailure.self) { try delivery("../out.wav") }
        let large = try request(root, frames: 0..<2_000_000_000)
        let refused = try await ExportJob().run(large, isCurrent: { true }, render: { _ in Issue.record("must preflight") })
        #expect(refused.problem?.kind == .destination)
        let request = try request(root, frames: 0..<4_800)
        let job = ExportJob()
        let renderer = render(request)
        let result = try await job.run(request, isCurrent: { true }, render: { sink in
            await #expect(throws: ExportFailure.self) {
                try await job.run(request, isCurrent: { true }, render: renderer)
            }
            try await renderer(sink)
        })
        #expect(result.succeeded)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

private actor Currency {
    var current = true
    func invalidate() { current = false }
}
