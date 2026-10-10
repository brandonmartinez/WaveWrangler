import Darwin
import Foundation
import Testing
import WWSpeech
import WWWhisperNative

@Suite("WW-026 isolated PCM inference refusal")
struct BoundedPCMInferenceTests {
    @Test func inputEnvelopeRejectsMissingOrMalformedPCMWithoutAModel() throws {
        let pcm = [Float](repeating: 0, count: 32_000)
        try BoundedPCMInference.validateInput(pcm: pcm, sampleRate: 16_000, channelCount: 1)
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try BoundedPCMInference.validateInput(pcm: pcm, sampleRate: nil, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try BoundedPCMInference.validateInput(pcm: pcm, sampleRate: 16_000, channelCount: nil)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try BoundedPCMInference.validateInput(pcm: pcm, sampleRate: 48_000, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try BoundedPCMInference.validateInput(pcm: pcm, sampleRate: 16_000, channelCount: 2)
        }
        for badPCM in [Array(pcm.dropLast()), pcm + [0], [.nan] + Array(pcm.dropFirst()),
                       [.infinity] + Array(pcm.dropFirst()), [2] + Array(pcm.dropFirst())] {
            #expect(throws: PCMInferenceRefusal.invalidPCM) {
                try BoundedPCMInference.validateInput(pcm: badPCM, sampleRate: 16_000, channelCount: 1)
            }
        }
    }

    @Test func missingAndWrongPinnedModelRefuse() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: SpeechModelError.missingModel) {
            try VerifiedTinyModel.load(path: missing.path)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0]).write(to: file)
        #expect(throws: SpeechModelError.invalidSize) {
            try VerifiedTinyModel.load(path: file.path)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(VerifiedTinyModel.byteCount))
        try handle.close()
        #expect(throws: SpeechModelError.hashMismatch) {
            try VerifiedTinyModel.load(path: file.path)
        }
    }

    @Test func nativeABIRefusesInvalidPCMBeforeModelLoad() {
        var fakeModel = [UInt8](repeating: 0, count: 1)
        var pcm = [Float](repeating: 0, count: 32_000)
        let active: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in 0 }
        let stopped: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in 1 }

        fakeModel.withUnsafeMutableBytes { bytes in
            pcm.withUnsafeBufferPointer { samples in
                let result = ww_whisper_infer_pcm(bytes.baseAddress, bytes.count,
                                                   samples.baseAddress, 32_000, active, nil)
                #expect(result.status == WW_INFERENCE_INVALID_INPUT)
                #expect(result.segments == nil)
                let cancelled = ww_whisper_infer_pcm(bytes.baseAddress, bytes.count,
                                                      samples.baseAddress, 32_000, stopped, nil)
                #expect(cancelled.status == WW_INFERENCE_CANCELLED)
            }
        }
        pcm[0] = .nan
        fakeModel.withUnsafeMutableBytes { bytes in
            pcm.withUnsafeBufferPointer { samples in
                let result = ww_whisper_infer_pcm(bytes.baseAddress, VerifiedTinyModel.byteCount,
                                                   samples.baseAddress, 32_000, active, nil)
                #expect(result.status == WW_INFERENCE_INVALID_INPUT)
                #expect(result.segments == nil)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_TINY_MODEL_PATH"] != nil))
    func optedInGeneratedPCMInference() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WW_TINY_MODEL_PATH"])
        let model = try VerifiedTinyModel.load(path: path)
        let generated = (0..<32_000).map { index in
            0.1 * sinf(Float(index) * (2 * .pi * 440 / 16_000))
        }
        let inference = BoundedPCMInference()
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: generated, sampleRate: nil, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: generated, sampleRate: 16_000, channelCount: nil)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: generated, sampleRate: 48_000, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: generated, sampleRate: 16_000, channelCount: 2)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: Array(generated.dropLast()), sampleRate: 16_000, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.invalidPCM) {
            try inference.transcribe(model: model, pcm: [.nan] + Array(generated.dropFirst()),
                                     sampleRate: 16_000, channelCount: 1)
        }
        #expect(throws: PCMInferenceRefusal.cancelled) {
            try inference.transcribe(model: model, pcm: generated, sampleRate: 16_000,
                                     channelCount: 1, isCancelled: { true })
        }
        let result = try inference.transcribe(model: model, pcm: generated, sampleRate: 16_000, channelCount: 1)
        #expect(result.segments.count <= 16)
        for segment in result.segments {
            #expect(segment.text.utf8.count <= 4096)
            #expect((segment.startSeconds == nil) == (segment.endSeconds == nil))
            if let start = segment.startSeconds, let end = segment.endSeconds {
                #expect(start >= 0 && end > start && end <= 2)
            }
        }
    }
}
