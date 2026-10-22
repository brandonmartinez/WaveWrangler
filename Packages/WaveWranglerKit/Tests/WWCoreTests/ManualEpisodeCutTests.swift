import Foundation
import Testing
import WWCore

@Suite("Manual shared ripple timeline")
struct ManualEpisodeCutTests {
    private func cut(_ start: Int64, _ end: Int64) -> ManualEpisodeCut {
        ManualEpisodeCut(alignmentRevision: 1, startFrame: start, endFrame: end)
    }

    @Test func seamsUseFollowingAudioAndEveryTrackReceivesIdenticalRanges() throws {
        let map = try ManualCutTimeline(cuts: [cut(48_000, 96_000), cut(192_000, 216_000)])
        #expect(map.editedFrame(forAlignedFrame: 48_000) == 48_000)
        #expect(map.editedFrame(forAlignedFrame: 72_000) == 48_000)
        #expect(map.editedFrame(forAlignedFrame: 96_000) == 48_000)
        #expect(map.alignedFrame(forEditedFrame: 48_000) == 96_000)
        #expect(map.editedFrame(forAlignedFrame: 216_000) == 144_000)
        let ranges = map.alignedRanges(forEditedFrames: 24_000..<168_000)
        #expect(ranges == [24_000..<48_000, 96_000..<192_000, 216_000..<240_000])
        #expect(ranges.reduce(0) { $0 + $1.count } == 144_000)
        #expect(map.alignedRanges(forEditedFrames: 48_000..<48_001) == [96_000..<96_001])
        #expect(map.alignedRanges(forEditedFrames: 0..<48_000) == [0..<48_000])
        #expect(map.alignedRanges(forEditedFrames: 144_000..<144_000).isEmpty)
        for frame in stride(from: Int64(-48_000), through: 300_000, by: 137) {
            #expect(map.editedFrame(forAlignedFrame: map.alignedFrame(forEditedFrame: frame)) == frame)
        }
    }

    @Test func overlappingAndAdjacentCutsRemoveTheirUnionOnlyOnce() throws {
        let cuts = [cut(20, 40), cut(10, 30), cut(40, 50), cut(60, 70)]
        let map = try ManualCutTimeline(cuts: cuts)
        #expect(map.removals == [10..<50, 60..<70])
        #expect(map.alignedRanges(forEditedFrames: 0..<40) == [0..<10, 50..<60, 70..<90])
        let restored = try ManualCutTimeline(cuts: Array(cuts.dropFirst()))
        #expect(restored.removals == [10..<30, 40..<50, 60..<70])
    }

    @Test func revealingOneCutKeepsOtherAndOverlappingRemovalsWithoutChangingSavedRecords() throws {
        let selected = cut(10, 30), overlap = cut(20, 40), later = cut(60, 70)
        var episode = Episode(title: "Synthetic")
        episode.alignment = EpisodeAlignment(acceptedRevision: 1)
        episode.cleanup = EpisodeCleanup(manualCuts: [selected, overlap, later])
        let original = episode
        #expect(try episode.manualCutTimeline().removals == [10..<40, 60..<70])
        #expect(try episode.manualCutTimeline(revealing: selected.id).removals == [20..<40, 60..<70])
        #expect(try episode.manualCutTimeline(revealing: UUID()).removals == [10..<40, 60..<70])
        #expect(episode == original, "Review is a presentation prescription, not restoration of saved edits")
    }

    @Test func signedTimeAndSubframePresentationDoNotMoveOriginalCoordinates() throws {
        let map = try ManualCutTimeline(cuts: [cut(-96_000, -48_000), cut(48_000, 96_000)])
        #expect(map.editedTime(forAlignedTime: -3) == -3)
        #expect(map.editedTime(forAlignedTime: -1) == -2)
        #expect(map.editedTime(forAlignedTime: 2.125) == 0.125)
        #expect(map.alignedTime(forEditedTime: 0) == 2)
        #expect(map.alignedRanges(forEditedFrames: -144_000..<48_000)
            == [-144_000..<(-96_000), -48_000..<48_000, 96_000..<144_000])
        #expect(map.keptAlignedRanges(in: 1.1...1.9).isEmpty)
        #expect(map.keptAlignedRanges(in: 0...3) == [0...1, 2...3])
    }

    @Test func invalidCutsAndDuplicateIDsCannotBecomeCanonicalCleanup() throws {
        for invalid in [cut(0, 0), cut(2, 1), cut(-ManualEpisodeCut.frameLimit - 1, 0),
                        cut(0, ManualEpisodeCut.frameLimit + 1),
                        ManualEpisodeCut(alignmentRevision: 0, startFrame: 0, endFrame: 1)] {
            #expect(!invalid.isValid)
            #expect(!EpisodeCleanup(manualCuts: [invalid]).isValid)
            #expect(throws: DomainError.invalidCleanup) { try ManualCutTimeline(cuts: [invalid]) }
        }
        let removal = cut(1, 2)
        #expect(!EpisodeCleanup(manualCuts: [removal, removal]).isValid)
    }

    @Test func originalMarkersAndTranscriptsSurviveCutSaveAndRestoration() throws {
        let marker = UUID()
        let removal = ManualEpisodeCut(markerID: marker, alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000)
        let episode = Episode(title: "Original", sources: [SourceRecord(displayNameHint: "Immutable.wav")])
        let original = ShowDocumentModel(show: Show(title: "Show"), episodes: [episode])
        let edited = try original.settingCleanup(EpisodeCleanup(manualCuts: [removal]), in: episode.id)
        #expect(edited.episodes[0].sources == original.episodes[0].sources)
        #expect(edited.episodes[0].alignment == original.episodes[0].alignment)
        #expect(edited.episodes[0].activeManualCuts.isEmpty, "A cut never invents accepted timing")
        #expect(edited.episodes[0].cleanup?.manualCuts?.first?.markerID == marker)
        #expect(try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(edited)) == edited)
        #expect(try edited.settingCleanup(nil, in: episode.id) == original)
    }
}
