import CryptoKit
import Darwin
import Foundation
import WWDecode
import WWDerived

/// Borrowed, unlinked 16 kHz mono Float32 little-endian PCM. The descriptor is
/// read-only and valid only during the synchronous callback; no pathname is supplied.
package struct BorrowedPrimaryPCMInput {
    package let descriptor: Int32
    package let selection: PrimarySpeechSelection
    package let declaredAuthorization: PrimarySpeechAuthorization
    package let showRevision: UInt64
    package let interpretation: FormatInterpretation
    package let sourceRevision: SourceRevision
    package let selectedSourcePCMHash: String
    package let inputAssetRevision: Int
    package let proxyAssetRevision: Int
    package let frameCount: Int
    package let sourceFramesPerOutputFrame: Int
    package let chunks: [PrimaryPCMChunk]
    package let sha256: String
    package let sampleRate: Int
    package let channelCount: Int
    package let format: String
}

/// The writer descriptor is private and retained solely to scrub the anonymous
/// file on scope exit. Only the read-only descriptor crosses the worker boundary.
final class SealedPrimaryPCMWorkerInput: @unchecked Sendable {
    private let writer: Int32
    private let reader: Int32
    private let proxy: SelectedPrimaryPCMProxy
    private let digest: SHA256.Digest
    private let byteCount: Int
    private let openedState: stat

