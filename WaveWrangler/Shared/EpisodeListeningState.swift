import Observation
import SwiftUI
import WWCore

@MainActor
@Observable
final class EpisodeListeningState {
    var workspace = EpisodeWorkspaceViewState() {
        didSet {
            if workspace != oldValue { viewStore?.save(workspace) }
        }
    }
    @ObservationIgnored private var viewStore: EpisodeWorkspaceViewStore?

    func restoreWorkspace(from store: EpisodeWorkspaceViewStore) {
        workspace = store.load() ?? EpisodeWorkspaceViewState()
        viewStore = store
    }

    enum Tool: String, CaseIterable {
        case select = "Pointer"
        case move = "Move recorder"
        case reviewed = "Reviewed"
        case reject = "Reject"

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .move: "hand.draw"
            case .reviewed: "checkmark.circle"
            case .reject: "xmark.circle"
            }
        }

        var reviewDecision: FillerReviewDecision? {
            switch self {
            case .reviewed: .reviewed
            case .reject: .rejected
            case .select, .move: nil
            }
        }
    }

    var playback = EpisodePlaybackState()
    var tool = Tool.select
    var commandTool = Tool.move
    private(set) var commandHeld = false
    var effectiveTool: Tool { commandHeld ? commandTool : tool }

    func updateCommandModifier(_ held: Bool) { commandHeld = held }

    @discardableResult
    func applyListeningPreset(_ policy: EditingPlaybackPolicy, in episode: Episode) throws -> Bool {
        let updated = try playback.applying(policy, in: episode)
        guard updated != playback else { return false }
        if previousPlayback == nil { previousPlayback = playback }
        playback = updated
        return true
    }

    func listeningPresetIsActive(_ policy: EditingPlaybackPolicy, in episode: Episode) -> Bool {
        guard policy != .keepChoices, playback.canApply(policy, in: episode) else { return false }
        return (try? playback.applying(policy, in: episode)) == playback
    }

    var selection: ClosedRange<Double>? {
        didSet {
            if selection != oldValue, selection != nil { selectionToolsPresented = true }
        }
    }
    var selectionToolsPresented = true
    var selectedTranscriptText: String?
    var expandedManualCutID: UUID? {
        get { workspace.expandedManualCutID }
        set { workspace.expandedManualCutID = newValue }
    }
    var cycleRange: ClosedRange<Double>?
    var cycleEnabled = false

    func setCycleRange(_ range: ClosedRange<Double>, selecting: Bool = false) {
        let updatesSelection = selecting || (cycleRange != nil && selection == cycleRange)
        cycleRange = range
        if updatesSelection {
            selection = range
            selectedTranscriptText = nil
        }
    }
    var collapsedRecorders: Set<RecorderGroupID> {
        get { workspace.collapsedRecorders }
        set { workspace.collapsedRecorders = newValue }
    }
    var collapsedSpeakers: Set<SpeakerID> {
        get { workspace.collapsedSpeakers }
        set { workspace.collapsedSpeakers = newValue }
    }
    var editingPolicyRevision: Int?
    private var appliedEditingPolicies: Set<String> = []
    var previousPlayback: EpisodePlaybackState?

    func applyAcceptedAlignmentPolicy(
        _ policy: EditingPlaybackPolicy, in episode: Episode, identity: String, revision: Int
    ) throws {
        let acceptance = "\(revision):\(identity)"
        guard !appliedEditingPolicies.contains(acceptance) else { return }
        let updated = try playback.applying(policy, in: episode)
        if policy != .keepChoices { previousPlayback = playback }
        playback = updated
        appliedEditingPolicies.insert(acceptance)
        editingPolicyRevision = revision
    }

    func select(from start: Double, to end: Double, within bounds: ClosedRange<Double>) {
        guard start.isFinite, end.isFinite else { return }
        let lo = max(bounds.lowerBound, min(start, end))
        let hi = min(bounds.upperBound, max(start, end))
        selection = hi > lo ? lo...hi : nil
        selectionToolsPresented = true
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

    var body: some View {
        GeometryReader { geometry in
            if let range = listening.selection, duration > 0 {
                let lo = max(0, (range.lowerBound - start) / duration * geometry.size.width)
                let hi = min(geometry.size.width, (range.upperBound - start) / duration * geometry.size.width)
                if hi > lo {
                    Rectangle().fill(Color.accentColor.opacity(0.16))
                        .frame(width: hi - lo, height: geometry.size.height)
                        .offset(x: lo)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AudioTimelineSelectionToolbar: View {
    @Bindable var listening: EpisodeListeningState
    let start: Double
    let duration: Double
    let play: (Double) -> Void
    var cleanup: EpisodeCleanupModel? = nil
    var trackWidth = 400.0

    private var rowHeight: Double {
        Self.height(width: trackWidth, cleanup: cleanup)
    }

    static func height(width: Double, cleanup: EpisodeCleanupModel?) -> Double {
        cleanup?.selectedManualCut == nil && cleanup?.selectedFiller != nil && width < 350 ? 76 : 44
    }

    var body: some View {
        GeometryReader { geometry in
            if let range = cleanup?.manualCutSelection ?? listening.selection, duration > 0 {
                let lo = max(0, (range.lowerBound - start) / duration * geometry.size.width)
                let hi = min(geometry.size.width, (range.upperBound - start) / duration * geometry.size.width)
                if hi > lo || (cleanup?.selectedManualCut != nil && hi >= 0 && lo <= geometry.size.width) {
                    let toolbarWidth = min(geometry.size.width,
                        cleanup?.selectedManualCut != nil ? 252 : cleanup?.selectedFiller == nil ? 184 : 366)
                    let horizontal = cleanup?.selectedFiller == nil || toolbarWidth >= 350
                    let layout = horizontal
                        ? AnyLayout(HStackLayout(spacing: 6))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    layout {
                        if let cleanup, let cut = cleanup.selectedManualCut {
                            ManualCutToolbar(model: cleanup, cut: cut)
                        } else {
                            auditionButtons(range)
                        }
                        if let cleanup, cleanup.selectedManualCut == nil, let review = cleanup.selectedFiller {
                            if horizontal {
                                Divider().frame(height: 22)
                            } else {
                                Divider()
                            }
                            FillerTimingToolbar(model: cleanup, reviewID: review.id)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .padding(4)
                    .frame(width: toolbarWidth)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .background(AudioTimelineToolbarClickAway {
                        listening.selectionToolsPresented = false
                    })
                    .position(x: TimelineToolbarPlacement.center(
                        selectionStart: lo, selectionEnd: hi,
                        toolbarWidth: toolbarWidth, trackWidth: geometry.size.width),
                        y: geometry.size.height / 2)
                    .help("Audition uses current Solo/Mute choices. Context adds up to half a second; episode IN/OUT is unchanged.")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ww.timeline.selection.actions")
                    .accessibilitySortPriority(1)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func auditionButtons(_ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Button("Play selection", systemImage: "play.fill") { play(0) }
            Button("Play with context", systemImage: "play.rectangle") { play(0.5) }
            if let cleanup, cleanup.selectedFiller != nil {
                Button("Loop marker", systemImage: "repeat") {
                    cleanup.loopsFillerAudition.toggle()
                }
                .tint(cleanup.loopsFillerAudition ? .accentColor : .secondary)
                .accessibilityValue(cleanup.loopsFillerAudition ? "On" : "Off")
                .accessibilityIdentifier("ww.cleanup.filler.loop")
                if cleanup.isPlaying || cleanup.isPreparingPlayback {
                    Button("Stop audition", systemImage: "stop.fill") { cleanup.stopPlayback() }
                        .accessibilityIdentifier("ww.cleanup.filler.stop")
                }
            } else {
                Button("Cycle selection", systemImage: "repeat") {
                    listening.setCycleRange(range)
                    listening.cycleEnabled = true
                }
            }
            Button("Clear selection", systemImage: "xmark") {
                cleanup?.selectedFillerID = nil
                listening.selection = nil
                listening.selectedTranscriptText = nil
            }
            if let cleanup {
                Button("Cut across all aligned tracks", systemImage: "scissors") { cleanup.applyManualCut() }
                    .tint(.red)
                    .disabled(!cleanup.canApplyManualCut)
                    .help("Remove this interval from every aligned track and ripple following audio to its start. Originals remain unchanged; Undo restores it.")
                    .accessibilityIdentifier("ww.timeline.selection.cut")
            }
        }
        .labelStyle(.iconOnly)
    }
}

enum TimelineToolbarPlacement {
    static func center(selectionStart: Double, selectionEnd: Double,
                       toolbarWidth: Double, trackWidth: Double) -> Double {
        let half = min(max(0, toolbarWidth), max(0, trackWidth)) / 2
        return min(max(half, (selectionStart + selectionEnd) / 2), max(half, trackWidth - half))
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
