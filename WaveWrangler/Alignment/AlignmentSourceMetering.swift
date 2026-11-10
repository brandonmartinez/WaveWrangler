import AVFAudio
import WWCore
import WWMix

/// Shares scheduled buffers (no PCM copies) until heard; all work stays on the output queue.
struct AlignmentSourceMetering {
    private struct Window {
        let first: Int64
        let buffers: [SourceID: AVAudioPCMBuffer]
        let count: Int
    }

    private var windows: [Window] = []
    private var cursor: Int64?
    private var metering = MixerConsoleMetering()
    var speakers: [SpeakerID: Set<SourceID>] = [:]
    var gains: [SourceID: Float] = [:]
    var bufferedWindowCount: Int { windows.count }

    mutating func append(_ buffers: [SourceID: AVAudioPCMBuffer], firstFrame: Int64) {
        guard let buffer = buffers.values.first else { return }
        windows.append(Window(first: firstFrame, buffers: buffers, count: Int(buffer.frameLength)))
        cursor = cursor ?? firstFrame
    }

    mutating func read(through frame: Int64) -> MixerConsoleSnapshot {
        while let window = windows.first, let next = cursor, next < frame {
            let end = min(frame, window.first + Int64(window.count), next + 512)
            guard end > next else {
                windows.removeFirst()
                continue
            }
            let count = Int(end - next)
            let offset = Int(next - window.first)
            func sum(_ sources: Set<SourceID>) -> [Float] {
                var result = Array(repeating: Float(0), count: count)
                for source in sources {
                    guard let buffer = window.buffers[source], let samples = buffer.floatChannelData?.pointee,
                          let gain = gains[source], gain != 0 else { continue }
                    for index in 0..<count { result[index] += samples[offset + index] * gain }
                }
                return result
            }
            let master = sum(Set(window.buffers.keys))
            metering.append(MixerPCMOutput(firstFrame: next, channels: [master, master],
                speakerMeters: speakers.mapValues { MixerMeter(sum($0)) }))
            cursor = end
            if end == window.first + Int64(window.count) { windows.removeFirst() }
        }
        return metering.read(through: frame)
    }

    mutating func resetPeaks(for bus: MixerBusAddress) { metering.resetPeaks(for: bus) }
}