    init(proxy: SelectedPrimaryPCMProxy) throws(SpeechAdmissionRefusal) {
        guard proxy.frameCount > 0,
              proxy.frameCount <= PrimarySpeechInputAdapter.maximumFrames,
              proxy.samples.allSatisfy(\.isFinite),
              proxy.proxyAssetRevision == SelectedPrimaryPCMProxy.proxyAsset.revision,
              proxy.inputAssetRevision == PrimarySpeechInputAdapter.inputAssetRevision
        else { throw .workerInputNotSealed }
        let byteCount = proxy.frameCount * MemoryLayout<Float>.size

        var directoryTemplate = Array("/private/tmp/ww-speech-pcm-XXXXXXXX".utf8CString)
        guard mkdtemp(&directoryTemplate) != nil else { throw .workerInputNotSealed }
        let directory = String(decoding: directoryTemplate.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            _ = rmdir(directory)
            throw .workerInputNotSealed
        }
        var directoryInfo = stat()
        var fileSystem = statfs()
        guard fstat(directoryFD, &directoryInfo) == 0,
              fstatfs(directoryFD, &fileSystem) == 0,
              fileSystem.f_flags & UInt32(MNT_LOCAL) != 0,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0,
              directoryInfo.st_flags & UInt32(SF_DATALESS) == 0
        else {
            _ = close(directoryFD)
            _ = rmdir(directory)
            throw .workerInputNotSealed
        }
        let created = openat(directoryFD, "input.pcm", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard created >= 0 else {
            _ = close(directoryFD)
            _ = rmdir(directory)
            throw .workerInputNotSealed
        }
        var openedReader: Int32 = -1
        defer {
            _ = unlinkat(directoryFD, "input.pcm", 0)
            _ = close(directoryFD)
            _ = rmdir(directory)
            if openedReader < 0 {
                Self.scrub(created, count: byteCount)
                _ = close(created)
            }
        }
        var info = stat()
        guard fstat(created, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_flags & UInt32(SF_DATALESS) == 0
        else { throw .workerInputNotSealed }

        var hasher = SHA256()
        for start in stride(from: 0, to: proxy.frameCount, by: SelectedPrimaryPCMProxy.chunkFrames) {
            guard !Task.isCancelled else { throw .decode(.cancelled) }
            let end = min(start + SelectedPrimaryPCMProxy.chunkFrames, proxy.frameCount)
            guard let bytes = proxy.samples[start..<end].withContiguousStorageIfAvailable({ samples in
                samples.withMemoryRebound(to: UInt8.self) { Data($0) }
            }), bytes.count == (end - start) * MemoryLayout<Float>.size else {
                throw .workerInputNotSealed
            }
            hasher.update(data: bytes)
            try bytes.withUnsafeBytes { buffer throws(SpeechAdmissionRefusal) in
                var written = 0
                while written < buffer.count {
                    let count = write(created, buffer.baseAddress! + written, buffer.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw .workerInputNotSealed }
                    written += count
                }
            }
        }
        guard !Task.isCancelled, fchmod(created, 0o400) == 0,
              fstat(created, &info) == 0, info.st_size == byteCount
        else { throw Task.isCancelled ? .decode(.cancelled) : .workerInputNotSealed }
        let fd = openat(directoryFD, "input.pcm", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw .workerInputNotSealed }
        openedReader = fd
        var readerInfo = stat()
        guard fstat(fd, &readerInfo) == 0,
              readerInfo.st_dev == info.st_dev, readerInfo.st_ino == info.st_ino,
              readerInfo.st_size == byteCount, readerInfo.st_uid == getuid(),
              readerInfo.st_mode & S_IFMT == S_IFREG,
              readerInfo.st_flags & UInt32(SF_DATALESS) == 0,
              fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY,
              unlinkat(directoryFD, "input.pcm", 0) == 0
        else {
            _ = close(fd)
            openedReader = -1
            throw .workerInputNotSealed
        }
        let expectedDigest = hasher.finalize()
        let state: stat
        do { state = try Self.verify(reader: fd, byteCount: byteCount, digest: expectedDigest) }
        catch {
            _ = close(fd)
            openedReader = -1
            throw error
        }
        writer = created
        reader = fd
        self.proxy = proxy
        self.byteCount = byteCount
        digest = expectedDigest
        openedState = state
    }

    deinit {
        Self.scrub(writer, count: byteCount)
        _ = close(reader)
        _ = close(writer)
    }

    func withBorrowedDescriptor<T: Sendable>(
        _ worker: (BorrowedPrimaryPCMInput) throws(SpeechAdmissionRefusal) -> T
    ) throws(SpeechAdmissionRefusal) -> T {
        try verify()
        guard !Task.isCancelled else { throw .decode(.cancelled) }
        let input = BorrowedPrimaryPCMInput(
            descriptor: reader, selection: proxy.selection,
            declaredAuthorization: proxy.declaredAuthorization, showRevision: proxy.showRevision,
            interpretation: proxy.interpretation,
            sourceRevision: proxy.sourceRevision,
            selectedSourcePCMHash: proxy.selectedSourcePCMHash,
            inputAssetRevision: proxy.inputAssetRevision,
            proxyAssetRevision: proxy.proxyAssetRevision, frameCount: proxy.frameCount,
            sourceFramesPerOutputFrame: proxy.sourceFramesPerOutputFrame, chunks: proxy.chunks,
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            sampleRate: SelectedPrimaryPCMProxy.sampleRate, channelCount: 1,
            format: "f32le")
        let result = try worker(input)
        try verify()
        guard !Task.isCancelled else { throw .decode(.cancelled) }
        return result
    }

    private func verify() throws(SpeechAdmissionRefusal) {
        _ = try Self.verify(reader: reader, byteCount: byteCount, digest: digest,
                            expected: openedState)
    }

    #if DEBUG
    func overwriteForTesting() {
        var byte: UInt8 = 0xFF
        _ = pwrite(writer, &byte, 1, 0)
    }
    #endif

    private static func verify(
        reader: Int32, byteCount: Int, digest: SHA256.Digest, expected: stat? = nil
    ) throws(SpeechAdmissionRefusal) -> stat
    {
        var before = stat()
        guard fstat(reader, &before) == 0, before.st_uid == getuid(),
              before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o777 == 0o400,
              before.st_nlink == 0, before.st_size == byteCount,
              before.st_flags & UInt32(SF_DATALESS) == 0,
              fcntl(reader, F_GETFL) & O_ACCMODE == O_RDONLY
        else { throw .workerInputChanged }
        if let expected, !sameState(before, expected) { throw .workerInputChanged }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        while offset < byteCount {
            guard !Task.isCancelled else { throw .decode(.cancelled) }
            let size = min(bytes.count, byteCount - offset)
            let count = bytes.withUnsafeMutableBytes {
                pread(reader, $0.baseAddress, size, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw .workerInputChanged }
            hasher.update(data: Data(bytes.prefix(count)))
            offset += count
        }
        var after = stat()
        guard hasher.finalize() == digest, fstat(reader, &after) == 0,
              sameState(before, after)
        else { throw .workerInputChanged }
        return after
    }

    private static func sameState(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid &&
        a.st_mode == b.st_mode && a.st_nlink == b.st_nlink &&
        a.st_size == b.st_size && a.st_flags == b.st_flags &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func scrub(_ fd: Int32, count: Int) {
        let zeros = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        while offset < count {
            let size = min(zeros.count, count - offset)
            let written = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress, size, off_t(offset)) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { break }
            offset += written
        }
        _ = ftruncate(fd, 0)
    }
}
