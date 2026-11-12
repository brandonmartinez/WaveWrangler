import AVFoundation
import Darwin
import Foundation

public struct VerifiedExport: Sendable, Equatable {
    public let stagingURL: URL
    public let settings: ExportSettings
    public let inputFrames: Int64
    public let decodedFrames: Int64
    public let byteCount: Int64
    let witness: ExportOutputWitness
    /// Container/decoder-visible difference; not a license to shift production timing.
    public var decodedFrameDelta: Int64 { decodedFrames - inputFrames }
}

struct ExportOutputWitness: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let bytes: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        bytes = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

// Internal: only the encoder's newly created, privately owned output may enter this reader.
enum ExportVerifier {
    /// Reopen and fully decode a staged result, bounded to 4096 frames per read.
    /// Lossy codecs can expose priming/padding: MP3 <=2304, AAC <=3072 frames; PCM must be exact.
    static func verify(url: URL, settings: ExportSettings, expectedFrames: Int64) throws -> VerifiedExport {
        try Task.checkCancellation()
        guard expectedFrames > 0 else { throw ExportFailure.verification("Expected frame count must be positive") }
        var initial = stat()
        guard lstat(url.path, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1 else {
            throw ExportFailure.verification("Output is not an exclusively owned regular file")
        }
        let witness = ExportOutputWitness(initial)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else {
            throw ExportFailure.verification("Output is not a nonempty regular file")
        }
        if case .mp3 = settings.codec {
            try MP3Integrity.verify(url: url, settings: settings, expectedFrames: expectedFrames, byteCount: Int64(size))
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.fileFormat.streamDescription.pointee
        let expectedID: AudioFormatID
        let tolerance: Int64
        switch settings.codec {
        case .wave(let encoding):
            expectedID = kAudioFormatLinearPCM
            tolerance = 0
            guard format.mBitsPerChannel == encoding.rawValue,
                  (format.mFormatFlags & kAudioFormatFlagIsFloat != 0) == (encoding == .float32) else {
                throw ExportFailure.verification("Wrong WAV PCM representation")
            }
        case .mp3: expectedID = kAudioFormatMPEGLayer3; tolerance = 2_304
        case .aacLC: expectedID = kAudioFormatMPEG4AAC; tolerance = 3_072
        }
        guard format.mFormatID == expectedID, format.mSampleRate == Double(settings.sampleRate),
              format.mChannelsPerFrame == settings.channels else {
            throw ExportFailure.verification("Encoded format does not match settings")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096),
              let channels = buffer.floatChannelData else {
            throw ExportFailure.verification("Cannot allocate decode buffer")
        }
        var decoded: Int64 = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, file.length - file.framePosition)))
            } catch {
                // Core Audio can overestimate CBR MP3 length (notably 96 kbps/44.1 kHz).
                // Only accept its empty EOF after the complete packet/tag audit above and enough PCM.
                let native = error as NSError
                if case .mp3 = settings.codec, native.domain == NSOSStatusErrorDomain, native.code == -39,
                   buffer.frameLength == 0, file.framePosition == decoded, decoded >= expectedFrames,
                   decoded - expectedFrames <= tolerance {
                    break
                }
                throw ExportFailure.verification("Decode failed at \(file.framePosition)/\(file.length), block \(buffer.frameLength): \(error)")
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            decoded += Int64(count)
            guard decoded <= expectedFrames + tolerance else {
                throw ExportFailure.verification("Decoded output is too long")
            }
            for channel in 0..<settings.channels {
                guard UnsafeBufferPointer(start: channels[channel], count: count).allSatisfy(\.isFinite) else {
                    throw ExportFailure.verification("Decoder produced nonfinite PCM")
                }
            }
        }
        guard decoded > 0, abs(decoded - expectedFrames) <= tolerance else {
            throw ExportFailure.verification("Decoded duration does not match input")
        }
        var final = stat()
        guard lstat(url.path, &final) == 0, final.st_nlink == 1, ExportOutputWitness(final) == witness else {
            throw ExportFailure.verification("Output changed during verification")
        }
        return VerifiedExport(stagingURL: url, settings: settings, inputFrames: expectedFrames,
                              decodedFrames: decoded, byteCount: Int64(size), witness: witness)
    }
}
