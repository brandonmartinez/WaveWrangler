import Foundation
import Testing
import WWCore
import WWTimeMap

@testable import WWCommonEdit

@Suite("Pure program-time composition")
struct ProgramTimelineTests {
    private let rate: Int64 = 48_000

    @Test func dialogueCutsRippleStartsOnlyAndNeverAlterClipAudio() throws {
        let f = try ProgramFixture()
        let removal = f.cut(20 * rate, 30 * rate)
        let spanning = try f.clip(.dialogue(f.anchor(15 * rate)), duration: 25 * rate)
        let later = try f.clip(.dialogue(f.anchor(35 * rate)))
        let pinned = f.clip(.absolute(frame: 35 * rate))
        let interior = try f.clip(.dialogue(f.anchor(25 * rate)))
        let episode = f.episode(cuts: [removal], clips: [spanning, later, pinned, interior])
        let snapshot = episode
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        let result = try timeline.composition()
        #expect(result.clips.map(\.programFrames.lowerBound) == [15, 25, 35, 20].map { $0 * rate })
        #expect(result.clips[0].programFrames == (15 * rate)..<(40 * rate))
        #expect(result.clips.map(\.clip) == [spanning, later, pinned, interior])
        #expect(result.clips[3].placement == .clampedToCutSeam(frame: 20 * rate, removed: (20 * rate)..<(30 * rate)))
        #expect(try timeline.dialoguePosition(atAlignedFrame: 20 * rate - 1) == .mapped(frame: 20 * rate - 1))
        #expect(
            try timeline.dialoguePosition(atAlignedFrame: 20 * rate)
                == .removed(interval: (20 * rate)..<(30 * rate), seam: 20 * rate))
        #expect(try timeline.dialoguePosition(atAlignedFrame: 30 * rate) == .mapped(frame: 20 * rate))
        #expect(try timeline.inverse(atProgramFrame: 20 * rate) == .dialogue(frame: 30 * rate))
        #expect(try timeline.dialoguePosition(atAlignedFrame: f.coverage.upperBound) == .outsideCoverage)
        #expect(episode == snapshot)
        #expect(result.timeline.cuts.removals == [(20 * rate)..<(30 * rate)])
    }

    @Test func overlappingAdjacentRestoredAndResizedCutsRecomputeFromOriginalAnchors() throws {
        let f = try ProgramFixture()
        let clip = try f.clip(.dialogue(f.anchor(60)))
        let cuts = [f.cut(20, 30), f.cut(10, 25), f.cut(30, 40), f.cut(45, 50)]
        for (edits, expected): ([ManualEpisodeCut], Int64) in [
            (cuts, 25), (Array(cuts.dropFirst()), 30), ([], 60),
            ([f.cut(10, 50)], 20), ([f.cut(55, 65)], 55), (cuts, 25),
        ] {
            let timeline = try ProgramTimeline(
                episode: f.episode(cuts: edits, clips: [clip]), dialogueFrames: f.coverage)
            #expect(try timeline.composition().clips[0].programFrames.lowerBound == expected)
            #expect(timeline.arrangement.clips == [clip])
        }
    }

    @Test func introAndSameBoundaryRegionsHaveStableOrderAndNoSpeakerInverse() throws {
        let f = try ProgramFixture()
        let first = try AudioInsertionRegion(anchor: .dialogue(f.anchor(0)), durationFrames: 10)
        let second = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 5)
        let atBoundary = try f.clip(.dialogue(f.anchor(0)))
        let origin = f.clip(.programOrigin(frame: 0))
        let pin = f.clip(.absolute(frame: 0))
        let regional = f.clip(.insertion(region: second.id, offsetFrames: 2), duration: 30)
        let episode = f.episode(clips: [atBoundary, origin, pin, regional], regions: [first, second])
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        #expect(timeline.insertions.map(\.programFrames) == [0..<10, 10..<15])
        #expect(timeline.insertions.map(\.region.id) == [first.id, second.id])
        #expect(try timeline.composition().clips.map(\.programFrames.lowerBound) == [15, 15, 0, 12])
        for frame: Int64 in 0..<15 {
            let id = frame < 10 ? first.id : second.id
            let offset = frame < 10 ? frame : frame - 10
            #expect(try timeline.inverse(atProgramFrame: frame) == .insertion(region: id, offsetFrames: offset))
        }
        #expect(try timeline.inverse(atProgramFrame: 15) == .dialogue(frame: 0))
        #expect(try timeline.dialoguePosition(atAlignedFrame: 0) == .mapped(frame: 15))
        #expect(try timeline.project(regional.anchor) == .placed(frame: 12))
        var reordered = episode
        reordered.audioArrangement?.insertionRegions.reverse()
        let reverse = try ProgramTimeline(episode: reordered, dialogueFrames: f.coverage)
        #expect(reverse.insertions.map(\.region.id) == [second.id, first.id])
        #expect(reverse.insertions.map(\.programFrames) == [0..<5, 5..<15])
        #expect(try reverse.project(regional.anchor) == .placed(frame: 2))
        #expect(episode.audioArrangement?.insertionRegions == [first, second])
    }

    @Test func insertionSeamAffinityDoesNotSplitSpanningClipsAndCutInteriorRegionsClamp() throws {
        let f = try ProgramFixture()
        let before = try f.clip(.dialogue(f.anchor(5)), duration: 40)
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(25)), durationFrames: 10)
        let follow = try f.clip(.dialogue(f.anchor(35)))
        let inCut = try f.clip(.dialogue(f.anchor(29)))
        let relative = f.clip(.insertion(region: region.id, offsetFrames: 7))
        for (cuts, regionStart, followStart): ([ManualEpisodeCut], Int64, Int64) in [
            ([f.cut(20, 30)], 20, 35), ([f.cut(10, 30)], 10, 25), ([], 25, 45),
        ] {
            let timeline = try ProgramTimeline(
                episode: f.episode(
                    cuts: cuts,
                    clips: [before, follow, inCut, relative], regions: [region]), dialogueFrames: f.coverage)
            let composition = try timeline.composition()
            #expect(timeline.insertions[0].programFrames.lowerBound == regionStart)
            #expect(composition.clips[0].programFrames == 5..<45)
            #expect(composition.clips[0].clip == before)
            #expect(composition.clips[1].programFrames.lowerBound == followStart)
            #expect(composition.clips[3].programFrames.lowerBound == regionStart + 7)
            if !cuts.isEmpty {
                #expect(
                    try timeline.project(inCut.anchor)
                        == .clampedToCutSeam(frame: regionStart + 10, removed: cuts[0].startFrame..<cuts[0].endFrame))
            }
        }
    }

    @Test func programOriginIsCutIndependentAndLaterReconciliationPreservesTheCurrentPosition() throws {
        let f = try ProgramFixture()
        let intro = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 10)
        let clip = f.clip(.programOrigin(frame: 35))
        var episode = f.episode(clips: [clip], regions: [intro])
        episode.alignment = nil
        let audioOnly = try ProgramTimeline(episode: episode)
        #expect(try audioOnly.composition().clips[0].programFrames.lowerBound == 45)
        #expect(try audioOnly.inverse(atProgramFrame: 45) == .outsideCoverage)
        #expect(try audioOnly.reconciledAnchor(for: clip.anchor) == clip.anchor)
        episode.alignment = .init(maps: [f.version], acceptedRevision: 1)
        episode.cleanup?.manualCuts = [f.cut(20, 30)]
        let admitted = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        #expect(try admitted.project(clip.anchor) == .placed(frame: 45))
        let reconciled = try admitted.reconciledAnchor(for: clip.anchor)
        #expect(reconciled == .dialogue(try f.anchor(45)))
        #expect(try admitted.project(reconciled) == .placed(frame: 45))
        #expect(episode.audioArrangement?.clips[0].anchor == clip.anchor)
        #expect(try admitted.pinnedAnchor(for: reconciled) == .absolute(frame: 45))
        #expect(try admitted.unpinnedAnchor(for: .absolute(frame: 45)) == reconciled)
    }

    @Test func newPlacementsInverseAnchorCurrentCutsAndInsertionInteriorsWithoutDoubleRipple() throws {
        let f = try ProgramFixture()
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(0)), durationFrames: 10)
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [f.cut(20, 30)], regions: [region]),
            dialogueFrames: f.coverage)
        for frame: Int64 in [-5, 0, 9, 10, 29, 30, 35, 100, f.coverage.upperBound + 100] {
            let anchor = try timeline.unpinnedAnchor(atProgramFrame: frame)
            #expect(try timeline.project(anchor) == .placed(frame: frame))
            #expect(try timeline.unpinnedAnchor(for: .absolute(frame: frame)) == anchor)
            #expect(try timeline.pinnedAnchor(for: anchor) == .absolute(frame: frame))
        }
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 35) == .dialogue(f.anchor(35)))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 5) == .insertion(region: region.id, offsetFrames: 5))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 30) == .dialogue(f.anchor(30)))
        let end = f.coverage.upperBound
        #expect(try timeline.unpinnedAnchor(atProgramFrame: end) == .dialogue(f.anchor(end)))
        #expect(try timeline.inverse(atProgramFrame: end) == .outsideCoverage)
    }

    @Test func unpinnedOutroBeyondDialogueCoverageRipplesButPinnedOutroAndSampleCoverageDoNot() throws {
        let f = try ProgramFixture()
        let coverage = Int64(0)..<(10 * rate)
        let original = try ProgramTimeline(episode: f.episode(), dialogueFrames: coverage)
        let anchor = try original.unpinnedAnchor(atProgramFrame: 12 * rate)
        #expect(anchor == .dialogue(try f.anchor(12 * rate)))
        let outro = f.clip(anchor, duration: rate)
        let pinned = f.clip(.absolute(frame: 12 * rate), duration: rate)
        for (cuts, expected): ([ManualEpisodeCut], Int64) in [
            ([f.cut(2 * rate, 4 * rate)], 10 * rate),
            ([f.cut(2 * rate, 5 * rate)], 9 * rate),
            ([], 12 * rate),
            ([f.cut(2 * rate, 4 * rate)], 10 * rate),
        ] {
            let episode = f.episode(cuts: cuts, clips: [outro, pinned])
            let snapshot = episode
            let timeline = try ProgramTimeline(episode: episode, dialogueFrames: coverage)
            let composition = try timeline.composition()
            #expect(composition.clips.map(\.programFrames.lowerBound) == [expected, 12 * rate])
            #expect(composition.clips.map(\.clip) == [outro, pinned])
            #expect(composition.programFrames == 0..<(13 * rate))
            #expect(try timeline.dialoguePosition(atAlignedFrame: 12 * rate) == .outsideCoverage)
            #expect(try timeline.inverse(atProgramFrame: expected) == .outsideCoverage)
            #expect(
                try timeline.segments(in: expected..<(expected + rate))
                    == [.outsideDialogueCoverage(expected..<(expected + rate))])
            #expect(episode == snapshot)
            #expect(episode.alignment?.acceptedMap == f.version)
        }
    }

    @Test func outroPlacedAfterExistingCutsInverseAnchorsOnceAcrossUnpinReconcileAndRestore() throws {
        let f = try ProgramFixture()
        let coverage = Int64(0)..<(10 * rate)
        let cut = f.cut(2 * rate, 4 * rate)
        let origin = AudioPlacementAnchor.programOrigin(frame: 12 * rate)
        let pinned = AudioPlacementAnchor.absolute(frame: 12 * rate)
        let current = try ProgramTimeline(episode: f.episode(cuts: [cut]), dialogueFrames: coverage)
        let placed = try current.unpinnedAnchor(atProgramFrame: 12 * rate)
        #expect(placed == .dialogue(try f.anchor(14 * rate)))
        #expect(try current.unpinnedAnchor(for: pinned) == placed)
        #expect(try current.reconciledAnchor(for: origin) == placed)
        #expect(try current.pinnedAnchor(for: placed) == pinned)
        #expect(try current.reconciledAnchor(for: pinned) == pinned)
        for (cuts, expected): ([ManualEpisodeCut], Int64) in [
            ([cut], 12 * rate),
            ([cut, f.cut(6 * rate, 7 * rate)], 11 * rate),
            ([], 14 * rate),
            ([cut], 12 * rate),
        ] {
            let timeline = try ProgramTimeline(episode: f.episode(cuts: cuts), dialogueFrames: coverage)
            #expect(try timeline.project(placed) == .placed(frame: expected))
            #expect(try timeline.project(origin) == .placed(frame: 12 * rate))
            #expect(try timeline.project(pinned) == .placed(frame: 12 * rate))
            #expect(try timeline.unpinnedAnchor(atProgramFrame: expected) == placed)
            #expect(try timeline.inverse(atProgramFrame: expected) == .outsideCoverage)
        }
        #expect(try JSONDecoder().decode(AudioPlacementAnchor.self, from: JSONEncoder().encode(placed)) == placed)
    }

    @Test func signedPlacementBeforeDialogueStartFollowsInsertionsButNotLaterCuts() throws {
        let f = try ProgramFixture()
        let coverage = Int64(-2 * rate)..<(10 * rate)
        let base = try ProgramTimeline(episode: f.episode(), dialogueFrames: coverage)
        let before = try base.unpinnedAnchor(atProgramFrame: -3 * rate)
        #expect(before == .dialogue(try f.anchor(-3 * rate)))
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(-4 * rate)), durationFrames: rate)
        let clip = f.clip(before, duration: rate / 2)
        let pin = f.clip(.absolute(frame: -3 * rate), duration: rate / 2)
        for cuts in [[], [f.cut(2 * rate, 4 * rate)]] {
            let episode = f.episode(cuts: cuts, clips: [clip, pin], regions: [region])
            #expect(episode.audioArrangement?.validationIssues(in: episode).isEmpty == true)
            let timeline = try ProgramTimeline(episode: episode, dialogueFrames: coverage)
            #expect(try timeline.composition().clips.map(\.programFrames.lowerBound) == [-2 * rate, -3 * rate])
            #expect(try timeline.unpinnedAnchor(atProgramFrame: -2 * rate) == before)
            #expect(try timeline.unpinnedAnchor(for: .absolute(frame: -2 * rate)) == before)
            #expect(try timeline.pinnedAnchor(for: before) == .absolute(frame: -2 * rate))
            #expect(try timeline.dialoguePosition(atAlignedFrame: -3 * rate) == .outsideCoverage)
            #expect(try timeline.inverse(atProgramFrame: -2 * rate) == .outsideCoverage)
            #expect(
                try timeline.segments(in: (-2 * rate)..<(-rate)) == [.outsideDialogueCoverage((-2 * rate)..<(-rate))])
        }
        #expect(try base.project(before) == .placed(frame: -3 * rate))
    }

    @Test func insertionBeyondDialogueEndAndLaterPlacementsFollowCutsWithoutCreatingDialogue() throws {
        let f = try ProgramFixture()
        let coverage = Int64(0)..<(10 * rate)
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(12 * rate)), durationFrames: rate)
        let original = try ProgramTimeline(episode: f.episode(regions: [region]), dialogueFrames: coverage)
        let later = try original.unpinnedAnchor(atProgramFrame: 14 * rate)
        #expect(later == .dialogue(try f.anchor(13 * rate)))
        #expect(try original.unpinnedAnchor(atProgramFrame: 13 * rate) == region.anchor)
        let relative = try original.unpinnedAnchor(atProgramFrame: 12 * rate + rate / 2)
        #expect(relative == .insertion(region: region.id, offsetFrames: rate / 2))
        let cut = f.cut(2 * rate, 4 * rate)
        for (cuts, start): ([ManualEpisodeCut], Int64) in [
            ([cut], 10 * rate), ([], 12 * rate), ([cut], 10 * rate),
        ] {
            let episode = f.episode(
                cuts: cuts,
                clips: [f.clip(later), f.clip(relative), f.clip(.absolute(frame: 14 * rate))], regions: [region])
            #expect(episode.audioArrangement?.validationIssues(in: episode).isEmpty == true)
            let timeline = try ProgramTimeline(episode: episode, dialogueFrames: coverage)
            #expect(timeline.insertions[0].programFrames == start..<(start + rate))
            #expect(
                try timeline.composition().clips.map(\.programFrames.lowerBound)
                    == [start + 2 * rate, start + rate / 2, 14 * rate])
            #expect(try timeline.unpinnedAnchor(atProgramFrame: start + 2 * rate) == later)
            #expect(try timeline.unpinnedAnchor(atProgramFrame: start + rate) == region.anchor)
            #expect(try timeline.unpinnedAnchor(atProgramFrame: start + rate / 2) == relative)
            #expect(try timeline.inverse(atProgramFrame: start) == .insertion(region: region.id, offsetFrames: 0))
            #expect(try timeline.inverse(atProgramFrame: start + rate) == .outsideCoverage)
            #expect(try timeline.dialoguePosition(atAlignedFrame: 12 * rate) == .outsideCoverage)
            #expect(
                try timeline.segments(in: start..<(start + 2 * rate)) == [
                    .insertion(region: region.id, offsetFrames: 0, programFrames: start..<(start + rate)),
                    .outsideDialogueCoverage((start + rate)..<(start + 2 * rate)),
                ])
        }
    }

    @Test func audioOnlyOutlyingOriginsRemainUnboundUntilExplicitPositionPreservingReconciliation() throws {
        let f = try ProgramFixture()
        let intro = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: rate)
        var episode = f.episode(regions: [intro])
        episode.alignment = nil
        let audioOnly = try ProgramTimeline(episode: episode)
        let origin = try audioOnly.unpinnedAnchor(atProgramFrame: 13 * rate)
        #expect(origin == .programOrigin(frame: 12 * rate))
        #expect(try audioOnly.unpinnedAnchor(atProgramFrame: -rate) == .programOrigin(frame: -rate))
        #expect(try audioOnly.unpinnedAnchor(for: .absolute(frame: 13 * rate)) == origin)
        #expect(try audioOnly.reconciledAnchor(for: origin) == origin)
        episode.alignment = .init(maps: [f.version], acceptedRevision: 1)
        episode.cleanup?.manualCuts = [f.cut(2 * rate, 4 * rate)]
        let coverage = Int64(0)..<(10 * rate)
        let admitted = try ProgramTimeline(episode: episode, dialogueFrames: coverage)
        #expect(try admitted.project(origin) == .placed(frame: 13 * rate))
        let reconciled = try admitted.reconciledAnchor(for: origin)
        #expect(reconciled == .dialogue(try f.anchor(14 * rate)))
        #expect(try admitted.project(reconciled) == .placed(frame: 13 * rate))
        #expect(try admitted.unpinnedAnchor(for: .absolute(frame: 13 * rate)) == reconciled)
        episode.cleanup?.manualCuts?.append(f.cut(6 * rate, 7 * rate))
        let changed = try ProgramTimeline(episode: episode, dialogueFrames: coverage)
        #expect(try changed.project(reconciled) == .placed(frame: 12 * rate))
        #expect(try changed.project(origin) == .placed(frame: 13 * rate))
        #expect(try changed.inverse(atProgramFrame: 12 * rate) == .outsideCoverage)
    }

    @Test func outsideCoverageBindingStillRefusesStaleBytesAndOutOfBoundsGridPositions() throws {
        let f = try ProgramFixture()
        let coverage = Int64(0)..<(10 * rate)
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [f.cut(2 * rate, 4 * rate)]), dialogueFrames: coverage)
        let limit = AudioArrangement.frameLimit
        #expect(try timeline.unpinnedAnchor(atProgramFrame: limit - 2 * rate) == .dialogue(f.anchor(limit)))
        #expect(try timeline.project(.dialogue(f.anchor(limit))) == .placed(frame: limit - 2 * rate))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: -limit) == .dialogue(f.anchor(-limit)))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 120 * rate) == .dialogue(f.anchor(122 * rate)))
        #expect(try timeline.dialoguePosition(atAlignedFrame: 122 * rate) == .outsideCoverage)
        #expect(try timeline.inverse(atProgramFrame: 120 * rate) == .outsideCoverage)
        let accepted = try JSONDecoder().decode(AlignedTimelineMap.self, from: JSONEncoder().encode(f.version.map))
        #expect(try accepted.sourceFrame(at: ExactRational(122), in: accepted.reference.occurrence) == .outsideCoverage)
        #expect(throws: ProgramTimelineError.outsideFrameEnvelope(limit + 2 * rate)) {
            try timeline.unpinnedAnchor(atProgramFrame: limit)
        }
        #expect(throws: ProgramTimelineError.outsideFrameEnvelope(limit + 2 * rate)) {
            try timeline.unpinnedAnchor(for: .absolute(frame: limit))
        }
        #expect(throws: ProgramTimelineError.outsideFrameEnvelope(limit + 2 * rate)) {
            try timeline.reconciledAnchor(for: .programOrigin(frame: limit))
        }
        for frame: Int64 in [.min, .max, -limit - 1, limit + 1] {
            #expect(throws: ProgramTimelineError.outsideFrameEnvelope(frame)) {
                try timeline.project(.dialogue(f.anchor(frame)))
            }
        }
        let anchor = try timeline.unpinnedAnchor(atProgramFrame: 12 * rate)
        guard case .dialogue(let bound) = anchor else {
            Issue.record("An outside-coverage placement must retain its accepted-map binding")
            return
        }
        let clip = f.clip(anchor)
        var replaced = f.episode(clips: [clip])
        replaced.alignment?.maps[0].inputs.recipe = .init(name: "Same revision, changed map bytes", revision: 1)
        let stale = try ProgramTimeline(episode: replaced, dialogueFrames: coverage)
        #expect(try stale.project(anchor) == .reviewRequired(bound))
        #expect(throws: ProgramTimelineError.clipRequiresReview(clip.id, bound)) {
            try stale.composition()
        }
        #expect(throws: ProgramTimelineError.placementRequiresReview(bound)) { try stale.unpinnedAnchor(for: anchor) }
        #expect(throws: ProgramTimelineError.placementRequiresReview(bound)) { try stale.pinnedAnchor(for: anchor) }
    }

    @Test func staleSameRevisionDifferentMapNeverReinterpretsAnAnchorOrOmitsItFromBounds() throws {
        let f = try ProgramFixture()
        let anchor = try f.anchor(35)
        let clip = f.clip(.dialogue(anchor))
        var episode = f.episode(clips: [clip])
        episode.alignment?.maps[0].inputs.recipe = .init(name: "Different accepted bytes", revision: 1)
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        #expect(try timeline.project(clip.anchor) == .reviewRequired(anchor))
        #expect(throws: ProgramTimelineError.clipRequiresReview(clip.id, anchor)) { try timeline.composition() }
        #expect(throws: ProgramTimelineError.placementRequiresReview(anchor)) {
            try timeline.pinnedAnchor(for: clip.anchor)
        }
        let region = AudioInsertionRegion(anchor: .dialogue(anchor), durationFrames: 10)
        episode.audioArrangement?.clips = []
        episode.audioArrangement?.insertionRegions = [region]
        #expect(throws: ProgramTimelineError.regionRequiresReview(region.id, anchor)) {
            try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        }
        episode.alignment?.acceptedRevision = nil
        episode.audioArrangement?.insertionRegions = []
        let unaccepted = try ProgramTimeline(episode: episode)
        #expect(try unaccepted.project(clip.anchor) == .reviewRequired(anchor))
        #expect(try unaccepted.unpinnedAnchor(atProgramFrame: 12 * rate) == .programOrigin(frame: 12 * rate))
        #expect(
            try unaccepted.reconciledAnchor(for: .programOrigin(frame: 12 * rate)) == .programOrigin(frame: 12 * rate))
        #expect(try anchor.isCurrent(in: episode) == false)
    }

    @Test func audioOnlyBoundsUseAllClipsRegionsAndNativeDurationRoundingWithoutMixOrVisibility() throws {
        let f = try ProgramFixture()
        var episode = f.episode()
        episode.alignment = nil
        let region = AudioInsertionRegion(anchor: .programOrigin(frame: -10), durationFrames: 5)
        let origin = f.clip(.programOrigin(frame: 0), duration: 100)
        let pin = f.clip(.absolute(frame: 200), duration: 50)
        episode.audioArrangement?.clips = [origin, pin]
        episode.audioArrangement?.insertionRegions = [region]
        let timeline = try ProgramTimeline(episode: episode)
        #expect(try timeline.composition().programFrames == -10..<250)
        #expect(try timeline.composition().clips.map(\.programFrames) == [5..<105, 200..<250])
        episode.mix = .init(audioTracks: [.init(track: f.track.id, gainDB: -96)])
        #expect(try ProgramTimeline(episode: episode).composition() == timeline.composition())
        episode.audioArrangement?.clips = []
        #expect(try ProgramTimeline(episode: episode).composition().programFrames == -10..<(-5))
        episode.audioArrangement?.insertionRegions = []
        #expect(try ProgramTimeline(episode: episode).composition().programFrames == nil)
    }

    @Test(arguments: [8_000, 44_100, 48_000, 88_200, 192_000])
    func fractionalRateNativeCoverageAndRepeatedSourceUsesStaySeparate(_ nativeRate: Int) throws {
        let f = try ProgramFixture()
        let asset = AudioAsset(source: f.asset.source, frameCount: 1_000, sampleRate: nativeRate, channelCount: 2)
        let a = AudioClip(
            track: f.track.id, source: asset.source, trim: .init(startFrame: 3, endFrame: 104),
            anchor: .programOrigin(frame: -20))
        let b = AudioClip(
            track: f.track.id, source: asset.source, trim: .init(startFrame: 11, endFrame: 112),
            channels: [1, 0], anchor: .absolute(frame: 100))
        var episode = f.episode(clips: [a, b])
        episode.alignment = nil
        episode.audioArrangement?.assets = [asset]
        let result = try ProgramTimeline(episode: episode).composition()
        let duration = (101 * rate + Int64(nativeRate) - 1) / Int64(nativeRate)
        #expect(result.clips.map { $0.programFrames.upperBound - $0.programFrames.lowerBound } == [duration, duration])
        #expect(result.clips.map(\.sourceChannels) == [[0, 1], [1, 0]])
        #expect(result.clips.map(\.clip.id) == [a.id, b.id])
        for placed in result.clips {
            for local in Int64(0)..<duration {
                let expected = try ExactRational(placed.clip.trim.startFrame)
                    .adding(
                        ExactRational(local).multiplied(by: ExactRational(Int64(nativeRate))).divided(
                            by: ExactRational(rate)))
                #expect(
                    try placed.sourcePosition(atProgramFrame: placed.programFrames.lowerBound + local)
                        == .source(localFrame: local, nativeFrame: expected))
                #expect(expected < ExactRational(placed.clip.trim.endFrame))
            }
            #expect(try placed.sourcePosition(atProgramFrame: placed.programFrames.upperBound) == .outsideCoverage)
            #expect(try placed.sourcePosition(atProgramFrame: placed.programFrames.lowerBound - 1) == .outsideCoverage)
        }
    }

    @Test func signedDialogueAndCutSeamsRoundTripWithoutRebasingToZero() throws {
        let f = try ProgramFixture()
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(-15)), durationFrames: 3)
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [f.cut(-10, -5), f.cut(5, 10)], regions: [region]),
            dialogueFrames: -20..<20)
        #expect(timeline.dialogueSpans.map(\.programFrames) == [-20..<(-15), -12..<(-7), -7..<3, 3..<13])
        #expect(try timeline.inverse(atProgramFrame: -15) == .insertion(region: region.id, offsetFrames: 0))
        #expect(try timeline.inverse(atProgramFrame: -7) == .dialogue(frame: -5))
        #expect(try timeline.inverse(atProgramFrame: 3) == .dialogue(frame: 10))
        for span in timeline.dialogueSpans {
            for frame in span.originalFrames {
                guard case .mapped(let program) = try timeline.dialoguePosition(atAlignedFrame: frame) else {
                    Issue.record("Kept aligned frame was not mapped")
                    continue
                }
                #expect(try timeline.inverse(atProgramFrame: program) == .dialogue(frame: frame))
            }
        }
    }

    @Test func requestPartitionsContainOnlyKeptDialogueInsertionSpaceAndExplicitOutsideCoverage() throws {
        let f = try ProgramFixture()
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(5)), durationFrames: 3)
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [f.cut(10, 15)], regions: [region]),
            dialogueFrames: 0..<20)
        let expected: [ProgramTimelineSegment] = [
            .outsideDialogueCoverage(-2..<0),
            .dialogue(.init(originalFrames: 0..<5, programFrames: 0..<5)),
            .insertion(region: region.id, offsetFrames: 0, programFrames: 5..<8),
            .dialogue(.init(originalFrames: 5..<10, programFrames: 8..<13)),
            .dialogue(.init(originalFrames: 15..<20, programFrames: 13..<18)),
            .outsideDialogueCoverage(18..<20),
        ]
        #expect(try timeline.segments(in: -2..<20) == expected)
        #expect(
            try timeline.segments(in: 6..<10) == [
                .insertion(region: region.id, offsetFrames: 1, programFrames: 6..<8),
                .dialogue(.init(originalFrames: 5..<7, programFrames: 8..<10)),
            ])
        #expect(try timeline.segments(in: 5..<5).isEmpty)
    }

    @Test func allRemovedDialogueAndTerminalInsertionsHaveNoInventedSamples() throws {
        let f = try ProgramFixture()
        let tail = try AudioInsertionRegion(anchor: .dialogue(f.anchor(20)), durationFrames: 7)
        let clip = try f.clip(.dialogue(f.anchor(20)))
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [f.cut(0, 20)], clips: [clip], regions: [tail]),
            dialogueFrames: 0..<20)
        #expect(timeline.dialogueSpans.isEmpty)
        #expect(try timeline.inverse(atProgramFrame: 0) == .insertion(region: tail.id, offsetFrames: 0))
        #expect(try timeline.inverse(atProgramFrame: 7) == .outsideCoverage)
        #expect(try timeline.project(clip.anchor) == .placed(frame: 7))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 7) == clip.anchor)
        #expect(try timeline.composition().programFrames == 0..<107)
        #expect(try timeline.dialoguePosition(atAlignedFrame: 0) == .removed(interval: 0..<20, seam: 7))
    }

    @Test func absoluteInsertionRegionsAreExplicitlyUnsupportedButPinnedClipsAreNot() throws {
        let f = try ProgramFixture()
        let region = AudioInsertionRegion(anchor: .absolute(frame: 10), durationFrames: 3)
        #expect(throws: ProgramTimelineError.unsupportedAbsoluteInsertion(region.id)) {
            try ProgramTimeline(episode: f.episode(regions: [region]), dialogueFrames: f.coverage)
        }
        let clip = f.clip(.absolute(frame: 10))
        #expect(
            try ProgramTimeline(episode: f.episode(clips: [clip]), dialogueFrames: f.coverage)
                .composition().clips[0].programFrames == 10..<110)
    }

    @Test func boundsIncludeClipOverhangsAndOutlyingInsertionsWithoutExtendingDialogueCoverage() throws {
        let f = try ProgramFixture()
        let early = f.clip(.absolute(frame: -50), duration: 25)
        let late = f.clip(.absolute(frame: 100), duration: 30)
        let region = AudioInsertionRegion(anchor: .programOrigin(frame: 80), durationFrames: 5)
        let timeline = try ProgramTimeline(
            episode: f.episode(clips: [early, late], regions: [region]),
            dialogueFrames: 0..<20)
        #expect(try timeline.composition().programFrames == -50..<130)
        #expect(try timeline.inverse(atProgramFrame: -50) == .outsideCoverage)
        #expect(try timeline.inverse(atProgramFrame: 20) == .outsideCoverage)
        #expect(try timeline.inverse(atProgramFrame: 80) == .insertion(region: region.id, offsetFrames: 0))
        #expect(try timeline.inverse(atProgramFrame: 100) == .outsideCoverage)
        #expect(try timeline.project(early.anchor) == .placed(frame: -50))
        #expect(try timeline.project(late.anchor) == .placed(frame: 100))
        #expect(try timeline.unpinnedAnchor(atProgramFrame: 100) == .dialogue(f.anchor(95)))
    }

    @Test func mergedCutInteriorRegionBoundariesUseSavedOrderAndExclusiveCutEndIsRetained() throws {
        let f = try ProgramFixture()
        let laterOriginal = try AudioInsertionRegion(anchor: .dialogue(f.anchor(30)), durationFrames: 4)
        let insideOriginal = try AudioInsertionRegion(anchor: .dialogue(f.anchor(25)), durationFrames: 3)
        let timeline = try ProgramTimeline(
            episode: f.episode(
                cuts: [f.cut(20, 30)],
                regions: [laterOriginal, insideOriginal]), dialogueFrames: 0..<50)
        #expect(timeline.insertions.map(\.baseFrame) == [20, 20])
        #expect(timeline.insertions.map(\.region.id) == [laterOriginal.id, insideOriginal.id])
        #expect(timeline.insertions.map(\.programFrames) == [20..<24, 24..<27])
        #expect(try timeline.dialoguePosition(atAlignedFrame: 30) == .mapped(frame: 27))
        #expect(try timeline.dialoguePosition(atAlignedFrame: 29) == .removed(interval: 20..<30, seam: 27))
        #expect(try timeline.inverse(atProgramFrame: 27) == .dialogue(frame: 30))
    }

    @Test func inactiveCutsAndMalformedAlignmentNeverBecomeAnImplicitNewClock() throws {
        let f = try ProgramFixture()
        let inactive = ManualEpisodeCut(alignmentRevision: 2, startFrame: 0, endFrame: 10)
        let clip = try f.clip(.dialogue(f.anchor(35)))
        let timeline = try ProgramTimeline(
            episode: f.episode(cuts: [inactive], clips: [clip]),
            dialogueFrames: f.coverage)
        #expect(timeline.cuts == .unedited)
        #expect(try timeline.composition().clips[0].programFrames.lowerBound == 35)
        var episode = f.episode()
        episode.alignment?.acceptedRevision = 2
        #expect(throws: ProgramTimelineError.self) { try ProgramTimeline(episode: episode, dialogueFrames: f.coverage) }
        episode = f.episode(cuts: [f.cut(5, 5)])
        #expect(throws: ProgramTimelineError.invalidCuts) {
            try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        }
        let cut = f.cut(5, 10)
        episode = f.episode(cuts: [cut, cut])
        #expect(throws: ProgramTimelineError.invalidCuts) {
            try ProgramTimeline(episode: episode, dialogueFrames: f.coverage)
        }
        let region = try AudioInsertionRegion(anchor: .dialogue(f.anchor(21)), durationFrames: 3)
        let outlying = try ProgramTimeline(episode: f.episode(regions: [region]), dialogueFrames: 0..<20)
        #expect(outlying.insertions[0].programFrames == 21..<24)
        #expect(try outlying.dialoguePosition(atAlignedFrame: 21) == .outsideCoverage)
        #expect(try outlying.inverse(atProgramFrame: 21) == .insertion(region: region.id, offsetFrames: 0))
        #expect(try outlying.inverse(atProgramFrame: 24) == .outsideCoverage)
    }

    @Test func boundariesOverflowInvalidInputsAndUnresolvedPlacementsRefuseVisibly() throws {
        let f = try ProgramFixture()
        let limit = AudioArrangement.frameLimit
        #expect(throws: ProgramTimelineError.missingDialogueCoverage) { try ProgramTimeline(episode: f.episode()) }
        var audioOnly = f.episode()
        audioOnly.alignment = nil
        #expect(throws: ProgramTimelineError.missingAcceptedAlignment) {
            try ProgramTimeline(episode: audioOnly, dialogueFrames: 0..<10)
        }
        #expect(throws: ProgramTimelineError.invalidDialogueCoverage(0..<0)) {
            try ProgramTimeline(episode: f.episode(), dialogueFrames: 0..<0)
        }
        for frame: Int64 in [.min, .max, -limit - 1, limit + 1] {
            let timeline = try ProgramTimeline(episode: audioOnly)
            #expect(throws: ProgramTimelineError.outsideFrameEnvelope(frame)) {
                try timeline.inverse(atProgramFrame: frame)
            }
            #expect(throws: ProgramTimelineError.outsideFrameEnvelope(frame)) {
                try timeline.project(.absolute(frame: frame))
            }
            #expect(throws: ProgramTimelineError.outsideFrameEnvelope(frame)) {
                try timeline.unpinnedAnchor(atProgramFrame: frame)
            }
        }
        let region = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 10)
        #expect(throws: ProgramTimelineError.outsideFrameEnvelope(limit + 10)) {
            try ProgramTimeline(episode: f.episode(regions: [region]), dialogueFrames: 0..<limit)
        }
        let endClip = f.clip(.programOrigin(frame: limit - 100))
        var overrun = audioOnly
        overrun.audioArrangement?.insertionRegions = [region]
        overrun.audioArrangement?.clips = [endClip]
        let shifted = try ProgramTimeline(episode: overrun)
        #expect(throws: ProgramTimelineError.outsideFrameEnvelope(limit + 10)) { try shifted.composition() }
        #expect(throws: ProgramTimelineError.cutOutsideDialogueCoverage(10..<30)) {
            try ProgramTimeline(episode: f.episode(cuts: [f.cut(10, 30)]), dialogueFrames: 0..<20)
        }
        let timeline = try ProgramTimeline(episode: f.episode(regions: [region]), dialogueFrames: 0..<20)
        #expect(throws: ProgramTimelineError.invalidInsertionOffset(region.id, 10)) {
            try timeline.project(.insertion(region: region.id, offsetFrames: 10))
        }
        let missing = AudioInsertionRegionID()
        #expect(throws: ProgramTimelineError.unknownInsertion(missing)) {
            try timeline.project(.insertion(region: missing, offsetFrames: 0))
        }
        let outside = try f.clip(.dialogue(f.anchor(21)))
        let outlying = try ProgramTimeline(episode: f.episode(clips: [outside]), dialogueFrames: 0..<20)
        #expect(try outlying.project(outside.anchor) == .placed(frame: 21))
        #expect(try outlying.composition().clips[0].programFrames == 21..<121)
        #expect(try outlying.pinnedAnchor(for: outside.anchor) == .absolute(frame: 21))
        #expect(try outlying.inverse(atProgramFrame: 21) == .outsideCoverage)
        #expect(try ProgramTimeline(episode: f.episode(), dialogueFrames: -limit..<limit).dialogueSpans.count == 1)
    }

    @Test(arguments: ["duplicateClip", "duplicateRegion", "nested", "zeroRegion", "badTrim", "badEnvelope", "hugeRate"])
    func malformedArrangementsAreNeverSuccessShaped(_ damage: String) throws {
        let f = try ProgramFixture()
        let clip = f.clip(.programOrigin(frame: 0))
        var episode = f.episode(clips: [clip])
        let region = AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: 10)
        switch damage {
        case "duplicateClip": episode.audioArrangement?.clips.append(clip)
        case "duplicateRegion": episode.audioArrangement?.insertionRegions = [region, region]
        case "nested":
            episode.audioArrangement?.insertionRegions = [
                region, .init(anchor: .insertion(region: region.id, offsetFrames: 0), durationFrames: 5),
            ]
        case "zeroRegion":
            episode.audioArrangement?.insertionRegions = [.init(anchor: .programOrigin(frame: 0), durationFrames: 0)]
        case "badTrim": episode.audioArrangement?.clips[0].trim.endFrame = .max
        case "badEnvelope": episode.audioArrangement?.clips[0].envelope.points = [.init(frame: 1, amplitude: .nan)]
        case "hugeRate": episode.audioArrangement?.assets[0].sampleRate = .max
        default: Issue.record("Unknown synthetic damage")
        }
        #expect(throws: ProgramTimelineError.self) { try ProgramTimeline(episode: episode, dialogueFrames: f.coverage) }
    }

    @Test func randomizedMergedCutsRegionsAndEveryKeptFrameRoundTrip() throws {
        let f = try ProgramFixture()
        var random = ProgramRandom()
        for _ in 0..<120 {
            let cuts = (0..<5).map { _ in
                let start = Int64(random.next(70)) - 20
                return f.cut(start, start + Int64(random.next(12)) + 1)
            }
            let regions = try (0..<4).map { _ in
                try AudioInsertionRegion(
                    anchor: .dialogue(f.anchor(Int64(random.next(90)) - 20)),
                    durationFrames: Int64(random.next(7)) + 1)
            }
            let timeline = try ProgramTimeline(
                episode: f.episode(cuts: cuts, regions: regions),
                dialogueFrames: -20..<80)
            let totalRemoved = timeline.cuts.removals.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound }
            #expect(
                timeline.dialogueSpans.reduce(Int64(0)) {
                    $0 + $1.programFrames.upperBound - $1.programFrames.lowerBound
                }
                    == 100 - totalRemoved)
            for frame: Int64 in -20..<80 {
                switch try timeline.dialoguePosition(atAlignedFrame: frame) {
                case .mapped(let program):
                    #expect(try timeline.inverse(atProgramFrame: program) == .dialogue(frame: frame))
                    #expect(
                        try timeline.project(timeline.unpinnedAnchor(atProgramFrame: program))
                            == .placed(frame: program))
                case .removed(let interval, let seam):
                    #expect(interval.contains(frame))
                    #expect(
                        try timeline.project(.dialogue(f.anchor(frame)))
                            == .clampedToCutSeam(frame: seam, removed: interval))
                case .outsideCoverage: Issue.record("Covered original frame became outside coverage")
                }
            }
            for region in timeline.insertions {
                for frame in region.programFrames {
                    #expect(
                        try timeline.inverse(atProgramFrame: frame)
                            == .insertion(
                                region: region.region.id,
                                offsetFrames: frame - region.programFrames.lowerBound))
                }
            }
            for frame: Int64 in [-40, -21, 0, 40, 80, 120, 160] {
                let anchor = try timeline.unpinnedAnchor(atProgramFrame: frame)
                #expect(try timeline.project(anchor) == .placed(frame: frame))
                #expect(try timeline.unpinnedAnchor(for: .absolute(frame: frame)) == anchor)
                if try timeline.inverse(atProgramFrame: frame) == .outsideCoverage {
                    guard case .dialogue = anchor else {
                        Issue.record("Outside sample coverage must still bind placements to the accepted grid")
                        continue
                    }
                }
            }
        }
    }

    @Test func downstreamInversePreservesExistingPerLaneGapAndUnsupportedClassification() throws {
        let f = try ProgramFixture()
        let original = try JSONDecoder().decode(AlignedTimelineMap.self, from: JSONEncoder().encode(f.version.map))
        let first = RecordingEpochID()
        let last = RecordingEpochID()
        let unknown = RecordingEpochID()
        let gap = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(48_000), frameCount: 300)
        let unsupported = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(48_000), frameCount: 300)
        let group = try GroupTimeMap(
            group: RecorderGroupID(), reference: original.reference,
            epochs: [
                .init(
                    epoch: first,
                    mapping: .mapped(
                        segments: [
                            AffineClockSegment(
                                groupClockStart: .zero, groupClockEnd: ExactRational(100, 48_000),
                                rateRatio: .one, alignedOffset: .zero)
                        ], provenance: .manual(.init(basis: .numericEntry)))),
                .init(epoch: unknown, mapping: .unsupported(.estimatorAbstained)),
                .init(
                    epoch: last,
                    mapping: .mapped(
                        segments: [
                            AffineClockSegment(
                                groupClockStart: ExactRational(200, 48_000), groupClockEnd: ExactRational(300, 48_000),
                                rateRatio: .one, alignedOffset: .zero)
                        ], provenance: .manual(.init(basis: .numericEntry)))),
            ],
            placements: [
                .init(
                    occurrence: gap,
                    spans: [
                        .init(startFrame: 0, endFrame: 100, epoch: first, groupClockOffset: .zero),
                        .init(startFrame: 200, endFrame: 300, epoch: last, groupClockOffset: .zero),
                    ]),
                .init(
                    occurrence: unsupported,
                    spans: [
                        .init(startFrame: 0, endFrame: 100, epoch: first, groupClockOffset: .zero),
                        .init(startFrame: 100, endFrame: 200, epoch: unknown, groupClockOffset: .zero),
                        .init(startFrame: 200, endFrame: 300, epoch: last, groupClockOffset: .zero),
                    ]),
            ])
        let map = try AlignedTimelineMap(reference: original.reference, groups: original.groups + [group])
        let version = try TimeMapVersion(
            revision: 1, inputs: f.version.inputs,
            map: JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map)))
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: version, frame: 50)), durationFrames: 10)
        var episode = f.episode(cuts: [f.cut(20, 30)], regions: [region])
        episode.alignment = .init(maps: [version], acceptedRevision: 1)
        let timeline = try ProgramTimeline(episode: episode, dialogueFrames: 0..<300)
        #expect(try timeline.inverse(atProgramFrame: 40) == .insertion(region: region.id, offsetFrames: 0))
        guard case .dialogue(let frame) = try timeline.inverse(atProgramFrame: 150) else {
            Issue.record("Kept aligned coordinate must survive downstream composition")
            return
        }
        #expect(frame == 150)
        let instant = try ExactRational(frame, 48_000)
        guard case .gap = try map.sourceFrame(at: instant, in: gap.id) else {
            Issue.record("Program projection must not replace a source gap with a speaker sample")
            return
        }
        #expect(try map.sourceFrame(at: instant, in: unsupported.id).regionState == .unsupported(.estimatorAbstained))
        #expect(episode.alignment?.acceptedMap == version)
    }

    @Test func productionCompositionIgnoresReviewExpansionAndPreservesAllOriginalStateBytes() throws {
        let f = try ProgramFixture()
        let cut = f.cut(20, 30)
        let clip = try f.clip(.dialogue(f.anchor(35)))
        var episode = f.episode(cuts: [cut], clips: [clip])
        episode.cleanup?.transcripts = [
            .init(
                speaker: SpeakerID(),
                primary: .init(sourceID: f.recording.id, statedChannel: 0), sourceRate: 48_000,
                sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1, model: "Synthetic only",
                workingRange: nil,
                words: [
                    .init(
                        text: "um", sourceStartFrame: 20, sourceEndFrame: 25,
                        alignedStart: 20.0 / 48_000, alignedEnd: 25.0 / 48_000)
                ])
        ]
        episode.cleanup = episode.cleanup?.proposingFillers()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(episode)
        let before = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage).composition()
        #expect(try episode.manualCutTimeline(revealing: cut.id).removals.isEmpty)
        let after = try ProgramTimeline(episode: episode, dialogueFrames: f.coverage).composition()
        #expect(before == after)
        #expect(after.clips[0].programFrames.lowerBound == 25)
        #expect(try encoder.encode(episode) == bytes)
        #expect(episode.sources == [f.recording, f.supplemental])
        #expect(episode.alignment?.maps == [f.version])
        #expect(episode.cleanup?.manualCuts == [cut])
        #expect(episode.cleanup?.transcripts[0].words[0].sourceStartFrame == 20)
        #expect(episode.audioArrangement?.assets == [f.asset])
        #expect(episode.audioArrangement?.clips == [clip])
    }
}

