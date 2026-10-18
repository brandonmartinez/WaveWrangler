import AVFoundation
import CryptoKit
import Darwin
import Foundation
import WWWhisperNative

public enum LocalWhisperWeights: String, Sendable, CaseIterable {
    case baseEnglish, turbo

    public var title: String {
        switch self {
        case .baseEnglish: "Whisper Base English"
        case .turbo: "Whisper Turbo (recommended)"
        }
    }

    public var detail: String {
        switch self {
        case .baseEnglish: "148 MB. Smaller and faster, but less accurate in our conversational test."
        case .turbo: "574 MB, Q5_0. Best recognition and filler retention in our small conversational test; slower than Base on this CPU backend."
        }
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    public var filename: String {
        switch self {
        case .baseEnglish: "ggml-base.en.bin"
        case .turbo: "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    public var byteCount: Int {
        switch self {
        case .baseEnglish: 147_964_211
        case .turbo: 574_041_195
        }
    }

    public var sha256: String {
        switch self {
        case .baseEnglish: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        case .turbo: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        }
    }
}

/// Offline inference, with no external process. Only an exact hash-pinned local model is admitted.
public struct LocalWhisper: Sendable {
    public let weights: LocalWhisperWeights
    private let bytes: Data
    public var revision: String { "whisper.cpp/1.6.2+ww-token-bounds-v1/\(weights.rawValue)/\(weights.sha256)/verbatim-v1" }

    @concurrent
    public static func load(url: URL, weights: LocalWhisperWeights) async throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let model = try load(path: url.path, weights: weights)
        try Task.checkCancellation()
        return model
    }

    @concurrent
    public func transcribeWindow(pcm: [Float], sampleRate: Int) async throws -> PCMTranscript {
        try transcribe(pcm: pcm, sampleRate: sampleRate)
    }

    public static func load(path: String, weights: LocalWhisperWeights) throws -> Self {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(policy, IOPOL_SCOPE_THREAD)
        guard previous >= 0, setiopolicy_np(policy, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw SpeechModelError.readPolicyUnavailable }
        let result = Result { try VerifiedTinyModel.readModel(path: path, byteCount: weights.byteCount) }
        guard setiopolicy_np(policy, IOPOL_SCOPE_THREAD, previous) == 0 else { throw SpeechModelError.readPolicyUnavailable }
        let bytes = try result.get()
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == weights.sha256
        else { throw SpeechModelError.hashMismatch }
        return Self(weights: weights, bytes: bytes)
    }

    public func transcribe(
        pcm: [Float], sampleRate: Int,
        isCancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> PCMTranscript {
        guard (8000...192000).contains(sampleRate), pcm.count >= sampleRate / 10,
              pcm.count <= sampleRate * 30, pcm.allSatisfy({ $0.isFinite && abs($0) <= 8 })
        else { throw PCMInferenceRefusal.invalidPCM }
        guard !isCancelled() else { throw PCMInferenceRefusal.cancelled }
        // Digital zero is known empty input, not a VAD decision or a general silence classifier.
        if pcm.allSatisfy({ $0 == 0 }) { return PCMTranscript(segments: []) }
        var samples = try Self.resample(pcm, sampleRate: sampleRate)
        guard samples.allSatisfy(\.isFinite) else { throw PCMInferenceRefusal.invalidPCM }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        // Resampling can overshoot full scale. Normalize this analysis buffer only, never source/playback audio.
        if peak > 1 { samples = samples.map { $0 / peak } }
        let cancellation = WindowCancellation(isCancelled)
        let raw = Unmanaged.passUnretained(cancellation).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<WindowCancellation>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
        }
        var native = bytes.withUnsafeBytes { model in
            samples.withUnsafeBufferPointer { audio in
                ww_whisper_infer_window(UnsafeMutableRawPointer(mutating: model.baseAddress), model.count,
                    audio.baseAddress, Int32(audio.count), callback, raw)
            }
        }
        defer { ww_whisper_free_transcript(&native) }
        withExtendedLifetime(cancellation) {}
        guard !isCancelled(), native.status != WW_INFERENCE_CANCELLED else { throw PCMInferenceRefusal.cancelled }
        guard native.status == WW_INFERENCE_OK else {
            throw native.status == WW_INFERENCE_LOAD_FAILED ? PCMInferenceRefusal.modelLoadFailed : .inferenceFailed
        }
        guard (0...2048).contains(native.segment_count),
              native.segment_count == 0 || native.segments != nil else { throw PCMInferenceRefusal.inferenceFailed }
        var segments: [PCMSegment] = []
        for index in 0..<Int(native.segment_count) {
            guard let textPointer = native.segments?[index].text,
                  let text = String(validatingUTF8: textPointer) else { throw PCMInferenceRefusal.inferenceFailed }
            let item = native.segments![index]
            let start = Double(item.t0) / 100, end = Double(item.t1) / 100
            let valid = start >= 0 && end > start && end <= Double(samples.count) / 16_000
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(PCMSegment(text: trimmed, startSeconds: valid ? start : nil, endSeconds: valid ? end : nil))
            }
        }
        return PCMTranscript(segments: segments)
    }

    private static func resample(_ pcm: [Float], sampleRate: Int) throws -> [Float] {
        if sampleRate == 16_000 { return pcm }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(pcm.count)),
              let target = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 480_000),
              let inputChannel = input.floatChannelData?[0]
        else { throw PCMInferenceRefusal.invalidPCM }
        input.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { values in inputChannel.update(from: values.baseAddress!, count: values.count) }
        converter.primeMethod = .none
        var provided = false
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            if provided { state.pointee = .endOfStream; return nil }
            provided = true
            state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, let output = target.floatChannelData?[0],
              target.frameLength >= 1600, target.frameLength <= 480_000
        else { throw PCMInferenceRefusal.inferenceFailed }
        return Array(UnsafeBufferPointer(start: output, count: Int(target.frameLength)))
    }
}

private final class WindowCancellation: Sendable {
    let check: @Sendable () -> Bool
    init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
}
