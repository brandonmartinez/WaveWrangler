import Darwin
import Foundation
import WWWhisperNative
import WWSpeech

enum ProbeError: Error, Equatable {
    case missingModel
    case invalidInput
    case invalidSize
    case notMaterialized
    case readPolicyUnavailable
    case filesystemStatusUnavailable
    case nonLocalFilesystem
    case readFailed
    case changedDuringRead
    case hashMismatch
    case loadFailed
    case inferenceFailed
}

struct TinyTokenTimingObservation: Encodable {
    let mode: String
    let provenance: String
    let tokenCount: Int
    let textTokenCount: Int
    let absentTextTokenCount: Int
    let experimentalTextTokenCount: Int
    let leadingWhitespaceTokenCount: Int
    let internalWhitespaceTokenCount: Int
    let unseparatedAdjacentTokenCount: Int

    static func fromNative(_ native: WWTokenTimingObservation, enabled: Bool) -> Self {
        Self(
            mode: enabled ? "experimental-enabled" : "disabled",
            provenance: "experimental/unsupported",
            tokenCount: Int(native.token_count),
            textTokenCount: Int(native.text_token_count),
            absentTextTokenCount: Int(native.absent_text_token_count),
            experimentalTextTokenCount: Int(native.experimental_text_token_count),
            leadingWhitespaceTokenCount: Int(native.leading_whitespace_token_count),
            internalWhitespaceTokenCount: Int(native.internal_whitespace_token_count),
            unseparatedAdjacentTokenCount: Int(native.unseparated_adjacent_token_count)
        )
    }
}

struct TinyProbeResult: Encodable {
    let loaded: Bool
    let inferred: Bool
    let sampleCount: Int
    let threads: Int
    let segmentCount: Int
    let whitespaceWordCount: Int
    let segmentTimingAvailable: Bool
    let loadSeconds: Double
    let inferenceSeconds: Double
    let enabledInferenceSeconds: Double
    let tokenTimingDisabled: TinyTokenTimingObservation
    let tokenTimingEnabled: TinyTokenTimingObservation
    let wordTimingAvailable = false
    let wordTimingProvenance = "experimental/unsupported"
    let supportedWordBoundaryCount = 0
}

enum TinyModelProbe {
    static func classifyTokenTiming(enabled: Bool, start: Int64, end: Int64) -> String {
        ww_whisper_classify_token_timing(enabled ? 1 : 0, start, end) == 1
            ? "experimental/unsupported" : "absent"
    }

    static func run(path: String) throws -> TinyProbeResult {
        let model: VerifiedTinyModel
        do {
            model = try VerifiedTinyModel.load(path: path)
        } catch let error as SpeechModelError {
            throw ProbeError(error)
        }
        let native = model.withNativeBytes { pointer, count in
            ww_whisper_tiny_pcm_probe(pointer, count)
        }
        guard native.loaded == 1 else { throw ProbeError.loadFailed }
        guard native.inferred == 1 else { throw ProbeError.inferenceFailed }
        return TinyProbeResult(
            loaded: true, inferred: true,
            sampleCount: Int(native.sample_count), threads: Int(native.threads),
            segmentCount: Int(native.segment_count), whitespaceWordCount: Int(native.word_count),
            segmentTimingAvailable: native.segment_timing_available == 1,
            loadSeconds: native.load_seconds, inferenceSeconds: native.inference_seconds,
            enabledInferenceSeconds: native.enabled_inference_seconds,
            tokenTimingDisabled: TinyTokenTimingObservation.fromNative(native.disabled_token_timing, enabled: false),
            tokenTimingEnabled: TinyTokenTimingObservation.fromNative(native.enabled_token_timing, enabled: true)
        )
    }

    static func readModel(
        path: String,
        fileSystemStatus: (Int32, UnsafeMutablePointer<statfs>) -> Int32 = Darwin.fstatfs,
        descriptorRead: (Int32, UnsafeMutableRawPointer, Int, off_t) -> ssize_t = Darwin.pread
    ) throws -> Data {
        do {
            return try VerifiedTinyModel.readModel(
                path: path, fileSystemStatus: fileSystemStatus, descriptorRead: descriptorRead
            )
        } catch let error as SpeechModelError {
            throw ProbeError(error)
        }
    }
}

extension ProbeError {
    init(_ error: SpeechModelError) {
        switch error {
        case .missingModel: self = .missingModel
        case .invalidInput: self = .invalidInput
        case .invalidSize: self = .invalidSize
        case .notMaterialized: self = .notMaterialized
        case .readPolicyUnavailable: self = .readPolicyUnavailable
        case .filesystemStatusUnavailable: self = .filesystemStatusUnavailable
        case .nonLocalFilesystem: self = .nonLocalFilesystem
        case .readFailed: self = .readFailed
        case .changedDuringRead: self = .changedDuringRead
        case .hashMismatch: self = .hashMismatch
        }
    }
}

@main
struct TinyPCMProbeCLI {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--model" else {
            fputs("usage: ww-tiny-pcm-probe --model <local model path>\n", stderr)
            exit(2)
        }
        do {
            let result = try TinyModelProbe.run(path: CommandLine.arguments[2])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(result)
            guard let output = String(data: data, encoding: .utf8) else {
                throw ProbeError.inferenceFailed
            }
            print(output)
        } catch let error as ProbeError {
            fputs("probe refused: \(error)\n", stderr)
            exit(1)
        } catch {
            fputs("probe refused: input I/O failure\n", stderr)
            exit(1)
        }
    }
}
