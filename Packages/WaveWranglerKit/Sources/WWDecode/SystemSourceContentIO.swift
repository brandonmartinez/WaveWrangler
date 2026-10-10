import AudioToolbox
import Darwin
import Foundation
import WWSources

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
///   a provider download. That policy is defence in depth; it has not been exercised against a real
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
    #endif
    private var streamFramesRead: Int64 = 0
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
        self.file = file
        self.retainedFile = retainedFile
        self.audioFile = audioFile
        self.extFile = extFile
        self.expectedRaw = expectedRaw
        #if DEBUG
        rawIdentityChallenge = gateway.rawIdentityChallenge
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
            channelLayout: layout,
            containerLength: length,
            openedFile: openedState(info)
        )
        return SystemDecodingReader(
            facts: facts, file: file, retainedFile: retained, audioFile: audioFile, extFile: extFile,
            expectedRaw: expected, gateway: gateway
        )
    }

    func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
        precondition(!isClosed, "read after close")
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
        return Int(frames)
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

private func property<T: BitwiseCopyable>(_ file: AudioFileID, _ id: AudioFilePropertyID, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutableBytes(of: &value) { AudioFileGetProperty(file, id, &size, $0.baseAddress!) }
}

private func extProperty<T: BitwiseCopyable>(_ file: ExtAudioFileRef, _ id: ExtAudioFilePropertyID, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutableBytes(of: &value) { ExtAudioFileGetProperty(file, id, &size, $0.baseAddress!) }
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
