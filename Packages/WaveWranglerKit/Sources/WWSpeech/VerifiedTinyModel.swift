import CryptoKit
import Darwin
import Foundation

public enum SpeechModelError: Error, Equatable {
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
}

/// Pinned, local tiny.en weights for an isolated, caller-supplied PCM experiment.
/// This is not evidence of model-artifact rights or permission to transcribe source media.
public struct VerifiedTinyModel: Sendable {
    public static let byteCount = 77_704_715
    private static let sha256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"
    private let bytes: Data

    private init(bytes: Data) { self.bytes = bytes }

    public static func load(path: String) throws -> Self {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(policy, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(policy, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw SpeechModelError.readPolicyUnavailable }
        let readResult = Result { try readModel(path: path) }
        guard setiopolicy_np(policy, IOPOL_SCOPE_THREAD, previous) == 0
        else { throw SpeechModelError.readPolicyUnavailable }
        let bytes = try readResult.get()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw SpeechModelError.hashMismatch }
        return Self(bytes: bytes)
    }

    package func withNativeBytes<T>(_ body: (UnsafeMutableRawPointer?, Int) -> T) -> T {
        var copy = bytes
        return copy.withUnsafeMutableBytes { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }

    package static func readModel(
        path: String,
        fileSystemStatus: (Int32, UnsafeMutablePointer<statfs>) -> Int32 = Darwin.fstatfs,
        descriptorRead: (Int32, UnsafeMutableRawPointer, Int, off_t) -> ssize_t = Darwin.pread
    ) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? SpeechModelError.missingModel : .invalidInput }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else { throw SpeechModelError.invalidInput }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw SpeechModelError.invalidInput
        }
        guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw SpeechModelError.notMaterialized }
        var filesystem = statfs()
        guard fileSystemStatus(fd, &filesystem) == 0 else { throw SpeechModelError.filesystemStatusUnavailable }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw SpeechModelError.nonLocalFilesystem }
        guard before.st_size == byteCount else { throw SpeechModelError.invalidSize }

        var bytes = Data(count: byteCount)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw SpeechModelError.readFailed }
            var offset = 0
            var interruptedReads = 0
            while offset < byteCount {
                let count = min(64 * 1024, byteCount - offset)
                let received = descriptorRead(fd, base + offset, count, off_t(offset))
                if received > 0 {
                    guard received <= count else { throw SpeechModelError.readFailed }
                    offset += received
                    interruptedReads = 0
                } else if received == 0 {
                    throw SpeechModelError.invalidSize
                } else if errno == EINTR {
                    interruptedReads += 1
                    guard interruptedReads <= 8 else { throw SpeechModelError.readFailed }
                } else {
                    throw SpeechModelError.readFailed
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
        else { throw SpeechModelError.changedDuringRead }
        return bytes
    }
}
