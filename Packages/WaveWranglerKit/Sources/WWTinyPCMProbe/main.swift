import CryptoKit
import Darwin
import Foundation
import WWWhisperNative

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
    private static let modelSize = 77_704_715
    private static let modelSHA256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    static func run(path: String) throws -> TinyProbeResult {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(policy, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(policy, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw ProbeError.readPolicyUnavailable }
        let readResult = Result { try readModel(path: path) }
        guard setiopolicy_np(policy, IOPOL_SCOPE_THREAD, previous) == 0
        else { throw ProbeError.readPolicyUnavailable }
        var bytes = try readResult.get()
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

    static func readModel(
        path: String,
        fileSystemStatus: (Int32, UnsafeMutablePointer<statfs>) -> Int32 = Darwin.fstatfs,
        descriptorRead: (Int32, UnsafeMutableRawPointer, Int, off_t) -> ssize_t = Darwin.pread
    ) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? ProbeError.missingModel : .invalidInput }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else { throw ProbeError.invalidInput }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw ProbeError.invalidInput
        }
        guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw ProbeError.notMaterialized }
        var filesystem = statfs()
        guard fileSystemStatus(fd, &filesystem) == 0 else { throw ProbeError.filesystemStatusUnavailable }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ProbeError.nonLocalFilesystem }
        guard before.st_size == modelSize else { throw ProbeError.invalidSize }

        var bytes = Data(count: modelSize)
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw ProbeError.readFailed }
            var offset = 0
            var interruptedReads = 0
            while offset < modelSize {
                let count = min(64 * 1024, modelSize - offset)
                let received = descriptorRead(fd, base + offset, count, off_t(offset))
                if received > 0 {
                    guard received <= count else { throw ProbeError.readFailed }
                    offset += received
                    interruptedReads = 0
                } else if received == 0 {
                    throw ProbeError.invalidSize
                } else if errno == EINTR {
                    // A permanently interrupted descriptor must not spin forever.
                    interruptedReads += 1
                    guard interruptedReads <= 8 else { throw ProbeError.readFailed }
                } else {
                    throw ProbeError.readFailed
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_flags & UInt32(SF_DATALESS) == 0,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ProbeError.changedDuringRead }
        return bytes
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
