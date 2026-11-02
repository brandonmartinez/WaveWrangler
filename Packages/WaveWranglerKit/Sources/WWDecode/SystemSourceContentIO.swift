import AudioToolbox
import Darwin
import Foundation
import WWSources

/// Nonserialized proof of the standard mono/stereo order defined by a qualified legacy WAVE header.
/// Only this gateway can mint it; empty/custom layout labels alone never create this evidence.
public struct LegacyWavePCMChannelOrderEvidence: Sendable, Equatable {
    package let channelCount: Int
    private let formatBytes: [UInt8]
    private let riffBytes: Int64
    private let formatOffset: Int64
    private let dataOffset: Int64
    private let dataBytes: Int64
    private let factFrames: UInt32?

    fileprivate init(channelCount: Int, formatBytes: [UInt8], riffBytes: Int64,
                     formatOffset: Int64, dataOffset: Int64, dataBytes: Int64, factFrames: UInt32?) {
        self.channelCount = channelCount
        self.formatBytes = formatBytes
        self.riffBytes = riffBytes
        self.formatOffset = formatOffset
        self.dataOffset = dataOffset
        self.dataBytes = dataBytes
        self.factFrames = factFrames
    }
}

/// Codec-declared order from the opened M4A's decompression cookie, not an inferred container layout.
public struct M4ACodecChannelOrderEvidence: Sendable, Equatable {
    package let channelCount: Int
    private let formatID: UInt32
    private let layoutTag: UInt32
    private let cookie: Data

    fileprivate init(channelCount: Int, formatID: UInt32, layoutTag: UInt32, cookie: Data) {
        self.channelCount = channelCount
        self.formatID = formatID
        self.layoutTag = layoutTag
        self.cookie = cookie
    }
}

/// The production `SourceContentIO`. This is the only file in the codebase allowed to open source
/// content, and it opens it read-only:
///
/// - The file is opened once with `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`, and `fcntl(F_GETFL)` then
///   confirms the descriptor's access mode is read-only before anything else uses it. There is no
///   write path.
/// - AudioFile reads through callbacks that only `pread` that descriptor. The write and set-size
///   callbacks are `nil`, so AudioFile cannot write even if asked to.
/// - ExtAudioFile wraps that AudioFile for reading only (`forWriting: false`). Its property setters
///   configure the in-memory reader (client format, packet-table handling), never the file.
/// - Before any content is read, `fstat` on the descriptor rejects dataless (not materialized) files.
///   The open and every content read (`ReadOnlyDescriptor.readFully`, through which all AudioFile,
///   ExtAudioFile and container-header reads go) also run with this thread's dataless-file
///   materialization turned off (`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`), so a race can't trigger
///   a provider download. That policy is defense in depth; it has not been exercised against a real
///   provider.
///
/// Package access: apps decode through `SourceDecoder`, which adds the scope, preflight, identity and
/// staleness checks this gateway relies on.
package struct SystemSourceContentIO: SourceContentIO {
    package init() {}

    #if DEBUG
    /// Test only: called at every content read with this thread's dataless-materialization policy.
    package var readPolicyObserver: (@Sendable (Int32) -> Void)?
    /// Test only: replaces the descriptor open so the read-only access-mode check can be exercised.
    package var descriptorOpener: (@Sendable (UnsafePointer<CChar>) -> Int32)?
    /// Negative-only challenge after real fstat; never substitutes a matching observation.
    package var rawIdentityChallenge: (@Sendable (RawSourceIdentity) -> RawSourceIdentity)?
    /// Test-only root descriptor for rejecting an invalid mount before any content read.
    package var volumeRootDescriptor: Int32?
    /// Test-only measurement of actual native decode calls (header/cache probes do not count).
    package var rawFrameReadObserver: (@Sendable () -> Void)?
    #endif

    package func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        try SystemDecodingReader.make(url, gateway: self)
    }

    fileprivate func openReadOnlySourceDescriptor(_ url: URL, gateway: SystemSourceContentIO) throws(DecodeFailure) -> Int32 {
        guard url.isFileURL else { throw .notFound }
        let (descriptor, openErrno): (Int32, Int32) = withoutMaterializingDataless {
            url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                guard let path else { return (-1, ENOENT) }
                var result: Int32
                repeat {
                    #if DEBUG
                    if let opener = gateway.descriptorOpener {
                        result = opener(path)
                        continue
                    }
                    #endif
                    result = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                } while result < 0 && errno == EINTR
                return (result, result < 0 ? errno : 0)
            }
        }
        guard descriptor >= 0 else { throw failure(forErrno: openErrno) }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0, statusFlags & O_ACCMODE == O_RDONLY else {
            Darwin.close(descriptor)
            throw .notOpenedReadOnly
        }
        return descriptor
    }

    fileprivate func observedRawIdentity(_ fd: Int32, gateway: SystemSourceContentIO) -> RawSourceIdentity? {
        #if DEBUG
        if let rootFD = gateway.volumeRootDescriptor {
            return RawSourceIdentity.onDescriptor(fd, volumeRootDescriptor: rootFD)
        }
        #endif
        return RawSourceIdentity.onDescriptor(fd)
    }

    /// The caller must already have obtained a confirmed witness under a separate authority gate.
    package func openForDecoding(_ url: URL, matching witness: RawSourceIdentity) throws(DecodeFailure) -> any DecodingContentReader {
        try SystemDecodingReader.make(url, gateway: self, expected: witness)
    }

    /// Descriptor metadata only: no AudioFile or ExtAudioFile call is reached.
    package func captureRawIdentity(
        _ url: URL, matching before: SourceMetadata, io: any SourceIO
    ) throws(DecodeFailure) -> RawSourceIdentity {
        switch before.volumeIsLocal.value {
        case true?: break
        case false?: throw .notMaterialized
        case nil: throw .residencyUnknown
        }
        let fingerprint = before.fingerprint
        guard let fileID = fingerprint.fileIdentifier.value,
              let size = fingerprint.fileSize.value,
              let volume = fingerprint.volumeUUID.value,
              fingerprint.creationDate.isKnown,
              fingerprint.contentModificationDate.isKnown
        else { throw .metadataUnavailable(nil) }
        var pathBefore = stat()
        guard lstat(url.path, &pathBefore) == 0 else { throw .sourceIdentityMismatch }
        let descriptor = try openReadOnlySourceDescriptor(url, gateway: self)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .readFailed(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw .notMaterialized }
        guard info.st_size > 0 else { throw .emptyFile }
        guard let raw = observedRawIdentity(descriptor, gateway: self),
              raw.isUsable, raw.matches(info), raw.matches(pathBefore),
              raw.inode == fileID, raw.sizeBytes == size, raw.volumeUUID == volume.lowercased()
        else { throw .sourceIdentityMismatch }
        var pathAfter = stat()
        guard lstat(url.path, &pathAfter) == 0, raw.matches(pathAfter) else {
            throw .sourceIdentityMismatch
        }
        guard case let .success(after) = io.metadata(at: url),
              after.isRegularFile.value == true,
              after.isSymbolicLink.value == false,
              after.isDataless.value == false,
              after.volumeIsLocal.value == true,
              fingerprint == after.fingerprint
        else { throw .sourceIdentityMismatch }
        var descriptorAfter = stat()
        var pathFinal = stat()
        guard fstat(descriptor, &descriptorAfter) == 0,
              lstat(url.path, &pathFinal) == 0,
              let rawAfter = observedRawIdentity(descriptor, gateway: self),
              rawAfter == raw, raw.matches(descriptorAfter), raw.matches(pathFinal)
        else { throw .sourceIdentityMismatch }
        return raw
    }
}

