import Foundation
import WWAlignPipeline
import WWCore
import WWMix

struct PlaybackCycleCursor {
    var frame: Int64
    let end: Int64
    private var cycle: Range<Int64>?
    private var armed = false

    init(frame: Int64, end: Int64) {
        self.frame = frame
        self.end = end
    }

    mutating func prepare(cycle: Range<Int64>?) {
        if cycle != self.cycle {
            self.cycle = cycle
            armed = cycle.map { !$0.isEmpty && frame <= $0.upperBound && $0.upperBound <= end } ?? false
        }
        if let cycle, armed, frame == cycle.upperBound { frame = cycle.lowerBound }
    }

    mutating func next(maximumFrames: Int64, cycle: Range<Int64>?) -> Range<Int64>? {
        prepare(cycle: cycle)
        let boundary = armed ? min(end, cycle?.upperBound ?? end) : end
        guard maximumFrames > 0, frame < boundary else { return nil }
        let result = frame..<min(boundary, frame + maximumFrames)
        frame = result.upperBound
        return result
    }
}

/// Device scheduling stays monotonic; only the displayed program position wraps.
struct PlaybackProgramTimeline: Sendable {
    struct Segment: Sendable {
        let playbackFrame: Int64
        let programFrame: Int64
    }
    private(set) var segments: [Segment] = []

    mutating func append(_ segment: Segment, heardFrame: Int64?) {
        if let last = segments.last,
           last.programFrame - last.playbackFrame == segment.programFrame - segment.playbackFrame { return }
        segments.append(segment)
        if let heardFrame, let index = segments.lastIndex(where: { $0.playbackFrame <= heardFrame }), index > 0 {
            segments.removeFirst(index)
        }
    }

    func programSeconds(at playbackSeconds: Double) -> Double {
        let frame = playbackSeconds * Double(MixerRecipe.sampleRate)
        guard let segment = segments.last(where: { Double($0.playbackFrame) <= frame }) else { return playbackSeconds }
        return playbackSeconds + Double(segment.programFrame - segment.playbackFrame) / Double(MixerRecipe.sampleRate)
    }
}

/// Retain ungained cycle tiles and the current decode tile, never rendered/frozen controls.
actor ProductionCyclePCMCache {
    private var tiles: [Int64: MixerPCMWindow] = [:]
    private let bounds: Range<Int64>
    private let prepare: @Sendable (Range<Int64>) async throws -> MixerPCMWindow

    init(bounds: Range<Int64>, prepare: @escaping @Sendable (Range<Int64>) async throws -> MixerPCMWindow) {
        self.bounds = bounds
        self.prepare = prepare
    }

    func window(_ frames: Range<Int64>, retaining cycle: Range<Int64>?) async throws -> MixerPCMWindow {
        guard !frames.isEmpty, frames.lowerBound >= bounds.lowerBound,
              frames.upperBound <= bounds.upperBound else { throw MixerFailure.incompletePCM }
        let width = Int64(MixerLiveTiming.sourceWindowFrames)
        tiles = tiles.filter { _, tile in
            tile.frames.contains(frames.lowerBound) || (cycle.map { $0.overlaps(tile.frames) } ?? false)
        }
        var channels: [ChannelReference: [Float]] = [:]
        var tracks: [AudioTrackID: [[Float]]] = [:]
        var next = frames.lowerBound
        while next < frames.upperBound {
            let key = bounds.lowerBound + ((next - bounds.lowerBound) / width) * width
            let range = key..<min(bounds.upperBound, key + width)
            let tile: MixerPCMWindow
            if let cached = tiles[key] { tile = cached }
            else {
                tile = try await prepare(range)
                try Task.checkCancellation()
                guard tile.frames == range else { throw MixerFailure.discontinuousPCM }
                guard tile.channels.values.allSatisfy({ $0.count == range.count }),
                      tile.audioTracks.values.allSatisfy({
                          $0.count == 2 && $0.allSatisfy({ $0.count == range.count })
                      }) else { throw MixerFailure.incompletePCM }
                tiles[key] = tile
            }
            let last = min(frames.upperBound, range.upperBound)
            let slice = Int(next - key)..<Int(last - key)
            for (reference, samples) in tile.channels { channels[reference, default: []].append(contentsOf: samples[slice]) }
            for (track, samples) in tile.audioTracks {
                var stereo = tracks[track] ?? [[], []]
                for channel in stereo.indices { stereo[channel].append(contentsOf: samples[channel][slice]) }
                tracks[track] = stereo
            }
            next = last
        }
        return .init(frames: frames, channels: channels, audioTracks: tracks)
    }

    #if DEBUG
    var retainedTileCount: Int { tiles.count }
    #endif
}

struct SourcePCMWindow: PlaybackPCMWindow {
    let frames: Range<Int64>
    let clips: [SourceID: AlignmentAudioClip]
}

actor SourceCyclePCMCache {
    private var tiles: [Int64: [SourceID: AlignmentAudioClip]] = [:]
    private let bounds: Range<Int64>
    private let width: Int64
    private let prepare: @Sendable ([SourceID], Range<Int64>) async throws -> [SourceID: AlignmentAudioClip]

    init(bounds: Range<Int64>, width: Int64,
         prepare: @escaping @Sendable ([SourceID], Range<Int64>) async throws -> [SourceID: AlignmentAudioClip]) {
        self.bounds = bounds
        self.width = width
        self.prepare = prepare
    }

    func window(_ frames: Range<Int64>, sources: [SourceID], retaining cycle: Range<Int64>?) async throws -> SourcePCMWindow {
        guard !frames.isEmpty, frames.lowerBound >= bounds.lowerBound, frames.upperBound <= bounds.upperBound else {
            throw WaveformWindowError.invalidWindow
        }
        tiles = tiles.filter { key, _ in
            let range = key..<min(bounds.upperBound, key + width)
            return range.contains(frames.lowerBound) || (cycle?.overlaps(range) ?? false)
        }
        var result: [SourceID: AlignmentAudioClip] = [:]
        var next = frames.lowerBound
        while next < frames.upperBound {
            let key = bounds.lowerBound + ((next - bounds.lowerBound) / width) * width
            let range = key..<min(bounds.upperBound, key + width)
            var clips = tiles[key] ?? [:]
            let missing = sources.filter { clips[$0] == nil }
            if !missing.isEmpty {
                let prepared = try await prepare(missing, range)
                try Task.checkCancellation()
                guard Set(prepared.keys) == Set(missing),
                      prepared.values.allSatisfy({
                          $0.channelCount == 1 && $0.sampleRate == Double(MixerRecipe.sampleRate)
                              && $0.samples.count == range.count
                      }) else { throw WaveformWindowError.invalidSamples }
                clips.merge(prepared) { _, new in new }
                tiles[key] = clips
            }
            let last = min(frames.upperBound, range.upperBound)
            let slice = Int(next - key)..<Int(last - key)
            for source in sources {
                guard var clip = clips[source] else { throw WaveformWindowError.invalidSamples }
                let samples = Array(clip.samples[slice])
                if var existing = result[source] {
                    existing.samples += samples
                    result[source] = existing
                } else {
                    clip.samples = samples
                    result[source] = clip
                }
            }
            next = last
        }
        return .init(frames: frames, clips: result)
    }
}
