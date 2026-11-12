import AVFoundation
import Foundation
import Testing
@testable import WWExport

@Suite("Export loudness", .serialized)
struct ExportLoudnessTests {
    private func tone(_ first: Int, count: Int, rate: Int, channels: Int = 2,
                      frequency: Double = 1_000, amplitude: Double = 0.1,
                      phase: Double = 0) -> [Float] {
        (first..<(first + count)).flatMap { frame in
            [Float](repeating: Float(amplitude * sin(2 * .pi * frequency * Double(frame) / Double(rate) + phase)),
                    count: channels)
        }
    }

    private func measure(rate: Int = 48_000, channels: Int = 2, seconds: Int = 3,
                         samples: (Int, Int) -> [Float]) throws -> ExportLoudnessMeasurement {
        var meter = ExportLoudnessMeter(sampleRate: rate, channels: channels)
        for first in stride(from: 0, to: rate * seconds, by: 4_096) {
            try meter.append(samples(first, min(4_096, rate * seconds - first)))
        }
        return meter.finish()
    }

    @Test(arguments: [44_100, 48_000, 88_200, 96_000])
    func calibratedSineAndChannelWeighting(rate: Int) throws {
        let mono = try measure(rate: rate, channels: 1) {
            tone($0, count: $1, rate: rate, channels: 1)
        }
        let stereo = try measure(rate: rate) { tone($0, count: $1, rate: rate) }
        // 1 kHz, -20 dBFS peak: approximately -23.0 LUFS mono, -20.0 stereo.
        #expect(abs(try #require(mono.integratedLUFS) - (-23.0)) < 0.06)
        #expect(abs(try #require(stereo.integratedLUFS) - (-20.0)) < 0.06)
        #expect(abs(try #require(stereo.integratedLUFS) - #require(mono.integratedLUFS) - 3.0103) < 0.001)
        #expect(abs(try #require(stereo.truePeakDBTP) + 20) < 0.05)
    }

    @Test func absoluteAndRelativeGatingExcludeQuietBlocks() throws {
        let baseline = try measure { tone($0, count: $1, rate: 48_000) }
        for quiet in [0.000001, 0.001] {
            let gated = try measure(seconds: 12) { first, count in
                (first..<(first + count)).flatMap { frame in
                    tone(frame, count: 1, rate: 48_000, amplitude: frame < 144_000 ? 0.1 : quiet)
                }
            }
            #expect(abs(try #require(gated.integratedLUFS) - #require(baseline.integratedLUFS)) < 0.3)
        }
        let silence = try measure { _, count in [Float](repeating: 0, count: count * 2) }
        #expect(silence.integratedLUFS == nil && silence.truePeakDBTP == nil)
        let quiet = try measure { tone($0, count: $1, rate: 48_000, amplitude: 0.000001) }
        #expect(quiet.integratedLUFS == nil && quiet.truePeakDBTP != nil)
    }

    @Test func intersamplePeaksAndBlockBoundaries() throws {
        let measured = try measure { tone($0, count: $1, rate: 48_000,
            frequency: 12_000, amplitude: 1, phase: .pi / 4) }
        // Every input sample is +/-sqrt(0.5), while the reconstructed sine reaches unity.
        #expect(abs(try #require(measured.truePeakDBTP)) < 0.15)
        var meter = ExportLoudnessMeter(sampleRate: 48_000, channels: 2)
        for first in 0..<48_000 {
            try meter.append(tone(first, count: 1, rate: 48_000, frequency: 12_000, amplitude: 1, phase: .pi / 4))
        }
        #expect(abs(try #require(meter.finish().truePeakDBTP) - #require(measured.truePeakDBTP)) < 0.001)
        var invalid = ExportLoudnessMeter(sampleRate: 48_000, channels: 1)
        #expect(throws: ExportFailure.self) { try invalid.append([.nan]) }
    }

