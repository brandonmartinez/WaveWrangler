import SwiftUI
import WWCore

struct EpisodeControlBar: View {
    @Bindable var model: EpisodeAlignmentModel
    @Bindable var state: ShowWindowState
    let width: CGFloat
    @Bindable private var settings = AppSettings.shared
    @State private var showingMore = false

    private var cleanup: EpisodeCleanupModel? { state.cleanupModel }
    private var hasRecordings: Bool { model.audioEditor.episode?.alignmentSources.isEmpty == false }
    private var processing: Bool { TrackProcessingOperation.current(alignment: model, cleanup: cleanup) != nil }
    private var layout: AlignmentWaveformLayout { model.listening.workspace.layout }
    private var navigation: AudioTimelineNavigation {
        AudioTimelineNavigation(
            prefix: "alignment.waveforms", maximumDuration: model.maximumWaveformDuration,
            duration: Binding(get: { model.waveformDurationSeconds }, set: {
                _ = model.zoomWaveformViewport(magnification: model.waveformDurationSeconds / $0)
            }),
            laneHeight: Binding(get: { model.listening.workspace.laneHeight }, set: {
                model.listening.workspace.fillSpace = false
                model.listening.workspace.laneHeight = min(220, max(64, $0))
            }),
            showsLaneHeight: layout != .overlay,
            isLoading: hasRecordings && model.isLoadingWaveforms,
            canNavigate: model.pendingWaveformMove == nil && !processing,
            zoomEditing: { editing in
                if !editing, hasRecordings, model.waveformDurationSeconds <= 30 {
                    model.loadWaveforms(keepingSnapshot: true, preload: true)
                }
            },
            fit: { if model.waveformFitRange != nil { model.fitWaveformTimeline() } },
            refresh: refreshWaveforms,
            fillSpace: Binding(get: { model.listening.workspace.fillSpace }, set: {
                model.listening.workspace.fillSpace = $0
            }),
            showsRefresh: false, compactScales: true)
    }

    private var displayedControls: [ControlBarConfiguration.Control] {
        var available = Set(ControlBarConfiguration.Control.allCases)
        if layout == .overlay { available.remove(.height) }
        return settings.controlBar.displayedControls(width: max(0, (width - 216) / 2 - 48), available: available)
    }

    private var overflowNavigation: AudioTimelineNavigation {
        var result = navigation
        result.compactScales = false
        return result
    }

