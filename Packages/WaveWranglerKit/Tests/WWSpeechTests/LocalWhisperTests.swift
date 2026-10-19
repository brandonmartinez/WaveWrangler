import AVFoundation
import CryptoKit
import Foundation
import Testing
import WWSpeech

@Suite("Pinned local Whisper", .serialized)
struct LocalWhisperTests {
    @Test func catalogOffersOnlyPinnedQualifiedModelsWithExplicitHTTPSDownloads() {
        #expect(LocalWhisperWeights.allCases == [.baseEnglish, .smallEnglish, .turbo, .largeV3])
        for weights in LocalWhisperWeights.allCases {
            #expect(weights.downloadURL.scheme == "https")
            #expect(weights.downloadURL.host == "huggingface.co")
            #expect(weights.downloadURL.lastPathComponent == weights.filename)
            #expect(weights.downloadURL.pathComponents.contains(LocalWhisperWeights.sourceRevision))
            #expect(!weights.downloadURL.pathComponents.contains("main"))
            #expect(weights.sha256.count == 64 && weights.byteCount > 100_000_000)
            #expect(!weights.title.isEmpty && !weights.detail.isEmpty)
        }
        #expect(LocalWhisperWeights.turbo.title.contains("recommended"))
        #expect(LocalWhisperWeights.allCases.filter { $0.title.contains("recommended") } == [.turbo])
        #expect(LocalWhisperWeights.baseEnglish.rawValue == "baseEnglish")
        #expect(LocalWhisperWeights.turbo.rawValue == "turbo")
        #expect(Set(LocalWhisperWeights.allCases.map(\.filename)).count == 4)
        #expect(Set(LocalWhisperWeights.allCases.map(\.sha256)).count == 4)
        #expect(LocalWhisperWeights.smallEnglish.byteCount == 487_614_201)
        #expect(LocalWhisperWeights.smallEnglish.sha256 == "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d")
        #expect(LocalWhisperWeights.largeV3.byteCount == 1_081_140_203)
        #expect(LocalWhisperWeights.largeV3.sha256 == "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")
    }
    @Test(arguments: LocalWhisperWeights.allCases)
    func missingAndWrongSizeModelsRefuseBeforeInference(_ weights: LocalWhisperWeights) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SpeechModelError.missingModel) {
            try LocalWhisper.load(path: url.path, weights: weights)
        }
        try Data([1]).write(to: url)
        #expect(throws: SpeechModelError.invalidSize) {
            try LocalWhisper.load(path: url.path, weights: weights)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_WHISPER_QUALIFICATION_MODEL"] != nil))
    func optedInGeneratedSpeechQualifiesPinnedModelAndBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let weights = try #require(env["WW_WHISPER_QUALIFICATION_MODEL"].flatMap(LocalWhisperWeights.init(rawValue:)))
        let backend = try #require(env["WW_WHISPER_QUALIFICATION_BACKEND"].flatMap(TranscriptionBackend.init(rawValue:)))
        let root = URL(fileURLWithPath: try #require(env["WW_WHISPER_QUALIFICATION_DIRECTORY"]))
        let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .two)
        let pool = TranscriptionWorkerPool()
        let cost = try TranscriptionResources(weights: weights, configuration: configuration)
        try await pool.withAdmission(resources: cost) {
            let engine = try await LocalWhisper.load(url: root.appendingPathComponent(weights.filename),
                                                    weights: weights, configuration: configuration)
            let audio = try AVAudioFile(forReading: root.appendingPathComponent("generated-control.wav"))
            try #require(audio.processingFormat.channelCount == 1 && audio.processingFormat.sampleRate == 48_000)
            try #require(audio.length > 4_800 && audio.length <= 30 * 48_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            let text = result.segments.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("review") && text.contains("meeting") && text.contains("notes"))
            #expect(result.segments.contains { $0.startSeconds != nil })
            for segment in result.segments {
                #expect(!segment.text.isEmpty)
                #expect((segment.startSeconds == nil) == (segment.endSeconds == nil))
                if let start = segment.startSeconds, let end = segment.endSeconds {
                    #expect(start >= 0 && end > start && end <= Double(pcm.count) / 48_000)
                }
            }
            #expect(engine.revision == configuration.revision(weights: weights))
            #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16_000), sampleRate: 16_000).segments.isEmpty)
            #expect(throws: PCMInferenceRefusal.cancelled) {
                try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCancelled: { true })
            }
            #expect(throws: PCMInferenceRefusal.invalidPCM) {
                try engine.transcribe(pcm: [Float](repeating: 0, count: 480_001), sampleRate: 16_000)
            }
            print("WHISPER-MODEL-QUALIFICATION \(weights.rawValue) \(configuration.backend.rawValue): \(text); recipe=\(engine.revision)")
        }
        #expect(await pool.snapshot.reservedBytes == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LOCAL_ASR_MODEL"] != nil
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_PUBLIC_WAV"] != nil))
    func explicitlyOptedInPublicSpeechRunsThroughTheActualNativeBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_LOCAL_ASR_MODEL"])
        let weights = try #require(LocalWhisperWeights.allCases.first { $0.filename == URL(fileURLWithPath: path).lastPathComponent })
        let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path), weights: weights)
        #expect(engine.revision == TranscriptionConfiguration.cpu.revision(weights: weights))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(env["WW_LOCAL_ASR_PUBLIC_WAV"])))
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length < 30 * Int64(file.processingFormat.sampleRate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let input = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        #expect(file.processingFormat.sampleRate == 16_000)
        // Exercise the app's 48 kHz input path, not only the recognizer's native 16 kHz path.
        let pcm = input.flatMap { [$0, $0, $0] }
        let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
        let text = result.segments.map(\.text).joined(separator: " ").lowercased()
        print("LOCAL-WHISPER-PUBLIC-CONTROL \(weights.rawValue): \(text)")
        #expect(text.contains("gospel"))
        #expect(text.contains("middle"))
        #expect(!result.segments.isEmpty)
        #expect(throws: PCMInferenceRefusal.cancelled) {
            try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCancelled: { true })
        }
        #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16000), sampleRate: 16000).segments.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LOCAL_ASR_CONCURRENT"] == "1"
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_MODEL"] != nil
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_PUBLIC_WAV"] != nil))
    func optedInNativeContextsActuallyOverlapAndPreserveRecognitionAndTimestamps() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_LOCAL_ASR_MODEL"])
        let weights = try #require(LocalWhisperWeights.allCases.first { $0.filename == URL(fileURLWithPath: path).lastPathComponent })
        let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path), weights: weights)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(env["WW_LOCAL_ASR_PUBLIC_WAV"])))
        try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
        try #require(file.length > 0 && file.length <= 30 * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] }
        let reference = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
        #expect(reference.segments.map(\.text).joined(separator: " ").lowercased().contains("gospel"))
        for policy in [TranscriptionConcurrency.two, .four] {
            let barrier = NativeInferenceBarrier(expected: policy.rawValue)
            let pool = TranscriptionWorkerPool(concurrency: policy)
            try await withThrowingTaskGroup(of: PCMTranscript.self) { group in
                for _ in 0..<policy.rawValue {
                    group.addTask {
                        try await pool.withAdmission {
                            try await Self.nativeControl(engine, pcm: pcm, barrier: barrier)
                        }
                    }
                }
                var count = 0
                for try await result in group {
                    #expect(result == reference, "Parallel decoding must not change text or approximate timestamps")
                    count += 1
                }
                #expect(count == policy.rawValue)
            }
            #expect(barrier.overlapped, "Every worker must reach native graph computation before any is released")
            #expect(await pool.snapshot.active == 0)
            print("LOCAL-WHISPER-CONCURRENT-CONTROL \(weights.rawValue): \(policy.rawValue) overlapping native contexts; serial text/timestamps preserved")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"] != nil),
          arguments: [LocalWhisperWeights.baseEnglish, .turbo])
    func optedInBundledMetalAndCPUUseVerifiedPublicAudio(_ weights: LocalWhisperWeights) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"]))
        let audio = root.appendingPathComponent("clips/ami-01.wav")
        #expect(SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
                == "56f4b4abd278c61426b7ec4c844c5aff1420204a7b18ac7976321f8dc26c9b83")
        let file = try AVAudioFile(forReading: audio)
        try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] }
        try #require(TranscriptionConfiguration.metalAvailable, "This opt-in qualification requires supported Apple silicon")
        for backend in [TranscriptionBackend.cpu, .metal] {
            let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .four)
            let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(weights.filename)"),
                                                    weights: weights, configuration: configuration)
            let heartbeat = Task { @MainActor in
                var last = ProcessInfo.processInfo.systemUptime, maximumGap = 0.0, count = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch is CancellationError { break }
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumGap = max(maximumGap, now - last)
                    last = now
                    count += 1
                }
                return (maximumGap, count)
            }
            defer { heartbeat.cancel() }
            let reference = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            let text = reference.segments.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("kick") && text.contains("meeting"))
            #expect(reference.segments.contains { $0.startSeconds != nil })
            for segment in reference.segments {
                if let start = segment.startSeconds, let end = segment.endSeconds {
                    #expect(start >= 0 && end > start && end <= Double(pcm.count) / 48_000)
                }
            }
            let barrier = NativeInferenceBarrier(expected: 2)
            let pool = TranscriptionWorkerPool(concurrency: .two)
            let cost = try TranscriptionResources(weights: weights, configuration: configuration)
            try await withThrowingTaskGroup(of: PCMTranscript.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await pool.withAdmission(resources: cost) {
                            try await Self.nativeControl(engine, pcm: pcm, barrier: barrier)
                        }
                    }
                }
                for try await result in group { #expect(result == reference) }
            }
            #expect(barrier.overlapped)
            #expect(await pool.snapshot.reservedBytes == 0)
            let checks = NativeInferenceStart()
            let cancelled = Task { try await Self.nativeCancelControl(engine, pcm: pcm, checks: checks) }
            defer { cancelled.cancel() }
            let deadline = Date().addingTimeInterval(30)
            while !checks.started, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(checks.started, "Wait for a native graph checkpoint, not just model initialization")
            try await Task.sleep(for: .milliseconds(20))
            let cancelStart = ProcessInfo.processInfo.systemUptime
            cancelled.cancel()
            await #expect(throws: PCMInferenceRefusal.cancelled) { try await cancelled.value }
            let cancelWall = ProcessInfo.processInfo.systemUptime - cancelStart
            #expect(cancelWall < 30, "Native graph/command buffers must drain; cancellation is not instantaneous")
            heartbeat.cancel()
            let (gap, ticks) = try await heartbeat.value
            #expect(ticks > 0 && gap < 1, "Native inference must not block the MainActor heartbeat")
            #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16_000), sampleRate: 16_000).segments.isEmpty)
            print("BUNDLED-ACCELERATION \(weights.rawValue) \(backend.rawValue): overlap=2; cancellation_wall=\(cancelWall); main_actor_max_gap=\(gap); ticks=\(ticks); text=\(text)")
        }
    }

    @concurrent
    private static func nativeCancelControl(
        _ engine: LocalWhisper, pcm: [Float], checks: NativeInferenceStart
    ) async throws -> PCMTranscript {
        try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCancelled: { checks.check() })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_FULL_CORPUS"] == "1"))
    func optedInProductionCorpusPersistsActualAdapterOutputs() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"]))
        let manifest = try JSONDecoder().decode(NativeCorpusManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try #require(manifest.clips.count == 7 && manifest.clips.first?.id == "ami-01")
        var inputs: [[Float]] = []
        for clip in manifest.clips {
            let url = root.appendingPathComponent(clip.audio)
            try #require(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                         == clip.audio_sha256)
            let file = try AVAudioFile(forReading: url)
            try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            inputs.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for weights in [LocalWhisperWeights.baseEnglish, .turbo] {
            for backend in [TranscriptionBackend.cpu, .metal] {
                let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .four)
                let loadStart = ProcessInfo.processInfo.systemUptime
                let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(weights.filename)"),
                                                        weights: weights, configuration: configuration)
                let load = ProcessInfo.processInfo.systemUptime - loadStart
                var rounds: [NativeCorpusRound] = []
                for _ in 0..<2 {
                    let start = ProcessInfo.processInfo.systemUptime
                    var clips: [NativeCorpusOutput] = []
                    for (index, pcm) in inputs.enumerated() {
                        let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
                        clips.append(NativeCorpusOutput(index: index, segments: result.segments.map {
                            NativeCorpusSegment(text: $0.text, start: $0.startSeconds, end: $0.endSeconds)
                        }))
                    }
                    #expect(clips.last?.segments.isEmpty == true, "Production bypasses exact digital zero")
                    rounds.append(NativeCorpusRound(wall_seconds: ProcessInfo.processInfo.systemUptime - start, clips: clips))
                }
                let evidence = NativeCorpusEvidence(recipe: engine.revision, model_load_seconds: load, rounds: rounds)
                try encoder.encode(evidence).write(to: root.appendingPathComponent("acceleration/production-\(weights.rawValue)-\(backend.rawValue).json"))
            }
        }
    }

    @concurrent
    private static func nativeControl(
        _ engine: LocalWhisper, pcm: [Float], barrier: NativeInferenceBarrier
    ) async throws -> PCMTranscript {
        let checks = NativeCancellationChecks(barrier: barrier)
        return try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCancelled: { checks.check() })
    }
}

