import Observation
import SwiftUI
import WWCore

@MainActor
@Observable
final class EpisodeListeningState {
    enum Tool: String, CaseIterable {
        case select = "Select"
        case move = "Move recorder"
    }

    var playback = EpisodePlaybackState()
    var tool = Tool.select
    var selection: ClosedRange<Double>?
    var selectedTranscriptText: String?
    var cycleRange: ClosedRange<Double>?
    var cycleEnabled = false
    var collapsedRecorders: Set<RecorderGroupID> = []
    var collapsedSpeakers: Set<SpeakerID> = []
    var editingPolicyRevision: Int?
    var previousPlayback: EpisodePlaybackState?

    func select(from start: Double, to end: Double, within bounds: ClosedRange<Double>) {
        guard start.isFinite, end.isFinite else { return }
        let lo = max(bounds.lowerBound, min(start, end))
        let hi = min(bounds.upperBound, max(start, end))
        selection = hi > lo ? lo...hi : nil
        selectedTranscriptText = nil
    }

    func auditionRange(context: Double, within bounds: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard let selection, context.isFinite, context >= 0 else { return nil }
        let lo = max(bounds.lowerBound, selection.lowerBound - context)
        let hi = min(bounds.upperBound, selection.upperBound + context)
        return hi > lo ? lo...hi : nil
    }
}

struct AudioTimelineSelectionOverlay: View {
    @Bindable var listening: EpisodeListeningState
    let start: Double
    let duration: Double
    let play: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            if let range = listening.selection, duration > 0 {
                let lo = max(0, (range.lowerBound - start) / duration * geometry.size.width)
                let hi = min(geometry.size.width, (range.upperBound - start) / duration * geometry.size.width)
                if hi > lo {
                    Rectangle().fill(Color.accentColor.opacity(0.16))
                        .frame(width: hi - lo, height: geometry.size.height)
                        .offset(x: lo)
                        .allowsHitTesting(false)
                    HStack(spacing: 4) {
                        Button("Play selection", systemImage: "play.fill") { play(0) }
                        Button("Play with context", systemImage: "play.rectangle") { play(0.5) }
                        Button("Cycle selection", systemImage: "repeat") {
                            listening.cycleRange = range
                            listening.cycleEnabled = true
                        }
                        Button("Clear selection", systemImage: "xmark") {
                            listening.selection = nil
                            listening.selectedTranscriptText = nil
                        }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
                    .padding(3).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .offset(x: min(lo, max(0, geometry.size.width - 140)), y: 3)
                    .help("Audition uses the current Solo/Mute choices. Context adds half a second; episode IN/OUT is unchanged.")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ww.timeline.selection.actions")
                }
            }
        }
    }
}

struct AudioTimelineListeningButtons: View {
    @Bindable var listening: EpisodeListeningState
    let scope: EpisodePlaybackScope
    let name: String
    var changed: () -> Void = {}

    var body: some View {
        HStack(spacing: 3) {
            Button("S") {
                listening.playback.setSoloed(!listening.playback.soloed.contains(scope), scope: scope)
                changed()
            }
            .tint(listening.playback.soloed.contains(scope) ? .yellow : .secondary)
            .accessibilityLabel("Solo \(name)")
            .accessibilityValue(listening.playback.soloed.contains(scope) ? "On" : "Off")
            .accessibilityIdentifier("ww.listening.solo.\(scopeIdentifier)")
            .help("Add this track or group's files to the solo selection. Explicit Mute always wins.")
            Button("M") {
                listening.playback.setMuted(!listening.playback.muted.contains(scope), scope: scope)
                changed()
            }
            .tint(listening.playback.muted.contains(scope) ? .orange : .secondary)
            .accessibilityLabel("Mute \(name)")
            .accessibilityValue(listening.playback.muted.contains(scope) ? "On" : "Off")
            .accessibilityIdentifier("ww.listening.mute.\(scopeIdentifier)")
            .help("Mute this track or group's files without changing other Solo/Mute choices or assignments.")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private var scopeIdentifier: String {
        switch scope {
        case .source(let id): "source.\(id)"
        case .speaker(let id): "speaker.\(id)"
        case .recorder(let id): "recorder.\(id)"
        }
    }
}
