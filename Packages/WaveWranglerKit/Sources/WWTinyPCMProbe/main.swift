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

struct TinyProbeResult {
    let loaded: Bool
    let inferred: Bool
    let sampleCount: Int
    let threads: Int
    let segmentCount: Int
    let wordCount: Int
    let segmentTimingAvailable: Bool
    let loadSeconds: Double
    let inferenceSeconds: Double
}

enum TinyModelProbe {
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
            segmentCount: Int(native.segment_count), wordCount: Int(native.word_count),
            segmentTimingAvailable: native.segment_timing_available == 1,
            loadSeconds: native.load_seconds, inferenceSeconds: native.inference_seconds
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
            print("loaded=\(result.loaded) inferred=\(result.inferred) samples=\(result.sampleCount) threads=\(result.threads) segments=\(result.segmentCount) words=\(result.wordCount) segmentTimingAvailable=\(result.segmentTimingAvailable) wordTimingAvailable=false loadSeconds=\(result.loadSeconds) inferenceSeconds=\(result.inferenceSeconds)")
        } catch let error as ProbeError {
            fputs("probe refused: \(error)\n", stderr)
            exit(1)
        } catch {
            fputs("probe refused: input I/O failure\n", stderr)
            exit(1)
        }
    }
}