// MARK: - Read-only descriptor and AudioFile callbacks

private final class ReadOnlyDescriptor {
    let descriptor: Int32
    let sizeBytes: Int64
    /// The `errno` of the most recent failed read, reported instead of the decoder's generic status.
    var lastErrno: Int32 = 0
    #if DEBUG
    let readPolicyObserver: (@Sendable (Int32) -> Void)?
    #endif

    init(descriptor: Int32, sizeBytes: Int64, gateway: SystemSourceContentIO) {
        self.descriptor = descriptor
        self.sizeBytes = sizeBytes
        #if DEBUG
        readPolicyObserver = gateway.readPolicyObserver
        #endif
    }

    /// Reads up to `count` bytes at `offset`; returns fewer only at end of file.
    func bytes(at offset: Int64, count: Int) -> [UInt8]? {
        guard offset >= 0, count > 0 else { return nil }
        var result = [UInt8](repeating: 0, count: count)
        let got = result.withUnsafeMutableBytes { readFully(into: $0.baseAddress!, count: count, at: offset) }
        guard let got, got == count else { return nil }
        return result
    }

    /// The only place source bytes are read. Every read runs with dataless materialization off, whoever
    /// calls it (AudioFile, ExtAudioFile or the container-length check).
    func readFully(into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) -> Int? {
        withoutMaterializingDataless {
            #if DEBUG
            readPolicyObserver?(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
            #endif
            var total = 0
            while total < count {
                let got = pread(descriptor, buffer + total, count - total, off_t(offset) + off_t(total))
                if got > 0 {
                    total += got
                } else if got == 0 {
                    break
                } else if errno != EINTR {
                    lastErrno = errno
                    return nil
                }
            }
            return total
        }
    }
}

private func readCallback(
    _ client: UnsafeMutableRawPointer,
    _ position: Int64,
    _ requestCount: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ actualCount: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let file = Unmanaged<ReadOnlyDescriptor>.fromOpaque(client).takeUnretainedValue()
    guard position >= 0 else {
        actualCount.pointee = 0
        return kAudioFilePositionError
    }
    guard let got = file.readFully(into: buffer, count: Int(requestCount), at: position) else {
        actualCount.pointee = 0
        return kAudioFileUnspecifiedError
    }
    actualCount.pointee = UInt32(got)
    return noErr
}

private func sizeCallback(_ client: UnsafeMutableRawPointer) -> Int64 {
    Unmanaged<ReadOnlyDescriptor>.fromOpaque(client).takeUnretainedValue().sizeBytes
}

/// Runs `body` with this thread's dataless-file materialization off, then restores the previous policy.
func withoutMaterializingDataless<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    let changed = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    defer {
        if changed, previous >= 0 {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
        }
    }
    return try body()
}

