import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWTimeMap

@Suite("Waveform selection")
struct AlignmentWaveformTests {
    @Test func playbackSelectsOnlySourcesWithAcceptedMappedEpochs() throws {
        let group = RecorderGroupID()
        let mappedEpoch = RecordingEpochID()
        let untimedEpoch = RecordingEpochID()
        let mapped = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 1_000
        )
        let untimed = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 1_000
        )
        let reference = TimelineReference(
            group: group, epoch: mappedEpoch, occurrence: mapped.id
        )
        let segment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(1),
            rateRatio: ExactRational(1), alignedOffset: .zero
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [
            GroupTimeMap(group: group, reference: reference, epochs: [
                EpochClockMap(epoch: mappedEpoch, mapping: .mapped(
                    segments: [segment], provenance: .timelineReference
                )),
                EpochClockMap(epoch: untimedEpoch, mapping: .unsupported(.notAttempted)),
            ], placements: [
                OccurrencePlacement(occurrence: mapped, spans: [
                    EpochSpan(startFrame: 0, endFrame: 1_000, epoch: mappedEpoch, groupClockOffset: .zero),
                ]),
                OccurrencePlacement(occurrence: untimed, spans: [
                    EpochSpan(startFrame: 0, endFrame: 1_000, epoch: untimedEpoch, groupClockOffset: .zero),
                ]),
            ]),
        ])
        #expect(AlignmentWaveformProjection.timedSources(in: map) == [mapped.source])
        #expect(!AlignmentWaveformProjection.timedSources(in: map).contains(untimed.source))
        #expect(!AlignmentWaveformProjection.timedSources(in: map).contains(SourceID()))
    }

    @Test func scalableRulerKeepsTimeAndCursorInTheSameCoordinates() throws {
        let start = 90.0
        let width = 800.0
        let duration = 20.0
        let zoom = try #require(AlignmentWaveformProjection.rulerZoom(
            start: start, duration: duration, anchor: 0.25, magnification: 2, end: 120
        ))
        #expect(zoom.duration == 10)
        #expect(zoom.start == 92.5)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: 200, width: width, start: zoom.start, duration: zoom.duration, end: 120
        ) == 95)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: 400, width: width, start: start, duration: duration, end: 95
        ) == 95)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: -100, width: width, start: start, duration: duration, end: 120
        ) == 90)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 10, translation: 50, width: 500, duration: 5, end: 100
        ) == 9.5)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 0, translation: 500, width: 500, duration: 5, end: 100
        ) == 0)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 4, translation: 0, width: 500, duration: 2, end: 5
        ) == 4)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 4.5, translation: -200, width: 500, duration: 2, end: 5
        ) == 4.5)
        #expect(AlignmentWaveformProjection.rulerZoom(
            start: 0, duration: 20, anchor: 0.25, magnification: 0.01, end: 120
        )?.duration == 30)
        #expect(AlignmentWaveformProjection.rulerZoom(
            start: 0, duration: 20, anchor: 0.25, magnification: 1_000, end: 120
        )?.duration == 0.5)
        #expect(AlignmentWaveformProjection.rulerZoom(
            start: 4, duration: 2, anchor: 0, magnification: 2, end: 4
        )?.start == 3.5)
        #expect(AlignmentWaveformProjection.rulerZoom(
            start: 0, duration: 20, anchor: 0.25, magnification: 0, end: 120
        ) == nil)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: .nan, width: width, start: start, duration: duration, end: 120
        ) == nil)
    }

    @Test func rulerTickDensityAdaptsToVisibleScale() {
        let wide = AlignmentWaveformProjection.rulerTicks(start: 60, duration: 30, width: 600)
        let close = AlignmentWaveformProjection.rulerTicks(start: 60, duration: 0.5, width: 600)
        let wideMajors = wide.filter(\.major).map(\.time)
        let closeMajors = close.filter(\.major).map(\.time)
        #expect(wideMajors == [60, 70, 80, 90])
        #expect(closeMajors.count >= 3)
        #expect(closeMajors[1] - closeMajors[0] < 1)
        #expect(wide.count < 100 && close.count < 100)
        #expect(AlignmentWaveformProjection.rulerTicks(start: 0, duration: 0, width: 600).isEmpty)
    }

    @Test func distinctSpeakerColorsRemainStableWhenSpeakerOrderChanges() throws {
        let first = try #require(SpeakerID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(SpeakerID(uuidString: "00000000-0000-0000-0000-000000000009"))
        let ordered = [first, second]
        let firstColor = AlignmentWaveformProjection.speakerColorIndex(
            for: first, speakers: ordered, paletteCount: 8
        )
        let secondColor = AlignmentWaveformProjection.speakerColorIndex(
            for: second, speakers: Array(ordered.reversed()), paletteCount: 8
        )
        #expect(firstColor == 0)
        #expect(secondColor == 1)
        #expect(firstColor != secondColor)
    }

    @Test func displayColumnsMergePeaksWithoutMixingUnplacedAudio() throws {
        let epoch = RecordingEpochID()
        func stroke(_ time: Double, _ low: Float, _ high: Float, mapped: Bool) -> AlignmentWaveformStroke {
            AlignmentWaveformStroke(
                sourceSeconds: time, groupSeconds: time, displaySeconds: time,
                low: low, high: high, mapped: mapped, epoch: epoch,
                displayRange: time...time, groupRange: time...time
            )
        }
        let strokes = [
            stroke(0.100, -0.2, 0.3, mapped: true),
            stroke(0.101, -0.8, 0.1, mapped: true),
            stroke(0.102, -0.4, 0.6, mapped: false),
        ]
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: strokes, start: 0, duration: 1, width: 100, pixelsPerPoint: 2
        )
        #expect(columns.count == 2)
        #expect(columns[0].x == 10.25)
        #expect(columns[0].low == -0.8 && columns[0].high == 0.3 && columns[0].mapped)
        #expect(columns[1].low == -0.4 && columns[1].high == 0.6 && !columns[1].mapped)
        #expect(AlignmentWaveformProjection.displayColumns(
            strokes: strokes, start: .nan, duration: 1, width: 100, pixelsPerPoint: 2
        ).isEmpty)
    }

    @Test func completeMeasuredEnvelopeCanRoundTripThroughDerivedPayload() throws {
        let source = SourceID()
        let envelope = WaveformEnvelope(
            source: source, sampleRate: 48_000, channelCount: 2, totalFrames: 480_000,
            bins: [WaveformBin(firstFrame: 0, endFrame: 240_000, minimum: -0.7, maximum: 0.9),
                   WaveformBin(firstFrame: 240_000, endFrame: 480_000, minimum: -0.5, maximum: 0.6)]
        )
        #expect(try JSONDecoder().decode(
            WaveformEnvelope.self, from: JSONEncoder().encode(envelope)
        ) == envelope)
    }

    @Test func logarithmicZoomKeepsTheTimelineCenterAndBounds() throws {
        #expect(AlignmentWaveformProjection.zoomDuration(for: 0) == 30)
        #expect(AlignmentWaveformProjection.zoomDuration(for: 1) == 0.5)
        let level = try #require(AlignmentWaveformProjection.zoomLevel(for: 2))
        #expect(abs((AlignmentWaveformProjection.zoomDuration(for: level) ?? 0) - 2) < 0.000_001)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 10, duration: 2) == 9)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 10, duration: 0.5) == 9.75)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 0.5, duration: 30) == 0)
        #expect(AlignmentWaveformProjection.zoomDuration(for: .nan) == nil)
        #expect(AlignmentWaveformProjection.zoomLevel(for: 0) == nil)
        #expect(AlignmentWaveformProjection.zoomLevel(for: 31) == nil)
    }

    @Test func pendingMoveRetainsOnlyThePriorTileAtItsDroppedPosition() {
        let moved = RecorderGroupID()
        let reference = RecorderGroupID()
        let pending = PendingWaveformMove(
            group: moved, milliseconds: 25.75,
            priorGeneration: 12, expectedGeneration: 13
        )
        #expect(pending.retainsTile(generation: 12, liveGeneration: 13))
        #expect(!pending.retainsTile(generation: 12, liveGeneration: 12))
        #expect(!pending.retainsTile(generation: 12, liveGeneration: 14))
        #expect(!pending.retainsTile(generation: 11, liveGeneration: 13))
        #expect(pending.displayShift(for: moved) == 25.75)
        #expect(pending.displayShift(for: reference) == 0)
    }

    @Test func smallPointerDragStaysSmallWhenTheCanvasRelayouts() {
        let group = RecorderGroupID()
        let drag = AlignmentWaveformDrag(
            startX: 420, width: 400, durationSeconds: 2,
            initialMilliseconds: 10, group: group, snapshot: UUID()
        )
        #expect(drag.previewMilliseconds(at: 422) == 20)
        #expect(drag.previewMilliseconds(at: 424) == 30)
        #expect(drag.previewMilliseconds(at: 420) == 10)
        #expect(drag.previewMilliseconds(at: 20) == -1_990)
        #expect(drag.previewMilliseconds(at: -1_000) == -7_090)
        let next = AlignmentWaveformDrag(
            startX: 600, width: 400, durationSeconds: 2,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        )
        #expect(next.previewMilliseconds(at: 594) == -30)
        #expect(drag.previewMilliseconds(at: .nan) == nil)
        #expect(AlignmentWaveformDrag(
            startX: 0, width: 0, durationSeconds: 2,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        ).previewMilliseconds(at: 2) == nil)
        let fineDrag = AlignmentWaveformDrag(
            startX: 800, width: 2_000, durationSeconds: 30,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        )
        #expect(fineDrag.previewMilliseconds(at: 802) == 30)
        #expect(AlignmentWaveformProjection.moveMicroseconds(
            fromMilliseconds: fineDrag.previewMilliseconds(at: 802) ?? .nan
        ) == 30_000)
        #expect(AlignmentWaveformProjection.moveMicroseconds(fromMilliseconds: 25.75) == 25_750)
        #expect(AlignmentWaveformProjection.moveMicroseconds(fromMilliseconds: .nan) == nil)
    }

    @Test func sharedNavigationUsesFullSourceLengthNotOnlyTheLoadedWindow() {
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(
            durations: [(frames: 48_000 * 360, rate: 48_000)]
        ) == 360)
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(durations: []) == 0)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 240, duration: 2) == 239)
        let tile = AlignmentWaveformProjection.tileWindow(start: 239, visible: 2)
        #expect(tile?.start == 237)
        #expect(tile?.duration == 6)
        #expect(AlignmentWaveformProjection.tileWindow(start: 20, visible: 30)?.start == 20)
        #expect(AlignmentWaveformProjection.tileWindow(start: 0, visible: 5)?.start == 0)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239, visible: 2, width: 400
        ) == -400)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239.5, visible: 2, width: 400
        ) == -500)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239, visible: 0, width: 400
        ) == nil)
    }

    @Test func adjacentTilesCoverContinuousPanningWithoutRebuildingStrokes() {
        let first = UUID()
        let second = UUID()
        let tiles = [(id: first, start: 0.0, duration: 30.0),
                     (id: second, start: 30.0, duration: 30.0)]
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 1, duration: 30, tiles: tiles
        ) == [
            .init(id: first, range: 1...30),
            .init(id: second, range: 30...31),
        ])
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 29.5, duration: 30, tiles: tiles
        ) == [
            .init(id: first, range: 29.5...30),
            .init(id: second, range: 30...59.5),
        ])
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 60, duration: 30, tiles: tiles
        ).isEmpty)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 1, duration: 30, tiles: Array(tiles.prefix(1))
        ) == 30)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 1, duration: 30, tiles: tiles
        ) == nil)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 0, duration: 30, margin: 15, tiles: Array(tiles.prefix(1))
        ) == 30)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 0, duration: 30, margin: 15, tiles: tiles
        ) == nil)
        let overlap = [(id: first, start: 0.0, duration: 30.0),
                       (id: second, start: 15.0, duration: 30.0)]
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 10, duration: 30, tiles: overlap
        ) == [
            .init(id: first, range: 10...15),
            .init(id: second, range: 15...40),
        ])
    }

    @Test func tileClipStaysAttachedToMeasuredAudioAcrossPanZoomAndGroupMoves() throws {
        let clip = try #require(AlignmentWaveformProjection.tileClip(
            range: 15...30, tileStart: 0, tileDuration: 30, tileWidth: 600
        ))
        #expect(clip.origin == 300)
        #expect(clip.width == 300)
        let firstWindow = try #require(AlignmentWaveformProjection.tileTranslation(
            tileStart: 0, windowStart: 15, visible: 15, width: 300
        ))
        let pannedWindow = try #require(AlignmentWaveformProjection.tileTranslation(
            tileStart: 0, windowStart: 20, visible: 15, width: 300
        ))
        #expect(firstWindow + clip.origin == 0)
        #expect(pannedWindow + clip.origin == -100)
        let moved = PendingWaveformMove(
            group: RecorderGroupID(), milliseconds: 125,
            priorGeneration: 1, expectedGeneration: 2
        )
        #expect(firstWindow + clip.origin + moved.displayShift(for: moved.group) / 1_000 / 15 * 300 == 2.5)
        #expect(AlignmentWaveformProjection.tileClip(
            range: 15...31, tileStart: 0, tileDuration: 30, tileWidth: 600
        ) == nil)
    }

    @Test func visualNormalizationUsesEachWindowPeakWithoutChangingSamples() {
        let epoch = RecordingEpochID()
        let strokes = [
            AlignmentWaveformStroke(
                sourceSeconds: 0.5, groupSeconds: 0.5, displaySeconds: 0.5,
                low: -0.1, high: 0.2, mapped: true, epoch: epoch,
                displayRange: 0...1, groupRange: 0...1
            ),
            AlignmentWaveformStroke(
                sourceSeconds: 1.5, groupSeconds: 1.5, displaySeconds: 1.5,
                low: -0.5, high: 0.3, mapped: false, epoch: epoch,
                displayRange: 1...2, groupRange: 1...2
            ),
        ]
        #expect(AlignmentWaveformProjection.displayGain(for: strokes, normalized: false) == 1)
        #expect(AlignmentWaveformProjection.displayGain(for: strokes, normalized: true) == 2)
        #expect(strokes[0].high == 0.2)
        #expect(AlignmentWaveformProjection.displayGain(for: [], normalized: true) == 1)
        let silent = strokes.map {
            AlignmentWaveformStroke(
                sourceSeconds: $0.sourceSeconds, groupSeconds: $0.groupSeconds,
                displaySeconds: $0.displaySeconds, low: 0, high: 0,
                mapped: $0.mapped, epoch: $0.epoch,
                displayRange: $0.displayRange, groupRange: $0.groupRange
            )
        }
        #expect(AlignmentWaveformProjection.displayGain(for: silent, normalized: true) == 1)
    }

    @Test func overviewSeparatesSourceDurationFromAcceptedAlignedExtent() throws {
        func stroke(offset: Int64, ratio: Int64 = 1) throws -> AlignmentWaveformStroke {
            let group = RecorderGroupID()
            let epoch = RecordingEpochID()
            let occurrence = try SourceOccurrence(
                source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 360_000
            )
            let reference = TimelineReference(
                group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID()
            )
            let segment = try AffineClockSegment(
                groupClockStart: .zero, groupClockEnd: ExactRational(360),
                rateRatio: ExactRational(ratio), alignedOffset: ExactRational(offset)
            )
            let map = try GroupTimeMap(
                group: group, reference: reference,
                epochs: [EpochClockMap(
                    epoch: epoch,
                    mapping: .mapped(segments: [segment], provenance: .manual(.init(basis: .numericEntry)))
                )],
                placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 360_000, epoch: epoch, groupClockOffset: .zero)
                ])]
            )
            guard case let .aligned(first) = try map.alignedTime(ofFrame: 0, in: occurrence.id),
                  case let .aligned(last) = try map.alignedTime(ofFrame: 359_999, in: occurrence.id)
            else { throw TimeMapError.invalidFrameCount(360_000) }
            let range = first.instant.approximateDouble...last.instant.approximateDouble
            return AlignmentWaveformStroke(
                sourceSeconds: 180, groupSeconds: 180,
                displaySeconds: (range.lowerBound + range.upperBound) / 2,
                low: -0.5, high: 0.5, mapped: true, epoch: epoch,
                displayRange: range, groupRange: 0...359.999
            )
        }
        func start(_ time: Double, _ stroke: AlignmentWaveformStroke) -> Double? {
            AlignmentWaveformProjection.overviewWindowStart(at: time, duration: 5, strokes: [stroke])
        }
        let negativeOffset = try stroke(offset: -180)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: negativeOffset.displayRange) == [-180...0])
        #expect(start(-100, negativeOffset) == nil)
        #expect(start(0, negativeOffset) == 0)
        #expect(start(100, negativeOffset) == 97.5)
        #expect(start(200, negativeOffset) == nil)

        let positiveOffset = try stroke(offset: 86_410)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: positiveOffset.displayRange) == [positiveOffset.displayRange])
        #expect(start(86_500, positiveOffset) == nil)
        #expect(start(86_400, positiveOffset) == nil)

        let fasterClock = try stroke(offset: 86_200, ratio: 2)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: fasterClock.displayRange) == [86_400...fasterClock.displayRange.upperBound])
        #expect(start(86_400, fasterClock) == 86_397.5)
        #expect(start(86_400.001, fasterClock) == nil)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: 0...86_400).isEmpty)
    }

    @Test func overviewNavigationBoundsExactWindowWithoutMakingAnAnchor() {
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 7_200, duration: 5) == 7_197.5)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 0, duration: 30) == 0)
        for time in [-1.0, .nan, .infinity, 86_401] {
            #expect(AlignmentWaveformProjection.windowStart(centeredAt: time, duration: 5) == nil)
        }
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 1, duration: 31) == nil)
        #expect(AlignmentWaveformProjection.overviewExtent([]) == nil)
    }

    @Test func coveredBinSelectionNeverSnapsAcrossRestartGaps() {
        let first = RecordingEpochID()
        let restart = RecordingEpochID()
        let bins = [
            AlignmentWaveformStroke(
                sourceSeconds: 1.5, groupSeconds: 1.5, displaySeconds: 1.5,
                low: 0, high: 0.5, mapped: false, epoch: first,
                displayRange: 1...2, groupRange: 1...2
            ),
            AlignmentWaveformStroke(
                sourceSeconds: 3.5, groupSeconds: 0.5, displaySeconds: 3.5,
                low: 0, high: 0.5, mapped: false, epoch: restart,
                displayRange: 3...4, groupRange: 0...1
            ),
        ]
        func select(_ time: Double, draft: RecordingEpochID? = nil) -> AlignmentWaveformStroke? {
            AlignmentWaveformProjection.selectedStroke(
                at: time, strokes: bins, draftEpoch: draft, ratePPM: 0, offsetMilliseconds: 0
            )
        }
        #expect(select(1.5)?.epoch == first)
        #expect(select(3.5)?.epoch == restart)
        #expect(select(2.5) == nil)
        #expect(select(4.5) == nil)
        #expect(select(.nan) == nil)
        #expect(select(0.5, draft: restart)?.sourceSeconds == 3.5)
        #expect(select(3.5, draft: restart) == nil)
    }

    @Test func sameRecorderDoesNotMakeAnotherSourceAnEpochMatch() throws {
        let source = SourceID()
        let otherSource = SourceID()
        let group = RecorderGroupID()
        let first = RecordingEpochID()
        let second = RecordingEpochID()
        let restart = RecordingEpochID()
        let occurrence = try SourceOccurrence(
            source: source, nominalRate: NominalRate(48_000), frameCount: 96_000
        )
        let reference = TimelineReference(group: group, epoch: first, occurrence: occurrence.id)
        let referenceSegment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: .one, rateRatio: .one, alignedOffset: .zero
        )
        let otherOccurrence = try SourceOccurrence(
            source: otherSource, nominalRate: NominalRate(48_000), frameCount: 48_000
        )
        let clock = try GroupTimeMap(
            group: group, reference: reference,
            epochs: [
                EpochClockMap(epoch: first, mapping: .mapped(
                    segments: [referenceSegment], provenance: .timelineReference
                )),
                EpochClockMap(epoch: second, mapping: .unsupported(.notAttempted)),
                EpochClockMap(epoch: restart, mapping: .unsupported(.notAttempted)),
            ],
            placements: [
                OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 48_000, epoch: first, groupClockOffset: .zero),
                    EpochSpan(startFrame: 48_000, endFrame: 96_000, epoch: restart, groupClockOffset: .zero),
                ]),
                OccurrencePlacement(occurrence: otherOccurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 48_000, epoch: second, groupClockOffset: .zero),
                ]),
            ]
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [clock])
        #expect(AlignmentWaveformProjection.timelineEnd(map: map) == 1)
        #expect(AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: first, map: map
        ))
        #expect(AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: restart, map: map
        ))
        #expect(!AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: second, map: map
        ))
        #expect(!AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: restart, map: nil
        ))
    }
}
