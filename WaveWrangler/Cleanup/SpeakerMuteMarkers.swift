import SwiftUI
import WWCore

struct SpeakerMuteMarkers: View {
    @Bindable var model: EpisodeCleanupModel
    let speaker: SpeakerID
    let selectContext: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let projection = model.cutTimeline
            ForEach(model.activeSpeakerMuteRegions.filter { $0.speaker == speaker }) { region in
                let spans = projection.originalRanges(in: region.alignedStart...region.alignedEnd)
                    .map { projection.displayRange(forOriginalRange: $0) }
                    .filter { $0.upperBound > model.windowStart && $0.lowerBound < model.windowStart + model.visibleDuration
                        && $0.upperBound > $0.lowerBound }
                if !spans.isEmpty {
                    ZStack(alignment: .topLeading) {
                        ForEach(spans.indices, id: \.self) { index in
                            let lo = max(0, x(spans[index].lowerBound, width: geometry.size.width))
                            let hi = min(geometry.size.width, x(spans[index].upperBound, width: geometry.size.width))
                            AudioTimelineNoPlayHatch()
                                .frame(width: max(0, hi - lo), height: geometry.size.height)
                                .offset(x: lo)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        ForEach([region.alignedStart, region.alignedEnd], id: \.self) { time in
                            let position = x(projection.editedTime(forAlignedTime: time), width: geometry.size.width)
                            Rectangle().fill(.orange).frame(width: 1.5, height: geometry.size.height)
                                .offset(x: position)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        Button("Muted speaker region", systemImage: "speaker.slash.fill") {
                            selectContext()
                            model.selectSpeakerMute(region.id)
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption.bold())
                        .padding(3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .buttonStyle(.plain)
                        .offset(x: min(max(0, x(spans[0].lowerBound, width: geometry.size.width)),
                                       max(0, geometry.size.width - 24)), y: 22)
                        .help("Select this speaker-only mute region for removal. No time has been removed.")
                        .accessibilityValue(String(format: "%.3f to %.3f aligned seconds",
                            region.alignedStart, region.alignedEnd))
                        .accessibilityIdentifier("ww.timeline.speakerMute.\(region.id)")
                        .contextMenu {
                            Button("Remove speaker mute", systemImage: "speaker.wave.2") {
                                model.removeSpeakerMute(region.id)
                            }
                            .disabled(!model.state.canEdit || model.isBusy || model.isRefreshing)
                        }
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(model.listening.effectiveTool == .select)
        .accessibilityElement(children: .contain)
    }

    private func x(_ time: Double, width: Double) -> Double {
        (time - model.windowStart) / model.visibleDuration * width
    }
}