private func failure(forErrno code: Int32) -> DecodeFailure {
    switch code {
    case ENOENT, ENOTDIR: .notFound
    case EACCES, EPERM: .permissionDenied
    case ELOOP: .notARegularFile
    case EDEADLK: .notMaterialized
    default: .readFailed(errno: code)
    }
}

private func openedState(_ info: stat) -> OpenedFileState {
    OpenedFileState(
        fileNumber: UInt64(info.st_ino),
        sizeBytes: Int64(info.st_size),
        modificationSeconds: Int64(info.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
    )
}

// MARK: - Reader

private final class SystemDecodingReader: DecodingContentReader {
    let facts: EncodedStreamFacts
    private let file: ReadOnlyDescriptor
    private let retainedFile: Unmanaged<ReadOnlyDescriptor>
    private let audioFile: AudioFileID
    private let extFile: ExtAudioFileRef
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let expectedRaw: RawSourceIdentity?
    #if DEBUG
    private let rawIdentityChallenge: (@Sendable (RawSourceIdentity) -> RawSourceIdentity)?
    private let rawFrameReadObserver: (@Sendable () -> Void)?
    #endif
    private var streamFramesRead: Int64 = 0
    private var mp3ValidatedPackets: Int64 = 0
    private var mp3BytePosition: Int64 = 0
    private var mp3MusicCRC: UInt16 = 0
    private var isClosed = false

    private init(
        facts: EncodedStreamFacts,
        file: ReadOnlyDescriptor,
        retainedFile: Unmanaged<ReadOnlyDescriptor>,
        audioFile: AudioFileID,
        extFile: ExtAudioFileRef,
        expectedRaw: RawSourceIdentity?,
        gateway: SystemSourceContentIO
    ) {
        self.facts = facts
        mp3BytePosition = facts.mp3Accounting?.firstAudioByte ?? 0
        self.file = file
        self.retainedFile = retainedFile
        self.audioFile = audioFile
        self.extFile = extFile
        self.expectedRaw = expectedRaw
        #if DEBUG
        rawIdentityChallenge = gateway.rawIdentityChallenge
        rawFrameReadObserver = gateway.rawFrameReadObserver
        #endif
        bufferList = AudioBufferList.allocate(maximumBuffers: Int(facts.channelsPerFrame))
    }

    deinit { close() }

    static func make(_ url: URL, gateway: SystemSourceContentIO, expected: RawSourceIdentity? = nil) throws(DecodeFailure) -> SystemDecodingReader {
        let descriptor = try gateway.openReadOnlySourceDescriptor(url, gateway: gateway)

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw .readFailed(errno: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw .notARegularFile
        }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            Darwin.close(descriptor)
            throw .notMaterialized
        }
        guard info.st_size > 0 else {
            Darwin.close(descriptor)
            throw .emptyFile
        }
        if let expected {
            let observed = gateway.observedRawIdentity(descriptor, gateway: gateway)
            guard expected.isUsable, let observed else {
                Darwin.close(descriptor)
                throw .sourceIdentityMismatch
            }
            #if DEBUG
            let challenged = gateway.rawIdentityChallenge?(observed) ?? observed
            #else
            let challenged = observed
            #endif
            guard challenged == expected, observed == expected,
                  observed.matches(info) else {
                Darwin.close(descriptor)
                throw .sourceIdentityMismatch
            }
        }

        let file = ReadOnlyDescriptor(descriptor: descriptor, sizeBytes: Int64(info.st_size), gateway: gateway)
        let retained = Unmanaged.passRetained(file)
        var openedAudioFile: AudioFileID?
        let openStatus = withoutMaterializingDataless {
            AudioFileOpenWithCallbacks(retained.toOpaque(), readCallback, nil, sizeCallback, nil, 0, &openedAudioFile)
        }
        guard openStatus == noErr, let audioFile = openedAudioFile else {
            retained.release()
            Darwin.close(descriptor)
            if file.lastErrno != 0 { throw failure(forErrno: file.lastErrno) }
            if openStatus == kAudioFileUnsupportedDataFormatError {
                throw .unsupported(.sampleFormat("platform cannot read this data format (fmt?)"))
            }
            throw .unreadableContainer(status: openStatus)
        }

        func discard(_ ext: ExtAudioFileRef?) {
            if let ext { ExtAudioFileDispose(ext) }
            AudioFileClose(audioFile)
            retained.release()
            Darwin.close(descriptor)
        }

        var containerType: UInt32 = 0
        var format = AudioStreamBasicDescription()
        guard property(audioFile, kAudioFilePropertyFileFormat, &containerType) == noErr,
              property(audioFile, kAudioFilePropertyDataFormat, &format) == noErr
        else {
            discard(nil)
            throw .unreadableContainer(status: kAudioFileInvalidFileError)
        }
        guard format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            discard(nil)
            throw .unreadableContainer(status: kAudioFileInvalidFileError)
        }
        var packetCount: UInt64 = 0
        let hasPacketCount = property(audioFile, kAudioFilePropertyAudioDataPacketCount, &packetCount) == noErr
        var maximumPacketSize: UInt32 = 0
        let hasMaximumPacketSize = property(audioFile, kAudioFilePropertyMaximumPacketSize, &maximumPacketSize) == noErr
        var byteCount: UInt64 = 0
        let hasByteCount = property(audioFile, kAudioFilePropertyAudioDataByteCount, &byteCount) == noErr
        var dataOffset: Int64 = 0
        let hasDataOffset = property(audioFile, kAudioFilePropertyDataOffset, &dataOffset) == noErr
        var bitRate: UInt32 = 0
        let hasBitRate = property(audioFile, kAudioFilePropertyBitRate, &bitRate) == noErr
        var table = AudioFilePacketTableInfo()
        let hasTable = property(audioFile, kAudioFilePropertyPacketTableInfo, &table) == noErr
        let layout = channelLayout(audioFile)
        let length = containerLength(
            containerType: containerType,
            dataOffset: hasDataOffset ? dataOffset : nil,
            file: file
        )
        let mp3: MP3AccountingEvidence?
        do {
            mp3 = containerType == kAudioFileMP3Type ? try qualifyMP3(file) : nil
        } catch {
            discard(nil)
            throw error
        }
        if let mp3 {
            guard hasTable, hasPacketCount, hasByteCount, hasDataOffset,
                  table.mNumberValidFrames == mp3.table.validFrames,
                  Int64(table.mPrimingFrames) == mp3.table.primingFrames,
                  Int64(table.mRemainderFrames) == mp3.table.remainderFrames,
                  packetCount == mp3.packetCount,
                  dataOffset == mp3.firstAudioByte,
                  byteCount == mp3.audioEndByte - mp3.firstAudioByte else {
                discard(nil)
                throw .unsupported(.mp3Accounting("native packet/byte accounting disagrees with LAME"))
            }
        }
        if file.lastErrno != 0 {
            discard(nil)
            throw failure(forErrno: file.lastErrno)
        }

        var wrapped: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(audioFile, false, &wrapped)
        guard wrapStatus == noErr, let extFile = wrapped else {
            discard(nil)
            throw .unreadableContainer(status: wrapStatus)
        }
        var readerLength: Int64 = 0
        let lengthStatus = extProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &readerLength)
        guard lengthStatus == noErr else {
            discard(extFile)
            throw .unreadableContainer(status: lengthStatus)
        }

        // Return the raw codec stream: the decoder removes priming and remainder itself, so the origin
        // of every published frame is explicit rather than implied by the platform reader.
        if hasTable, table.mPrimingFrames != 0 || table.mRemainderFrames != 0,
           hasPacketCount, format.mFramesPerPacket > 0 {
            var raw = AudioFilePacketTableInfo(
                mNumberValidFrames: Int64(packetCount) * Int64(format.mFramesPerPacket),
                mPrimingFrames: 0,
                mRemainderFrames: 0
            )
            let status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_PacketTable, UInt32(MemoryLayout.size(ofValue: raw)), &raw)
            guard status == noErr else {
                discard(extFile)
                throw .decodeFailed(status: status, atStreamFrame: 0)
            }
        }

        var client = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let clientStatus = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard clientStatus == noErr else {
            discard(extFile)
            if clientStatus == kAudioFileUnsupportedDataFormatError || clientStatus == kAudioConverterErr_FormatNotSupported {
                throw .unsupported(.codec(container: FourCharacterCode.string(containerType), codec: FourCharacterCode.string(format.mFormatID)))
            }
            throw .unreadableContainer(status: clientStatus)
        }

        let facts = EncodedStreamFacts(
            containerTypeCode: containerType,
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            sampleRate: format.mSampleRate,
            bytesPerPacket: format.mBytesPerPacket,
            framesPerPacket: format.mFramesPerPacket,
            bytesPerFrame: format.mBytesPerFrame,
            channelsPerFrame: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel,
            packetCount: hasPacketCount ? Int64(clamping: packetCount) : nil,
            maximumPacketSize: hasMaximumPacketSize ? Int64(maximumPacketSize) : nil,
            audioDataByteCount: hasByteCount ? Int64(clamping: byteCount) : nil,
            dataOffset: hasDataOffset ? dataOffset : nil,
            averageBitRate: hasBitRate && bitRate > 0 ? Int64(bitRate) : nil,
            packetTable: hasTable ? PacketTableFacts(
                validFrames: table.mNumberValidFrames,
                primingFrames: Int64(table.mPrimingFrames),
                remainderFrames: Int64(table.mRemainderFrames)
            ) : nil,
            readerLengthFrames: readerLength,
            channelLayout: mp3.map {
                // MPEG's channel-mode bits establish mono or left/right, even without an AudioFile layout.
                ChannelLayoutFacts(isDeclaredBySource: true, channelLabels: $0.channelCount == 1 ? [42] : [1, 2])
            } ?? layout,
            containerLength: mp3.map { .consistent(declaredBytes: $0.audioEndByte - $0.firstAudioByte) } ?? length,
            openedFile: openedState(info),
            mp3Accounting: mp3,
            legacyWavePCMChannelOrder: legacyWavePCMChannelOrder(
                file: file, containerType: containerType, format: format, layout: layout,
                nativeDataOffset: hasDataOffset ? dataOffset : nil,
                nativeDataBytes: hasByteCount ? Int64(exactly: byteCount) : nil, nativeFrames: readerLength),
            m4aCodecChannelOrder: m4aCodecChannelOrder(
                audioFile, containerType: containerType, format: format, layout: layout)
        )
        if file.lastErrno != 0 {
            discard(extFile)
            throw failure(forErrno: file.lastErrno)
        }
        return SystemDecodingReader(
            facts: facts, file: file, retainedFile: retained, audioFile: audioFile, extFile: extFile,
            expectedRaw: expected, gateway: gateway
        )
    }

    func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
        precondition(!isClosed, "read after close")
        #if DEBUG
        rawFrameReadObserver?()
        #endif
        precondition(buffer.channelCount == Int(facts.channelsPerFrame), "buffer channel count must match the source")
        let capacity = buffer.capacityFrames
        for index in 0..<buffer.channelCount {
            bufferList[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(capacity * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer.channel(index).baseAddress)
            )
        }
        var frames = UInt32(capacity)
        let status = withoutMaterializingDataless {
            ExtAudioFileRead(extFile, &frames, bufferList.unsafeMutablePointer)
        }
        if file.lastErrno != 0 { throw failure(forErrno: file.lastErrno) }
        guard status == noErr else { throw .decodeFailed(status: status, atStreamFrame: streamFramesRead) }
        guard Int(frames) <= capacity else { throw .inconsistentStream(.readerOverran(requested: capacity, returned: Int(frames))) }
        streamFramesRead += Int64(frames)
        if let mp3 = facts.mp3Accounting {
            let expectedFrames = mp3.packetCount * 1152
            guard streamFramesRead <= expectedFrames, frames != 0 || streamFramesRead == expectedFrames else {
                throw .inconsistentStream(.mp3Integrity("native decoded codec-stream frame count"))
            }
            let target = frames == 0 ? mp3.packetCount : min(mp3.packetCount, (streamFramesRead + 1151) / 1152)
            while mp3ValidatedPackets < target {
                guard let first = file.bytes(at: mp3BytePosition, count: 4) else {
                    throw .inconsistentStream(.mp3Integrity("short audio frame header"))
                }
                let header = try MP3FrameHeader(first[...])
                guard header.sampleRate == mp3.sampleRate, header.channelCount == mp3.channelCount,
                      mp3BytePosition + Int64(header.byteCount) <= mp3.audioEndByte,
                      let bytes = file.bytes(at: mp3BytePosition, count: header.byteCount) else {
                    throw .inconsistentStream(.mp3Integrity("short or changing audio frame"))
                }
                mp3MusicCRC = MP3Qualification.crc(bytes, starting: mp3MusicCRC)
                mp3BytePosition += Int64(header.byteCount)
                mp3ValidatedPackets += 1
            }
            if mp3ValidatedPackets == mp3.packetCount {
                guard mp3BytePosition == mp3.audioEndByte, mp3MusicCRC == mp3.musicCRC else {
                    throw .inconsistentStream(.mp3Integrity("audio frame count/bytes or LAME music CRC"))
                }
            }
        }
        return Int(frames)
    }

    var supportsRandomAccess: Bool {
        facts.formatID == kAudioFormatLinearPCM
            && (facts.packetTable?.primingFrames ?? 0) == 0
            && (facts.packetTable?.remainderFrames ?? 0) == 0
    }

    func seekRawFrame(to frame: Int64) throws(DecodeFailure) {
        guard !isClosed else { throw .canceled }
        guard supportsRandomAccess else { throw .seekUnavailable }
        guard frame >= 0, frame <= facts.readerLengthFrames else { throw .invalidSourceFrame(frame) }
        let status = withoutMaterializingDataless { ExtAudioFileSeek(extFile, frame) }
        if file.lastErrno != 0 { throw failure(forErrno: file.lastErrno) }
        guard status == noErr else { throw .seekFailed(status: status, atStreamFrame: frame) }
        var actual: Int64 = -1
        let tellStatus = withoutMaterializingDataless { ExtAudioFileTell(extFile, &actual) }
        if file.lastErrno != 0 { throw failure(forErrno: file.lastErrno) }
        guard tellStatus == noErr else { throw .seekFailed(status: tellStatus, atStreamFrame: frame) }
        guard actual == frame else { throw .seekFailed(status: kAudioFilePositionError, atStreamFrame: frame) }
        streamFramesRead = frame
    }

    func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState {
        precondition(!isClosed, "state after close")
        var info = stat()
        guard fstat(file.descriptor, &info) == 0 else { throw .readFailed(errno: errno) }
        if let expectedRaw {
            guard let observed = RawSourceIdentity.onDescriptor(file.descriptor),
                  observed == expectedRaw, observed.matches(info) else {
                throw .sourceChangedDuringDecode
            }
            #if DEBUG
            if let rawIdentityChallenge, rawIdentityChallenge(observed) != expectedRaw {
                throw .sourceChangedDuringDecode
            }
            #endif
        }
        return openedState(info)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        ExtAudioFileDispose(extFile)
        AudioFileClose(audioFile)
        retainedFile.release()
        Darwin.close(file.descriptor)
        free(bufferList.unsafeMutablePointer)
    }
}

