import Foundation
import Testing
import WWCommonEdit
import WWCore
import WWTimeMap
@testable import WaveWrangler

@Suite("Inserted-time whole-value edits")
struct AudioInsertionEditingTests {
    private let rate: Int64 = 48_000

    @Test func indexedCutGeometryMatchesFullScanWithInsertionsAndExpandedReview() throws {
        let f = try AudioInsertionTestFixture()
        let cuts: [ManualEpisodeCut] = (0..<100).map { index in
            let start = Int64(index) * 38_400 + 4_800
            return ManualEpisodeCut(alignmentRevision: 1, startFrame: start, endFrame: start + 9_600)
        }
        let regions = [
            AudioInsertionRegion(anchor: .programOrigin(frame: 0), durationFrames: rate),
            AudioInsertionRegion(anchor: try f.anchor(40 * rate), durationFrames: 2 * rate),
        ]
        let program = try ProgramTimeline(episode: f.episode(regions: regions, cuts: cuts),
            dialogueFrames: f.coverage)
        let boundaries = program.dialogueSpans.flatMap {
            [Double($0.originalFrames.lowerBound) / 48_000, Double($0.originalFrames.upperBound) / 48_000]
        }
        for expanded in [nil, cuts[50]] {
            let visible = try ManualCutTimeline(cuts: cuts.filter { $0.id != expanded?.id })
            let projection = AudioTimelineProjection(cuts: visible, program: program, expanded: expanded)
            func forward(_ time: Double, following: Bool) -> Double {
                let base = program.cuts.editedTime(forAlignedTime: time)
                let restored = expanded.map { time > $0.alignedStart && time <= $0.alignedEnd } ?? false
                let shift = program.insertions.filter {
                    let boundary = Double($0.baseFrame) / 48_000
                    return following || restored ? boundary <= base : boundary < base
                }.reduce(0.0) { $0 + Double($1.region.durationFrames) / 48_000 }
                return visible.editedTime(forAlignedTime: time) + shift
            }
            let points = stride(from: -1.0, through: 101, by: 0.137).map { $0 }
                + cuts.flatMap { [$0.alignedStart, $0.alignedEnd] }
            for time in points {
                #expect(projection.editedTime(forAlignedTime: time) == forward(time, following: true))
                for width in [0.0, 0.01, 1.0] {
                    let range = time...(time + width)
                    let expected = visible.keptAlignedRanges(in: range).flatMap { kept in
                        let splits = [kept.lowerBound]
                            + boundaries.filter { $0 > kept.lowerBound && $0 < kept.upperBound }.sorted()
                            + [kept.upperBound]
                        return zip(splits, splits.dropFirst()).map { $0...$1 }
                    }
                    #expect(projection.originalRanges(in: range) == expected)
                    let lower = forward(time, following: true)
                    #expect(projection.displayRange(forOriginalRange: range)
                        == lower...max(lower, forward(time + width, following: false)))
                }
            }
        }
    }

    @Test func introRetargetsFortySecondBedWithIndependentTenSecondLeadIn() throws {
        let f = try AudioInsertionTestFixture()
        let bed = f.clip(at: .programOrigin(frame: 0), duration: 40 * rate)
        let cut = ManualEpisodeCut(alignmentRevision: 1, startFrame: 50 * rate, endFrame: 51 * rate)
        var episode = f.episode(clips: [bed], cuts: [cut])
        episode.cleanup?.transcripts = [
            .init(speaker: SpeakerID(), primary: .init(sourceID: f.recording.id, statedChannel: 0),
                sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64),
                alignmentRevision: 1, model: "Synthetic only", workingRange: nil,
                words: [.init(text: "um", sourceStartFrame: rate, sourceEndFrame: rate + 9_600,
                    alignedStart: 1, alignedEnd: 1.2)]),
        ]
        episode.cleanup = episode.cleanup?.proposingFillers()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalCleanup = try encoder.encode(episode.cleanup)
        let editing = try f.editing(episode)
        let edit = try editing.inserting(at: editing.introPosition, duration: 10 * rate, moving: bed.id)
        #expect(edit.after.clips[0].programFrames == 0..<(40 * rate))
        #expect(edit.after.timeline.dialogueSpans.first?.programFrames.lowerBound == 10 * rate)
        #expect(edit.after.clips[0].clip.anchor == .insertion(region: edit.regionID, offsetFrames: 0))
        var originalAudio = edit.after.clips[0].clip
        originalAudio.anchor = bed.anchor
        #expect(originalAudio == bed, "Source, trim, output ownership, channel order, envelope, and ID must be identical.")
        var afterEpisode = episode
        afterEpisode.audioArrangement = edit.arrangement
        var unchanged = afterEpisode
        unchanged.audioArrangement = episode.audioArrangement
        #expect(unchanged == episode, "No map, source, transcript provenance, or cut mutation.")
        #expect(try encoder.encode(afterEpisode.cleanup) == originalCleanup)
        #expect(afterEpisode.cleanup?.transcripts.first?.words.first?.sourceStartFrame == rate)
        #expect(afterEpisode.cleanup?.manualCuts == [cut])
        #expect(edit.after.programFrames == 0..<(109 * rate))
    }

    @Test func signedIntroUsesEarliestRetainedUnpinnedContentNotAnUnrelatedEarlierPin() throws {
        let f = try AudioInsertionTestFixture()
        let unpinned = f.clip(at: try f.anchor(-7 * rate))
        let pinned = f.clip(at: .absolute(frame: -20 * rate))
        let episode = f.episode(clips: [unpinned, pinned])
        let editing = try f.editing(episode, coverage: (-5 * rate)..<(10 * rate))
        #expect(editing.introPosition == -7 * rate)
        let edit = try editing.inserting(at: editing.introPosition, duration: 3 * rate)
        #expect(edit.after.clips.map(\.programFrames.lowerBound) == [-4 * rate, -20 * rate])
        #expect(edit.after.timeline.dialogueSpans.first?.programFrames.lowerBound == -2 * rate)
        #expect(edit.after.timeline.dialogueSpans.first?.originalFrames.lowerBound == -5 * rate)
        #expect(edit.arrangement.clips == [unpinned, pinned])
    }

    @Test func midrollShiftsLaterStartsAndRegionsButNeverSplitsSpanningBedsOrMovesOtherPins() throws {
        let f = try AudioInsertionTestFixture()
        let spanning = f.clip(at: try f.anchor(5 * rate), duration: 40 * rate)
        let later = f.clip(at: try f.anchor(30 * rate))
        let pinned = f.clip(at: .absolute(frame: 30 * rate))
        let region = AudioInsertionRegion(anchor: try f.anchor(40 * rate), durationFrames: 3 * rate)
        let relative = f.clip(at: .insertion(region: region.id, offsetFrames: rate))
        let episode = f.episode(clips: [spanning, later, pinned, relative], regions: [region])
        let edit = try f.editing(episode).inserting(at: 20 * rate, duration: 10 * rate)
        #expect(edit.after.clips.map(\.programFrames.lowerBound) == [5, 40, 30, 51].map { $0 * rate })
        #expect(edit.after.clips[0].programFrames == (5 * rate)..<(45 * rate))
        #expect(edit.arrangement.clips == episode.audioArrangement?.clips)
        #expect(edit.after.timeline.insertions.map(\.programFrames.lowerBound) == [20 * rate, 50 * rate])
        #expect(edit.after.timeline.dialogueSpans.map(\.programFrames)
            == [0..<(20 * rate), (30 * rate)..<(50 * rate), (53 * rate)..<(113 * rate)])
    }

    @Test func explicitlyRetargetedPinKeepsItsPinAndAllOtherPinsStayFixed() throws {
        let f = try AudioInsertionTestFixture()
        let chosen = f.clip(at: .absolute(frame: 30 * rate), duration: 40 * rate)
        let other = f.clip(at: .absolute(frame: 35 * rate))
        let edit = try f.editing(f.episode(clips: [chosen, other]))
            .inserting(at: 0, duration: 10 * rate, moving: chosen.id)
        #expect(edit.after.clips.map(\.programFrames.lowerBound) == [0, 35 * rate])
        #expect(edit.after.clips[0].clip.anchor == .absolute(frame: 0))
        #expect(edit.after.clips[1].clip == other)
        var retained = edit.after.clips[0].clip
        retained.anchor = chosen.anchor
        #expect(retained == chosen)
    }

    @Test func sameBoundaryEdgeInsertionPreservesSavedOrderAndRefusesInteriors() throws {
        let f = try AudioInsertionTestFixture()
        let a = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 3 * rate)
        let b = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 2 * rate)
        let relative = f.clip(at: .insertion(region: b.id, offsetFrames: rate))
        let editing = try f.editing(f.episode(clips: [relative], regions: [a, b]))
        for (frame, index) in [(10 * rate, 0), (13 * rate, 1), (15 * rate, 2)] {
            let edit = try editing.inserting(at: frame, duration: rate)
            var expected = [a.id, b.id]
            expected.insert(edit.regionID, at: index)
            #expect(edit.arrangement.insertionRegions.map(\.id) == expected)
            #expect(edit.after.timeline.insertions.map(\.region.id) == expected)
            #expect(edit.after.timeline.insertions.first { $0.region.id == edit.regionID }?.programFrames.lowerBound == frame)
            #expect(edit.after.clips[0].clip == relative)
        }
        #expect(throws: AudioInsertionEditing.Refusal.self) {
            try editing.inserting(at: 11 * rate, duration: rate)
        }
        #expect(throws: AudioInsertionEditing.Refusal.self) {
            try editing.inserting(at: 14 * rate, duration: rate)
        }
    }

    @Test func shorteningClampsOnlyRemovedOffsetsAndRetainsOverhangsChannelsWindowsAndFades() throws {
        let f = try AudioInsertionTestFixture()
        let a = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 10 * rate)
        let b = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 2 * rate)
        let starts = [0, 2, 5, 9].map { f.clip(at: .insertion(region: a.id, offsetFrames: Int64($0) * rate), duration: 40 * rate) }
        let pin = f.clip(at: .absolute(frame: 19 * rate))
        let editing = try f.editing(f.episode(clips: starts + [pin], regions: [a, b]))
        let shortened = try editing.replacing(a.id, at: 10 * rate, duration: 5 * rate)
        #expect(shortened.after.clips.map(\.programFrames.lowerBound) == [10, 12, 15, 15, 19].map { $0 * rate })
        #expect(shortened.clampedClips == Set(starts.suffix(2).map(\.id)))
        #expect(shortened.arrangement.insertionRegions.map(\.id) == [a.id, b.id])
        #expect(shortened.after.timeline.insertions.map(\.programFrames) == [(10 * rate)..<(15 * rate), (15 * rate)..<(17 * rate)])
        for (original, retained) in zip(starts + [pin], shortened.arrangement.clips) {
            var audio = retained
            audio.anchor = original.anchor
            #expect(audio == original)
        }
        let removed = try editing.removing(a.id)
        #expect(removed.after.clips.map(\.programFrames.lowerBound) == [10, 10, 10, 10, 19].map { $0 * rate })
        #expect(removed.arrangement.insertionRegions == [b])
        #expect(removed.arrangement.clips.prefix(4).allSatisfy {
            $0.anchor == .insertion(region: b.id, offsetFrames: 0)
        })
        #expect(removed.after.clips.map(\.programFrames.count) == editing.composition.clips.map(\.programFrames.count))
    }

    @Test func movingARegionRetainsItsIDAndRelativeOffsetsAndRipplesBothSeams() throws {
        let f = try AudioInsertionTestFixture()
        let region = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 5 * rate)
        let first = f.clip(at: .insertion(region: region.id, offsetFrames: 2 * rate), duration: 40 * rate)
        let last = f.clip(at: .insertion(region: region.id, offsetFrames: 4 * rate))
        let later = f.clip(at: try f.anchor(50 * rate))
        let editing = try f.editing(f.episode(clips: [first, last, later], regions: [region]))
        let moved = try editing.replacing(region.id, at: 30 * rate, duration: 5 * rate)
        #expect(moved.after.timeline.insertions[0].region.id == region.id)
        #expect(moved.after.clips.map(\.programFrames.lowerBound) == [32, 34, 55].map { $0 * rate })
        #expect(moved.arrangement.clips == [first, last, later])
        let movedAndShortened = try editing.replacing(region.id, at: 30 * rate, duration: 3 * rate)
        #expect(movedAndShortened.after.clips.map(\.programFrames.lowerBound) == [32, 33, 53].map { $0 * rate })
        #expect(movedAndShortened.arrangement.clips[0] == first)
        #expect(movedAndShortened.clampedClips == [last.id])
    }

    @Test func emptyAndAudioOnlyProgramsNeverFabricateAcceptedTiming() throws {
        let empty = Episode(title: "Audio only")
        let composition = try ProgramTimeline(episode: empty).composition()
        let editing = try AudioInsertionEditing(episode: empty, composition: composition)
        #expect(editing.introPosition == 0)
        let edit = try editing.inserting(at: -480_000, duration: 240_000)
        #expect(edit.after.timeline.dialogueFrames == nil && edit.after.timeline.dialogueSpans.isEmpty)
        #expect(edit.arrangement.insertionRegions[0].anchor == .programOrigin(frame: -480_000))
        var episode = empty
        episode.audioArrangement = edit.arrangement
        let removed = try AudioInsertionEditing(episode: episode, composition: edit.after).removing(edit.regionID)
        #expect(removed.after.programFrames == nil && removed.arrangement.clips.isEmpty)
        #expect(episode.alignment == nil)
    }

    @Test func invalidBoundsStaleBindingsAndStaleCompositionRefuseWholeEdits() throws {
        let f = try AudioInsertionTestFixture()
        let episode = f.episode()
        let editing = try f.editing(episode)
        for duration in [Int64.min, -1, 0, AudioArrangement.frameLimit + 1, Int64.max] {
            #expect(throws: AudioInsertionEditing.Refusal.self) { try editing.inserting(at: 0, duration: duration) }
        }
        for frame in [Int64.min, -AudioArrangement.frameLimit - 1, AudioArrangement.frameLimit, Int64.max] {
            #expect(throws: (any Error).self) { try editing.inserting(at: frame, duration: 1) }
        }
        #expect(throws: (any Error).self) {
            try editing.inserting(at: 0, duration: AudioArrangement.frameLimit)
        }
        var changed = episode
        changed.audioArrangement?.insertionRegions = [.init(anchor: .programOrigin(frame: 1), durationFrames: 1)]
        #expect(throws: AudioInsertionEditing.Refusal.self) {
            try AudioInsertionEditing(episode: changed, composition: editing.composition)
        }
        var stale = try f.anchor(0)
        if case .dialogue(var anchor) = stale {
            anchor.mapIdentity = String(repeating: "a", count: 64)
            stale = .dialogue(anchor)
        }
        #expect(throws: ProgramTimelineError.self) {
            try f.editing(f.episode(regions: [.init(anchor: stale, durationFrames: rate)]))
        }
        #expect(throws: (any Error).self) {
            try f.editing(f.episode(clips: [f.clip(at: stale)]))
        }
    }

    @Test func signedDayEdgeAndCutSeamsRemainExactAndReopenWithValidAnchors() throws {
        let f = try AudioInsertionTestFixture()
        let cut = ManualEpisodeCut(alignmentRevision: 1, startFrame: -2 * rate, endFrame: 2 * rate)
        let region = AudioInsertionRegion(anchor: try f.anchor(0), durationFrames: 10 * rate)
        let clip = f.clip(at: .insertion(region: region.id, offsetFrames: 9 * rate), duration: 40 * rate)
        let episode = f.episode(clips: [clip], regions: [region], cuts: [cut])
        let editing = try f.editing(episode, coverage: (-5 * rate)..<(10 * rate))
        #expect(editing.composition.timeline.insertions[0].programFrames.lowerBound == -2 * rate)
        let edit = try editing.removing(region.id)
        #expect(edit.after.clips[0].programFrames.lowerBound == -2 * rate)
        #expect(edit.after.timeline.cuts.removals == [(-2 * rate)..<(2 * rate)])
        let reopened = try JSONDecoder().decode(AudioArrangement.self, from: JSONEncoder().encode(edit.arrangement))
        #expect(reopened == edit.arrangement)
        var next = episode
        next.audioArrangement = reopened
        #expect(try ProgramTimeline(episode: next, dialogueFrames: editing.composition.timeline.dialogueFrames).composition() == edit.after)
        let empty = Episode(title: "Edge")
        let emptyEditing = try AudioInsertionEditing(episode: empty, composition: ProgramTimeline(episode: empty).composition())
        #expect(try emptyEditing.inserting(at: -AudioArrangement.frameLimit, duration: 1).after.programFrames
            == (-AudioArrangement.frameLimit)..<(-AudioArrangement.frameLimit + 1))
        #expect(try emptyEditing.inserting(at: AudioArrangement.frameLimit - 1, duration: 1).after.programFrames
            == (AudioArrangement.frameLimit - 1)..<AudioArrangement.frameLimit)
    }

    @Test func insertedCursorFollowsMovesAndClampsShortenedOrRemovedOffsetsBeforeLaterSiblings() throws {
        let f = try AudioInsertionTestFixture()
        let a = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 5 * rate)
        let b = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: 2 * rate)
        let c = AudioInsertionRegion(anchor: try f.anchor(10 * rate), durationFrames: rate)
        let editing = try f.editing(f.episode(regions: [a, b, c]))
        let prior = AudioTimelineProjection(program: editing.composition.timeline)
        let shortened = try editing.replacing(a.id, at: 10 * rate, duration: 2 * rate)
        let shorter = AudioTimelineProjection(program: shortened.after.timeline)
        #expect(prior.reprojectInsertedDisplayTime(11, to: shorter) == 11)
        #expect(prior.reprojectInsertedDisplayTime(14, to: shorter) == 12)
        let removed = try editing.removing(b.id)
        let next = AudioTimelineProjection(program: removed.after.timeline)
        #expect(prior.reprojectInsertedDisplayTime(16, to: next) == 15)
        #expect(prior.reprojectInsertedDisplayTime(17.5, to: next) == 15.5)
        let moved = try editing.replacing(a.id, at: 30 * rate, duration: 5 * rate)
        #expect(prior.reprojectInsertedDisplayTime(12, to: AudioTimelineProjection(program: moved.after.timeline)) == 32)
    }

    @Test func expandedCutDisplayOffsetsNeverBecomeInsertionDestinationsOrMoveSavedState() throws {
        let f = try AudioInsertionTestFixture()
        let cut = ManualEpisodeCut(alignmentRevision: 1, startFrame: 2 * rate, endFrame: 3 * rate)
        let region = AudioInsertionRegion(anchor: try f.anchor(0), durationFrames: rate)
        let episode = f.episode(regions: [region], cuts: [cut])
        let editing = try f.editing(episode)
        let expanded = AudioTimelineProjection(cuts: .unedited, program: editing.composition.timeline, expanded: cut)
        #expect(expanded.programTime(forDisplayTime: 3.5) == nil)
        #expect(expanded.programTime(forDisplayTime: 4) == 3)
        let removed = try editing.removing(region.id)
        let next = AudioTimelineProjection(cuts: .unedited, program: removed.after.timeline, expanded: cut)
        #expect(expanded.reprojectInsertedDisplayTime(0.5, to: next) == 0)
        #expect(editing.episode == episode && episode.cleanup?.manualCuts == [cut])
    }
}

