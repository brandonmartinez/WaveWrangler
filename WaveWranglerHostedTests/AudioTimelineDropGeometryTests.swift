import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
import WWCommonEdit
import WWCore
@testable import WaveWrangler

@MainActor @Suite("Audio file drop coordinates and payloads", .serialized)
struct AudioTimelineDropGeometryTests {
    @Test func canvasCoordinatesCaptureWholeProgramFramesAtZoomPanAndHeaderOffsets() throws {
        let track = AudioTrackID()
        let geometry = AudioTimelineDropGeometry(size: .init(width: 720, height: 100),
            start: 17.25, duration: 3, projection: .unedited, track: .existing(track))
        let globalCanvas = CGRect(x: 412, y: 193, width: 720, height: 100)
        let drop = CGPoint(x: 652, y: 233)
        let local = CGPoint(x: drop.x - globalCanvas.minX, y: drop.y - globalCanvas.minY)
        #expect(try geometry.destination(at: local) == .init(frame: 876_000, track: .existing(track)))
        #expect(try geometry.destination(at: .init(x: 0, y: 0)).frame == 828_000)
        #expect(try geometry.destination(at: .init(x: 720, y: 100)).frame == 972_000)
        #expect(throws: (any Error).self) { try geometry.destination(at: .init(x: -12, y: 40)) }
        #expect(throws: (any Error).self) { try geometry.destination(at: .init(x: 100, y: -1)) }
        #expect(throws: (any Error).self) { try geometry.destination(at: .init(x: CGFloat.infinity, y: 40)) }
    }

    @Test func expandedCutHasNoDropFrameAndInsertionUsesCurrentInverse() throws {
        let map = TimeMapVersion(revision: 1, inputs: .init(sources: []), map: .object([:]))
        var episode = Episode(title: "Synthetic")
        episode.alignment = .init(maps: [map], acceptedRevision: 1)
        let cut = ManualEpisodeCut(alignmentRevision: 1, startFrame: 96_000, endFrame: 144_000)
        episode.cleanup = .init(manualCuts: [cut])
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: map, frame: 48_000)),
                                             durationFrames: 24_000)
        episode.audioArrangement = .init(insertionRegions: [region])
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: 0..<480_000)
        let expanded = AudioTimelineProjection(cuts: .unedited, program: timeline, expanded: cut)
        let geometry = AudioTimelineDropGeometry(size: .init(width: 1000, height: 100),
            start: 0, duration: 10, projection: expanded, track: .newTrack)
        #expect(throws: (any Error).self) { try geometry.destination(at: .init(x: 275, y: 40)) }
        let insertion = try geometry.destination(at: .init(x: 125, y: 40))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: insertion.frame)
            == .insertion(region: region.id, offsetFrames: 12_000))
        let after = try geometry.destination(at: .init(x: 400, y: 40))
        #expect(after.frame == 144_000)
        #expect(try timeline.unpinnedAnchor(atProgramFrame: after.frame) == .dialogue(.init(map: map, frame: 168_000)))
    }

    @Test func onlyFileLocationRepresentationsAreAcceptedAndHoverNeedsNoProviderLoads() throws {
        let counter = DropProviderCounter()
        let file = NSItemProvider()
        file.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            counter.increment()
            completion(URL(filePath: "/synthetic/unopened.wav").dataRepresentation, nil)
            return nil
        }
        let geometry = AudioTimelineDropGeometry(size: .init(width: 100, height: 80),
            start: 8, duration: 2, projection: .unedited, track: .newTrack)
        for x in 0...100 {
            _ = try geometry.destination(at: .init(x: Double(x), y: 40))
            try AudioTimelineFileDropPayload.validate([file])
        }
        #expect(counter.value == 0)
        try AudioTimelineFileDropPayload.validate([file], itemCount: 1)
        try AudioTimelineFileDropPayload.validate([file, file], itemCount: 2)
        #expect(throws: (any Error).self) {
            try AudioTimelineFileDropPayload.validate([file], itemCount: 2)
        }
        #expect(throws: (any Error).self) {
            try AudioTimelineFileDropPayload.validate([], itemCount: 0)
        }
        #expect(counter.value == 0)
        let row = NSItemProvider()
        row.register(SetupSourceDrag(showID: ShowID(), episodeID: EpisodeID(), sourceID: SourceID()))
        #expect(throws: (any Error).self) { try AudioTimelineFileDropPayload.validate([row]) }
        #expect(throws: (any Error).self) { try AudioTimelineFileDropPayload.validate([file, row]) }
        let web = NSItemProvider(object: try #require(NSURL(string: "https://example.invalid/audio.wav")))
        #expect(throws: (any Error).self) { try AudioTimelineFileDropPayload.validate([file, web]) }
        let promise = NSItemProvider()
        promise.registerFileRepresentation(forTypeIdentifier: UTType.audio.identifier,
            fileOptions: [], visibility: .all) { _ in
                counter.increment()
                return nil
            }
        #expect(throws: (any Error).self) { try AudioTimelineFileDropPayload.validate([promise]) }
        #expect(counter.value == 0)
    }

    @Test func sessionInventoryRequiresFreshActiveMatchingMetadata() throws {
        var metadata = AudioTimelineDropSessionMetadata<UUID>()
        let first = UUID(), second = UUID(), third = UUID()
        metadata.updated(id: first, phase: .active, itemCount: 2)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.entered()
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.updated(id: first, phase: .entering, itemCount: 2)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.updated(id: first, phase: .active, itemCount: 2)
        #expect(try metadata.consumeCount() == 2)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.entered()
        metadata.updated(id: first, phase: .ended, itemCount: 2)
        metadata.updated(id: first, phase: .active, itemCount: 2)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.updated(id: second, phase: .active, itemCount: 3)
        #expect(try metadata.consumeCount() == 3)
        metadata.entered()
        metadata.updated(id: third, phase: .active, itemCount: 1)
        metadata.exited()
        metadata.entered()
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.updated(id: third, phase: .active, itemCount: 1)
        #expect(try metadata.consumeCount() == 1)
        metadata.entered()
        metadata.updated(id: UUID(), phase: .active, itemCount: 1)
        metadata.updated(id: UUID(), phase: .active, itemCount: 1)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
        metadata.entered()
        metadata.updated(id: UUID(), phase: .active, itemCount: 0)
        #expect(throws: (any Error).self) { try metadata.consumeCount() }
    }
}

private final class DropProviderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