// MARK: - Property helpers

/// Header-only qualification. Complete audio-frame and music-CRC validation advances with decoding,
/// so opening a prepared-cache read scope never scans or decodes an entire prefix.
private func qualifyMP3(_ file: ReadOnlyDescriptor) throws(DecodeFailure) -> MP3AccountingEvidence {
    var offset: Int64 = 0
    if let id3 = file.bytes(at: 0, count: 10), Array(id3.prefix(3)) == Array("ID3".utf8) {
        guard [3, 4].contains(id3[3]), id3[6..<10].allSatisfy({ $0 < 128 }) else {
            throw .unsupported(.mp3Accounting("unsupported ID3 header"))
        }
        let size = id3[6..<10].reduce(Int64(0)) { $0 << 7 | Int64($1) }
        offset = 10 + size + (id3[3] == 4 && id3[5] & 0x10 != 0 ? 10 : 0)
    }
    guard let first = file.bytes(at: offset, count: 4) else { throw .unsupported(.encoderDelayUnknown) }
    let header = try MP3FrameHeader(first[...])
    guard let frame = file.bytes(at: offset, count: header.byteCount) else {
        throw .truncated(declaredBytes: Int64(header.byteCount), availableBytes: max(0, file.sizeBytes - offset))
    }
    let evidence = try MP3Qualification.firstFrame(frame, at: offset)
    guard evidence.audioEndByte <= file.sizeBytes else {
        throw .truncated(declaredBytes: evidence.audioEndByte, availableBytes: file.sizeBytes)
    }
    let trailing = file.sizeBytes - evidence.audioEndByte
    guard trailing == 0 || (trailing == 128 && file.bytes(at: evidence.audioEndByte, count: 3) == Array("TAG".utf8)) else {
        throw .unsupported(.mp3Accounting("unaccounted trailing bytes"))
    }
    return evidence
}