private struct AudioInsertionTestFixture {
    let recording = SourceRecord(displayNameHint: "Synthetic speech")
    let supplemental = SourceRecord(displayNameHint: "Synthetic music", purpose: .supplementalAudio)
    let track = AudioTrack(name: "Bed")
    let version: TimeMapVersion
    let coverage: Range<Int64> = 0..<4_800_000
    var asset: AudioAsset { .init(source: supplemental.id, frameCount: 4_800_000, sampleRate: 48_000, channelCount: 2) }

    init() throws {
        let group = RecorderGroupID(), epoch = RecordingEpochID()
        let occurrence = try SourceOccurrence(source: recording.id, nominalRate: NominalRate(48_000), frameCount: 4_800_000)
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence.id)
        let map = try AlignedTimelineMap(reference: reference, groups: [
            GroupTimeMap(group: group, reference: reference, epochs: [
                .init(epoch: epoch, mapping: .mapped(segments: [
                    AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(100),
                        rateRatio: .one, alignedOffset: .zero),
                ], provenance: .timelineReference)),
            ], placements: [.init(occurrence: occurrence, spans: [
                .init(startFrame: 0, endFrame: 4_800_000, epoch: epoch, groupClockOffset: .zero),
            ])]),
        ])
        version = try .init(revision: 1, inputs: .init(sources: [.init(sourceID: recording.id)]),
            map: JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map)))
    }

    func anchor(_ frame: Int64) throws -> AudioPlacementAnchor { .dialogue(try .init(map: version, frame: frame)) }
    func clip(at anchor: AudioPlacementAnchor, duration: Int64 = 48_000) -> AudioClip {
        .init(track: track.id, source: asset.source, trim: .init(startFrame: 0, endFrame: duration + 2),
            channels: [1, 0], anchor: anchor,
            envelope: .init(points: [.init(frame: 0, amplitude: 0.25), .init(frame: duration, amplitude: 0.75)]),
            outputWindow: .init(offsetFrames: 1, countFrames: duration))
    }
    func episode(clips: [AudioClip] = [], regions: [AudioInsertionRegion] = [],
                 cuts: [ManualEpisodeCut] = []) -> Episode {
        .init(title: "Synthetic inserted time", sources: [recording, supplemental],
            alignment: .init(maps: [version], acceptedRevision: 1), cleanup: .init(manualCuts: cuts),
            audioArrangement: .init(assets: [asset], tracks: [track], clips: clips, insertionRegions: regions))
    }
    func editing(_ episode: Episode, coverage: Range<Int64>? = nil) throws -> AudioInsertionEditing {
        try .init(episode: episode,
            composition: ProgramTimeline(episode: episode, dialogueFrames: coverage ?? self.coverage).composition())
    }
}
