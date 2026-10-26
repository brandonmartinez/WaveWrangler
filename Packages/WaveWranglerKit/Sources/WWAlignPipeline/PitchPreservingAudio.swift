import AVFoundation
import Foundation
import Synchronization
import WWDecode

public enum PitchPreservingAudio {
    public static let identifier = "ww-native-time-pitch-multichannel/1"
    public static let renderRecipeVersion = 5

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidPCM
        case allocation
        case renderFailed
        case nativeRender(Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidPCM: "Pitch-preserving rendering received unsupported audio or an invalid output-frame request."
            case .allocation: "The pitch-preserving audio processor could not allocate its buffers."
            case .renderFailed: "The pitch-preserving audio processor did not return complete, finite audio."
            case let .nativeRender(status): "The native pitch-preserving audio processor failed (status \(status))."
            }
        }
    }

    /// Bounded offline processing: every channel passes through the same pitch-preserving unit.
    @concurrent
    public static func stretch(_ channels: [[Float]], sampleRate: Int, rateRatio: Double,
                               outputRate: Int? = nil, minimumOutputFrames: Int = 0) async throws -> [[Float]] {
        let destinationRate = outputRate ?? sampleRate
        guard let frames = channels.first?.count, frames > 0, channels.count <= 32,
              (8000...192000).contains(sampleRate), (8000...192000).contains(destinationRate),
              frames <= sampleRate * 15,
              rateRatio.isFinite, (0.98...1.02).contains(rateRatio),
              minimumOutputFrames >= 0,
              channels.allSatisfy({ $0.count == frames && $0.allSatisfy(\.isFinite) }) else { throw Failure.invalidPCM }
        let exactFrames = Double(frames) * rateRatio * Double(destinationRate) / Double(sampleRate)
        guard Double(minimumOutputFrames) <= ceil(exactFrames) + 1 else { throw Failure.invalidPCM }
        try Task.checkCancellation()
        let pcm = try await PCMResampling.convert(channels, inputRate: sampleRate, outputRate: destinationRate)
        let nativeFrames = pcm[0].count
        let format = try PCMResampling.format(sampleRate: destinationRate, channelCount: channels.count)
        let pitch = AVAudioUnitTimePitch()
        defer { withExtendedLifetime(pitch) {} }
        pitch.rate = Float(1 / rateRatio)
        pitch.pitch = 0
        pitch.overlap = 8
        let unit = pitch.audioUnit
        func check(_ status: OSStatus) throws {
            guard status == noErr else { throw Failure.nativeRender(status) }
        }
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            format.streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
            format.streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        var offline: UInt32 = 1, maximumFrames: UInt32 = 4096
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0,
            &offline, UInt32(MemoryLayout<UInt32>.size)))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maximumFrames, UInt32(MemoryLayout<UInt32>.size)))
        let padding = destinationRate / 2
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(nativeFrames + padding)),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let destination = input.floatChannelData else { throw Failure.allocation }
        input.frameLength = input.frameCapacity
        for channel in channels.indices {
            destination[channel].initialize(repeating: 0, count: nativeFrames + padding)
            pcm[channel].withUnsafeBufferPointer { samples in
                destination[channel].update(from: samples.baseAddress!, count: nativeFrames)
            }
        }
        let context = Unmanaged.passRetained(PCMInput(buffer: input))
        defer { context.release() }
        var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, buffers in
            guard let buffers else { return kAudioUnitErr_InvalidPropertyValue }
            return Unmanaged<PCMInput>.fromOpaque(context).takeUnretainedValue().pull(frames: frames, buffers: buffers)
        }, inputProcRefCon: context.toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(unit))
        defer { AudioUnitUninitialize(unit) }
        // A canonical tile may need the next native sample to cover its fractional output-grid boundary.
        let wanted = max(Int(exactFrames.rounded()), minimumOutputFrames)
        let latency = Int((pitch.latency * Double(destinationRate)).rounded())
        var collected = channels.map { _ in [Float]() }
        var remaining = wanted + latency, position = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, remaining))
            output.frameLength = count
            guard let samples = output.floatChannelData else { throw Failure.allocation }
            for channel in channels.indices { samples[channel].update(repeating: 0, count: Int(count)) }
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(position)
            timestamp.mFlags = .sampleTimeValid
            var flags: AudioUnitRenderActionFlags = []
            try check(AudioUnitRender(unit, &flags, &timestamp, 0, count, output.mutableAudioBufferList))
            for channel in channels.indices {
                collected[channel].append(contentsOf: UnsafeBufferPointer(start: samples[channel], count: Int(count)))
            }
            remaining -= Int(count)
            position += Int(count)
        }
        guard collected.allSatisfy({ $0.count >= latency + wanted && $0.allSatisfy(\.isFinite) }) else {
            throw Failure.renderFailed
        }
        return collected.map { Array($0[latency..<latency + wanted]) }
    }

    private final class PCMInput: Sendable {
        let state: Mutex<(position: Int, buffer: AVAudioPCMBuffer)>

        init(buffer: sending AVAudioPCMBuffer) { state = Mutex((0, buffer)) }

        func pull(frames count: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            state.withLock { state in
                let frames = Int(count)
                guard state.position + frames <= Int(state.buffer.frameLength),
                      let channels = state.buffer.floatChannelData else { return kAudioUnitErr_TooManyFramesToProcess }
                let destination = UnsafeMutableAudioBufferListPointer(buffers)
                guard destination.count == Int(state.buffer.format.channelCount) else { return kAudioUnitErr_FormatNotSupported }
                for channel in destination.indices {
                    destination[channel].mData = UnsafeMutableRawPointer(channels[channel].advanced(by: state.position))
                    destination[channel].mDataByteSize = count * 4
                }
                state.position += frames
                return noErr
            }
        }
    }
}
