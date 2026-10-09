import Foundation
import WWWhisperNative

public enum PCMInferenceRefusal: Error, Sendable, Equatable {
    case invalidPCM
    case cancelled
    case modelLoadFailed
    case inferenceFailed
}

public struct PCMSegment: Sendable, Equatable {
    public let text: String
    /// Segment timing only; nil when the engine does not supply a valid bounded interval.
    public let startSeconds: Double?
    public let endSeconds: Double?
}

public struct PCMTranscript: Sendable, Equatable {
    public let segments: [PCMSegment]
    /// Word boundaries and confidence are deliberately absent: token timestamps are unsupported.
}

private final class CancellationCheck: Sendable {
    let check: @Sendable () -> Bool
    init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
}

/// Lower-level experimental adapter: only already-decoded, caller-supplied PCM; no
/// selection, source authorization, I/O, persistence or app production entry point.
public struct BoundedPCMInference: Sendable {
    public init() {}

    package static func validateInput(
        pcm: [Float], sampleRate: Int?, channelCount: Int?
    ) throws(PCMInferenceRefusal) {
        guard sampleRate == 16_000, channelCount == 1, pcm.count == 32_000,
              pcm.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw .invalidPCM }
    }

    public func transcribe(
        model: VerifiedTinyModel, pcm: [Float], sampleRate: Int?,
        channelCount: Int?, isCancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws(PCMInferenceRefusal) -> PCMTranscript {
        try Self.validateInput(pcm: pcm, sampleRate: sampleRate, channelCount: channelCount)
        guard !isCancelled() else { throw .cancelled }

        let cancellation = CancellationCheck(isCancelled)
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { raw in
            guard let raw else { return 1 }
            return Unmanaged<CancellationCheck>.fromOpaque(raw).takeUnretainedValue().check() ? 1 : 0
        }
        var native = model.withNativeBytes { bytes, size in
            pcm.withUnsafeBufferPointer { samples in
                ww_whisper_infer_pcm(bytes, size, samples.baseAddress, Int32(samples.count), callback, context)
            }
        }
        defer { ww_whisper_free_transcript(&native) }
        withExtendedLifetime(cancellation) {}
        guard !isCancelled(), native.status != WW_INFERENCE_CANCELLED else { throw .cancelled }
        switch native.status {
        case WW_INFERENCE_OK: break
        case WW_INFERENCE_INVALID_INPUT: throw .invalidPCM
        case WW_INFERENCE_LOAD_FAILED: throw .modelLoadFailed
        default: throw .inferenceFailed
        }
        guard native.segment_count >= 0, native.segment_count <= 16 else { throw .inferenceFailed }
        guard native.segment_count == 0 || native.segments != nil else { throw .inferenceFailed }
        var segments: [PCMSegment] = []
        for index in 0..<Int(native.segment_count) {
            let segment = native.segments![index]
            guard let pointer = segment.text, let text = String(validatingUTF8: pointer) else {
                throw .inferenceFailed
            }
            let validTiming = segment.t0 >= 0 && segment.t1 > segment.t0 && segment.t1 <= 200
            segments.append(PCMSegment(
                text: text,
                startSeconds: validTiming ? Double(segment.t0) / 100 : nil,
                endSeconds: validTiming ? Double(segment.t1) / 100 : nil
            ))
        }
        guard !isCancelled() else { throw .cancelled }
        return PCMTranscript(segments: segments)
    }
}
