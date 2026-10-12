import Foundation
import Testing
import WWCore
import WWTimeMap

@Suite("Waveform selection")
struct AlignmentWaveformTests {
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
    }

    @Test func sharedNavigationUsesFullSourceLengthNotOnlyTheLoadedWindow() {
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(
            durations: [(frames: 48_000 * 360, rate: 48_000)]
        ) == 360)
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(durations: []) == 0)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 240, duration: 2) == 239)
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