private func property<T: BitwiseCopyable>(_ file: AudioFileID, _ id: AudioFilePropertyID, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutableBytes(of: &value) { AudioFileGetProperty(file, id, &size, $0.baseAddress!) }
}

private func extProperty<T: BitwiseCopyable>(_ file: ExtAudioFileRef, _ id: ExtAudioFilePropertyID, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutableBytes(of: &value) { ExtAudioFileGetProperty(file, id, &size, $0.baseAddress!) }
}

private func legacyWavePCMChannelOrder(
    file: ReadOnlyDescriptor, containerType: UInt32, format: AudioStreamBasicDescription,
    layout: ChannelLayoutFacts, nativeDataOffset: Int64?, nativeDataBytes: Int64?, nativeFrames: Int64
) -> LegacyWavePCMChannelOrderEvidence? {
    guard containerType == kAudioFileWAVEType, format.mFormatID == kAudioFormatLinearPCM,
          layout == .undeclared, (1...2).contains(format.mChannelsPerFrame),
          format.mFramesPerPacket == 1, format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
          let header = file.bytes(at: 0, count: 12), Array(header[0..<4]) == Array("RIFF".utf8),
          Array(header[8..<12]) == Array("WAVE".utf8) else { return nil }
    func little(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
    }
    let end = Int64(little(header[4..<8])) + 8
    guard end == file.sizeBytes, end >= 44 else { return nil }
    var cursor: Int64 = 12, chunks = 0
    var fmt: (offset: Int64, bytes: [UInt8])?
    var data: (offset: Int64, bytes: Int64)?
    var factFrames: UInt32?
    let ancillary = Set(["JUNK", "PAD ", "bext", "cue ", "smpl", "ID3 "])
    while cursor < end {
        guard chunks < 4096, end - cursor >= 8,
              let chunk = file.bytes(at: cursor, count: 8) else { return nil }
        chunks += 1
        let tag = String(bytes: chunk[0..<4], encoding: .ascii) ?? ""
        let count = Int64(little(chunk[4..<8])), body = cursor + 8
        guard count <= end - body else { return nil }
        switch tag {
        case "fmt ":
            guard fmt == nil, count == 16 || count == 18,
                  let bytes = file.bytes(at: body, count: Int(count)) else { return nil }
            fmt = (body, bytes)
        case "data":
            guard data == nil, body == nativeDataOffset, count == nativeDataBytes else { return nil }
            data = (body, count)
        case "fact":
            guard factFrames == nil, count == 4, let bytes = file.bytes(at: body, count: 4) else { return nil }
            factFrames = little(bytes[0..<4])
        case "LIST":
            guard count >= 4, let type = file.bytes(at: body, count: 4),
                  type == Array("INFO".utf8) || type == Array("adtl".utf8) else { return nil }
        default:
            guard ancillary.contains(tag) else { return nil }
        }
        let padding = count % 2
        guard padding <= end - body - count else { return nil }
        cursor = body + count + padding
    }
    guard cursor == end, let fmt, let data else { return nil }
    let bytes = fmt.bytes
    let tag = little(bytes[0..<2]), channels = little(bytes[2..<4]), rate = little(bytes[4..<8])
    let byteRate = little(bytes[8..<12]), alignment = little(bytes[12..<14]), bits = little(bytes[14..<16])
    let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    guard (tag == 1 && [16, 24, 32].contains(bits) && !floating
            && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
            || (tag == 3 && bits == 32 && floating) else { return nil }
    guard bytes.count == 16 || little(bytes[16..<18]) == 0,
          channels == format.mChannelsPerFrame, rate > 0, Double(rate) == format.mSampleRate,
          bits == format.mBitsPerChannel, alignment == channels * (bits / 8),
          alignment == format.mBytesPerFrame, alignment == format.mBytesPerPacket,
          UInt64(byteRate) == UInt64(rate) * UInt64(alignment), alignment > 0,
          data.bytes > 0, data.bytes % Int64(alignment) == 0,
          data.bytes / Int64(alignment) == nativeFrames,
          factFrames.map({ Int64($0) == nativeFrames }) != false else { return nil }
    return .init(channelCount: Int(channels), formatBytes: bytes, riffBytes: end,
                 formatOffset: fmt.offset, dataOffset: data.offset, dataBytes: data.bytes, factFrames: factFrames)
}

private func m4aCodecChannelOrder(
    _ file: AudioFileID, containerType: UInt32, format: AudioStreamBasicDescription,
    layout: ChannelLayoutFacts
) -> M4ACodecChannelOrderEvidence? {
    guard containerType == kAudioFileM4AType, layout == .undeclared,
          [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless].contains(format.mFormatID),
          (1...2).contains(format.mChannelsPerFrame) else { return nil }
    var size: UInt32 = 0
    guard AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &size, nil) == noErr,
          size > 0, size <= 65_536 else { return nil }
    var cookie = Data(count: Int(size))
    let status = cookie.withUnsafeMutableBytes {
        AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &size, $0.baseAddress!)
    }
    guard status == noErr, size > 0, Int(size) <= cookie.count else { return nil }
    cookie = Data(cookie.prefix(Int(size)))
    return cookie.withUnsafeBytes { bytes in
        // Supply no guessed rate or channel count: FormatList must derive them from the cookie.
        var codec = AudioStreamBasicDescription()
        codec.mFormatID = format.mFormatID
        var info = AudioFormatInfo(mASBD: codec, mMagicCookie: bytes.baseAddress!, mMagicCookieSize: size)
        let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
        var resultSize: UInt32 = 0
        let itemSize = UInt32(MemoryLayout<AudioFormatListItem>.stride)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &resultSize) == noErr,
              resultSize > 0, resultSize <= itemSize * 16, resultSize % itemSize == 0 else { return nil }
        let capacity = resultSize
        var items = Array(repeating: AudioFormatListItem(), count: Int(resultSize / itemSize))
        let itemStatus = items.withUnsafeMutableBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &resultSize, $0.baseAddress!)
        }
        guard itemStatus == noErr, resultSize > 0, resultSize <= capacity, resultSize % itemSize == 0 else { return nil }
        let matching = items.prefix(Int(resultSize / itemSize)).filter {
            $0.mASBD.mFormatID == format.mFormatID && $0.mASBD.mSampleRate == format.mSampleRate
                && $0.mASBD.mChannelsPerFrame == format.mChannelsPerFrame
                && $0.mASBD.mFramesPerPacket == format.mFramesPerPacket
        }
        let tag = format.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        guard !matching.isEmpty, matching.allSatisfy({ $0.mChannelLayoutTag == tag }) else { return nil }
        return M4ACodecChannelOrderEvidence(channelCount: Int(format.mChannelsPerFrame),
            formatID: format.mFormatID, layoutTag: tag, cookie: cookie)
    }
}

