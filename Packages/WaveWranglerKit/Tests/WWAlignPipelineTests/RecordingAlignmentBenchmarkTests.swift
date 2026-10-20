import AVFAudio
import AudioToolbox
import CryptoKit
import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWSources
@testable import WWAlignPipeline

/// Opt-in real-file production rematches; no experimental estimator or backend injection.
@Suite("Recording alignment CPU benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["WW_RECORDING_BENCH_DIR"] != nil))
struct RecordingAlignmentBenchmarkTests {
    struct Failure: Error { let message: String }

    struct Workload {
        let name: String
        let seconds: Int
        var referenceRate = 48_000
        var targetRate = 48_000
        var channels = 1
        var offset = 0.83
        var ppm = 180.0
        var polarity = 1.0
        var kind = "scene"
    }

    struct Event: Codable {
        let workload: String
        let round: Int
        let cold: Double
        let warmRematch: Double
        let cachedRecord: Double
        let truthErrorMs: Double
        let attempts: Int
        let thermalState: Int
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ url: URL, workload: Workload, target: Bool, base: [Float]) throws {
        let rate = target ? workload.targetRate : workload.referenceRate
        let layout = try #require(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(workload.channels)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                   interleaved: false, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384))
        let channels = try #require(buffer.floatChannelData)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        for start in stride(from: 0, to: workload.seconds * rate, by: 16_384) {
            let count = min(16_384, workload.seconds * rate - start)
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let time = Double(start + frame) / Double(rate)
                let position = ((target ? (1 + workload.ppm / 1e6) * time + workload.offset : time) + 4) * 8000
                let at = Int(floor(position)), fraction = Float(position - floor(position))
                var value = base[at] * (1 - fraction) + base[at + 1] * fraction
                if target { value *= Float(workload.polarity * 0.7) }
                if target, workload.kind == "weak" {
                    value = Signal.hash(901, Int64(start + frame)) * 1e-5
                } else if target, workload.kind == "unrelated" {
                    value = Signal.scene(712, time)
                }
                for channel in 0..<workload.channels {
                    channels[channel][frame] = channel == workload.channels - 1 ? value
                        : Signal.hash(UInt64(100 + channel + (target ? 99 : 0)), Int64(start + frame)) * 0.1
                }
            }
            try file.write(from: buffer)
        }
    }

    static func compare(_ actual: EpochAnalysisRecord, _ baseline: EpochAnalysisRecord) throws {
        #expect(actual.estimator == baseline.estimator && actual.recordVersion == baseline.recordVersion)
        #expect(actual.recipe.components(separatedBy: "[ref=").first == baseline.recipe.components(separatedBy: "[ref=").first)
        #expect(actual.recipe.components(separatedBy: "[auto=").last == baseline.recipe.components(separatedBy: "[auto=").last)
        #expect(actual.abstention == baseline.abstention && actual.flags == baseline.flags)
        #expect(actual.coverage == baseline.coverage)
        #expect(actual.coarseWindows == baseline.coarseWindows)
        #expect(actual.refinementRatePPM == baseline.refinementRatePPM)
        for (a, b) in [(actual.reference, baseline.reference), (actual.target, baseline.target)] {
            #expect(a.sourceRate == b.sourceRate && a.sourceFrames == b.sourceFrames)
            #expect(a.excerptStartFrame == b.excerptStartFrame && a.excerptEndFrame == b.excerptEndFrame)
            #expect(a.analysisRate == b.analysisRate && a.channelCount == b.channelCount)
        }
        let a = actual.windows + (actual.automaticAttempts ?? [])
        let b = baseline.windows + (baseline.automaticAttempts ?? [])
        #expect(a.count == b.count)
        var lagDelta = 0.0, scoreDelta = 0.0
        for (a, b) in zip(a, b) {
            #expect(a.index == b.index && a.groupClockCenter == b.groupClockCenter)
            #expect(a.status == b.status && a.polarity == b.polarity && a.method == b.method)
            for (x, y) in [(a.offsetSeconds, b.offsetSeconds), (a.phatOffsetSeconds, b.phatOffsetSeconds)] {
                #expect((x == nil) == (y == nil))
                if let x, let y { lagDelta = max(lagDelta, abs(x - y)) }
            }
            scoreDelta = max(scoreDelta, abs(a.peakScore - b.peakScore), abs(a.secondPeakScore - b.secondPeakScore))
            #expect((a.phatPeakRatio == nil) == (b.phatPeakRatio == nil))
            if let x = a.phatPeakRatio, let y = b.phatPeakRatio { #expect(abs(x - y) < 1e-12) }
        }
        #expect(lagDelta < 1e-9 && scoreDelta < 1e-12)
        #expect((actual.proposal == nil) == (baseline.proposal == nil))
        if let a = actual.proposal, let b = baseline.proposal {
            #expect(a.segment.rateRatio == b.segment.rateRatio)
            #expect(a.segment.alignedOffset == b.segment.alignedOffset)
        }
        print("RECORDING-PARITY maxLagDeltaSeconds=\(lagDelta) maxScoreDelta=\(scoreDelta)")
    }

    @Test(.timeLimit(.minutes(15)))
    func realFileRematches() async throws {
        let variables = ProcessInfo.processInfo.environment
        let path = try #require(variables["WW_RECORDING_BENCH_DIR"])
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
            throw Failure(message: "WW_RECORDING_BENCH_DIR must be a new absolute directory")
        }
        guard let repeats = Int(variables["WW_RECORDING_REPEATS"] ?? "3"), (1...5).contains(repeats) else {
            throw Failure(message: "WW_RECORDING_REPEATS must be 1...5")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var workloads = [
            Workload(name: "scene-64", seconds: 64),
            Workload(name: "stereo-600", seconds: 600, channels: 2, offset: -1.25, ppm: -145),
            Workload(name: "mono-1800", seconds: 1800, referenceRate: 8000, targetRate: 8000, offset: 2.25),
            Workload(name: "mixed7-96", seconds: 96, referenceRate: 44_100, channels: 7),
            Workload(name: "inverted-64", seconds: 64, offset: -0.83, ppm: -180, polarity: -1),
            Workload(name: "silence-64", seconds: 64, kind: "silence"),
            Workload(name: "periodic-64", seconds: 64, referenceRate: 8000, targetRate: 8000, kind: "periodic"),
            Workload(name: "weak-64", seconds: 64, referenceRate: 8000, targetRate: 8000, kind: "weak"),
            Workload(name: "unrelated-64", seconds: 64, referenceRate: 8000, targetRate: 8000, kind: "unrelated"),
        ]
        if let selected = variables["WW_RECORDING_CASES"] {
            let names = selected.split(separator: ",").map(String.init)
            workloads = workloads.filter { names.contains($0.name) }
            guard workloads.count == names.count else { throw Failure(message: "unknown recording workload") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var events: [Event] = [], hashes: [String: String] = [:]
        for workload in workloads {
            let base: [Float] = (0..<(workload.seconds + 12) * 8000).map { index in
                let time = Double(index) / 8000
                switch workload.kind {
                case "silence": return 0
                case "periodic": return Float(0.2 * sin(2 * .pi * 440 * time))
                default: return Signal.scene(990, time)
                }
            }
            let urls = ["reference", "target"].map { media.appendingPathComponent("\(workload.name)-\($0).wav") }
            for index in urls.indices {
                try Self.write(urls[index], workload: workload, target: index == 1, base: base)
                hashes[urls[index].lastPathComponent] = try Self.hash(urls[index])
            }
            for round in 0..<repeats {
                let io = SystemSourceIO()
                let fingerprints = try urls.map { url in
                    guard case let .success(metadata) = io.metadata(at: url) else {
                        throw Failure(message: "source metadata failed")
                    }
                    return metadata.fingerprint
                }
                let coordinator = DerivedJobCoordinator(store: try DerivedAssetStore(
                    root: root.appendingPathComponent("\(workload.name)-cache-\(round)"), sourceLocations: urls))
                let decoder = SourceDecoder(access: SourceAccessContext(io: io))
                let pipeline = AlignmentPipeline(coordinator: coordinator, decoder: decoder,
                    configuration: AlignmentPipelineConfiguration(concurrency: 1))
                let epochs = [RecordingEpoch(label: "Reference"), RecordingEpoch(label: "Target")]
                let groups = epochs.enumerated().map { RecorderGroup(name: "Recorder \($0.offset)", epochs: [$0.element]) }
                let records = urls.indices.map {
                    SourceRecord(displayNameHint: urls[$0].lastPathComponent,
                        placement: SourcePlacement(recorderGroupID: groups[$0].id, epochID: epochs[$0].id))
                }
                let sources = urls.indices.map {
                    AlignmentSource(id: records[$0].id, url: urls[$0], availability: .on,
                                    recordedFingerprint: fingerprints[$0])
                }
                for index in urls.indices {
                    await coordinator.updateSource(SourceRevision.metadata(records[index].id, fingerprint: fingerprints[index]))
                }
                let speaker = Speaker(name: "Generated shared lane"), lane = workload.channels - 1
                let episode = Episode(title: "Recording benchmark", recorderGroups: groups, sources: records,
                    speakerAssignments: [SpeakerAssignment(speakerID: speaker.id,
                        primary: ChannelReference(sourceID: records[0].id, statedChannel: lane),
                        backups: [ChannelReference(sourceID: records[1].id, statedChannel: lane)])])
                let model = ShowDocumentModel(show: Show(title: "Benchmark only"), speakers: [speaker], episodes: [episode])
                let authorizations = sources.map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
                let prepared = try await pipeline.prepareManual(model: model, episode: episode.id, sources: sources,
                    authorizations: authorizations)
                let unit = AnalysisUnit(referenceChoice: try #require(prepared.plan.reference), reference: sources[0],
                    referenceFacts: try #require(prepared.facts[sources[0].id]),
                    targetGroup: groups[1].id, targetEpoch: epochs[1].id, target: sources[1],
                    targetFacts: try #require(prepared.facts[sources[1].id]),
                    configuration: AlignmentPipeline.speakerLocatorConfiguration(durationDifference: 0, base: pipeline.configuration),
                    chunkFrames: decoder.configuration.chunkFrames, referenceChannel: lane, targetChannel: lane, automatic: true)
                var start = Self.now()
                let report = try await pipeline.analyzeSpeaker(model: model, episode: episode.id, sources: sources,
                    authorizations: authorizations, targetEpoch: epochs[1].id, speaker: speaker.id)
                let coldTime = Self.now() - start
                #expect(report.epochFailures.isEmpty && report.sourceFailures.isEmpty)
                let cold = try #require(report.records[epochs[1].id])
                start = Self.now()
                let warm = try EpochAnalysisRecord.decode(await AutomaticAnalysis.run(unit: unit, environment: pipeline.environment))
                let warmTime = Self.now() - start
                #expect(warm == cold)
                start = Self.now()
                let cached = try await pipeline.analyzeSpeaker(model: model, episode: episode.id, sources: sources,
                    authorizations: authorizations, targetEpoch: epochs[1].id, speaker: speaker.id)
                let cachedTime = Self.now() - start
                #expect(cached.records[epochs[1].id] == cold && model.episodes[0].alignment == nil)
                var truthError = 0.0
                if let proposal = warm.proposal {
                    #expect(workload.kind == "scene")
                    for time in [warm.coverage.declaredStart, warm.coverage.declaredEnd] {
                        truthError = max(truthError, abs(proposal.segment.rateRatio.approximateDouble * time
                            + proposal.segment.alignedOffset.approximateDouble
                            - ((1 + workload.ppm / 1e6) * time + workload.offset)) * 1000)
                    }
                    #expect(truthError < 1)
                    #expect(warm.windows.filter { $0.status == "eligible" }.allSatisfy { $0.polarity == Int(workload.polarity) })
                } else {
                    #expect(workload.kind != "scene")
                }
                let snapshot = "\(workload.name)-\(round).json"
                try encoder.encode(warm).write(to: root.appendingPathComponent(snapshot))
                if let baseline = variables["WW_RECORDING_BASELINE"] {
                    let url = URL(fileURLWithPath: baseline).appendingPathComponent(snapshot)
                    try Self.compare(warm, EpochAnalysisRecord.decode(Data(contentsOf: url)))
                }
                let event = Event(workload: workload.name, round: round, cold: coldTime, warmRematch: warmTime,
                    cachedRecord: cachedTime, truthErrorMs: truthError, attempts: warm.automaticAttempts?.count ?? 0,
                    thermalState: ProcessInfo.processInfo.thermalState.rawValue)
                events.append(event)
                print("RECORDING-BENCH \(String(decoding: try encoder.encode(event), as: UTF8.self))")
                await pipeline.shutdown()
            }
        }
        try encoder.encode(events).write(to: root.appendingPathComponent("timings.json"))
        try encoder.encode(hashes).write(to: root.appendingPathComponent("hashes.json"))
        if let baseline = variables["WW_RECORDING_BASELINE"] {
            let url = URL(fileURLWithPath: baseline).appendingPathComponent("hashes.json")
            #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) == hashes)
        }
    }
}
