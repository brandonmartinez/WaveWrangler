import AVFoundation
import Foundation
import Testing
import WWSpeech

@Suite("Pinned local Whisper")
struct LocalWhisperTests {
    @Test func catalogOffersOnlyPinnedQualifiedModelsWithExplicitHTTPSDownloads() {
        #expect(LocalWhisperWeights.allCases.count == 2)
        for weights in LocalWhisperWeights.allCases {
            #expect(weights.downloadURL.scheme == "https")
            #expect(weights.downloadURL.host == "huggingface.co")
            #expect(weights.downloadURL.lastPathComponent == weights.filename)
            #expect(weights.sha256.count == 64 && weights.byteCount > 100_000_000)
            #expect(!weights.title.isEmpty && !weights.detail.isEmpty)
        }
        #expect(LocalWhisperWeights.turbo.title.contains("recommended"))
    }
    @Test func missingAndWrongSizeModelsRefuseBeforeInference() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SpeechModelError.missingModel) {
            try LocalWhisper.load(path: url.path, weights: .baseEnglish)
        }
        try Data([1]).write(to: url)
        #expect(throws: SpeechModelError.invalidSize) {
            try LocalWhisper.load(path: url.path, weights: .baseEnglish)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LOCAL_ASR_MODEL"] != nil
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_PUBLIC_WAV"] != nil))
    func explicitlyOptedInPublicSpeechRunsThroughTheActualNativeBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_LOCAL_ASR_MODEL"])
        let weights: LocalWhisperWeights = path.contains("turbo") ? .turbo : .baseEnglish
        let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path), weights: weights)
        #expect(engine.revision == "whisper.cpp/1.6.2+ww-token-bounds-v1/\(weights.rawValue)/\(weights.sha256)/verbatim-v1")
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
        let weights: LocalWhisperWeights = path.contains("turbo") ? .turbo : .baseEnglish
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

    @concurrent
    private static func nativeControl(
        _ engine: LocalWhisper, pcm: [Float], barrier: NativeInferenceBarrier
    ) async throws -> PCMTranscript {
        let checks = NativeCancellationChecks(barrier: barrier)
        return try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCancelled: { checks.check() })
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
