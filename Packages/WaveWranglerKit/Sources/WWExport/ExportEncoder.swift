import AVFoundation
import Darwin
import Foundation
import WWLameNative

/// Serial, non-realtime encoder. The caller owns authorization, conversion, mixing and publication.
/// A unique child of `stagingDirectory` is owned here; no delivery file is created or overwritten.
public actor ExportEncoder {
    public static let maximumBlockFrames = 16_384
    public let settings: ExportSettings
    private let metadata: ExportMetadata
    private let directory: URL
    private let directoryIdentity: stat
    private let output: URL
    private let writer: CodecWriter
    private var frames: Int64 = 0
    private enum State { case encoding, finishing, finished, canceled, failed }
    private var state = State.encoding
    private var remux: AVAssetExportSession?
    private var disposed = false

    public init(stagingDirectory: URL, settings: ExportSettings, metadata: ExportMetadata = .init()) throws {
        try metadata.validate(for: settings.codec)
        guard stagingDirectory.isFileURL,
              try stagingDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try stagingDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ExportFailure.destination("An existing local staging directory is required")
        }
        let directory = stagingDirectory.appendingPathComponent("ww-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var identity = stat()
        guard lstat(directory.path, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFailure.destination("Cannot inspect the newly created encoder staging directory")
        }
        let output = directory.appendingPathComponent("encoded.\(settings.codec.fileExtension)")
        do {
            writer = try CodecWriter(url: output, settings: settings, metadata: metadata)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        self.settings = settings
        self.metadata = metadata
        self.directory = directory
        directoryIdentity = identity
        self.output = output
    }

    /// Interleaved Float32. Float WAV preserves finite over-range values; other codecs require [-1, 1].
    /// An append error invalidates the encoder; cancel to discard its private staging directory.
    public func append(interleaved samples: [Float]) throws {
        guard state == .encoding else { throw ExportFailure.invalidState }
        do {
            try Task.checkCancellation()
            let allowsOverRange = settings.codec == .wave(.float32)
            guard !samples.isEmpty, samples.count % settings.channels == 0,
                  samples.count / settings.channels <= Self.maximumBlockFrames,
                  samples.allSatisfy({ $0.isFinite && (allowsOverRange || abs($0) <= 1) }) else {
                throw ExportFailure.invalidPCM("Expected 1...16384 complete finite PCM frames; integer/lossy codecs require [-1, 1]")
            }
            let count = samples.count / settings.channels
            let (total, overflow) = frames.addingReportingOverflow(Int64(count))
            guard !overflow else { throw ExportFailure.invalidPCM("Frame count overflow") }
            if case .wave(let encoding) = settings.codec {
                let maximum = (Int64(UInt32.max) - 1_048_576) / Int64(settings.channels * (encoding.rawValue / 8))
                guard total <= maximum else {
                    throw ExportFailure.encoder("WAV exceeds RIFF's 4 GiB limit; RF64 is not supported")
                }
            }
            try writer.append(samples)
            frames = total
        } catch {
            state = .failed
            writer.abort()
            throw error
        }
    }

    /// Closes headers/tags and decodes every frame in bounded blocks before returning.
    /// The result remains private staging: the job coordinator must publish it transactionally.
    public func finish() async throws -> VerifiedExport {
        guard state == .encoding else { throw ExportFailure.invalidState }
        state = .finishing
        do {
            try Task.checkCancellation()
            guard frames > 0 else { throw ExportFailure.invalidPCM("Cannot finish an empty export") }
            try writer.finish()
            var verifiedURL = output
            if case .aacLC = settings.codec, !metadata.m4aItems.isEmpty {
                let tagged = directory.appendingPathComponent("tagged.m4a")
                guard let session = AVAssetExportSession(asset: AVURLAsset(url: output),
                                                        presetName: AVAssetExportPresetPassthrough) else {
                    throw ExportFailure.encoder("System M4A metadata remux is unavailable")
                }
                remux = session
                session.metadata = metadata.m4aItems
                try await session.export(to: tagged, as: .m4a)
                remux = nil
                try Task.checkCancellation()
                guard state == .finishing else { throw CancellationError() }
                try FileManager.default.removeItem(at: output)
                verifiedURL = tagged
            }
            let file = try FileHandle(forWritingTo: verifiedURL)
            try file.synchronize()
            try file.close()
            let result = try ExportVerifier.verify(url: verifiedURL, settings: settings, expectedFrames: frames)
            try Task.checkCancellation()
            guard state == .finishing else { throw CancellationError() }
            state = .finished
            return result
        } catch {
            if state != .canceled { state = .failed }
            writer.abort()
            remux?.cancelExport()
            remux = nil
            // Explicit cancel also retries cleanup if a filesystem error prevented it.
            throw error
        }
    }

    /// Idempotent disposal, including a finished staging result. Cleanup failures are reported.
    /// The coordinator must dispose this directory after copying/publishing the verified file.
    public func cancel() throws {
        remux?.cancelExport()
        writer.abort()
        state = .canceled
        if !disposed {
            var current = stat()
            if lstat(directory.path, &current) != 0 {
                guard errno == ENOENT else { throw ExportFailure.destination("Cannot inspect encoder staging for cleanup") }
                disposed = true
                return
            }
            guard current.st_dev == directoryIdentity.st_dev, current.st_ino == directoryIdentity.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR else {
                throw ExportFailure.destination("Encoder staging changed; it was not followed or removed")
            }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // An already removed owned directory is the idempotent disposal case.
            }
            disposed = true
        }
    }
}

