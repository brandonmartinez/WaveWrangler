import Darwin
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

// Test-only shape of the missing confirmed, device-local raw identity. This does not issue access
// authority: no caller-supplied value may authorize a selected Primary in production.
private struct ExpectedRawIdentity: Decodable, Equatable {
    let version: Int
    let volumeUUID: String
    let device: Int64
    let inode: UInt64
    let sizeBytes: Int64
    let mode: UInt16
    let dataless: Bool
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64

    init(_ info: stat, volumeUUID: String) {
        version = 1
        self.volumeUUID = volumeUUID
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        sizeBytes = Int64(info.st_size)
        mode = UInt16(info.st_mode)
        dataless = info.st_flags & UInt32(SF_DATALESS) != 0
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }

    func movingModification(by nanoseconds: Int64) -> Self {
        var changed = self
        let sum = modificationNanoseconds + nanoseconds
        changed.modificationSeconds += sum / 1_000_000_000
        changed.modificationNanoseconds = sum % 1_000_000_000
        return changed
    }
}

private struct ExpectedConfirmedRecord: Decodable {
    struct Identity: Decodable {
        let rawWitness: ExpectedRawIdentity
    }
    let recordedIdentity: Identity
}

private func rawIdentity(at url: URL, volumeUUID: String) throws -> ExpectedRawIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return ExpectedRawIdentity(info, volumeUUID: volumeUUID)
}