/// The declared layout and its channel labels (expanded from a tag or bitmap by AudioFormat).
private func channelLayout(_ file: AudioFileID) -> ChannelLayoutFacts {
    // A tag-only layout is just the 12-byte header (no descriptions), smaller than `AudioChannelLayout`.
    guard let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return .undeclared }
    var size: UInt32 = 0
    guard AudioFileGetPropertyInfo(file, kAudioFilePropertyChannelLayout, &size, nil) == noErr,
          Int(size) >= descriptionsOffset
    else { return .undeclared }
    let byteCount = max(Int(size), MemoryLayout<AudioChannelLayout>.size)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    guard AudioFileGetProperty(file, kAudioFilePropertyChannelLayout, &size, raw) == noErr, Int(size) >= descriptionsOffset else { return .undeclared }
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    let tag = layout.pointee.mChannelLayoutTag
    let bitmap = layout.pointee.mChannelBitmap.rawValue
    let describable = (Int(size) - descriptionsOffset) / MemoryLayout<AudioChannelDescription>.stride
    var labels = Array(descriptionLabels(layout).prefix(describable))
    if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
        labels = expandedLabels(tag: tag, bitmap: bitmap) ?? labels
    }
    return ChannelLayoutFacts(
        isDeclaredBySource: true,
        layoutTag: tag,
        channelBitmap: tag == kAudioChannelLayoutTag_UseChannelBitmap ? bitmap : nil,
        channelLabels: labels
    )
}

