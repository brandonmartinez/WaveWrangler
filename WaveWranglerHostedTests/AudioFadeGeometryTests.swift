import Foundation
import Testing
import WWCommonEdit
import WWCore
@testable import WaveWrangler

@MainActor @Suite("Fade viewport geometry and exact numeric input", .serialized)
struct AudioFadeGeometryTests {
    private func key(envelope: AudioClipEnvelope, duration: Int64 = 480_000,
                     start: Double = 0, width: Double = 640,
                     projection: AudioTimelineProjection = .unedited) -> AudioEnvelopeGeometryKey {
        .init(envelope: envelope, durationFrames: duration, programStart: 0,
              viewportStart: start, viewportDuration: 10, viewportWidth: width,
              left: 0, width: width, height: 96, projection: projection)
    }

    @Test func geometryIsViewportBoundedAndExactKnotsAreVisibleWithoutChangingLaneSize() throws {
        let curve = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 0), .init(frame: 240_000, amplitude: 0.25),
            .init(frame: 480_000, amplitude: 1),
        ])
        let shape = try AudioEnvelopeGeometry.make(key(envelope: curve))
        #expect(shape.points.count == 3)
        #expect(shape.points.map(\.position.x) == [0, 320, 640])
        #expect(shape.points.map(\.position.y) == [90, 69, 6])
        let vertices = shape.lines.flatMap { $0 }
        let withinViewport = vertices.allSatisfy { (point: CGPoint) in
            point.x >= 0 && point.x <= 640 && point.y >= 6 && point.y <= 90
        }
        #expect(withinViewport)
        let dense = AudioClipEnvelope(points: (0...48_000).map {
            .init(frame: Int64($0), amplitude: $0.isMultiple(of: 2) ? 0 : 1)
        })
        let huge = try AudioEnvelopeGeometry.make(key(envelope: dense, duration: 48_000, width: 100_000))
        #expect(huge.points.count <= AudioEnvelopeGeometry.maximumColumns)
        #expect(huge.lines.reduce(0) { $0 + $1.count } <= 3 * AudioEnvelopeGeometry.maximumColumns + 1)
        let day = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 1), .init(frame: AudioArrangement.frameLimit, amplitude: 0),
        ])
        let zoomed = try AudioEnvelopeGeometry.make(key(envelope: day, duration: AudioArrangement.frameLimit, start: 20))
        let zoomedVertexCount = zoomed.lines.reduce(0) { $0 + $1.count }
        #expect(zoomedVertexCount <= 1281 && zoomed.points.isEmpty)
        let fraction = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 0), .init(frame: 1, amplitude: 1),
        ], window: .init(offset: try .init(numerator: 1, denominator: 3)))
        let fractionalKey = AudioEnvelopeGeometryKey(envelope: fraction, durationFrames: 1,
            programStart: 0, viewportStart: 0, viewportDuration: 1.0 / 48_000, viewportWidth: 600,
            left: 0, width: 600, height: 96, projection: .unedited)
        let fractional = try AudioEnvelopeGeometry.make(fractionalKey)
        let knot = try #require(fractional.points.first)
        #expect(abs(Double(knot.position.x) - 400) < 1e-10)
        #expect(knot.position.y == 6)
        #expect(fractional.lines.flatMap { $0 }.contains(knot.position))
    }

    @Test func unchangedCacheKeysReuseGeometryButCurveViewportAndProjectionChangesRebuild() throws {
        let cache = AudioEnvelopeGeometryCache(), clip = AudioClipID()
        let curve = AudioClipEnvelope(points: [.init(frame: 0, amplitude: 1), .init(frame: 480_000, amplitude: 0)])
        let first = cache.geometry(for: clip, key: key(envelope: curve))
        for _ in 0..<1000 {
            #expect(cache.geometry(for: clip, key: key(envelope: curve)).id == first.id)
        }
        #expect(cache.buildCount == 1 && first.failure == nil)
        let second = cache.geometry(for: clip, key: key(envelope: curve, start: 1))
        #expect(second.id != first.id && cache.buildCount == 2)
        let changed = AudioClipEnvelope(points: [.init(frame: 0, amplitude: 0.5)])
        #expect(cache.geometry(for: clip, key: key(envelope: changed)).id != second.id)
        #expect(cache.buildCount == 3)
        let failure = cache.geometry(for: clip, key: key(envelope: changed, width: .infinity))
        #expect(failure.geometry == nil && failure.failure?.contains("viewport") == true)
    }

    @Test func geometryCacheEvictsLeastRecentVisitedClipsAndPrunesRemovedClips() throws {
        let cache = AudioEnvelopeGeometryCache()
        let curve = AudioClipEnvelope(points: [.init(frame: 0, amplitude: 1), .init(frame: 480_000, amplitude: 0)])
        let input = key(envelope: curve)
        let clips = (0..<AudioEnvelopeGeometryCache.maximumEntries).map { _ in AudioClipID() }
        let first = cache.geometry(for: clips[0], key: input)
        for clip in clips.dropFirst() { _ = cache.geometry(for: clip, key: input) }
        #expect(cache.entryCount == AudioEnvelopeGeometryCache.maximumEntries)
        #expect(cache.geometry(for: clips[0], key: input).id == first.id)
        _ = cache.geometry(for: AudioClipID(), key: input)
        #expect(cache.geometry(for: clips[0], key: input).id == first.id, "A recently reused entry survives eviction.")
        let builds = cache.buildCount
        _ = cache.geometry(for: clips[1], key: input)
        #expect(cache.buildCount == builds + 1, "The least-recently-used entry was evicted.")
        for _ in 0..<100 {
            _ = cache.geometry(for: AudioClipID(), key: input)
            #expect(cache.entryCount == AudioEnvelopeGeometryCache.maximumEntries)
        }
        cache.retain([])
        #expect(cache.entryCount == 0)
        #expect(cache.geometry(for: clips[0], key: input).id != first.id)
        #expect(cache.entryCount == 1)
    }

    @Test func expandedReviewOnlyCutsBreakTheCurveAndNeverInventAProductionFadeCoordinate() throws {
        let map = TimeMapVersion(revision: 1, inputs: .init(sources: []), map: .object([:]))
        var episode = Episode(title: "Synthetic")
        episode.alignment = .init(maps: [map], acceptedRevision: 1)
        let cut = ManualEpisodeCut(alignmentRevision: 1, startFrame: 96_000, endFrame: 144_000)
        episode.cleanup = .init(manualCuts: [cut])
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: 0..<480_000)
        let projection = AudioTimelineProjection(cuts: .unedited, program: timeline, expanded: cut)
        let curve = AudioClipEnvelope(points: [.init(frame: 0, amplitude: 0), .init(frame: 480_000, amplitude: 1)])
        let geometry = try AudioEnvelopeGeometry.make(key(envelope: curve, projection: projection))
        #expect(geometry.lines.count == 2)
        #expect(projection.programTime(forDisplayTime: 2.5) == nil)
        #expect(geometry.lines[0].allSatisfy { $0.x < 128 })
        #expect(geometry.lines[1].allSatisfy { $0.x >= 192 })
    }

    @Test func automationHitTargetsPreferPointsAndOnlyExposeFlatEditableSegments() throws {
        let curve = AudioClipEnvelope(points: [
            .init(frame: 48_000, amplitude: 1), .init(frame: 96_000, amplitude: 0.25),
            .init(frame: 192_000, amplitude: 0.25), .init(frame: 240_000, amplitude: 0),
        ])
        let shape = try AudioEnvelopeGeometry.make(key(envelope: curve))
        #expect(shape.segments.map { [$0.first, $0.last] } == [[0, 0], [1, 2], [3, 3]])
        #expect(shape.target(at: shape.points[1].position) == .point(1))
        let flat = try #require(shape.segments.first { $0.first == 1 })
        #expect(shape.target(at: .init(x: flat.frame.midX, y: flat.frame.midY)) == .level(first: 1, last: 2))
        #expect(shape.target(at: .init(x: 96, y: 40)) == nil, "A sloping ramp is not a level-drag target.")
        let empty = try AudioEnvelopeGeometry.make(key(envelope: .init()))
        #expect(empty.points.isEmpty && empty.segments.isEmpty)
    }

    @Test func exactLocalFrameAndAmplitudeInputsRejectMalformedNonfiniteAndOverflowValues() throws {
        #expect(try AudioFadeInput.coordinate("14540/147") == AudioEnvelopeCoordinate(numerator: 14_540, denominator: 147))
        #expect(try AudioFadeInput.coordinate(" 10 ") == AudioEnvelopeCoordinate(numerator: 10))
        for text in ["", "1/", "/1", "nan", "1.5", "1/0", "1/-1", "1/999999", "9223372036854775808", "1/2/3"] {
            #expect(throws: (any Error).self) { try AudioFadeInput.coordinate(text) }
        }
        for text in ["", "nan", "inf", "-inf", "-0.1", "1.1", "1e300"] {
            #expect(throws: (any Error).self) { try AudioFadeInput.amplitude(text, silence: false) }
        }
        #expect(try AudioFadeInput.amplitude("unused", silence: true) == 0)
        #expect(try AudioFadeInput.amplitude("0", silence: false) == 0)
        #expect(try AudioFadeInput.amplitude("1", silence: false) == 1)
    }
}