    var body: some View {
        EpisodeControlBarLayout {
            HStack(spacing: 10) {
                if width >= 1000 {
                    AudioWorkspaceActions(state: state, alignment: model, surface: .add)
                    Divider().frame(height: 28)
                }
                listeningMode
                transport
            }
            EpisodeClockDisplay(model: model, clock: $settings.controlBar.primaryClock,
                                configuration: settings.controlBar)
            HStack(spacing: 10) {
                ForEach(settings.controlBar.groups, id: \.self) { group in
                    let controls = displayedControls.filter { $0.group == group }
                    if !controls.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(controls, id: \.self) { control in primaryControl(control) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ww.controlBar.group.\(group.rawValue)")
                        Divider().frame(height: 28)
                    }
                }
                Button("More", systemImage: "ellipsis") { showingMore.toggle() }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("ww.controlBar.more")
                    .help("Episode actions, boundary editing, timeline tools, and view controls")
                    .popover(isPresented: $showingMore) { moreControls }
            }
            .labelStyle(ControlBarLabelStyle(showsLabels: settings.controlBar.showsLabels))
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .background(TimelineToolModifierMonitor(listening: model.listening).frame(width: 0, height: 0))
        .contextMenu { customize }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.controlBar")
    }

    @ViewBuilder
    private func primaryControl(_ control: ControlBarConfiguration.Control) -> some View {
        switch control {
        case .boundaries: EpisodeBoundaryControls(model: model, cleanup: cleanup)
        case .primaryTool: TimelineToolControls(listening: model.listening, showsCommand: false)
        case .commandTool: TimelineToolControls(listening: model.listening, showsPrimary: false)
        case .anchors: anchorMenu
        case .zoom: navigation.zoomControls
        case .height: navigation.heightControls
        case .layout: layoutPicker
        case .fit: navigation.fitButton
        case .fillSpace: navigation.fillSpaceButton
        case .normalize: normalization
        }
    }

    private var listeningMode: some View {
        Menu {
            Button("Production Mix") { model.selectProductionMix() }
                .accessibilityIdentifier("ww.audioWorkspace.playMix")
            Button("Source Audition") { model.selectSourceAudition() }
                .accessibilityIdentifier("ww.audioWorkspace.sourceAudition")
        } label: {
            Label(model.listening.usesProductionMix ? "Mix" : "Source",
                  systemImage: model.listening.usesProductionMix ? "waveform" : "ear")
        }
        .fixedSize()
        .accessibilityIdentifier("ww.controlBar.listeningMode")
        .accessibilityValue(model.listening.usesProductionMix ? "Production Mix" : "Source Audition")
        .help("Mix follows Episode Start/End and saved speaker restriction. Source Audition is diagnostic and may expose excluded original audio.")
    }

    private var transport: some View {
        AudioTimelineTransport(
            prefix: "alignment.waveforms", isPlaying: model.canStopAudition,
            isPreparing: model.isPreparingAudition, canPlay: !processing, canNavigate: !processing,
            playhead: model.waveformPlayheadSeconds, status: model.auditionLabel,
            back: { model.jumpEnabledTracks(by: -settings.timelineJumpInterval.seconds) },
            playPause: { model.canStopAudition ? model.pauseEnabledTracks() : model.playTransport() },
            stop: { model.stopEnabledTracks() },
            forward: { model.jumpEnabledTracks(by: settings.timelineJumpInterval.seconds) },
            seek: { model.seekEnabledTracks(to: $0) },
            isEdited: !model.isSourceTimePreview && !model.cutTimeline.removals.isEmpty,
            cycleEnabled: width >= 900 ? model.listening.cycleEnabled : nil,
            toggleCycle: toggleCycle,
            followPlayhead: width >= 900 ? model.listening.workspace.followPlayhead : nil,
            toggleFollowPlayhead: { model.setFollowPlayhead(!model.listening.workspace.followPlayhead) },
            jumpSeconds: settings.timelineJumpInterval.rawValue,
            showsDisplay: false, showsStatus: false, compact: true, showsJumps: width >= 1200)
        .padding(.vertical, 2)
    }

    private func toggleCycle() {
        if model.listening.cycleRange == nil {
            model.listening.setCycleRange(model.listening.selection ?? model.waveformAuditionBounds)
        }
        model.listening.cycleEnabled.toggle()
    }

    private var moreControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if width < 1000 { AudioWorkspaceActions(state: state, alignment: model, surface: .add) }
                Text("Episode").font(.headline)
                EpisodeBoundaryControls(model: model, cleanup: cleanup)
                AudioWorkspaceWorkflowActions(state: state, alignment: model)
                AudioWorkspaceActions(state: state, alignment: model, surface: .listening)
                Button("Transcription Settings…", systemImage: "gearshape") {
                    SettingsWindowController.show(pane: .transcription)
                }
                .help(cleanup?.transcriptionSettings.selection.title ?? "Transcription engine settings")
                Divider()
                Text("Timeline").font(.headline)
                HStack {
                    if width < 1200 {
                        Button("Jump Back") { model.jumpEnabledTracks(by: -settings.timelineJumpInterval.seconds) }
                        Button("Jump Forward") { model.jumpEnabledTracks(by: settings.timelineJumpInterval.seconds) }
                    }
                    if width < 900 {
                        Toggle("Cycle", isOn: Binding(get: { model.listening.cycleEnabled }, set: { enabled in
                            if enabled, model.listening.cycleRange == nil {
                                model.listening.setCycleRange(model.listening.selection ?? model.waveformAuditionBounds)
                            }
                            model.listening.cycleEnabled = enabled
                        }))
                        Toggle("Follow Playhead", isOn: Binding(get: { model.listening.workspace.followPlayhead },
                                                               set: { model.setFollowPlayhead($0) }))
                    }
                }
                TimelineToolControls(listening: model.listening)
                anchorMenu
                Divider()
                Text("View").font(.headline)
                layoutPicker
                normalization
                overflowNavigation.zoomGroup
                overflowNavigation.heightGroup
                AudioTimelineRefresh(
                    prefix: "alignment.waveforms",
                    isLoading: hasRecordings && (model.isLoadingWaveforms || model.isLoadingOverview),
                    canNavigate: model.pendingWaveformMove == nil && !processing,
                    refresh: refreshWaveforms)
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                customize
                if let error = settings.controlBarError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .controlSize(.small).disabled(processing)
            .padding(16).frame(width: 560, alignment: .leading)
        }
        .frame(width: 560, height: 500)
        .accessibilityIdentifier("ww.controlBar.overflow")
    }

    private var customize: some View {
        Button("Customize Control Bar and Display…", systemImage: "slider.horizontal.3") {
            ControlBarCustomizationController.show()
        }
        .accessibilityIdentifier("ww.controlBar.customize")
    }

    private var anchorMenu: some View {
        Menu("Anchor points", systemImage: "pin") {
            if let track = model.selectedWaveform { AlignmentAnchorControls(model: model, track: track) }
            else { Text("Click a point on a waveform first.") }
        }
        .fixedSize().labelStyle(.iconOnly)
        .help("Mark a sound on the reference, link the same sound on another recording, then apply offset or drift.")
        .accessibilityIdentifier("alignment.waveforms.anchorPoints")
    }

    private var layoutPicker: some View {
        Picker("Track view", selection: Binding(get: { layout }, set: { model.listening.workspace.layout = $0 })) {
            ForEach(AlignmentWaveformLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .accessibilityLabel("Compare waveform layout")
        .accessibilityIdentifier("alignment.waveforms.layout")
        .help("Speakers only shows confirmed Primary tracks and mutes non-primary tracks. Primary Solo/Mute choices are preserved. Hidden tracks receive the same cross-track cuts.")
    }

    private var normalization: some View {
        Toggle("Normalize view", isOn: Binding(get: { model.listening.workspace.normalizeView },
                                              set: { model.listening.workspace.normalizeView = $0 }))
            .toggleStyle(.checkbox)
            .help("Scales displayed peaks only. Playback, originals, and saved timing are unchanged.")
            .accessibilityIdentifier("alignment.waveforms.normalizeView")
    }

    private func refreshWaveforms() {
        if hasRecordings && (model.isLoadingWaveforms || model.isLoadingOverview) {
            model.cancelWaveforms(keepingSnapshot: true)
            model.cancelWaveformOverview(keepingSnapshot: true)
        } else {
            model.audioEditor.reloadWaveforms()
            if hasRecordings { model.loadWaveforms(keepingSnapshot: model.pendingWaveformMove != nil) }
            if let cleanup, !cleanup.isBusy, !cleanup.isRefreshing, !model.isWorking {
                Task { await cleanup.refresh() }
            }
        }
    }
}

// Equal side regions keep the display centered independently of inspector and control visibility.
struct EpisodeControlBarLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 760, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}
