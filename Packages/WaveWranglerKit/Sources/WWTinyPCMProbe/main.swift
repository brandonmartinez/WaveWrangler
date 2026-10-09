import CryptoKit
import Darwin
import Foundation
import WWWhisperNative

enum ProbeError: Error, Equatable {
    case missingModel
    case invalidInput
    case invalidSize
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
    private static let modelSize = 77_704_715
    private static let modelSHA256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    static func run(path: String) throws -> TinyProbeResult {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw errno == ENOENT ? ProbeError.missingModel : .invalidInput }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw ProbeError.invalidInput
        }
        guard before.st_size == modelSize else { throw ProbeError.invalidSize }

        // Bound the read to the verified descriptor, not a second open by path.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var bytes = handle.readData(ofLength: modelSize + 1)
        guard bytes.count == modelSize else { throw ProbeError.invalidSize }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ProbeError.changedDuringRead }

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == modelSHA256 else { throw ProbeError.hashMismatch }
        let native = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            ww_whisper_tiny_pcm_probe(buffer.baseAddress, buffer.count)
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
