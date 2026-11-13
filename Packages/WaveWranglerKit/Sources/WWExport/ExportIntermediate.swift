import AVFoundation
import Darwin
import Foundation

/// Owns only a freshly created raw stereo Float32 file. There is deliberately no arbitrary-URL reader.
actor ExportIntermediate {
    private let handle: FileHandle
    private let directory: URL
    private let directoryDescriptor: Int32
    private let directoryIdentity: stat
    private let artifact: ExportOwnedArtifact
    private let frames: Range<Int64>
    private var writtenBytes: Int64 = 0
    private(set) var writtenFrames: Int64 = 0
    private var finished = false

    init(directory: URL, frames: Range<Int64>) throws {
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ExportFailure.destination("Cannot open private intermediate directory") }
        var identity = stat()
        guard fstat(parent, &identity) == 0 else {
            Darwin.close(parent)
            throw ExportFailure.destination("Cannot inspect private intermediate directory")
        }
        let descriptor = openat(parent, "production.f32", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Darwin.close(parent)
            throw ExportFailure.destination("Cannot exclusively create private production intermediate: \(String(cString: strerror(errno)))")
        }
        do {
            let artifact = try ExportOwnedArtifact(descriptor: descriptor, name: "production.f32")
            let reader = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard reader >= 0 else {
                let failure = ExportFailure.destination("Cannot retain private intermediate read descriptor: \(String(cString: strerror(errno)))")
                do { try artifact.remove(in: parent, missingAllowed: false) }
                catch { throw ExportFailure.destination("\(failure); intermediate cleanup failed: \(error)") }
                throw failure
            }
            self.artifact = artifact
            handle = FileHandle(fileDescriptor: reader, closeOnDealloc: true)
        } catch {
            Darwin.close(parent)
            throw error
        }
        self.directory = directory
        directoryDescriptor = parent
        directoryIdentity = identity
        self.frames = frames
    }

    deinit { Darwin.close(directoryDescriptor) }

    func append(firstFrame: Int64, stereo: [[Float]]) throws {
        try validate()
        guard !finished, stereo.count == 2, !stereo[0].isEmpty,
              stereo[0].count <= 240_000, stereo[0].count == stereo[1].count,
              firstFrame == frames.lowerBound + writtenFrames,
              Int64(stereo[0].count) <= frames.count64 - writtenFrames,
              stereo.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw ExportFailure.invalidPCM("Production output must be finite, bounded, contiguous stereo within Episode Start/End")
        }
        var interleaved = [Float](repeating: 0, count: stereo[0].count * 2)
        for frame in stereo[0].indices {
            interleaved[frame * 2] = stereo[0][frame]
            interleaved[frame * 2 + 1] = stereo[1][frame]
        }
        try interleaved.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ExportFailure.invalidState }
            var offset = 0
            while offset < bytes.count {
                try validate()
                let count = pwrite(artifact.descriptor, base.advanced(by: offset),
                                   bytes.count - offset, off_t(writtenBytes))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ExportFailure.destination("Write private production intermediate: \(String(cString: strerror(errno)))")
                }
                offset += count
                writtenBytes += Int64(count)
                try artifact.checkpoint(in: directoryDescriptor, expectedBytes: writtenBytes)
            }
        }
        writtenFrames += Int64(stereo[0].count)
    }

    func finish() throws {
        try validate()
        guard !finished, writtenFrames == frames.count64 else {
            throw ExportFailure.invalidPCM("Renderer did not deliver the complete Episode Start/End range")
        }
        try handle.synchronize()
        try validate()
        finished = true
    }

    func validate() throws {
        var current = stat()
        guard lstat(directory.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == directoryIdentity.st_dev, current.st_ino == directoryIdentity.st_ino else {
            throw ExportFailure.destination("Private intermediate directory changed; its contents were preserved")
        }
        try artifact.validate(in: directoryDescriptor)
    }

    func cleanup() throws {
        try validate()
        try artifact.remove(in: directoryDescriptor, missingAllowed: false)
    }

    func close() throws { try handle.close() }

    /// Measurement omits dither, quantization and overload rejection; encoding never omits them.
    func convert(delivery: ExportDelivery, gainDB: Double = 0, measuring: Bool = false,
                 sink: @Sendable ([Float]) async throws -> Void) async throws {
        guard finished else { throw ExportFailure.invalidState }
        try validate()
        try handle.seek(toOffset: 0)
        let reader = IntermediateConversionInput(handle: handle, channels: delivery.settings.channels,
            validate: { try self.validate() })
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                             channels: AVAudioChannelCount(delivery.settings.channels), interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: Double(delivery.settings.sampleRate),
                channels: AVAudioChannelCount(delivery.settings.channels), interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
            throw ExportFailure.encoder("Cannot allocate the bounded delivery rate converter")
        }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let expected = Int64((Double(writtenFrames) * Double(delivery.settings.sampleRate) / 48_000).rounded())
        var delivered: Int64 = 0
        var random = UInt64.random(in: 1...UInt64.max)
        var emptyTurns = 0
        let gain = pow(10, gainDB / 20)
        while true {
            try Task.checkCancellation()
            try validate()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { count, status in
                reader.next(count: count, format: inputFormat, status: status)
            }
            if let failure = reader.failure { throw failure }
            try validate()
            if let error { throw ExportFailure.encoder("Delivery conversion failed: \(error)") }
            let count = min(Int64(output.frameLength), expected - delivered)
            if count > 0 {
                guard let channels = output.floatChannelData else { throw ExportFailure.invalidState }
                var samples = [Float](repeating: 0, count: Int(count) * delivery.settings.channels)
                for frame in 0..<Int(count) {
                    for channel in 0..<delivery.settings.channels {
                        var value = Float(Double(channels[channel][frame]) * gain)
                        if !measuring, delivery.dither == .tpdf, case .wave(let pcm) = delivery.settings.codec {
                            func uniform() -> Double {
                                random ^= random << 13; random ^= random >> 7; random ^= random << 17
                                return Double(random >> 11) / 9_007_199_254_740_992
                            }
                            let scale = Double(1 << (pcm.rawValue - 1))
                            value = Float(((Double(value) * scale) + uniform() - uniform()).rounded() / scale)
                            guard value >= -1, Double(value) <= 1 - 1 / scale else {
                                throw ExportFailure.invalidPCM("TPDF quantization needs more headroom. Reduce the production mix level.")
                            }
                        }
                        guard value.isFinite,
                              measuring || delivery.settings.codec == .wave(.float32) || abs(value) <= 1 else {
                            throw ExportFailure.invalidPCM("Delivery exceeds full scale after conversion. Reduce the production mix level or choose Float32 WAV; no clipping or gain adjustment was applied.")
                        }
                        samples[frame * delivery.settings.channels + channel] = value
                    }
                }
                try await sink(samples)
                try validate()
                delivered += count
                emptyTurns = 0
            } else {
                emptyTurns += 1
                guard emptyTurns <= 8 else { throw ExportFailure.encoder("Rate converter made no progress") }
            }
            if status == .endOfStream { break }
            guard status != .error else { throw ExportFailure.encoder("Rate converter failed without an error description") }
        }
        guard delivered == expected, reader.readFrames == writtenFrames else {
            throw ExportFailure.verification("Rate conversion did not preserve the rounded production duration")
        }
    }
}

