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
    case invalidDTWPreset
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

    static func fromNative(_ native: WWTokenTimingObservation, mode: String) -> Self {
        Self(
            mode: mode,
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

struct TinyDTWObservation: Encodable {
    let alignmentHeadPreset: String
    let loadSeconds: Double
    let inferenceSeconds: Double
    let tokenTiming: TinyTokenTimingObservation
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
    let dtw: TinyDTWObservation?
    let wordTimingAvailable = false
    let wordTimingProvenance = "experimental/unsupported"
    let supportedWordBoundaryCount = 0
}

enum TinyModelProbe {
    static func parseArguments(_ arguments: [String]) throws -> (path: String, dtwPreset: String?) {
        guard arguments.count >= 3, arguments[1] == "--model", !arguments[2].isEmpty else {
            throw ProbeError.invalidInput
        }
        if arguments.count >= 4, arguments[3] == "--experimental-dtw" {
            guard arguments.count == 5, arguments[4] == "tiny.en" else {
                throw ProbeError.invalidDTWPreset
            }
            return (arguments[2], "tiny.en")
        }
        guard arguments.count == 3 else { throw ProbeError.invalidInput }
        return (arguments[2], nil)
    }

    static func classifyTokenTiming(enabled: Bool, start: Int64, end: Int64) -> String {
        ww_whisper_classify_token_timing(enabled ? 1 : 0, start, end) == 1
            ? "experimental/unsupported" : "absent"
    }

    static func classifyDTWPoint(enabled: Bool, point: Int64) -> String {
        ww_whisper_classify_dtw_point(enabled ? 1 : 0, point) == 1
            ? "experimental/unsupported" : "absent"
    }

    static func run(path: String, dtwPreset: String? = nil) throws -> TinyProbeResult {
        guard dtwPreset == nil || dtwPreset == "tiny.en" else { throw ProbeError.invalidDTWPreset }
        let model: VerifiedTinyModel
        do {
            model = try VerifiedTinyModel.load(path: path)
        } catch let error as SpeechModelError {
            throw ProbeError(error)
        }
        let native = model.withNativeBytes { pointer, count in
            if dtwPreset != nil {
                return ww_whisper_tiny_pcm_probe_with_dtw(pointer, count, "tiny.en")
            }
            return ww_whisper_tiny_pcm_probe(pointer, count)
        }
        guard native.loaded == 1 else { throw ProbeError.loadFailed }
        guard native.inferred == 1 else { throw ProbeError.inferenceFailed }
        if dtwPreset != nil, native.dtw_inferred != 1 { throw ProbeError.inferenceFailed }
        let dtw: TinyDTWObservation? = dtwPreset == nil ? nil : TinyDTWObservation(
            alignmentHeadPreset: "tiny.en",
            loadSeconds: native.dtw_load_seconds, inferenceSeconds: native.dtw_inference_seconds,
            tokenTiming: .fromNative(native.dtw_token_timing, mode: "dtw-experimental")
        )
        return TinyProbeResult(
            loaded: true, inferred: true,
            sampleCount: Int(native.sample_count), threads: Int(native.threads),
            segmentCount: Int(native.segment_count), whitespaceWordCount: Int(native.word_count),
            segmentTimingAvailable: native.segment_timing_available == 1,
            loadSeconds: native.load_seconds, inferenceSeconds: native.inference_seconds,
            enabledInferenceSeconds: native.enabled_inference_seconds,
            tokenTimingDisabled: TinyTokenTimingObservation.fromNative(native.disabled_token_timing, mode: "disabled"),
            tokenTimingEnabled: TinyTokenTimingObservation.fromNative(native.enabled_token_timing, mode: "experimental-enabled"),
            dtw: dtw
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
        do {
            let arguments = try TinyModelProbe.parseArguments(CommandLine.arguments)
            let result = try TinyModelProbe.run(path: arguments.path, dtwPreset: arguments.dtwPreset)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(result)
            guard let output = String(data: data, encoding: .utf8) else {
                throw ProbeError.inferenceFailed
            }
            print(output)
        } catch let error as ProbeError {
            if error == .invalidInput || error == .invalidDTWPreset {
                fputs("usage: ww-tiny-pcm-probe --model <local model path> [--experimental-dtw tiny.en]\n", stderr)
                exit(2)
            }
            fputs("probe refused: \(error)\n", stderr)
            exit(1)
        } catch {
            fputs("probe refused: input I/O failure\n", stderr)
            exit(1)
        }
    }
}