/// Owned solely by ExportEncoder. Native pointers never cross the actor boundary.
private final class CodecWriter {
    private let settings: ExportSettings
    private let metadata: ExportMetadata
    private var audio: AVAudioFile?
    private var lame: OpaquePointer?
    private var handle: FileHandle?
    private var tagOffset: UInt64 = 0

    init(url: URL, settings: ExportSettings, metadata: ExportMetadata) throws {
        self.settings = settings
        self.metadata = metadata
        do {
            switch settings.codec {
            case .mp3(let mode):
                guard let encoder = lame_init() else { throw ExportFailure.encoder("lame_init failed") }
                lame = encoder
                func check(_ code: Int32) throws {
                    guard code >= 0 else { throw ExportFailure.encoder("LAME configuration failed: \(code)") }
                }
                try check(lame_set_in_samplerate(encoder, Int32(settings.sampleRate)))
                try check(lame_set_out_samplerate(encoder, Int32(settings.sampleRate)))
                try check(lame_set_num_channels(encoder, Int32(settings.channels)))
                try check(lame_set_mode(encoder, settings.channels == 1 ? MONO : JOINT_STEREO))
                switch mode {
                case .constantBitrate(let kbps):
                    try check(lame_set_VBR(encoder, vbr_off))
                    try check(lame_set_brate(encoder, Int32(kbps)))
                case .variableBitrate(let quality):
                    try check(lame_set_VBR(encoder, vbr_default))
                    try check(lame_set_VBR_q(encoder, Int32(quality)))
                }
                lame_set_write_id3tag_automatic(encoder, 0)
                try check(lame_set_bWriteVbrTag(encoder, 1))
                try check(lame_init_params(encoder))
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw ExportFailure.destination("Cannot create MP3 staging file")
                }
                let file = try FileHandle(forWritingTo: url)
                handle = file
                let tag = metadata.mp3Tag
                try file.write(contentsOf: tag)
                tagOffset = UInt64(tag.count)
            case .wave(let encoding):
                audio = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: settings.sampleRate,
                    AVNumberOfChannelsKey: settings.channels,
                    AVLinearPCMBitDepthKey: encoding.rawValue,
                    AVLinearPCMIsFloatKey: encoding == .float32,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                handle = try FileHandle(forWritingTo: url)
            case .aacLC(let bitrate):
                audio = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: settings.sampleRate,
                    AVNumberOfChannelsKey: settings.channels,
                    AVEncoderBitRateKey: bitrate,
                    AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
        } catch {
            abort()
            throw error
        }
    }

    deinit { abort() }

    func append(_ samples: [Float]) throws {
        let frames = samples.count / settings.channels
        if let lame, let handle {
            var bytes = [UInt8](repeating: 0, count: Int(ceil(1.25 * Double(frames))) + 7_200)
            let count = samples.withUnsafeBufferPointer { pcm in
                if settings.channels == 2 {
                    return lame_encode_buffer_interleaved_ieee_float(lame, pcm.baseAddress, Int32(frames),
                                                                     &bytes, Int32(bytes.count))
                }
                return lame_encode_buffer_ieee_float(lame, pcm.baseAddress, pcm.baseAddress, Int32(frames),
                                                     &bytes, Int32(bytes.count))
            }
            guard count >= 0 else { throw ExportFailure.encoder("LAME encode failed: \(count)") }
            try handle.write(contentsOf: Data(bytes.prefix(Int(count))))
        } else if let audio {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                               frameCapacity: AVAudioFrameCount(frames)),
                  let channels = buffer.floatChannelData else {
                throw ExportFailure.encoder("Cannot allocate bounded PCM buffer")
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<settings.channels {
                for frame in 0..<frames { channels[channel][frame] = samples[frame * settings.channels + channel] }
            }
            try audio.write(from: buffer)
        } else {
            throw ExportFailure.invalidState
        }
    }

    func finish() throws {
        if let lame, let handle {
            var bytes = [UInt8](repeating: 0, count: 7_200)
            let count = lame_encode_flush(lame, &bytes, Int32(bytes.count))
            guard count >= 0 else { throw ExportFailure.encoder("LAME flush failed: \(count)") }
            try handle.write(contentsOf: Data(bytes.prefix(Int(count))))
            let tagCount = lame_get_lametag_frame(lame, &bytes, bytes.count)
            guard tagCount > 0, tagCount <= bytes.count else {
                throw ExportFailure.encoder("LAME gapless seek tag is unavailable")
            }
            try handle.seek(toOffset: tagOffset)
            try handle.write(contentsOf: Data(bytes.prefix(tagCount)))
            lame_close(lame)
            self.lame = nil
        } else {
            guard audio != nil else { throw ExportFailure.invalidState }
            // AVAudioFile finalizes the converter and container on release.
            audio = nil
            if case .wave = settings.codec {
                guard let handle else { throw ExportFailure.invalidState }
                let size = try handle.seekToEnd()
                guard size >= 8, size + UInt64(metadata.waveInfo.count) - 8 <= UInt64(UInt32.max) else {
                    throw ExportFailure.encoder("Invalid or oversized RIFF output")
                }
                try handle.write(contentsOf: metadata.waveInfo)
                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: ExportMetadata.littleEndian(UInt32(size + UInt64(metadata.waveInfo.count) - 8)))
            }
        }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    func abort() {
        audio = nil
        if let lame { lame_close(lame); self.lame = nil }
        // FileHandle releases its descriptor; explicit close errors on success use finish().
        handle = nil
    }
}
