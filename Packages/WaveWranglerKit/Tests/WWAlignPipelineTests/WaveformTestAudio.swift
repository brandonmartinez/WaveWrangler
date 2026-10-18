import Foundation
import AudioToolbox
import AVFAudio
import WWCore
import WWTimeMap

enum WaveformTestAudio {
    static func compressedAAC(at url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
           let samples = buffer.floatChannelData?.pointee
        else { throw CocoaError(.coderValueNotFound) }
        buffer.frameLength = 16_000
        samples.update(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Generated sparse PCM fixture: late landmarks require no episode-sized test allocation.
    static func sparseWave(at url: URL, rate: Int, frames: Int64, landmarks: [Int64: Int16]) throws {
        var header = wave(rate: rate, samples: [])
        func replace(_ value: UInt32, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        replace(UInt32(36 + frames * 2), at: 4)
        replace(UInt32(frames * 2), at: 40)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(44 + frames * 2))
        for (frame, sample) in landmarks {
            try handle.seek(toOffset: UInt64(44 + frame * 2))
            var little = sample.littleEndian
            try withUnsafeBytes(of: &little) { try handle.write(contentsOf: Data($0)) }
        }
    }

    static func wave(rate: Int, samples: [Int16], channels: Int = 1) -> Data {
        var data = Data()
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        number(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        number(UInt32(16))
        number(UInt16(1))
        number(UInt16(channels))
        number(UInt32(rate))
        number(UInt32(rate * channels * 2))
        number(UInt16(channels * 2))
        number(UInt16(16))
        data.append(contentsOf: "data".utf8)
        number(UInt32(samples.count * 2))
        for sample in samples { number(sample) }
        return data
    }

    static func map(
        source: SourceID, rate: Int, frames: Int64, offset: ExactRational,
        ratio: ExactRational = .one, spans: [EpochSpan]? = nil
    ) throws -> GroupTimeMap {
        let group = RecorderGroupID()
        let epoch = spans?.first?.epoch ?? RecordingEpochID()
        let occurrence = try SourceOccurrence(source: source, nominalRate: NominalRate(Int64(rate)), frameCount: frames)
        let reference = TimelineReference(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID())
        let end = try ExactRational(numerator: Int128(frames), denominator: Int128(rate))
        let segment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: end, rateRatio: ratio, alignedOffset: offset
        )
        let placed = spans ?? [EpochSpan(startFrame: 0, endFrame: frames, epoch: epoch, groupClockOffset: .zero)]
        let others = Set(placed.map(\.epoch)).subtracting([epoch])
        return try GroupTimeMap(
            group: group, reference: reference,
            epochs: [EpochClockMap(
                epoch: epoch, mapping: .mapped(segments: [segment], provenance: .manual(.init(basis: .numericEntry)))
            )] + others.map { EpochClockMap(epoch: $0, mapping: .unsupported(.notAttempted)) },
            placements: [OccurrencePlacement(occurrence: occurrence, spans: placed)]
        )
    }
}