    @Test func customValidationAndDefault() throws {
        let settings = try ExportSettings(codec: .wave(.float32))
        #expect(try ExportDelivery(filename: "a.wav", settings: settings).normalization == .off)
        for target in [-Double.infinity, Double.nan, -36.1, -8.9] {
            #expect(throws: ExportFailure.self) {
                try ExportDelivery(filename: "a.wav", settings: settings,
                    normalization: .custom(targetLUFS: target, ceilingDBTP: -1))
            }
        }
        for ceiling in [-Double.infinity, Double.nan, -12.1, 0] {
            #expect(throws: ExportFailure.self) {
                try ExportDelivery(filename: "a.wav", settings: settings,
                    normalization: .custom(targetLUFS: -16, ceilingDBTP: ceiling))
            }
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ww-loudness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func delivery(_ name: String, codec: ExportCodec = .wave(.float32), rate: Int = 48_000,
                          channels: Int = 2, mode: ExportNormalization = .podcast,
                          dither: ExportDither = .none) throws -> ExportDelivery {
        try .init(filename: name, settings: .init(codec: codec, sampleRate: rate, channels: channels),
                  dither: dither, normalization: mode)
    }

    private func request(_ root: URL, _ deliveries: [ExportDelivery], seconds: Int = 3) throws -> ExportJobRequest {
        try .init(userSelectedDirectory: root, protectedLocations: [], productionFrames: -123..<(48_000 * Int64(seconds) - 123),
                  deliveries: deliveries)
    }

    private func renderer(_ request: ExportJobRequest, amplitude: Double = 0.1, frequency: Double = 1_000,
                          phase: Double = 0, invertRight: Bool = false) -> ExportJob.Renderer {
        { sink in
            for first in stride(from: 0, to: Int(request.productionFrames.count64), by: 4_096) {
                let count = min(4_096, Int(request.productionFrames.count64) - first)
                let mono = tone(first, count: count, rate: 48_000, channels: 1, frequency: frequency,
                                amplitude: amplitude, phase: phase)
                try await sink(request.productionFrames.lowerBound + Int64(first), [mono, invertRight ? mono.map(-) : mono])
            }
        }
    }

