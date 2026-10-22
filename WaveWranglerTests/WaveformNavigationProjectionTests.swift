import Foundation
import Testing
import WWCore

@Suite("Waveform silhouette and scroll projection")
struct WaveformNavigationProjectionTests {
    @Test func zoomButtonsStepInOppositeDirectionsAndClamp() {
        #expect(AlignmentWaveformProjection.steppedZoomDuration(duration: 10, maximum: 30, zoomIn: true) == 8)
        #expect(AlignmentWaveformProjection.steppedZoomDuration(duration: 8, maximum: 30, zoomIn: false) == 10)
        #expect(AlignmentWaveformProjection.steppedZoomDuration(duration: 0.5, maximum: 30, zoomIn: true) == 0.5)
        #expect(AlignmentWaveformProjection.steppedZoomDuration(duration: 30, maximum: 30, zoomIn: false) == 30)
        #expect(AlignmentWaveformProjection.steppedZoomDuration(duration: .nan, maximum: 30, zoomIn: false) == nil)
    }

    @Test func crossTrackCutsSplitWaveformBinsAndRemoveCutAudioBeforeDrawing() throws {
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000),
        ])
        let bins = [stroke(0...3, amplitude: 0.5), stroke(1.1...1.9, amplitude: 1)]
        let shortened = AlignmentWaveformProjection.applyingCuts(cuts, to: bins)
        #expect(shortened.map(\.displayRange) == [0...1, 1...2])
        #expect(shortened.map(\.groupRange) == [0...1, 2...3])
        #expect(shortened.allSatisfy { $0.high == 0.5 })
        #expect(AlignmentWaveformProjection.applyingCuts(.unedited, to: bins) == bins)
    }

    private func stroke(
        _ span: ClosedRange<Double>, amplitude: Float, mapped: Bool = true,
        epoch: RecordingEpochID = RecordingEpochID()
    ) -> AlignmentWaveformStroke {
        let middle = (span.lowerBound + span.upperBound) / 2
        return AlignmentWaveformStroke(
            sourceSeconds: middle, groupSeconds: middle, displaySeconds: middle,
            low: -amplitude, high: amplitude, mapped: mapped, epoch: epoch,
            displayRange: span, groupRange: span)
    }

    @Test(arguments: [1.0, 2.0])
    func coarseBinsFillTheirMeasuredSpansWithoutBridgingGaps(scale: Double) {
        let bins = [
            stroke(0...1, amplitude: 0.8), stroke(1...2, amplitude: 0.2),
            stroke(2...3, amplitude: 0), stroke(4...5, amplitude: 0.5),
        ]
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: bins, start: 0, duration: 5, width: 500, pixelsPerPoint: scale)
        #expect(columns.count == Int(400 * scale))
        #expect(columns.filter { $0.x < 100 }.allSatisfy { $0.low == -0.8 && $0.high == 0.8 })
        #expect(columns.filter { (100..<200).contains($0.x) }.allSatisfy { $0.high == 0.2 })
        #expect(columns.filter { (200..<300).contains($0.x) }.allSatisfy { $0.high == 0 && $0.low == 0 })
        #expect(!columns.contains { (300..<400).contains($0.x) }, "No invented audio across a source/timing gap")
        #expect(columns.filter { $0.x > 400 }.allSatisfy { $0.high == 0.5 })
    }

    @Test func clippedBinsRemainVisibleEvenWhenTheirMidpointsAreOffscreen() {
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: [stroke(-2...2, amplitude: 0.75)], start: 1, duration: 0.5,
            width: 240, pixelsPerPoint: 2)
        #expect(columns.count == 480)
        #expect(columns.first?.x == 0.25 && columns.last?.x == 239.75)
        #expect(columns.allSatisfy { $0.low == -0.75 && $0.high == 0.75 })
    }

    @Test func compressionKeepsExtremaAndUnplacedAudioSeparate() {
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: [stroke(0...0.1, amplitude: 0.2), stroke(0.1...0.2, amplitude: 0.9),
                      stroke(0...0.2, amplitude: 0.4, mapped: false)],
            start: 0, duration: 20, width: 100, pixelsPerPoint: 1)
        #expect(columns.count == 2)
        #expect(columns.first?.mapped == true && columns.first?.high == 0.9)
        #expect(columns.last?.mapped == false && columns.last?.high == 0.4)
    }

    @Test func draftProjectionMovesBothEdgesOfTheMeasuredSpan() {
        let epoch = RecordingEpochID()
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: [stroke(1...2, amplitude: 0.8, epoch: epoch)],
            start: 0, duration: 5, width: 500, pixelsPerPoint: 1,
            draftEpoch: epoch, ratePPM: 100_000, offsetMilliseconds: 500)
        #expect(columns.first?.x == 160.5)
        #expect(columns.last?.x == 269.5)
        #expect(columns.count == 110)
    }

    @Test(arguments: [1.0, 2.0])
    func indexedDrawingMatchesFullScanAcrossOverlapsGapsAndDrafts(scale: Double) throws {
        let epoch = RecordingEpochID()
        let bins = [
            stroke(8...9, amplitude: 0.4), stroke(-10...20, amplitude: 0.1),
            stroke(-2...(-1), amplitude: 0.8, epoch: epoch),
            stroke(0...0, amplitude: 0.9), stroke(2...3, amplitude: 0.6, mapped: false),
            stroke(4...5, amplitude: 0.7, epoch: epoch), stroke(-1...0, amplitude: 0.3),
        ]
        let index = AlignmentWaveformStrokeIndex(strokes: bins)
        #expect(index.normalizedGain == AlignmentWaveformProjection.displayGain(for: bins, normalized: true))
        for start in stride(from: -12.0, through: 22, by: 0.5) {
            #expect(index.hasVisible(start: start, duration: 0.5)
                == !index.visible(start: start, duration: 0.5).isEmpty)
            for draft in [false, true] {
                let selectedEpoch = draft ? epoch : nil
                let visible = index.visible(start: start, duration: 0.5,
                    draftEpoch: selectedEpoch, ratePPM: 100_000, offsetMilliseconds: 500)
                let actual = AlignmentWaveformProjection.displayColumns(
                    strokes: visible, start: start, duration: 0.5, width: 160, pixelsPerPoint: scale,
                    draftEpoch: selectedEpoch, ratePPM: 100_000, offsetMilliseconds: 500)
                let expected = AlignmentWaveformProjection.displayColumns(
                    strokes: bins, start: start, duration: 0.5, width: 160, pixelsPerPoint: scale,
                    draftEpoch: selectedEpoch, ratePPM: 100_000, offsetMilliseconds: 500)
                #expect(actual == expected)
                #expect(visible == bins.filter { visible.contains($0) }, "Preserve hit-test tie order")
            }
        }
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000),
        ])
        let cutBins = AlignmentWaveformProjection.applyingCuts(cuts, to: bins)
        let cutIndex = AlignmentWaveformStrokeIndex(strokes: cutBins)
        #expect(AlignmentWaveformProjection.displayColumns(
            strokes: cutIndex.visible(start: -1, duration: 5), start: -1, duration: 5,
            width: 320, pixelsPerPoint: scale) == AlignmentWaveformProjection.displayColumns(
                strokes: cutBins, start: -1, duration: 5, width: 320, pixelsPerPoint: scale))
        #expect(index.visible(start: .nan, duration: 1).isEmpty)
        #expect(index.visible(start: 0, duration: 0).isEmpty)
        #expect(!index.hasVisible(start: .infinity, duration: 1))
    }

    @Test func viewportClipsRemainBoundedWhenZoomingPanningAndMoving() throws {
        for duration in [0.5, 1, 8, 30] {
            for start in [-10.0, 0, 10, 29.75, 40] {
                for shift in [-12.0, -0.25, 0, 0.25, 12] {
                    let clip = AlignmentWaveformProjection.viewportClip(
                        range: 0...30, start: start, duration: duration, width: 640, shift: shift)
                    let lower = max(0, start - shift), upper = min(30, start - shift + duration)
                    if upper > lower {
                        let clip = try #require(clip)
                        #expect(clip.drawingStart == start - shift)
                        #expect(clip.origin >= 0 && clip.width > 0 && clip.width <= 640)
                        #expect(clip.origin + clip.width <= 640.000_001)
                        #expect(abs(clip.origin - (lower - start + shift) / duration * 640) < 0.000_001)
                    } else {
                        #expect(clip == nil)
                    }
                }
            }
        }
        #expect(AlignmentWaveformProjection.viewportClip(
            range: 0...30, start: 0, duration: 0.5, width: 640, shift: .nan) == nil)
    }

    @Test func indexedLargeTimelineKeepsPerFrameWorkViewportBounded() {
        let epoch = RecordingEpochID()
        let bins = (0..<120_000).map {
            stroke(Double($0) / 100...Double($0 + 1) / 100, amplitude: Float($0 % 10) / 10, epoch: epoch)
        }
        let index = AlignmentWaveformStrokeIndex(strokes: bins)
        let start = 600.125, duration = 0.5
        let visible = index.visible(start: start, duration: duration)
        #expect(visible.count <= 52, "A close zoom must not prepare all 120,000 bins")
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: visible, start: start, duration: duration, width: 640, pixelsPerPoint: 2)
        #expect(columns.count <= 1_280)
        #expect(columns == AlignmentWaveformProjection.displayColumns(
            strokes: bins, start: start, duration: duration, width: 640, pixelsPerPoint: 2))
    }

    @Test func cachedExtentsMatchCombinedBinsIncludingPointTracksAndUnmappedAudio() {
        let tracks = [
            [stroke(-3...(-3), amplitude: 0.2)],
            [stroke(1...2, amplitude: 0.8), stroke(4...6, amplitude: 0.5)],
            [stroke(20...21, amplitude: 0.3, mapped: false)],
            [],
        ]
        let indices = tracks.map { AlignmentWaveformStrokeIndex(strokes: $0) }
        #expect(indices[0].displayExtent == -3...(-3))
        #expect(indices[2].mappedDisplayExtent == nil)
        #expect(AlignmentWaveformProjection.overviewExtent(indices: indices)
            == AlignmentWaveformProjection.overviewExtent(tracks.flatMap { $0 }))
        #expect(AlignmentWaveformProjection.overviewExtent(indices: indices, mappedOnly: true)
            == AlignmentWaveformProjection.overviewExtent(tracks.flatMap { $0 }.filter(\.mapped)))
        #expect(AlignmentWaveformProjection.overviewExtent(indices: [indices[0]]) == nil)
        #expect(AlignmentWaveformProjection.overviewExtent(indices: [AlignmentWaveformStrokeIndex.empty]) == nil)
    }

    @Test func scrollAxesKeepNormalVerticalScrollingNative() throws {
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: 0, deltaY: 12, option: false, precise: true) == nil)
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: 0.1, deltaY: 12, option: false, precise: true) == nil)
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: -12, deltaY: 0.1, option: false, precise: true) == .pan(-12))
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: 0, deltaY: 12, option: true, precise: true) == .resize(12))
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: 0, deltaY: -2, option: true, precise: false) == .resize(-20))
        let zoom = try #require(AlignmentWaveformProjection.scrollAction(
            deltaX: 12, deltaY: 0, option: true, precise: true))
        guard case let .zoom(magnification) = zoom else {
            Issue.record("Option-horizontal must zoom, not pan or resize")
            return
        }
        let viewport = try #require(AlignmentWaveformProjection.rulerZoom(
            duration: 8, playhead: 14, magnification: magnification,
            bounds: -100...100, maximumDuration: 30))
        #expect(abs(viewport.start + viewport.duration / 2 - 14) < 0.000_001)
        #expect(viewport.duration < 8)
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: .nan, deltaY: 0, option: true, precise: true) == nil)
    }

    @Test(arguments: [0.5, 1.0, 2.0, 8.0])
    func zoomCentersOnPlayheadInBothDirections(magnification: Double) throws {
        let window = try #require(AlignmentWaveformProjection.rulerZoom(
            duration: 8, playhead: 42, magnification: magnification,
            bounds: 0...120, maximumDuration: 120))
        #expect(window.duration == 8 / magnification)
        #expect(window.start + window.duration / 2 == 42)
    }

    @Test func zoomClampsAtTimelineEdgesAndRejectsInvalidInput() throws {
        let first = try #require(AlignmentWaveformProjection.rulerZoom(
            duration: 8, playhead: 0, magnification: 2, bounds: 0...120, maximumDuration: 30))
        #expect(first.start == 0 && first.duration == 4)
        let last = try #require(AlignmentWaveformProjection.rulerZoom(
            duration: 8, playhead: 120, magnification: 2, bounds: 0...120, maximumDuration: 30))
        #expect(last.start == 116 && last.duration == 4)
        for playhead in [-1, 121, .nan, .infinity] {
            #expect(AlignmentWaveformProjection.rulerZoom(
                duration: 8, playhead: playhead, magnification: 2,
                bounds: 0...120, maximumDuration: 30) == nil)
        }
    }
}
