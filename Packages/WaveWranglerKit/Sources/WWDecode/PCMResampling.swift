import AVFoundation
import Foundation
import Synchronization

/// Nominal sample-rate conversion of already decoded, bounded planar PCM; no source or file access.
public enum PCMResampling {
    public enum Failure: Error {
        case invalidPCM
        case allocation
        case conversion(String)
        case incomplete
    }

    public static func format(sampleRate: Int, channelCount: Int) throws -> AVAudioFormat {
        guard (8000...192000).contains(sampleRate), (1...32).contains(channelCount) else { throw Failure.invalidPCM }
        let layout: AVAudioChannelLayout
        if channelCount <= 2 {
            guard let standard = AVAudioChannelLayout(layoutTag: channelCount == 1
                ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo) else { throw Failure.invalidPCM }
            layout = standard
        } else {
            let descriptions = AudioChannelLayout.allocate(maximumDescriptions: channelCount)
            defer { descriptions.unsafeMutablePointer.deallocate() }
            for channel in 0..<channelCount {
                descriptions[channel] = AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Discrete_0 + UInt32(channel),
                    mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
            layout = AVAudioChannelLayout(layout: descriptions.unsafeMutablePointer)
        }
        return AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channelLayout: layout)
    }

    @concurrent
    public static func convert(_ channels: [[Float]], inputRate: Int, outputRate: Int) async throws -> [[Float]] {
        guard let frames = channels.first?.count, frames > 0, (1...32).contains(channels.count),
              (8000...192000).contains(inputRate), (8000...192000).contains(outputRate),
              frames <= inputRate * 15, channels.allSatisfy({ $0.count == frames && $0.allSatisfy(\.isFinite) })
        else { throw Failure.invalidPCM }
        try Task.checkCancellation()
        if inputRate == outputRate { return channels }
        let sourceFormat = try format(sampleRate: inputRate, channelCount: channels.count)
        let targetFormat = try format(sampleRate: outputRate, channelCount: channels.count)
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)
        else { throw Failure.allocation }
        converter.channelMap = channels.indices.map { NSNumber(value: $0) }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let state = Mutex(Input(channels: channels, buffer: input, padding: inputRate / 2))
        let supply: AVAudioConverterInputBlock = { requested, status in
            state.withLock { state in
                let limit = frames + state.padding
                guard state.position < limit else { status.pointee = .endOfStream; return nil }
                guard let destination = state.buffer.floatChannelData else {
                    state.failed = true
                    status.pointee = .noDataNow
                    return nil
                }
                let count = min(4096, Int(requested), limit - state.position)
                state.buffer.frameLength = AVAudioFrameCount(count)
                let available = min(count, max(0, frames - state.position))
                for channel in state.channels.indices {
                    destination[channel].update(repeating: 0, count: count)
                    if available > 0 {
                        state.channels[channel].withUnsafeBufferPointer {
                            destination[channel].update(from: $0.baseAddress!.advanced(by: state.position), count: available)
                        }
                    }
                }
                state.position += count
                status.pointee = .haveData
                return state.buffer
            }
        }
        let wanted = Int((Double(frames) * Double(outputRate) / Double(inputRate)).rounded())
        var result = channels.map { _ in [Float]() }
        while result[0].count < wanted {
            try Task.checkCancellation()
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: supply)
            if state.withLock({ $0.failed }) { throw Failure.allocation }
            if status == .error { throw Failure.conversion(error?.localizedDescription ?? "Native PCM conversion failed without a diagnostic.") }
            guard output.frameLength > 0, let samples = output.floatChannelData else { throw Failure.incomplete }
            let count = min(Int(output.frameLength), wanted - result[0].count)
            for channel in channels.indices {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: samples[channel], count: count))
            }
        }
        guard result.allSatisfy({ $0.count == wanted && $0.allSatisfy(\.isFinite) }) else { throw Failure.incomplete }
        return result
    }

    private struct Input {
        let channels: [[Float]]
        let buffer: AVAudioPCMBuffer
        let padding: Int
        var position = 0
        var failed = false
    }
}
