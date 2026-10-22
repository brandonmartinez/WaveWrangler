import SwiftUI

struct AudioTimelineTrackStack<Content: View>: View {
    let fits: Bool
    var spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if fits {
            VStack(alignment: .leading, spacing: spacing, content: content)
        } else {
            LazyVStack(alignment: .leading, spacing: spacing, content: content)
        }
    }
}

struct AudioTimelineFitMeasurement: Equatable {
    var laneHeight = 0.0
    var contentHeight = 0.0
    var rows = 0
}

struct AudioTimelineFitRequest: Equatable {
    let enabled: Bool
    let measurement: AudioTimelineFitMeasurement
    let viewport: Double
}

enum AudioTimelineTrackFit {
    static let minimumHeight = 64.0

    static func height(current: Double, viewport: Double, content: Double,
                       rows: Int, scale: Double) -> Double? {
        guard rows > 0, current.isFinite, viewport.isFinite, viewport > 0,
              content.isFinite, content > 0, scale.isFinite, scale > 0 else { return nil }
        // Measure real chrome (including metadata-only rows), not fabricated waveform counts.
        let next = max(minimumHeight, floor((current + (viewport - content) / Double(rows)) * scale) / scale)
        return abs(next - current) >= 1 / scale ? next : nil
    }
}
