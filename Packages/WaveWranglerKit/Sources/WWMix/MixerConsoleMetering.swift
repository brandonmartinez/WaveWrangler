import Foundation
import WWCore

public enum MixerConsoleScale {
    public static let meterFloorDB = -60.0
    public static func decibels(_ amplitude: Float) -> Double {
        amplitude > 0 ? 20 * log10(Double(amplitude)) : -.infinity
    }

    public static func meterPosition(_ decibels: Double) -> Double {
        min(1, max(0, (decibels - meterFloorDB) / -meterFloorDB))
    }

    /// Piecewise dB taper reserves most of the travel for normal mixing levels.
    public static func faderPosition(_ decibels: Double) -> Double {
        decibels <= -12 ? (decibels + 96) / 84 * 0.4 : 0.4 + (decibels + 12) / 36 * 0.6
    }

    public static func faderDecibels(_ position: Double) -> Double {
        let value = min(1, max(0, position))
        return value <= 0.4 ? -96 + value / 0.4 * 84 : -12 + (value - 0.4) / 0.6 * 36
    }
}

public struct MixerConsoleLevel: Sendable, Equatable {
    public var peakDB: Double = -.infinity
    public var rmsDB: Double = -.infinity
    public var heldPeakDB: Double = -.infinity
    public var clipped = false
    public init() {}
}

public struct MixerConsoleSnapshot: Sendable, Equatable {
    public var frame: Int64 = 0
    public var levels: [MixerBusAddress: [MixerConsoleLevel]] = [:]
    public init() {}
}

/// Bounded, meter-only delivery from serial DSP to the UI's playback-clock reader.
/// Every block contributes, even when it falls entirely between display refreshes.
public struct MixerConsoleMetering: Sendable {
    private struct Moment: Sendable {
        var peak: Float
        var energy: Double
        var count: Double
        init(_ meter: MixerMeter, frames: Int) {
            peak = meter.peak
            count = Double(frames)
            energy = Double(meter.rms) * Double(meter.rms) * count
        }
        mutating func combine(_ other: Self, fraction: Double = 1) {
            peak = max(peak, other.peak)
            energy += other.energy * fraction
            count += other.count * fraction
        }
        var rms: Float { count > 0 ? Float(sqrt(energy / count)) : 0 }
    }

    private struct Packet: Sendable {
        var first: Int64
        var end: Int64
        var buses: [MixerBusAddress: [Moment]]
    }

    public static let maximumPendingPackets = 128
    public static let rmsWindowFrames: Int64 = 14_400
    private var pending: [Packet] = []
    private var window: [Packet] = []
    private var snapshot = MixerConsoleSnapshot()
    public var pendingPacketCount: Int { pending.count }

    public init() {}

    public mutating func append(_ output: MixerPCMOutput) {
        guard output.frameCount > 0 else { return }
        var buses: [MixerBusAddress: [Moment]] = [.master: output.masterMeters.map {
            Moment($0, frames: output.frameCount)
        }]
        for (speaker, meter) in output.speakerMeters {
            buses[.speaker(speaker)] = [Moment(meter, frames: output.frameCount)]
        }
        for (track, meters) in output.audioTrackMeters {
            buses[.audioTrack(track)] = meters.map { Moment($0, frames: output.frameCount) }
        }
        pending.append(Packet(first: output.firstFrame, end: output.firstFrame + Int64(output.frameCount), buses: buses))
        // A stalled display must neither retain PCM nor lose a transient. Coalescing delays a
        // merged interval until its end is heard, but preserves its peak and weighted energy.
        if pending.count > Self.maximumPendingPackets {
            let first = pending.removeFirst()
            pending[0].first = first.first
            for (bus, moments) in first.buses {
                for (index, moment) in moments.enumerated() {
                    if pending[0].buses[bus]?.indices.contains(index) == true {
                        pending[0].buses[bus]?[index].combine(moment)
                    }
                }
            }
        }
    }

    public mutating func read(through frame: Int64) -> MixerConsoleSnapshot {
        let elapsed = max(0, Double(frame - snapshot.frame) / Double(MixerRecipe.sampleRate))
        var peaks: [MixerBusAddress: [Float]] = [:]
        while let packet = pending.first, packet.end <= frame {
            pending.removeFirst()
            window.append(packet)
            for (bus, moments) in packet.buses {
                let previous = peaks[bus] ?? Array(repeating: 0, count: moments.count)
                peaks[bus] = zip(previous, moments).map { max($0.0, $0.1.peak) }
            }
        }
        let cutoff = frame - Self.rmsWindowFrames
        window.removeAll { $0.end <= cutoff }
        var sums: [MixerBusAddress: [Moment]] = [:]
        for packet in window {
            let fraction = Double(packet.end - max(packet.first, cutoff)) / Double(packet.end - packet.first)
            for (bus, moments) in packet.buses {
                if sums[bus] == nil {
                    sums[bus] = moments.map { _ in Moment(MixerMeter([]), frames: 0) }
                }
                for index in moments.indices { sums[bus]?[index].combine(moments[index], fraction: fraction) }
            }
        }
        for bus in Set(snapshot.levels.keys).union(sums.keys).union(peaks.keys) {
            let count = max(snapshot.levels[bus]?.count ?? 0, sums[bus]?.count ?? 0, peaks[bus]?.count ?? 0)
            var levels = snapshot.levels[bus] ?? Array(repeating: MixerConsoleLevel(), count: count)
            for index in levels.indices {
                let peak = peaks[bus]?[index] ?? 0
                let db = MixerConsoleScale.decibels(peak)
                levels[index].peakDB = max(db, levels[index].peakDB - 20 * elapsed)
                levels[index].rmsDB = MixerConsoleScale.decibels(sums[bus]?[index].rms ?? 0)
                levels[index].heldPeakDB = max(levels[index].heldPeakDB, db)
                levels[index].clipped = levels[index].clipped || peak > 1
            }
            snapshot.levels[bus] = levels
        }
        snapshot.frame = frame
        return snapshot
    }

    public mutating func resetPeaks(for bus: MixerBusAddress) {
        guard var levels = snapshot.levels[bus] else { return }
        for index in levels.indices {
            levels[index].heldPeakDB = -.infinity
            levels[index].clipped = false
        }
        snapshot.levels[bus] = levels
    }
}
