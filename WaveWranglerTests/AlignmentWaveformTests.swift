import Testing
import WWCore
import WWTimeMap

@Suite("Waveform selection")
struct AlignmentWaveformTests {
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
