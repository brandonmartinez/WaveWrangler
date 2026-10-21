import Foundation
import Testing
import WWCore

@Suite("Waveform silhouette and scroll projection")
struct WaveformNavigationProjectionTests {
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
            start: 12, duration: 8, anchor: 0.25, magnification: magnification,
            bounds: -100...100, maximumDuration: 30))
        #expect(abs(viewport.start + viewport.duration * 0.25 - 14) < 0.000_001)
        #expect(viewport.duration < 8)
        #expect(AlignmentWaveformProjection.scrollAction(
            deltaX: .nan, deltaY: 0, option: true, precise: true) == nil)
    }
}