private struct ProgramFixture {
    let recording = SourceRecord(displayNameHint: "Generated recording")
    let supplemental = SourceRecord(displayNameHint: "Generated stereo asset", purpose: .supplementalAudio)
    let track = AudioTrack(name: "Music")
    let version: TimeMapVersion
    let coverage: Range<Int64> = 0..<4_800_000
    var asset: AudioAsset { .init(source: supplemental.id, frameCount: 4_800_000, sampleRate: 48_000, channelCount: 2) }

    init() throws {
        let group = RecorderGroupID()
        let epoch = RecordingEpochID()
        let occurrence = try SourceOccurrence(
            source: recording.id, nominalRate: NominalRate(48_000), frameCount: 4_800_000)
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence.id)
        let map = try AlignedTimelineMap(
            reference: reference,
            groups: [
                GroupTimeMap(
                    group: group, reference: reference,
                    epochs: [
                        .init(
                            epoch: epoch,
                            mapping: .mapped(
                                segments: [
                                    AffineClockSegment(
                                        groupClockStart: .zero, groupClockEnd: ExactRational(100),
                                        rateRatio: .one, alignedOffset: .zero)
                                ], provenance: .timelineReference))
                    ],
                    placements: [
                        .init(
                            occurrence: occurrence,
                            spans: [
                                .init(startFrame: 0, endFrame: 4_800_000, epoch: epoch, groupClockOffset: .zero)
                            ])
                    ])
            ])
        version = try .init(
            revision: 1, inputs: .init(sources: [.init(sourceID: recording.id)]),
            map: JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map)))
    }

    func anchor(_ frame: Int64) throws -> AudioDialogueAnchor { try .init(map: version, frame: frame) }
    func cut(_ start: Int64, _ end: Int64) -> ManualEpisodeCut {
        .init(alignmentRevision: 1, startFrame: start, endFrame: end)
    }
    func clip(_ anchor: AudioPlacementAnchor, duration: Int64 = 100) -> AudioClip {
        .init(
            track: track.id, source: asset.source, trim: .init(startFrame: 0, endFrame: duration), anchor: anchor,
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: duration, amplitude: 1)]))
    }
    func episode(
        cuts: [ManualEpisodeCut] = [], clips: [AudioClip] = [],
        regions: [AudioInsertionRegion] = []
    ) -> Episode {
        .init(
            title: "Synthetic", sources: [recording, supplemental],
            alignment: .init(maps: [version], acceptedRevision: 1), cleanup: .init(manualCuts: cuts),
            audioArrangement: .init(assets: [asset], tracks: [track], clips: clips, insertionRegions: regions))
    }
}

private struct ProgramRandom {
    private var state: UInt64 = 0xF200_469
    mutating func next(_ upper: UInt64) -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state % upper
    }
}
