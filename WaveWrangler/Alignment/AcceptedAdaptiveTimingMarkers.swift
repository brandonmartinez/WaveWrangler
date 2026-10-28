import SwiftUI
import WWCore

/// No listening-model observation: moving the playhead does not rebuild static timing labels.
struct AcceptedAdaptiveTimingMarkers: View, Equatable {
    let segments: [SourceTimingSegment]
    let start: Double
    let duration: Double
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let position = position(for: segment) {
                    let style = AlignmentWaveformView.adaptiveMarkerStyle(segment.kind, accepted: true)
                    Image(systemName: style.symbol)
                        .foregroundStyle(style.color).font(.caption)
                        .position(x: position, y: 12)
                        .help("Accepted \(style.label) at source \(AlignmentPresentation.formatTime(segment.sourceStart)). Pitch preserved; all file channels share this curve.")
                        .accessibilityLabel("Accepted \(style.label), pitch preserved")
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    func position(for segment: SourceTimingSegment) -> Double? {
        guard segment.alignedStart.isFinite, start.isFinite, duration.isFinite, duration > 0,
              size.width.isFinite, size.width >= 0 else { return nil }
        let position = (segment.alignedStart - start) / duration * size.width
        return (0...size.width).contains(position) ? position : nil
    }
}