private struct NativeCorpusManifest: Decodable {
    struct Clip: Decodable {
        let id: String
        let audio: String
        let audio_sha256: String
    }
    let clips: [Clip]
}
private struct NativeCorpusSegment: Encodable {
    let text: String
    let start: Double?
    let end: Double?
}
private struct NativeCorpusOutput: Encodable {
    let index: Int
    let segments: [NativeCorpusSegment]
}
private struct NativeCorpusRound: Encodable {
    let wall_seconds: Double
    let clips: [NativeCorpusOutput]
}
private struct NativeCorpusEvidence: Encodable {
    let recipe: String
    let model_load_seconds: Double
    let rounds: [NativeCorpusRound]
}

private final class NativeInferenceStart: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var started: Bool { lock.withLock { calls >= 5 } }
    func check() -> Bool {
        lock.withLock { calls += 1 }
        return Task<Never, Never>.isCancelled
    }
}

// All mutable state is protected by the corresponding lock/condition; callbacks are synchronous C calls.
private final class NativeCancellationChecks: @unchecked Sendable {
    let barrier: NativeInferenceBarrier
    private let lock = NSLock()
    private var calls = 0
    init(barrier: NativeInferenceBarrier) { self.barrier = barrier }
    func check() -> Bool {
        let call = lock.withLock { calls += 1; return calls }
        // The pinned adapter makes one Swift and three C preflight checks. The fifth is inside
        // whisper_full's CPU graph, so this detects the former full-inference mutex, not just Swift overlap.
        if call == 5 { barrier.enter() }
        return Task<Never, Never>.isCancelled
    }
}

private final class NativeInferenceBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expected: Int
    private var entered = 0
    private var timedOut = false
    init(expected: Int) { self.expected = expected }
    var overlapped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered == expected && !timedOut
    }
    func enter() {
        condition.lock()
        defer { condition.unlock() }
        entered += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(30)
        while entered < expected && !timedOut {
            if !condition.wait(until: deadline) {
                timedOut = true
                condition.broadcast()
            }
        }
    }
}