private final class IntermediateConversionInput {
    let handle: FileHandle
    let channels: Int
    var failure: (any Error)?
    var readFrames: Int64 = 0
    let validate: () throws -> Void
    init(handle: FileHandle, channels: Int, validate: @escaping () throws -> Void) {
        self.handle = handle; self.channels = channels; self.validate = validate
    }

    func next(count: AVAudioPacketCount, format: AVAudioFormat,
              status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        do {
            try validate()
            let frames = min(Int(count), 4_096)
            guard frames > 0 else { throw ExportFailure.invalidPCM("Converter requested an empty input block") }
            let data = try handle.read(upToCount: frames * 8) ?? Data()
            try validate()
            guard data.count % 8 == 0 else { throw ExportFailure.invalidPCM("Truncated private intermediate") }
            if data.isEmpty { status.pointee = .endOfStream; return nil }
            let length = data.count / 8
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
                  let output = buffer.floatChannelData else { throw ExportFailure.invalidState }
            buffer.frameLength = AVAudioFrameCount(length)
            data.withUnsafeBytes { bytes in
                for frame in 0..<length {
                    let left = bytes.loadUnaligned(fromByteOffset: frame * 8, as: Float.self)
                    let right = bytes.loadUnaligned(fromByteOffset: frame * 8 + 4, as: Float.self)
                    if channels == 1 { output[0][frame] = left * 0.5 + right * 0.5 }
                    else { output[0][frame] = left; output[1][frame] = right }
                }
            }
            readFrames += Int64(length)
            status.pointee = .haveData
            return buffer
        } catch {
            failure = error
            status.pointee = .endOfStream
            return nil
        }
    }
}
