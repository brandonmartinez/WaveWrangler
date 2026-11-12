import SwiftUI
import WWCommonEdit

struct SpokenNoPlayOverlay: View {
    let production: EpisodeProductionProjection?
    let presentation: AudioTimelineProjection
    let start: Double
    let duration: Double
    let enabled: Bool

    var body: some View {
        if enabled, production?.restrictSpeech == true {
            GeometryReader { geometry in
                let width = geometry.size.width
                let allowed = production?.speakerProgramFrames.map { frames in
                    let first = presentation.displayTime(forProgramTime: Double(frames.lowerBound) / 48_000)
                    let last = presentation.displayTime(forProgramTime: Double(frames.upperBound) / 48_000)
                    return first...last
                }
                let first = allowed.map { min(width, max(0, ($0.lowerBound - start) / duration * width)) } ?? width
                let last = allowed.map { min(width, max(0, ($0.upperBound - start) / duration * width)) } ?? width
                HStack(spacing: 0) {
                    AudioTimelineNoPlayHatch().frame(width: first)
                    Color.clear.frame(width: max(0, last - first))
                    AudioTimelineNoPlayHatch().frame(width: max(0, width - last))
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Spoken audio outside Speaker In and Speaker Out does not play in the production mix")
            .accessibilityIdentifier("ww.waveforms.noPlay")
        }
    }
}

struct AudioTimelineNoPlayHatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.78)))
            var lines = Path()
            for x in stride(from: -size.height, through: size.width, by: 9) {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(lines, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        }
        .clipped()
    }
}