    @Test func normalizedOutputsUseOneRenderAndActualOutputLayouts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, [
            delivery("stereo.wav"), delivery("mono.wav", rate: 44_100, channels: 1),
            delivery("out.mp3", codec: .mp3(.constantBitrate(kbps: 128)), rate: 44_100),
            delivery("out.m4a", codec: .aacLC(bitrate: 128_000), channels: 1),
        ])
        let count = RenderCount()
        let render = renderer(request)
        let result = try await ExportJob().run(request, isCurrent: { true }) { sink in
            await count.increment()
            try await render(sink)
        }
        #expect(result.succeeded, "\(String(describing: result.problem)) \(result.cleanupErrors)")
        #expect(await count.value == 1)
        #expect(result.published.count == 4)
        for file in result.published {
            let target = file.settings.channels == 1 ? -19.0 : -16
            let actual = try #require(file.loudness.measurement.integratedLUFS)
            #expect(try #require(file.loudness.measurement.truePeakDBTP) <= -1)
            if case .mp3 = file.settings.codec {
                #expect(abs(actual - target) <= 0.55)
                #expect(file.loudness.targetStatus == (abs(actual - target) <= 0.2 ? .achieved : .targetMissed))
            } else {
                #expect(abs(actual - target) <= 0.2)
                #expect(file.loudness.targetStatus == .achieved)
            }
            #expect(abs(file.loudness.appliedGainDB - 4) < 0.1)
            #expect(file.inputFrames == Int64(file.settings.sampleRate * 3))
            if ProcessInfo.processInfo.environment["WW_EXPORT_REFERENCE_FFMPEG"] != nil {
                let reference = try reference(file.url)
                #expect(abs(actual - reference.loudness) <= 0.1)
                #expect(reference.peak <= -1)
            }
        }
        let monoRoot = root.appendingPathComponent("canceling-mono")
        try FileManager.default.createDirectory(at: monoRoot, withIntermediateDirectories: false)
        let cancellation = try self.request(monoRoot, [delivery("mono.wav", channels: 1)])
        let silent = try await ExportJob().run(cancellation, isCurrent: { true },
            render: renderer(cancellation, invertRight: true))
        #expect(silent.succeeded)
        #expect(silent.published.first?.loudness.targetStatus == .unmeasurable)
        #expect(silent.published.first?.loudness.measurement.truePeakDBTP == nil)
    }

    @Test func boostBoundSilenceAndPeakLimitedGainDoNotPretendSuccess() async throws {
        for (amplitude, status) in [
            (0.0, ExportLoudnessReport.TargetStatus.unmeasurable),
            (0.000001, .unmeasurable), (0.001, .boostLimited), (1.0, .peakLimited),
        ] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let request = try request(root, [delivery("out.wav", mode: .custom(targetLUFS: -9, ceilingDBTP: -12))])
            let result = try await ExportJob().run(request, isCurrent: { true },
                render: renderer(request, amplitude: amplitude))
            #expect(result.succeeded, "\(String(describing: result.problem))")
            let report = try #require(result.published.first?.loudness)
            #expect(report.targetStatus == status)
            #expect(report.appliedGainDB <= ExportNormalization.maximumBoostDB)
            #expect(report.measurement.truePeakDBTP == nil || report.measurement.truePeakDBTP! <= -12)
            if status == .unmeasurable { #expect(report.appliedGainDB == 0) }
        }
    }

    @Test func offPreservesOverRangeAndNormalizationPreservesStartEndWithoutTail() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, [delivery("off.wav", mode: .off), delivery("on.wav")])
        let result = try await ExportJob().run(request, isCurrent: { true },
            render: renderer(request, amplitude: 2, frequency: 12_000, phase: .pi / 4))
        #expect(result.succeeded, "\(String(describing: result.problem))")
        let off = try #require(result.published.first)
        let on = try #require(result.published.last)
        #expect(off.loudness.targetStatus == .off && off.loudness.appliedGainDB == 0)
        #expect(try #require(off.loudness.measurement.truePeakDBTP) > 5.9)
        let a = try AVAudioFile(forReading: off.url)
        let b = try AVAudioFile(forReading: on.url)
        #expect(a.length == b.length && a.length == request.productionFrames.count64)
        let gain = Float(pow(10, on.loudness.appliedGainDB / 20))
        let ab = try #require(AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: 4_096))
        let bb = try #require(AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: 4_096))
        while a.framePosition < a.length {
            try a.read(into: ab); try b.read(into: bb)
            #expect(ab.frameLength == bb.frameLength)
            let ap = try #require(ab.floatChannelData)
            let bp = try #require(bb.floatChannelData)
            for frame in 0..<Int(ab.frameLength) {
                #expect(abs(ap[0][frame] * gain - bp[0][frame]) < 0.000001)
            }
        }
    }

    @Test func cancellationDuringMeasurementAndVerificationCleansAllStaging() async throws {
        for phase in ["measurement", "verification"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let request = try request(root, [delivery("out.wav")])
            let job = ExportJob()
            let result = try await job.run(request, isCurrent: { true }, render: renderer(request), progress: { value in
                if phase == "measurement", case .measuring = value.phase, value.completedFrames > 0 { await job.cancel() }
                if phase == "verification", case .verifying = value.phase { await job.cancel() }
            })
            #expect(result.problem?.kind == .canceled)
            #expect(result.published.isEmpty && result.cleanupErrors.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    private func transientRenderer(_ request: ExportJobRequest, frequency: Double) -> ExportJob.Renderer {
        { sink in
            for first in stride(from: 0, to: Int(request.productionFrames.count64), by: 4_096) {
                let count = min(4_096, Int(request.productionFrames.count64) - first)
                let samples = (first..<(first + count)).map { frame -> Float in
                    let t = Double(frame) / 48_000
                    let envelope = frame % 12_000 < 1_200 ? 0.7 : 0.007
                    return Float(envelope * sin(2 * .pi * frequency * t))
                }

                try await sink(request.productionFrames.lowerBound + Int64(first), [samples, samples])
            }
        }
    }

    @Test(arguments: [ExportCodec.mp3(.constantBitrate(kbps: 96)), .aacLC(bitrate: 64_000)])
    func realLossyCorrectionAndCancellationKeepOneRenderAndCleanAttempts(codec: ExportCodec) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "out.\(codec.fileExtension)"
        let frequency: Double = if case .mp3 = codec { 16_997 } else { 3_997 }
        let deliveries = try [delivery(filename, codec: codec, rate: 44_100, channels: 1,
                                      mode: .custom(targetLUFS: -9, ceilingDBTP: -1))]
        let request = try request(root, deliveries)
        let counter = RenderCount()
        let render = transientRenderer(request, frequency: frequency)
        let result = try await ExportJob().run(request, isCurrent: { true }) { sink in
            await counter.increment()
            try await render(sink)
        }
        #expect(result.succeeded, "\(String(describing: result.problem)) \(result.cleanupErrors)")
        #expect(await counter.value == 1)
        var corrected = false
        for file in result.published {
            print("CORRECTION \(file.settings): \(file.loudness)")
            #expect(try #require(file.loudness.measurement.truePeakDBTP) <= -1)
            #expect(file.loudness.targetStatus == .peakLimited)
            #expect(file.loudness.correctionPasses <= 3)
            if file.loudness.correctionPasses > 0 {
                corrected = true
                #expect(file.loudness.correctiveAttenuationDB > 0)
            }
            if ProcessInfo.processInfo.environment["WW_EXPORT_REFERENCE_FFMPEG"] != nil {
                let reference = try reference(file.url)
                #expect(reference.peak <= -1)
                #expect(abs(try #require(file.loudness.measurement.integratedLUFS) - reference.loudness) <= 0.1)
                print("CORRECTED REFERENCE \(codec): \(reference)")
            }
        }
        #expect(corrected, "Fixture must exercise an actual decoded-codec overshoot and re-encode")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [filename])
        for stale in [false, true] {
            let folder = root.appendingPathComponent(stale ? "stale" : "canceled")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let next = try self.request(folder, deliveries)
            let job = ExportJob()
            let currency = LoudnessCurrency()
            let interrupted = try await job.run(next, isCurrent: { await currency.current },
                render: transientRenderer(next, frequency: frequency), progress: { value in
                    if case .correcting = value.phase {
                        if stale { await currency.invalidate() }
                        else { await job.cancel() }
                    }
                })
            #expect(interrupted.problem?.kind == (stale ? .stale : .canceled))
            #expect(interrupted.published.isEmpty && interrupted.cleanupErrors.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_EXPORT_REFERENCE_FFMPEG"] != nil),
          arguments: [44_100, 48_000, 88_200, 96_000])
    func independentFFmpegReference(rate: Int) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for variant in ["sine", "gated", "intersample", "hard-edge", "burst"] {
            let settings = try ExportSettings(codec: .wave(.float32), sampleRate: rate,
                                               channels: variant == "sine" ? 1 : 2)
            let encoder = try ExportEncoder(stagingDirectory: root, settings: settings)
            let seconds = variant == "gated" ? 8 : 3
            for first in stride(from: 0, to: rate * seconds, by: 4_096) {
                let count = min(4_096, rate * seconds - first)
                let samples = (first..<(first + count)).flatMap { frame -> [Float] in
                    var amplitude: Double = variant == "gated" && frame >= rate * 2
                        ? (frame < rate * 5 ? 0.001 : 0.000001) : 0.1
                    if variant == "burst", frame % (rate / 4) >= rate / 40 { amplitude *= 0.01 }
                    let ramp = variant == "hard-edge" || variant == "burst" ? 1
                        : min(1, Double(frame) / 1_000, Double(rate * seconds - 1 - frame) / 1_000)
                    return tone(frame, count: 1, rate: rate, channels: settings.channels,
                        frequency: variant == "intersample" || variant == "hard-edge" ? Double(rate) / 4
                            : variant == "burst" ? 3_997 : 1_000,
                        amplitude: amplitude * ramp,
                        phase: variant == "intersample" || variant == "hard-edge" ? .pi / 4 : 0)
                }
                try await encoder.append(interleaved: samples)
            }
            let output = try await encoder.finish()
            let reference = try reference(output.stagingURL)
            let referenceLUFS = reference.loudness
            let referencePeak = reference.peak
            let measuredLUFS = try #require(output.loudness.integratedLUFS)
            let measuredPeak = try #require(output.loudness.truePeakDBTP)
            #expect(abs(measuredLUFS - referenceLUFS) <= 0.1,
                    "\(rate) \(variant): \(measuredLUFS) vs reference \(referenceLUFS)")
            let tolerance = variant == "hard-edge" || variant == "burst" ? 0.7 : 0.15
            #expect(abs(measuredPeak - referencePeak) <= tolerance,
                    "\(rate) \(variant): \(measuredPeak) vs reference \(referencePeak)")
            print("REFERENCE \(rate) \(variant): LUFS \(measuredLUFS)/\(referenceLUFS), dBTP \(measuredPeak)/\(referencePeak)")
            try await encoder.cancel()
        }
    }

    private func reference(_ url: URL) throws -> (loudness: Double, peak: Double) {
        let executable = try #require(ProcessInfo.processInfo.environment["WW_EXPORT_REFERENCE_FFMPEG"])
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-nostats", "-threads", "1", "-i", url.path,
                             "-filter_complex", "ebur128=peak=true", "-f", "null", "-"]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: data, as: UTF8.self)
        let summary = try #require(text.components(separatedBy: "Summary:").last)
        func value(_ pattern: String) throws -> Double {
            let regex = try NSRegularExpression(pattern: pattern)
            let match = try #require(regex.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)))
            let range = try #require(Range(match.range(at: 1), in: summary))
            return try #require(Double(summary[range]))
        }
        return (try value(#"I:\s+(-?[0-9.]+) LUFS"#), try value(#"Peak:\s+(-?[0-9.]+) dBFS"#))
    }

    @Test func staleAdmissionDuringDecodedMeasurementFailsBeforePublication() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, [delivery("out.wav")])
        let currency = VerificationCurrency()
        let result = try await ExportJob().run(request, isCurrent: { await currency.check() },
            render: renderer(request), progress: { progress in
                if case .verifying = progress.phase { await currency.startVerification() }
            })
        #expect(result.problem?.kind == .stale && result.published.isEmpty)
        #expect(await currency.verificationChecks == 3)
        #expect(result.cleanupErrors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: [ExportPCMEncoding.int16, .int24])
    func normalizationPrecedesIntegerDitherAndProtectsOverRangeMix(pcm: ExportPCMEncoding) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, [
            delivery("out.wav", codec: .wave(pcm), rate: 96_000,
                     mode: .custom(targetLUFS: -9, ceilingDBTP: -12), dither: .tpdf),
        ])
        let result = try await ExportJob().run(request, isCurrent: { true },
            render: renderer(request, amplitude: 4))
        #expect(result.succeeded, "\(String(describing: result.problem))")
        let file = try #require(result.published.first)
        #expect(file.inputFrames == 288_000 && file.decodedFrames == 288_000)
        #expect(file.loudness.targetStatus == .peakLimited)
        #expect(try #require(file.loudness.measurement.truePeakDBTP) <= -12.7)
        #expect(file.loudness.appliedGainDB < -24)
    }

    @Test func correctionDisposalPreservesForeignEntriesAndPublishesNothing() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try request(root, [
            delivery("good.wav"),
            delivery("out.mp3", codec: .mp3(.constantBitrate(kbps: 96)), rate: 44_100, channels: 1,
                     mode: .custom(targetLUFS: -9, ceilingDBTP: -1)),
        ])
        let result = try await ExportJob().run(request, isCurrent: { true },
            render: transientRenderer(request, frequency: 16_997), progress: { progress in
                guard progress.phase == .verifying(delivery: 1) else { return }
                do {
                    let staging = try #require(FileManager.default.contentsOfDirectory(at: root,
                        includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".ww-export-job-") })
                    let encoder = try #require(FileManager.default.contentsOfDirectory(at: staging,
                        includingPropertiesForKeys: nil).first {
                            FileManager.default.fileExists(atPath: $0.appendingPathComponent("encoded.mp3").path)
                        })
                    try Data("foreign".utf8).write(to: encoder.appendingPathComponent("external"))
                } catch { Issue.record(error) }
            })
        #expect(!result.succeeded && result.published.isEmpty)
        #expect(result.problem?.kind == .encoding && !result.cleanupErrors.isEmpty)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let foreign = try #require(enumerator.allObjects.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == "external"
        })
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("good.wav").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out.mp3").path))
    }
}

private actor RenderCount {
    var value = 0
    func increment() { value += 1 }
}

private actor LoudnessCurrency {
    var current = true
    func invalidate() { current = false }
}

private actor VerificationCurrency {
    private var verifying = false
    var verificationChecks = 0
    func startVerification() { verifying = true }
    func check() -> Bool {
        if verifying { verificationChecks += 1 }
        return verificationChecks < 3
    }
}