private func descriptionLabels(_ layout: UnsafePointer<AudioChannelLayout>) -> [UInt32] {
    let count = Int(layout.pointee.mNumberChannelDescriptions)
    guard count > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
    let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
    return (0..<count).map { first[$0].mChannelLabel }
}

private func expandedLabels(tag: AudioChannelLayoutTag, bitmap: UInt32) -> [UInt32]? {
    let propertyID: AudioFormatPropertyID
    var specifier: UInt32
    if tag == kAudioChannelLayoutTag_UseChannelBitmap {
        propertyID = kAudioFormatProperty_ChannelLayoutForBitmap
        specifier = bitmap
    } else {
        propertyID = kAudioFormatProperty_ChannelLayoutForTag
        specifier = tag
    }
    var size: UInt32 = 0
    guard AudioFormatGetPropertyInfo(propertyID, UInt32(MemoryLayout<UInt32>.size), &specifier, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
    else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    guard AudioFormatGetProperty(propertyID, UInt32(MemoryLayout<UInt32>.size), &specifier, &size, raw) == noErr else { return nil }
    return descriptionLabels(raw.assumingMemoryBound(to: AudioChannelLayout.self))
}

/// Checks the declared audio-chunk size against the file for containers whose platform reader clamps a
/// truncated length silently (WAVE) or whose chunk header is fixed (CAF, AIFF/AIFC).
private func containerLength(containerType: UInt32, dataOffset: Int64?, file: ReadOnlyDescriptor) -> ContainerLengthEvidence {
    let chunked = [kAudioFileWAVEType, kAudioFileCAFType, kAudioFileAIFFType, kAudioFileAIFCType].contains(containerType)
    // The header always precedes the audio, so a data offset of 0 (or none) means no data chunk.
    guard let dataOffset, dataOffset > 0 else { return chunked ? .audioDataChunkMissing : .notChecked }
    let available = file.sizeBytes - dataOffset
    func verdict(_ declared: Int64) -> ContainerLengthEvidence {
        declared > available ? .exceedsFile(declaredBytes: declared, availableBytes: available) : .consistent(declaredBytes: declared)
    }
    switch containerType {
    case kAudioFileWAVEType:
        guard let header = file.bytes(at: dataOffset - 8, count: 8), Array(header[0..<4]) == Array("data".utf8) else {
            return .unverifiable("WAVE data chunk header not found")
        }
        let size = header[4..<8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard size != 0, size != UInt32.max else { return .unverifiable("WAVE data size \(size)") }
        return verdict(Int64(size))
    case kAudioFileCAFType:
        guard let header = file.bytes(at: dataOffset - 16, count: 16), Array(header[0..<4]) == Array("data".utf8) else {
            return .unverifiable("CAF data chunk header not found")
        }
        let size = header[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard size != UInt64.max, size >= 4, size <= UInt64(Int64.max) else { return .unverifiable("CAF data size \(Int64(bitPattern: size))") }
        return verdict(Int64(size) - 4)
    case kAudioFileAIFFType, kAudioFileAIFCType:
        // SSND: ckID, ckSize (BE), offset, blockSize, then `offset` bytes before audio. Checked only for
        // the usual offset 0; otherwise the frame-count check after decoding still catches truncation.
        guard let header = file.bytes(at: dataOffset - 16, count: 16), Array(header[0..<4]) == Array("SSND".utf8) else {
            return .notChecked
        }
        let size = header[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let offset = header[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard offset == 0, size >= 8 else { return .notChecked }
        return verdict(Int64(size) - 8)
    default:
        return .notChecked
    }
}
