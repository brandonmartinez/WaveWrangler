import Foundation
import Testing
import WWCore
@testable import WWCommonEdit

@Suite("Audio clip editor operations")
struct AudioClipEditingTests {
    @Test func movePinDuplicateAndCropPreserveIdentitySupportAndCurve() throws {
        let f = fixture()
        let timeline = try ProgramTimeline(episode: f)
        let original = try #require(timeline.composition().clips.first)
        let track = try #require(f.audioArrangement?.tracks.last)
        let moved = try AudioClipEditing.moving(original, to: 200, track: track.id, timeline: timeline)
        #expect(moved.id == original.clip.id)
        #expect(moved.track == track.id)
        #expect(moved.anchor == .programOrigin(frame: 200))
        #expect(moved.trim == original.clip.trim)
        #expect(moved.envelope == original.clip.envelope)
        let pinned = try AudioClipEditing.pinning(original, pinned: true, timeline: timeline)
        #expect(pinned.anchor == .absolute(frame: 0))
        #expect(try AudioClipEditing.pinning(original, pinned: false, timeline: timeline).anchor == original.clip.anchor)
        let duplicate = try AudioClipEditing.duplicating(original, timeline: timeline)
        #expect(duplicate.id != original.clip.id)
        #expect(duplicate.source == original.clip.source)
        #expect(duplicate.envelope == original.clip.envelope)
        let crop = try AudioClipEditing.resizing(original, localFrames: 2..<470, timeline: timeline)
        #expect(crop.id == original.clip.id)
        #expect(crop.trim == original.clip.trim)
        #expect(crop.outputWindow == .init(offsetFrames: 2, countFrames: 468))
        #expect(crop.anchor == .programOrigin(frame: 2))
        let evaluator = try AudioEnvelopeEvaluator(envelope: crop.envelope, durationFrames: 468)
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 2.0 / 480)
        #expect(try evaluator.amplitude(atLocalFrame: 467) == 469.0 / 480)
    }

    @Test func repeated44100EditsAndReopenKeepExactOutputOwnership() throws {
        var episode = fixture()
        var timeline = try ProgramTimeline(episode: episode)
        var projected = try #require(timeline.composition().clips.first)
        let halves = try projected.split(atProgramFrame: 2, timeline: timeline)
        episode.audioArrangement?.clips = [halves.leading, halves.trailing]
        timeline = try ProgramTimeline(episode: episode)
        projected = try #require(timeline.composition().clips.last)
        let crop = try AudioClipEditing.resizing(projected, localFrames: 1..<477, timeline: timeline)
        episode.audioArrangement?.clips[1] = crop
        let reopened = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(episode))
        let result = try ProgramTimeline(episode: reopened).composition()
        #expect(result.clips.map(\.programFrames) == [0..<2, 3..<479])
        #expect(result.clips[1].clip.trim == halves.trailing.trim)
        #expect(result.clips[1].clip.outputWindow == .init(offsetFrames: 3, countFrames: 476))
        guard case let .source(_, actual) = try result.clips[1].sourcePosition(atProgramFrame: 3),
              case let .source(_, expected) = try projected.sourcePosition(atProgramFrame: 3) else {
            Issue.record("The retained clip must schedule the shared source sample.")
            return
        }
        #expect(actual == expected)
        let evaluator = try AudioEnvelopeEvaluator(envelope: crop.envelope, durationFrames: 476)
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 3.0 / 480)
    }

    @Test func unityCanExtendButDiscardedAutomationAndOutOfSupportRefuse() throws {
        var episode = fixture()
        episode.audioArrangement?.clips[0].envelope = .init()
        var timeline = try ProgramTimeline(episode: episode)
        let original = try #require(timeline.composition().clips.first)
        episode.audioArrangement?.clips[0] = try AudioClipEditing.resizing(
            original, localFrames: 2..<470, timeline: timeline)
        timeline = try ProgramTimeline(episode: episode)
        let crop = try #require(timeline.composition().clips.first)
        let extended = try AudioClipEditing.resizing(crop, localFrames: -2..<478, timeline: timeline)
        #expect(extended.outputWindow == .init(offsetFrames: 0, countFrames: 480))
        #expect(extended.anchor == .programOrigin(frame: 0))
        #expect(throws: AudioClipEditError.invalidBounds) {
            try AudioClipEditing.resizing(crop, localFrames: -3..<478, timeline: timeline)
        }
        episode = fixture()
        timeline = try ProgramTimeline(episode: episode)
        let automated = try #require(timeline.composition().clips.first)
        episode.audioArrangement?.clips[0] = try AudioClipEditing.resizing(
            automated, localFrames: 2..<470, timeline: timeline)
        timeline = try ProgramTimeline(episode: episode)
        let automatedCrop = try #require(timeline.composition().clips.first)
        #expect(throws: AudioClipEditError.extensionRequiresEnvelope) {
            try AudioClipEditing.resizing(automatedCrop, localFrames: -1..<468, timeline: timeline)
        }
        #expect(throws: AudioClipEditError.staleProjection) {
            try AudioClipEditing.moving(original, to: 100, track: original.clip.track, timeline: timeline)
        }
    }

    private func fixture() -> Episode {
        let source = SourceRecord(displayNameHint: "Synthetic stereo.wav", purpose: .supplementalAudio)
        let asset = AudioAsset(source: source.id, frameCount: 441, sampleRate: 44_100, channelCount: 2)
        let a = AudioTrack(name: "Audio 1"), b = AudioTrack(name: "Audio 2")
        let clip = AudioClip(track: a.id, source: source.id,
            trim: .init(startFrame: 0, endFrame: 441), channels: [1, 0],
            anchor: .programOrigin(frame: 0),
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)]))
        var episode = Episode(title: "Synthetic audio editor")
        episode.sources = [source]
        episode.audioArrangement = .init(assets: [asset], tracks: [a, b], clips: [clip])
        return episode
    }
}