@Suite("Selected Primary raw source identity (RED: production contract absent)")
struct RawSelectedPrimaryWitnessTests {
    @Test("Unchanged copied Primary decodes exactly 32000 frames; Backup stays unopened; confirmation persists raw identity")
    func copiedPrimaryNeedsRawConfirmation() async throws {
        let directory = try FixtureDirectory("raw-primary")
        let signal = LandmarkSignal(frames: 32_000, channelCount: 1, seed: 413)
        let spec = FixtureSpec(
            container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false),
            sampleRate: 48_000, channelCount: 1
        )
        let original = try directory.write(spec, signal: signal, name: "original.wav")
        let primary = try directory.copy(original, as: "selected-primary.wav")
        let backup = try directory.writeBytes(Data(repeating: 0x5A, count: 128), as: "unselected-backup.wav")
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: primary),
              let volume = metadata.fingerprint.volumeUUID.value
        else { throw POSIXError(.EIO) }
        let confirmed = DeviceAccessRecord(
            showID: ShowID(), sourceID: SourceID(), lastKnownPath: primary.path,
            recordedIdentity: RecordedIdentity(
                fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
            ), createdAt: Date()
        )
        let expected = try rawIdentity(at: primary, volumeUUID: volume)
        let backupOpens = Counter()
        var gateway = SystemSourceContentIO()
        gateway.descriptorOpener = { path in
            if String(cString: path) == backup.path { backupOpens.increment() }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let result = try await decodeAll(primary, chunkFrames: 4096, content: gateway)
        #expect(result.interpretation.frames.validFrames == 32_000)
        #expect(result.product.channels == signal.channels)
        #expect(backupOpens.count == 0)
        #expect(expected.mode & UInt16(S_IFMT) == UInt16(S_IFREG) && !expected.dataless)

        // RED: Date-only schema 1 has no rawWitness. Passing the ordinary decoder above proves only
        // that its old path still works; it does not prove selected-Primary authorization.
        let persisted = try JSONEncoder().encode(confirmed)
        let recovered = try JSONDecoder().decode(ExpectedConfirmedRecord.self, from: persisted)
        #expect(recovered.recordedIdentity.rawWitness == expected)
        #expect(DeviceAccessRecord.schemaVersion > 1)
    }

    @Test("A 211ns pre-open raw mtime difference must refuse before a decoded frame or sink")
    func sub500NanosecondPreOpenDrift() async throws {
        let source = try ScriptedSource()
        guard case let .success(metadata) = SystemSourceIO().metadata(at: source.url),
              let volume = metadata.fingerprint.volumeUUID.value
        else { throw POSIXError(.EIO) }
        let confirmedRaw = try rawIdentity(at: source.url, volumeUUID: volume)
        let observedRaw = confirmedRaw.movingModification(by: 211)
        #expect(observedRaw != confirmedRaw)
        #expect(observedRaw.modificationSeconds * 1_000_000_000 + observedRaw.modificationNanoseconds
                - confirmedRaw.modificationSeconds * 1_000_000_000 - confirmedRaw.modificationNanoseconds == 211)
        var facts = source.aacFacts()
        facts.openedFile.modificationSeconds = observedRaw.modificationSeconds
        facts.openedFile.modificationNanoseconds = observedRaw.modificationNanoseconds
        let content = ScriptedContentIO(source.script(facts))
        let attempt = await runAttempt(source.url, content: content)

        // Negative-only scripted descriptor seam: the exact raw difference is deterministic,
        // but this cannot prove pre-header refusal or platform timestamp precision. Both require
        // the absent checked-descriptor opener; a frame-read count is not a header-read count.
        // RED: the existing Date-tolerant decoder reads and finishes instead of refusing.
        #expect(attempt.failure == .sourceIdentityMismatch)
        #expect(content.record.opens == 1)
        #expect(content.record.reads == 0)
        #expect(attempt.sinksMade == 0)
        expectNothingPublished(attempt)
    }

    @Test("Appending to an open synthetic Primary changes raw same-file state and cannot finish")
    func postAppendSameFileDriftAbandons() async throws {
        let directory = try FixtureDirectory("raw-post-append")
        let spec = FixtureSpec(
            container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false),
            sampleRate: 48_000, channelCount: 1
        )
        let original = try directory.write(spec, signal: LandmarkSignal(frames: 32_000, channelCount: 1, seed: 42))
        let primary = try directory.copy(original, as: "selected-primary.wav")
        let fd = Darwin.open(primary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var beforeInfo = stat()
        guard fstat(fd, &beforeInfo) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let accessSeconds = beforeInfo.st_atimespec.tv_sec
        let accessNanoseconds = beforeInfo.st_atimespec.tv_nsec
        let modifiedSeconds = beforeInfo.st_mtimespec.tv_sec + 2
        let modifiedNanoseconds = beforeInfo.st_mtimespec.tv_nsec
        let appended = Counter()
        let attempt = await runAttempt(
            primary, content: SystemSourceContentIO(), io: SystemSourceIO(), chunkFrames: 4096,
            onAppend: { index in
                guard index == 1 else { return }
                let writer = Darwin.open(primary.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
                guard writer >= 0 else { Issue.record("synthetic append open failed: \(errno)"); return }
                defer { Darwin.close(writer) }
                var byte: UInt8 = 0
                guard Darwin.write(writer, &byte, 1) == 1 else { Issue.record("synthetic append failed: \(errno)"); return }
                var times = [
                    timespec(tv_sec: accessSeconds, tv_nsec: accessNanoseconds),
                    timespec(tv_sec: modifiedSeconds, tv_nsec: modifiedNanoseconds),
                ]
                guard utimensat(AT_FDCWD, primary.path, &times, 0) == 0 else {
                    Issue.record("synthetic mtime change failed: \(errno)")
                    return
                }
                appended.increment()
            }
        )
        var afterInfo = stat()
        guard fstat(fd, &afterInfo) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        #expect(appended.count == 1)
        #expect(afterInfo.st_dev == beforeInfo.st_dev && afterInfo.st_ino == beforeInfo.st_ino)
        #expect(afterInfo.st_size == beforeInfo.st_size + 1)
        #expect(afterInfo.st_mtimespec.tv_sec == modifiedSeconds)
        #expect(afterInfo.st_mtimespec.tv_nsec == modifiedNanoseconds)
        #expect(attempt.events.contains("append"))
        #expect(attempt.failure == .sourceChangedDuringDecode)
        expectNothingPublished(attempt)
    }
}
