import SwiftUI
import WWAlignPipeline
import WWCore

struct AlignmentWaveformView: View {
    @Bindable var model: EpisodeAlignmentModel
    var cleanup: EpisodeCleanupModel? = nil
    var showTranscript: () -> Void = {}
    let showInspector: () -> Void
    #if DEBUG
    var trackVisibilityChanged: ((SourceID, Bool) -> Void)?
    #endif
    @Environment(\.displayScale) private var displayScale
    @State private var dragSession: AlignmentWaveformDrag?
    private var layout: AlignmentWaveformLayout {
        get { model.listening.workspace.layout }
        nonmutating set { model.listening.workspace.layout = newValue }
    }
    private var normalizeView: Bool {
        get { model.listening.workspace.normalizeView }
        nonmutating set { model.listening.workspace.normalizeView = newValue }
    }
    private var showProposedAlignment: Bool {
        get { model.listening.workspace.showProposedAlignment }
        nonmutating set { model.listening.workspace.showProposedAlignment = newValue }
    }
    private var laneHeight: Double {
        get { model.listening.workspace.laneHeight }
        nonmutating set { model.listening.workspace.laneHeight = newValue }
    }
    @State private var trackScrollPosition = ScrollPosition(y: 0)
    @State private var trackContentWidth: CGFloat = 0
    @State private var hoveringMovableWaveform = false
    @State private var handCursorPushed = false
    @State private var confirmingExtension = false
    @State private var confirmingReset = false
    @State private var confirmingAdaptiveAcceptance = false

    private let headerWidth: CGFloat = 190

    private typealias WaveformTrackDrawing = AudioTimelineWaveformDrawing

    private var groups: [RecorderGroupID] {
        var seen: Set<RecorderGroupID> = []
        return model.waveformTracks.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    private var visibleTracks: [AlignmentWaveformTrack] {
        layout == .speakersOnly
            ? model.waveformTracks.filter { model.primaryWaveformSources.contains($0.id) }
            : model.waveformTracks
    }
    private var activeSourceID: SourceID? {
        if let selected = model.selectedWaveformSource, visibleTracks.contains(where: { $0.id == selected }) {
            return selected
        }
        return visibleTracks.first?.id
    }

    private var trackContent: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
                if model.waveformMap == nil, model.pendingWaveformMove == nil,
                   !model.waveformTracks.isEmpty {
                    if model.hasAcceptedRevision {
                        Text("Accepted timing is unavailable for these sources; it cannot be used for another match.")
                            .font(.caption).foregroundStyle(.secondary)
                        resetAction
                    } else {
                        Button("Place groups at source time") { model.placeGroupsAtSourceTime() }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("alignment.waveforms.placeInitial")
                        Text("Start at source time, then align recorder groups. The reference stays fixed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.waveformTracks.isEmpty, model.waveformNavigationEndSeconds > 0 {
                    ContentUnavailableView(
                        "No audio in this window",
                        systemImage: "waveform",
                        description: Text("Zoom out, pan the ruler, or enter an aligned time. Recordings that failed to load are listed below.")
                    )
                    .frame(minHeight: 200)
                } else if visibleTracks.isEmpty && (layout == .overlay || layout == .speakersOnly) {
                    ContentUnavailableView(
                        "No waveforms showing",
                        systemImage: "waveform",
                        description: Text(layout == .speakersOnly
                            ? "Assign and confirm speaker Primary tracks in Setup, or refresh audio."
                            : "Enable a recorder and track below, or refresh audio to load a measured window.")
                    )
                    .frame(minHeight: 200)
                } else if layout == .overlay {
                    overlay
                } else if layout == .speakersOnly {
                    ForEach(model.primaryWaveformGroups) { speakerLanes($0) }
                } else if layout == .speaker {
                    ForEach(AlignmentWaveformProjection.speakerGroups(
                        tracks: visibleTracks, speakerForSource: model.trackSpeakerID
                    )) { speakerGroup in
                        speakerLanes(speakerGroup)
                    }
                } else {
                    ForEach(groups, id: \.self) { group in
                        groupLane(group)
                    }
                }
                if layout == .overlay { recordings }
                if let cleanup {
                    let inactive = cleanup.manualCuts.count - cleanup.activeManualCuts.count
                    if inactive > 0 {
                        Label("\(inactive) saved cuts are inactive because accepted alignment changed. Undo the timing change to recover their original alignment.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = cleanup.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                ForEach(model.waveformRefusals) { refusal in
                    Label("\(refusal.name): \(refusal.reason)", systemImage: "exclamationmark.triangle")
                        .accessibilityLabel("\(refusal.name), \(refusal.reason)")
                        .accessibilityIdentifier("alignment.waveforms.refusal.\(refusal.id)")
                }
                if model.waveformTracks.isEmpty {
                    Text("Refresh audio reads a bounded portion of grouped recordings. Confirm originals in Setup first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.waveformMessage)
                    .font(.caption)
                    .accessibilityIdentifier("alignment.waveforms.status")
                if model.isLoadingOverview {
                    ProgressView("Preparing zoomed-out waveforms", value: model.waveformOverviewProgress)
                        .font(.caption)
                }
                ForEach(model.waveformOverviewRefusals) { refusal in
                    Label("\(refusal.name): \(refusal.reason)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackContentWidth = $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineChrome
            ScrollView { trackContent }
            .scrollPosition($trackScrollPosition)
            .onScrollGeometryChange(for: Double.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                if trackScrollPosition.isPositionedByUser { model.listening.workspace.trackScrollOffset = offset }
            }
            .task(id: visibleTracks.map(\.id)) {
                guard !visibleTracks.isEmpty else { return }
                trackScrollPosition.scrollTo(y: model.listening.workspace.trackScrollOffset)
            }
            .accessibilityLabel("Alignment workspace scroll area")
            .accessibilityIdentifier("ww.alignment.workspace")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(floatingToolbar)
        .background(alignment: .leading) {
            AudioTimelineScrollSurface(headerWidth: headerWidth + 48) { action, width in
                guard dragSession == nil, model.pendingWaveformMove == nil else { return false }
                switch action {
                case .pan(let delta):
                    guard let start = AlignmentWaveformProjection.rulerPanStart(
                        from: model.waveformStartSeconds, translation: delta, width: width,
                        duration: model.waveformDurationSeconds, bounds: model.waveformViewingBounds
                    ) else { return false }
                    return model.previewWaveformViewport(
                        start: start, duration: model.waveformDurationSeconds)
                case .zoom(let magnification):
                    return model.zoomWaveformViewport(magnification: magnification)
                case .resize(let delta):
                    laneHeight = min(220, max(64, laneHeight + delta))
                    return true
                }
            }
            .frame(width: trackContentWidth > 0 ? trackContentWidth : nil)
        }
        .onChange(of: layout, initial: true) { _, value in
            clearHandCursor()
            if value == .speakersOnly { model.muteNonPrimaryTracks() }
        }
        .onChange(of: model.listening.effectiveTool) { _, _ in
            if dragSession != nil { cancelGroupDrag() }
            clearHandCursor()
        }
        .onDisappear { clearHandCursor() }
    }

    private var timelineChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            transport
            AudioTimelineAdaptiveRow(horizontalSpacing: 8, verticalSpacing: 8) {
                timelineTools
                editingPlaybackControls
            }
            .controlSize(.small)
            AudioTimelineAdaptiveRow(horizontalSpacing: 8, verticalSpacing: 8) {
                comparisonControls
                navigationControls.frame(maxWidth: .infinity, alignment: .trailing)
            }
            ruler
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: trackContentWidth > 0 ? trackContentWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Track controls")
        .accessibilityIdentifier("alignment.waveforms.controls")
    }

    private var comparisonControls: some View {
        AudioTimelineAdaptiveRow(horizontalSpacing: 8, verticalSpacing: 8) {
            layoutPicker
            normalization
        }
    }

    private var layoutPicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Compare", selection: Binding(get: { layout }, set: { layout = $0 })) {
                layoutOptions
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Compare", selection: Binding(get: { layout }, set: { layout = $0 })) {
                layoutOptions
            }
            .pickerStyle(.menu)
        }
        .accessibilityLabel("Compare waveform layout")
        .accessibilityIdentifier("alignment.waveforms.layout")
        .help("Speakers only shows confirmed Primary tracks and mutes non-primary tracks. Primary Solo/Mute choices are preserved. Hidden tracks receive the same cross-track cuts.")
    }

    private var layoutOptions: some View {
        ForEach(AlignmentWaveformLayout.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
        }
    }

    private var normalization: some View {
        Toggle("Normalize view", isOn: Binding(get: { normalizeView }, set: { normalizeView = $0 }))
            .toggleStyle(.checkbox)
            .help("Scales displayed peaks only. Playback, originals, and saved timing are unchanged.")
            .accessibilityIdentifier("alignment.waveforms.normalizeView")
    }

    private var recordings: some View {
        GroupBox("Recorder listening & position") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.self) { group in
                    let tracks = model.waveformTracks.filter { $0.group == group }
                    HStack {
                        Label(tracks.first?.groupName ?? "Recorder group", systemImage: model.recorderIcon(group).rawValue)
                        listeningButtons(.recorder(group), name: tracks.first?.groupName ?? "Recorder")
                        positionLock(group)
                    }
                }
            }
        }
    }

    private func groupLane(_ group: RecorderGroupID) -> some View {
        let tracks = model.waveformTracks.filter { $0.group == group }
        return LazyVStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if !model.listening.collapsedRecorders.insert(group).inserted {
                        model.listening.collapsedRecorders.remove(group)
                    }
                } label: {
                    Label(tracks.first?.groupName ?? "Recorder",
                          systemImage: model.listening.collapsedRecorders.contains(group) ? "chevron.right" : "chevron.down")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityValue(model.listening.collapsedRecorders.contains(group) ? "Collapsed" : "Expanded")
                Image(systemName: model.recorderIcon(group).rawValue).accessibilityHidden(true)
                listeningButtons(.recorder(group), name: tracks.first?.groupName ?? "Recorder")
                positionLock(group)
                Label("\(tracks.count) \(tracks.count == 1 ? "source" : "sources")", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Dragging a recording moves its whole recorder group. The reference recorder stays fixed.")
            }
            if !model.listening.collapsedRecorders.contains(group) {
                ForEach(tracks) { track in lane(track) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var timelineTools: some View {
        HStack {
            TimelineToolControls(listening: model.listening)
            Button("Cycle", systemImage: "repeat") {
                if model.listening.cycleRange == nil {
                    model.listening.cycleRange = model.listening.selection
                        ?? model.waveformStartSeconds...(model.waveformStartSeconds + model.waveformDurationSeconds)
                }
                model.listening.cycleEnabled.toggle()
            }
            .tint(model.listening.cycleEnabled ? .yellow : .secondary)
            .accessibilityValue(model.listening.cycleEnabled ? "On" : "Off")
            .accessibilityIdentifier("ww.timeline.cycle")
        }
    }

    private var editingPlaybackControls: some View {
        HStack {
            NativeActionMenu(label: "After alignment", symbol: nil, identifier: "ww.listening.savedPolicy",
                value: model.editingPlaybackPolicy.title, prefix: "After alignment",
                actions: EditingPlaybackPolicy.allCases.map { policy in
                    .init(title: policy.title, isSelected: policy == model.editingPlaybackPolicy) {
                        model.setEditingPlaybackPolicy(policy)
                    }
                })
            .frame(width: 140, height: 24)
            .help("Saved editing playback policy. Applied once per accepted revision only when you explicitly begin editing; Listen now presets do not change it.")
            Button("Begin editing", systemImage: "pencil") { model.beginEditing() }
                .disabled(!model.hasAcceptedRevision || model.isWorking)
        }
    }

    private var transport: some View {
        AudioTimelineTransport(
            prefix: "alignment.waveforms", isPlaying: model.canStopAudition,
            isPreparing: model.isPreparingAudition, canPlay: model.pendingWaveformMove == nil,
            canNavigate: model.pendingWaveformMove == nil,
            playhead: model.waveformPlayheadSeconds, status: model.auditionLabel,
            back: { model.seekEnabledTracks(to: max(-86_400, model.waveformPlayheadSeconds - 5)) },
            playPause: { model.canStopAudition ? model.pauseEnabledTracks() : model.playEnabledTracks() },
            stop: { model.stopEnabledTracks() },
            forward: { model.seekEnabledTracks(to: min(86_400, model.waveformPlayheadSeconds + 5)) },
            seek: { model.seekEnabledTracks(to: $0) }, isEdited: !model.cutTimeline.removals.isEmpty
        )
        .padding(.vertical, 2)
    }

    private var navigationControls: some View {
        AudioTimelineNavigation(
            prefix: "alignment.waveforms", maximumDuration: model.maximumWaveformDuration,
            duration: Binding(get: { model.waveformDurationSeconds }, set: { duration in
                _ = model.zoomWaveformViewport(
                    magnification: model.waveformDurationSeconds / duration)
            }), laneHeight: Binding(get: { laneHeight }, set: { laneHeight = $0 }), showsLaneHeight: layout != .overlay,
            isLoading: model.isLoadingWaveforms,
            canNavigate: model.pendingWaveformMove == nil,
            zoomEditing: { editing in
                if !editing {
                    if model.waveformDurationSeconds <= 30 {
                        model.loadWaveforms(keepingSnapshot: true, preload: true)
                    }
                }
            },
            fit: { if model.waveformFitRange != nil { model.fitWaveformTimeline() } },
            refresh: {
                model.isLoadingWaveforms ? model.cancelWaveforms()
                    : model.loadWaveforms(keepingSnapshot: model.pendingWaveformMove != nil)
            }
        )
    }

    private var ruler: some View {
        AudioTimelineRuler(
            prefix: "alignment.waveforms", headerWidth: headerWidth,
            start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
            playhead: model.waveformPlayheadSeconds, bounds: model.waveformViewingBounds,
            seekBounds: -86_400...min(86_400, max(0, model.waveformNavigationEndSeconds)),
            maximumDuration: model.maximumWaveformDuration, isPlaying: model.canStopAudition,
            canNavigate: model.pendingWaveformMove == nil,
            markers: [
                cleanup?.episode?.cleanup?.workingRange?.tracksIn.map {
                    AudioTimelineMarker(id: "in", time: model.cutTimeline.editedTime(forAlignedTime: $0), title: "IN", color: .yellow)
                },
                cleanup?.episode?.cleanup?.workingRange?.tracksOut.map {
                    AudioTimelineMarker(id: "out", time: model.cutTimeline.editedTime(forAlignedTime: $0), title: "OUT", color: .yellow)
                },
            ].compactMap { $0 },
            cycleRange: model.listening.cycleRange, cycleEnabled: model.listening.cycleEnabled,
            changeCycle: { model.listening.cycleRange = $0 },
            previewSeek: { model.previewWaveformPlayhead(to: $0) },
            resumePlayback: { model.playEnabledTracks() },
            previewPan: { _ = model.previewWaveformWindow(start: $0) },
            setWindow: { model.waveformStartSeconds = $0; model.waveformDurationSeconds = $1 },
            commitWindow: {
                if model.waveformDurationSeconds <= 30 {
                    model.loadWaveforms(keepingSnapshot: true, preload: true)
                }
            }, isEdited: !model.cutTimeline.removals.isEmpty
        )
        .padding(.horizontal, 8)
        .frame(height: 44)
        .help("Click the ruler to seek, drag its marker to move the playhead, drag empty space to pan, or pinch to zoom around the pointer.")
    }

    private var overlay: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(AlignmentWaveformProjection.speakerGroups(
                tracks: visibleTracks, speakerForSource: model.trackSpeakerID
            )) { speakerGroup in
                speakerOverlay(speakerGroup)
            }
            if showsMatchReview, visibleTracks.contains(where: { $0.id == model.selectedWaveformSource }) {
                matchReview
            }
            ForEach(visibleTracks) { track in
                transcriptStrip(for: track)
                if let error = model.waveformProjectionErrors[track.id] {
                    Label("\(track.name): \(error)", systemImage: "exclamationmark.triangle")
                }
            }
            Text("Overlay compares recordings per speaker. Select a recording beside its waveform, then drag to move its entire recorder group across all speakers; the reference stays fixed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private func speakerOverlay(_ speakerGroup: AlignmentWaveformSpeakerGroup) -> some View {
        let tracks = speakerGroup.tracks
        let speakerName = model.speakerName(speakerGroup.id)
        return AudioTimelineTrackRow(headerWidth: headerWidth) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(speakerName.uppercased()) · \(tracks.count) \(tracks.count == 1 ? "SOURCE" : "SOURCES")")
                    .font(.caption2.weight(.semibold))
                if let speaker = speakerGroup.id {
                    HStack {
                        SpeakerAvatarView(name: speakerName, appearance: model.speakerAppearance(speaker))
                        listeningButtons(.speaker(speaker), name: speakerName)
                    }
                }
                ForEach(tracks) { track in
                    let identity = model.trackIdentity(track.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            model.selectWaveform(track)
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(identity.color).frame(width: 9, height: 9)
                                Text("\(track.groupName) · \(track.name)").lineLimit(1)
                            }
                            .font(.caption)
                            .fontWeight(model.selectedWaveformSource == track.id ? .semibold : .regular)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select \(track.groupName) recording: \(track.name), \(identity.label)")
                        .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                        listeningButtons(.source(track.id), name: track.name)
                        inlineMatchControls(for: track)
                    }
                }
            }
        } content: {
            GeometryReader { geometry in
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.04))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    ForEach(tracks) { track in
                        ForEach(model.waveformTileSlices(for: track.group)) { slice in
                            if model.waveformDurationSeconds <= 30,
                               slice.indices[track.id]?.isEmpty == false {
                                waveformDrawing(
                                    track: track, slice: slice,
                                    size: geometry.size, overlay: true
                                )
                            }
                        }
                    }
                    ForEach(tracks) { track in
                        if model.waveformDurationSeconds > 30
                            || !model.hasVisibleWaveformStrokes(for: track) {
                            cachedOverviewDrawing(track: track, size: geometry.size, overlay: true)
                        }
                        retainedWaveformDrawing(track: track, size: geometry.size)
                        proposedWaveformDrawing(track: track, size: geometry.size)
                    }
                    ForEach(tracks) { track in
                        anchorMarkers(for: track, size: geometry.size)
                    }
                    Rectangle().fill(Color.primary).frame(width: 1.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width),
                                  y: geometry.size.height / 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard model.listening.effectiveTool.reviewDecision == nil else { return }
                    let time = model.waveformStartSeconds
                        + Double(point.x / geometry.size.width) * model.waveformDurationSeconds
                    if let track = tracks.first(where: { $0.id == model.selectedWaveformSource }),
                       pick(track, strokes: model.waveformInteractionStrokes(for: track.id), time: time) {
                        return
                    }
                    model.seekEnabledTracks(to: time)
                }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag in
                        guard let track = tracks.first(where: { $0.id == model.selectedWaveformSource })
                            ?? (model.listening.effectiveTool == .select ? tracks.first : nil) else { return }
                        dragGroup(
                            track,
                            strokes: model.listening.effectiveTool == .move && dragSession == nil
                                ? model.waveformInteractionStrokes(for: track.id) : [],
                            drag: drag, geometry: geometry
                        )
                    }
                    .onEnded { drag in finishGroupDrag(drag) })
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        let track = tracks.first { $0.id == model.selectedWaveformSource }
                        updateHandHover(track.map { canGrab($0, at: point.x, width: geometry.size.width) } ?? false)
                    case .ended:
                        updateHandHover(false)
                    }
                }
            }
            .frame(height: max(laneHeight + 50, CGFloat(tracks.count * 30 + 40)))
            .clipped()
            .overlay {
                if let cleanup {
                    ManualCutMarkers(model: cleanup) {
                        guard let track = tracks.first(where: { $0.id == activeSourceID }) ?? tracks.first else { return }
                        model.selectWaveform(track)
                        cleanup.selectedSpeaker = speakerGroup.id ?? model.trackSpeakerID(track.id)
                    }
                }
            }
            .overlay {
                if let cleanup {
                    ForEach(cleanup.plan?.lanes.filter { lane in tracks.contains { $0.id == lane.primary.sourceID } } ?? []) { lane in
                        FillerTimingOverlay(model: cleanup, reviews: cleanup.visibleFillers(for: lane))
                    }
                }
            }
            .overlay {
                if cleanup?.selectedFiller == nil,
                   tracks.contains(where: { $0.id == activeSourceID }) {
                    selectionOverlay
                }
            }
            .overlay(alignment: .topLeading) {
                if tracks.contains(where: { $0.group == dragSession?.group }) { dragPreview }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3))
                .allowsHitTesting(false).accessibilityHidden(true))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(speakerName), \(tracks.count) \(tracks.count == 1 ? "track" : "tracks") overlaid")
            .accessibilityHint("Select a recording and unlock its position before using the Move recorder tool. Solo and Mute do not hide waveforms.")
            .accessibilityIdentifier("alignment.waveforms.overlay.\(speakerGroup.id.map { "\($0)" } ?? "unknown")")
            .anchorPreference(key: AudioTimelineToolbarAnchor.self, value: .bounds) {
                hasActiveSelection(in: tracks) ? $0 : nil
            }
        }
        .zIndex(hasActiveSelection(in: tracks) ? 1 : 0)
    }

    private func speakerLanes(_ speakerGroup: AlignmentWaveformSpeakerGroup) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            HStack {
                if let speaker = speakerGroup.id {
                    SpeakerAvatarView(name: model.speakerName(speaker), appearance: model.speakerAppearance(speaker))
                }
                Text(model.speakerName(speakerGroup.id))
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("alignment.waveforms.speakerHeading.\(speakerGroup.id.map { "\($0)" } ?? "unknown")")
                if let speaker = speakerGroup.id {
                    listeningButtons(.speaker(speaker), name: model.speakerName(speaker))
                }
            }
            ForEach(speakerGroup.tracks) { track in
                lane(track, speaker: layout == .speakersOnly ? speakerGroup.id : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lane(_ track: AlignmentWaveformTrack, speaker: SpeakerID? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            laneContent(track, speaker: speaker)
            transcriptStrip(for: track, speaker: speaker)
            if showsMatchReview, model.selectedWaveformSource == track.id {
                matchReview
            }
        }
        .zIndex(hasActiveSelection(in: [track]) ? 1 : 0)
        #if DEBUG
        .onAppear { trackVisibilityChanged?(track.id, true) }
        .onDisappear { trackVisibilityChanged?(track.id, false) }
        #endif
    }

    private func hasActiveSelection(in tracks: [AlignmentWaveformTrack], speaker: SpeakerID? = nil) -> Bool {
        guard model.listening.selection != nil || cleanup?.selectedManualCut != nil else { return false }
        if let review = cleanup?.selectedFiller {
            return (speaker == nil || speaker == review.speaker)
                && tracks.contains { $0.id == review.primary.sourceID }
        }
        if let speaker {
            let groups = model.primaryWaveformGroups.filter { $0.tracks.contains { $0.id == activeSourceID } }
            let activeSpeaker = groups.first { $0.id == cleanup?.selectedSpeaker }?.id ?? groups.first?.id
            guard speaker == activeSpeaker else { return false }
        }
        return tracks.contains { $0.id == activeSourceID }
    }

    private func laneContent(_ track: AlignmentWaveformTrack, speaker: SpeakerID? = nil) -> some View {
        let identity = model.trackIdentity(track.id)
        return AudioTimelineTrackRow(headerWidth: headerWidth) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    listeningButtons(.source(track.id), name: track.name)
                    Circle().fill(identity.color).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Button(track.name) { model.selectWaveform(track) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(model.selectedWaveformSource == track.id ? .semibold : .regular))
                        .lineLimit(2)
                        .accessibilityLabel("Select \(track.groupName) recording: \(track.name), \(identity.label)")
                        .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                }
                if layout == .speaker {
                    HStack {
                        Label(track.groupName, systemImage: model.recorderIcon(track.group).rawValue)
                        positionLock(track.group)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Text(identity.label + (model.trackEnabled(track.id) ? "" : " · Not heard (Solo/Mute)"))
                    .font(.caption).foregroundStyle(.secondary)
                inlineMatchControls(for: track)
                if !model.sourceHasAcceptedTiming(track.id) {
                    Label("Not timed · not played", systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.waveforms.state.\(track.id)")
                }
            }
        } content: {
            if (model.hasVisibleWaveformStrokes(for: track)
                   || model.waveformOverviewStrokes[track.id]?.isEmpty == false) {
                GeometryReader { geometry in
                    let slices = model.waveformTileSlices(for: track.group)
                    ZStack {
                        Rectangle().fill(identity.color.opacity(0.04))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                        }.stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        ForEach(slices) { slice in
                            if model.waveformDurationSeconds <= 30,
                               slice.indices[track.id]?.isEmpty == false {
                                waveformDrawing(
                                    track: track, slice: slice,
                                    size: geometry.size, overlay: false
                                )
                            }
                        }
                        if model.waveformDurationSeconds > 30
                            || !model.hasVisibleWaveformStrokes(for: track) {
                            cachedOverviewDrawing(track: track, size: geometry.size, overlay: false)
                        }
                        retainedWaveformDrawing(track: track, size: geometry.size)
                        proposedWaveformDrawing(track: track, size: geometry.size)
                        anchorMarkers(for: track, size: geometry.size)
                        Rectangle().fill(Color.primary).frame(width: 1.5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width), y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        guard model.listening.effectiveTool.reviewDecision == nil else { return }
                        pick(track, strokes: model.waveformInteractionStrokes(for: track.id), time: model.waveformStartSeconds
                             + Double(point.x / geometry.size.width) * model.waveformDurationSeconds)
                    }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { drag in
                            if model.listening.effectiveTool == .select {
                                cleanup?.selectedSpeaker = speaker ?? model.trackSpeakerID(track.id)
                            }
                            dragGroup(
                                track,
                                strokes: model.listening.effectiveTool == .move && dragSession == nil
                                    ? model.waveformInteractionStrokes(for: track.id) : [],
                                drag: drag, geometry: geometry
                            )
                        }
                        .onEnded { drag in finishGroupDrag(drag) })
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            updateHandHover(canGrab(track, at: point.x, width: geometry.size.width))
                        case .ended:
                            updateHandHover(false)
                        }
                    }
                }
                .frame(height: laneHeight)
                .clipped()
                .overlay {
                    if let cleanup {
                        ManualCutMarkers(model: cleanup) {
                            model.selectWaveform(track)
                            cleanup.selectedSpeaker = speaker ?? model.trackSpeakerID(track.id)
                        }
                    }
                }
                .overlay {
                    if let cleanup {
                        ForEach(cleanup.plan?.lanes.filter {
                            $0.primary.sourceID == track.id && (speaker == nil || $0.speaker == speaker)
                        } ?? []) { lane in
                            FillerTimingOverlay(model: cleanup, reviews: cleanup.visibleFillers(for: lane))
                        }
                    }
                }
                .overlay {
                    if cleanup?.selectedFiller == nil,
                       track.id == activeSourceID {
                        selectionOverlay
                    }
                }
                .overlay(alignment: .topLeading) {
                    if dragSession?.group == track.group { dragPreview }
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.selectedWaveformSource == track.id ? Color.accentColor : Color.secondary.opacity(0.3))
                    .allowsHitTesting(false).accessibilityHidden(true))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(track.groupName), \(track.name), audio waveform. \(model.waveformMeasuredBinCount(for: track.id)) measured amplitude bins."
                    + (model.selectedWaveformSource == track.id
                       ? " Stored offset \(model.numericEditorDefaults.offsetMilliseconds) milliseconds in the selected epoch."
                       : ""))
                .accessibilityIdentifier("alignment.waveforms.track.\(track.id)")
                .accessibilityAction { model.selectWaveform(track) }
                .anchorPreference(key: AudioTimelineToolbarAnchor.self, value: .bounds) {
                    hasActiveSelection(in: [track], speaker: speaker) ? $0 : nil
                }
            } else if let error = model.waveformProjectionErrors[track.id] {
                Text("Cannot place this waveform: \(error)")
            } else {
                Color.primary.opacity(0.02)
                    .frame(height: 34)
                    .overlay(alignment: .leading) {
                        Text(model.isLoadingOverview ? "Preparing zoomed-out waveforms…"
                            : model.isLoadingWaveforms ? "Loading measured waveform…"
                            : "No measured audio in this window")
                            .font(.caption).foregroundStyle(.secondary)
            }
            }
        }
    }

    private func listeningButtons(_ scope: EpisodePlaybackScope, name: String) -> some View {
        AudioTimelineListeningButtons(listening: model.listening, scope: scope, name: name,
                                      changed: { model.refreshListeningGains() })
    }

    private var selectionOverlay: some View {
        AudioTimelineSelectionOverlay(listening: model.listening,
            start: model.waveformStartSeconds, duration: model.waveformDurationSeconds)
    }

    private var floatingToolbar: AudioTimelineFloatingToolbar {
        AudioTimelineFloatingToolbar(listening: model.listening,
            start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
            play: { context in
                if let cleanup, let review = cleanup.selectedFiller {
                    cleanup.auditionFiller(review.id, context: context)
                } else {
                    model.playSelection(context: context)
                }
            }, cleanup: cleanup)
    }

    @ViewBuilder
    private func transcriptStrip(for track: AlignmentWaveformTrack, speaker: SpeakerID? = nil) -> some View {
        if let cleanup {
            ForEach(cleanup.plan?.lanes.filter {
                $0.primary.sourceID == track.id && (speaker == nil || $0.speaker == speaker)
            } ?? []) { lane in
                if let transcript = cleanup.transcript(for: lane) {
                    AudioTimelineTrackRow(headerWidth: headerWidth) {
                        Button(lane.name, systemImage: "text.bubble") {
                            cleanup.selectedSpeaker = lane.speaker
                            showTranscript()
                        }.buttonStyle(.plain).font(.caption)
                    } content: {
                        AudioTimelineWords(words: transcript.words, start: model.waveformStartSeconds,
                            duration: model.waveformDurationSeconds, selectedWord: cleanup.selectedWord?.id,
                            select: {
                                model.selectWaveform(track)
                                cleanup.select($0, speaker: lane.speaker)
                                showTranscript()
                            },
                            zoom: { model.seekEnabledTracks(to: $0) },
                            uncertainWordIDs: cleanup.uncertainWordIDs(for: lane), cuts: model.cutTimeline,
                            selectUnit: { words in
                                model.selectWaveform(track)
                                cleanup.select(words, speaker: lane.speaker)
                                showTranscript()
                            })
                    }
                }
            }
        }
    }

    private func positionLock(_ group: RecorderGroupID) -> some View {
        Button {
            model.setPositionLocked(!model.positionIsLocked(group), group: group)
        } label: {
            Image(systemName: group == model.referenceGroup ? "pin.fill"
                  : model.positionIsLocked(group) ? "lock.fill" : "lock.open")
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking || group == model.referenceGroup)
        .accessibilityLabel(group == model.referenceGroup ? "Fixed alignment reference" : "Lock position")
        .accessibilityValue(model.positionIsLocked(group) ? "Locked" : "Unlocked")
        .accessibilityIdentifier("alignment.waveforms.positionLock.\(group)")
        .help("Accepted positions are protected. Unlock deliberately before automatic alignment or an advanced timing correction; the reference stays fixed.")
    }

    private func inlineMatchControls(for track: AlignmentWaveformTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Recording settings", systemImage: "slider.horizontal.3") {
                model.selectWaveform(track)
                showInspector()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Assign a speaker or channel and adjust timing in Inspector.")
            .accessibilityLabel("Recording settings for \(track.name)")
            .accessibilityIdentifier("alignment.waveforms.settings.\(track.id)")
            let options = model.matchOptions(for: track)
            if !options.isEmpty, model.selectedWaveformSource == track.id {
                Menu("Adaptive review…") {
                    ForEach(options, id: \.self) { option in
                        Button("\(model.speakerName(option.speaker)): \(model.speakerMatchDescription(option, fileLocal: true))") {
                            model.analyzeAdaptively(track, with: option)
                        }
                    }
                }
                .disabled(model.isWorking)
                .help("Measure changing audio delay within this file. Experimental, visual review only; no playback or saved timing changes.")
                .accessibilityIdentifier("alignment.waveforms.adaptive.\(track.id)")
            }
            if options.count == 1, let option = options.first {
                Button(model.isWorking && model.selectedWaveformSource == track.id ? "Analyzing…" : "Align…") {
                    model.align(track, with: option)
                }
                .disabled(model.isWorking)
                .help("Compare \(model.speakerName(option.speaker)) with \(model.speakerMatchDescription(option))")
                .accessibilityLabel("Align \(track.name) using \(model.speakerName(option.speaker))")
                .accessibilityIdentifier("alignment.waveforms.align.\(track.id)")
            } else if options.count > 1 {
                Menu("Align…") {
                    ForEach(options, id: \.self) { option in
                        Button("\(model.speakerName(option.speaker)): \(model.speakerMatchDescription(option))") {
                            model.align(track, with: option)
                        }
                    }
                }
                .disabled(model.isWorking)
                .accessibilityLabel("Choose a speaker match for \(track.name)")
                .accessibilityIdentifier("alignment.waveforms.align.\(track.id)")
            } else {
                Text(model.hasAcceptedRevision && model.waveformMap == nil
                     ? "Timing unavailable"
                     : model.waveformMap?.reference.group == track.group
                     ? "Reference recorder"
                     : model.trackSpeakerID(track.id) == nil
                         ? (model.availableSpeakers.isEmpty
                             ? "Create a speaker in Setup"
                             : "Assign a speaker in Inspector")
                         : model.statedChannel(for: track.id) == nil
                             ? "Choose a channel in Inspector"
                             : "No timed speaker match")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("alignment.waveforms.noMatch.\(track.id)")
            }
        }
    }

    @ViewBuilder
    private func anchorMarkers(for track: AlignmentWaveformTrack, size: CGSize) -> some View {
        if let correction = model.adaptiveCorrection(for: track.id) {
            ForEach(Array(correction.segments.enumerated()), id: \.offset) { _, segment in
                let position = x(segment.alignedStart, width: size.width)
                if (0...size.width).contains(position) {
                    let style = adaptiveMarkerStyle(segment.kind, accepted: true)
                    Image(systemName: style.symbol)
                        .foregroundStyle(style.color).font(.caption)
                        .position(x: position, y: 12)
                        .help("Accepted \(style.label) at source \(AlignmentPresentation.formatTime(segment.sourceStart)). Pitch preserved; all file channels share this curve.")
                        .accessibilityLabel("Accepted \(style.label), pitch preserved")
                }
            }
        }
        if showProposedAlignment, let record = model.currentAdaptiveAnalysis {
            ForEach(AlignmentWaveformProjection.adaptiveMarkers(
                track: track, record: record, includeEstimated: model.includeEstimatedAdaptiveTiming)) { marker in
                let position = x(model.cutTimeline.editedTime(forAlignedTime: marker.alignedSeconds), width: size.width)
                if (0...size.width).contains(position) {
                    let style = adaptiveMarkerStyle(marker.kind, accepted: false)
                    Image(systemName: style.symbol)
                        .foregroundStyle(style.color).font(.caption)
                        .position(x: position, y: 12)
                        .help("Proposed \(style.label) at source \(AlignmentPresentation.formatTime(marker.sourceSeconds)): \(AlignmentPresentation.offsetLabel(marker.adjustmentMilliseconds)). Preview only, not applied or played.")
                        .accessibilityLabel("Proposed \(style.label), not applied")
                }
            }
        }
        ForEach(model.waveformReferenceMarkers.filter { $0.source == track.id }) { marker in
            let position = x(model.cutTimeline.editedTime(forAlignedTime: marker.alignedSeconds), width: size.width)
            if (0...size.width).contains(position) {
                Rectangle().fill(Color.orange).frame(width: 2, height: size.height)
                    .position(x: position, y: size.height / 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        ForEach(model.acceptedAnchorRows(for: track)) { anchor in
            let position = x(model.cutTimeline.editedTime(forAlignedTime: anchor.alignedSeconds), width: size.width)
            if (0...size.width).contains(position) {
                Rectangle().fill(Color.orange).frame(width: 2, height: size.height)
                    .position(x: position, y: size.height / 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        if model.selectedWaveformSource == track.id {
            ForEach(model.waveformDraftAnchors, id: \.sourceSeconds) { anchor in
                let time = model.sourceHasAcceptedTiming(track.id)
                    ? anchor.alignedSeconds : anchor.sourceSeconds
                let position = x(model.cutTimeline.editedTime(forAlignedTime: time), width: size.width)
                if (0...size.width).contains(position) {
                    Rectangle().fill(Color.green).frame(width: 2, height: size.height)
                        .position(x: position, y: size.height / 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }

    private func adaptiveMarkerStyle(
        _ kind: SourceTimingSegment.Kind?, accepted: Bool
    ) -> (symbol: String, color: Color, label: String) {
        switch kind {
        case .quietTransition?: return ("waveform.path", .orange, "quiet-only timing inferred between speech anchors")
        case .anchorGuided?: return ("point.3.connected.trianglepath.dotted", .green, "anchor-guided short acoustic match")
        case .estimated?: return ("questionmark.diamond", .purple, "estimated timing, not acoustically verified")
        case nil: return (accepted ? "clock.badge.checkmark" : "clock.arrow.2.circlepath",
                          accepted ? .blue : .teal, "independently measured timing")
        }
    }

    private var showsMatchReview: Bool {
        model.isAnalyzingAdaptively || model.currentAdaptiveAnalysis != nil
            || model.selectedWaveformSource.flatMap { model.adaptiveCorrection(for: $0) } != nil
            || model.selectedAnalysis != nil || model.selectedAnalysisState != nil || model.lastError != nil
            || (model.staleAcceptedTiming && model.hasAcceptedRevision)
    }

    private var matchReview: some View {
        GroupBox(model.currentAdaptiveAnalysis == nil && !model.isAnalyzingAdaptively
                 && model.selectedWaveformSource.flatMap { model.adaptiveCorrection(for: $0) } == nil
                 ? "Automatic alignment · review before applying" : "Adaptive audio timing · review before applying") {
            VStack(alignment: .leading, spacing: 8) {
                if let pair = model.selectedMatchOption {
                    Text(model.speakerMatchDescription(pair, fileLocal: model.currentAdaptiveAnalysis != nil))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.auto.pairSummary")
                }
                if model.isAnalyzingAdaptively {
                    ProgressView(value: model.adaptiveProgress)
                        .accessibilityLabel("Adaptive analysis progress")
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel adaptive review") { model.cancelAdaptiveAnalysis() }
                        .accessibilityIdentifier("alignment.adaptive.cancel")
                } else if let adaptive = model.currentAdaptiveAnalysis {
                    Toggle("Show proposed adaptive timing", isOn: Binding(
                        get: { showProposedAlignment }, set: { showProposedAlignment = $0 }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("alignment.adaptive.showGhost")
                    Text("\(adaptive.timing.regions.count) independently measured runs; \(String(format: "%.1f", adaptive.timing.supportedSeconds)) s of \(String(format: "%.1f", adaptive.timing.measuredEnd - adaptive.timing.measuredStart)) s overlap. \(adaptive.timing.usableWindows)/\(adaptive.timing.attemptedWindows) original windows passed the local quality gate.")
                        .font(.caption)
                        .accessibilityIdentifier("alignment.adaptive.coverage")
                    if let quiet = adaptive.timing.quietTransitions, !quiet.isEmpty {
                        Text("\(quiet.count) quiet-only transitions; \(String(format: "%.1f", adaptive.timing.quietSeconds)) s additional low-energy audio. Orange waveform icons mark timing inferred between speech anchors, not extra speech matches. Every target channel and the reference were checked.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("alignment.adaptive.quietCoverage")
                    }
                    if let recovery = adaptive.timing.anchoredRecovery {
                        Text("\(recovery.regions.count) anchor-guided short matches; \(String(format: "%.1f", recovery.supportedSeconds)) s additional acoustic support. Green markers identify fresh half- and quarter-second checks guided by nearby independent anchors, not independent clock measurements.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("alignment.adaptive.guidedCoverage")
                    }
                    let estimated = adaptive.playbackIntervals(includeEstimated: true).filter { $0.kind == .estimated }
                    if !estimated.isEmpty {
                        Toggle("Keep bounded gaps using estimated timing", isOn: $model.includeEstimatedAdaptiveTiming)
                            .toggleStyle(.checkbox)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("alignment.adaptive.includeEstimated")
                        Text("\(String(format: "%.1f", estimated.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart })) s can use interpolated timing in gaps up to five minutes long. Off by default. Purple question marks identify estimates: audio is retained but its alignment is not acoustically verified and speech may still be out of sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Dashed waveforms preview placement; icons distinguish independent measurements, anchor-guided matches, quiet transitions and optional estimates. No leading or trailing timing is extrapolated.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Preview only until accepted. All channels of this file share one pitch-preserving curve. \(model.includeEstimatedAdaptiveTiming ? "Bounded estimated gaps will also play; their timing can be wrong." : "Unmatched intervals stay silent unless you opt into estimated gap timing.") Larger unsupported gaps and unmeasured ends stay silent. Originals and other files remain unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.adaptive.previewOnly")
                    Button("Accept supported file timing…") { confirmingAdaptiveAcceptance = true }
                        .disabled(model.isWorking || adaptive.timing.regions.isEmpty)
                        .accessibilityIdentifier("alignment.adaptive.accept")
                    if let refusal = adaptive.refusal {
                        Label(refusal, systemImage: "exclamationmark.triangle")
                    }
                    DisclosureGroup("Local timing details") {
                        ForEach(Array(adaptive.timing.regions.enumerated()), id: \.offset) { _, region in
                            Text("\(AlignmentPresentation.formatTime(region.sourceStart))–\(AlignmentPresentation.formatTime(region.sourceEnd)): \(AlignmentPresentation.offsetLabel(region.offsetSeconds * 1000)); \(AlignmentPresentation.rateLabel((region.rateRatio - 1) * 1e6)); \(region.measurements) measurements, maximum residual \(String(format: "%.3f", region.maximumResidualMilliseconds)) ms.")
                                .font(.caption).monospacedDigit()
                        }
                        ForEach(Array((adaptive.timing.quietTransitions ?? []).enumerated()), id: \.offset) { _, region in
                            Text("\(AlignmentPresentation.formatTime(region.sourceStart))–\(AlignmentPresentation.formatTime(region.sourceEnd)): quiet-only transition, \(String(format: "%+.3f", (region.rateRatio - 1) * 100))% rate adjustment; not a speech timing measurement.")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ForEach(Array((adaptive.timing.anchoredRecovery?.regions ?? []).enumerated()), id: \.offset) { _, region in
                            Text("\(AlignmentPresentation.formatTime(region.sourceStart))–\(AlignmentPresentation.formatTime(region.sourceEnd)): anchor-guided acoustic support from \(region.observations.count) fresh checks; not independent clock proof.")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } else if let source = model.selectedWaveformSource, let correction = model.adaptiveCorrection(for: source) {
                    Label("Adaptive timing accepted · pitch preserved", systemImage: "clock.badge.checkmark")
                        .accessibilityIdentifier("alignment.adaptive.applied")
                    Text("\(correction.segments.filter { $0.kind == nil }.count) independent measured runs; \(correction.segments.filter { $0.kind == .anchorGuided }.count) green anchor-guided matches; \(correction.segments.filter { $0.kind == .quietTransition }.count) orange quiet transitions; \(correction.segments.filter { $0.kind == .estimated }.count) purple estimated gaps, not verified alignment. Other intervals are silent. Remove this file correction before editing recorder-group timing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Remove adaptive file timing") { model.saveAdaptiveCorrection(removing: source) }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("alignment.adaptive.remove")
                } else if let analysis = model.selectedAnalysis {
                    if analysis.automaticAttempts != nil || analysis.fingerprintSeconds != nil {
                        Text(AlignmentPresentation.automaticMethod(
                            fingerprintSeconds: analysis.fingerprintSeconds, refinementRatePPM: analysis.refinementRatePPM
                        ))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("alignment.auto.method")
                        if analysis.automaticAttempts != nil {
                            Text(AlignmentPresentation.automaticEvidence(analysis))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("alignment.auto.coverage")
                        }
                    }
                    if let proposal = analysis.proposal {
                        Toggle("Show proposed alignment", isOn: Binding(
                            get: { showProposedAlignment }, set: { showProposedAlignment = $0 }))
                            .toggleStyle(.checkbox)
                            .disabled(!model.canAcceptProposal)
                            .help("Dashed teal waveforms preview the proposed measured interval. Saved timing and playback do not change.")
                            .accessibilityIdentifier("alignment.auto.showGhost")
                        Text("Dashed teal is the proposal; solid waveforms keep their current timing. Preview only, not played.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Proposed for \(model.selectedRow?.epochLabel ?? "selected epoch"): \(AlignmentPresentation.offsetLabel(proposal.segment.alignedOffset.approximateDouble * 1_000)); \(AlignmentPresentation.rateLabel(proposal.ppm)).")
                            .accessibilityIdentifier("alignment.auto.timing")
                        Text("Measured source interval \(AlignmentPresentation.formatTime(proposal.segment.groupClockStart.approximateDouble))–\(AlignmentPresentation.formatTime(proposal.segment.groupClockEnd.approximateDouble)); \(analysis.coverage.eligibleCount)/\(analysis.coverage.windowCount) windows, peak \(proposal.provenance.evidenceScore.map { String(format: "%.3f", $0) } ?? "unavailable"), residual p95 \(String(format: "%.3f", proposal.acousticResidualP95Milliseconds)) ms. These are evidence measures, not a probability or clock proof.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("alignment.auto.evidence")
                        Text(analysis.fingerprintSeconds != nil
                             ? "The full recordings were indexed, but precise timing is verified at selected passages. Short edits between them can still be missed. Review the beginning, middle and end before accepting; this does not approve recorder clock accuracy."
                             : analysis.automaticAttempts != nil
                             ? "The line is supported by sampled regions, not continuous inspection of every frame. Unmeasured intervals can still hide edits or restarts. Review the beginning, middle and end before accepting; this does not approve recorder clock accuracy."
                             : analysis.flags.contains("coverageGap")
                             ? "The silence between the matching regions was verified in both recordings. Accept to retain evidence markers at the first and last reliable windows; this still needs your review."
                             : "Accept to retain evidence markers at the first and last reliable windows. They do not approve recorder clock accuracy.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("alignment.auto.anchorEvidence")
                        HStack {
                            Button("Accept measured interval") { model.acceptProposal() }
                                .disabled(!model.canAcceptProposal)
                                .accessibilityIdentifier("alignment.auto.accept")
                            if model.proposalNeedsExtension {
                                Button("Extend to whole epoch…") { confirmingExtension = true }
                                    .disabled(!model.canAcceptProposal)
                                    .accessibilityIdentifier("alignment.auto.extend")
                            }
                        }
                        Text(model.proposalNeedsExtension
                             ? "Only measured frames align automatically. The rest stays unplaced unless you explicitly extend this rate and offset beyond the measured audio."
                             : "Accepting maps only the measured epoch; restarted epochs and gaps remain separate.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let abstention = analysis.abstention {
                        Label("No reliable match: \(abstention.detail)", systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("alignment.auto.abstention")
                        Text(analysis.fingerprintSeconds != nil
                             ? "No automatic timing was applied. Whole-track search does not require an anchor or initial placement. Check the shared speaker channels or try another shared speaker; anchors remain an optional manual fallback."
                             : "No automatic timing was applied. Check the shared speaker channels, try a closer initial placement, or add anchors. Weak or ambiguous matches alone do not establish a recorder restart.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let state = model.selectedAnalysisState {
                    let copy = AlignmentPresentation.copy(for: state.status)
                    Label("\(copy.heading): \(copy.evidence)",
                          systemImage: copy.isBlocked ? "exclamationmark.triangle" : "info.circle")
                        .accessibilityIdentifier("alignment.auto.refusal")
                } else {
                    Text(model.message)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("alignment.auto.error")
                }
                if model.staleAcceptedTiming && model.hasAcceptedRevision {
                    resetAction
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help("Only the chosen speaker channels are compared. Accepting a match moves the target recorder's tracks together; unequal recording lengths need no percentage setting.")
        .accessibilityIdentifier("alignment.auto")
        .confirmationDialog("Apply pitch-preserving timing to this file?", isPresented: $confirmingAdaptiveAcceptance) {
            Button(model.includeEstimatedAdaptiveTiming ? "Accept with estimated gaps" : "Accept supported intervals") {
                model.saveAdaptiveCorrection()
            }
            Button("Keep preview only", role: .cancel) {}
        } message: {
            Text("\(model.includeEstimatedAdaptiveTiming ? "Bounded gaps will play using ESTIMATED timing. These gaps have no acoustic confirmation and may contain misaligned speech." : "Only independently measured runs, anchor-guided acoustic matches and verified quiet-only transitions will play. Unmatched intervals will be silent.") Unmeasured ends and larger unsupported gaps remain silent. Quiet timing is inferred, not an extra speech match. All channels in this file share one correction; other files and originals stay unchanged. This is saved and undoable.")
        }
        .confirmationDialog("Extend the measured timing beyond its evidence?", isPresented: $confirmingExtension) {
            Button("Extend rate and offset to whole epoch") { model.extendProposalToEpoch() }
            Button("Keep measured interval", role: .cancel) {}
        } message: {
            Text("This extrapolates the proposed time stretch into unmeasured audio. It cannot establish continuity, drift or clock accuracy outside the measured interval. Review playback; the decision is undoable and originals remain unchanged.")
        }
    }

    private var resetAction: some View {
        Button("Start fresh alignment…") { confirmingReset = true }
            .disabled(model.isWorking)
            .accessibilityIdentifier("alignment.auto.startFresh")
            .confirmationDialog("Stop using the accepted timing and start fresh?",
                                isPresented: $confirmingReset) {
                Button("Start fresh alignment") { model.clearAcceptedTiming() }
                Button("Keep accepted timing", role: .cancel) {}
            } message: {
                Text("This removes the accepted timing from the current timeline after the show is saved. The old map stays in history, and Undo can restore its selection, but it may remain unusable if its original source revision cannot be verified. You must place the groups again; original recordings are untouched.")
            }
    }

    private func dragGroup(
        _ track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke],
        drag: DragGesture.Value, geometry: GeometryProxy
    ) {
        if model.listening.effectiveTool == .select {
            cleanup?.selectedFillerID = nil
            cleanup?.selectedManualCutID = nil
            model.selectWaveform(track)
            let origin = geometry.frame(in: .global).minX
            let width = max(1, geometry.size.width)
            model.listening.select(
                from: model.waveformStartSeconds + (drag.startLocation.x - origin) / width * model.waveformDurationSeconds,
                to: model.waveformStartSeconds + (drag.location.x - origin) / width * model.waveformDurationSeconds,
                within: model.waveformViewingBounds)
            return
        }
        guard model.listening.effectiveTool == .move else { return }
        if dragSession == nil {
            let width = geometry.size.width
            guard width > 0, !model.isWorking, !model.isLoadingWaveforms,
                  model.waveformMap?.reference.group != track.group else { return }
            guard pick(track, strokes: strokes, time: model.waveformStartSeconds
                + Double((drag.startLocation.x - geometry.frame(in: .global).minX) / width)
                    * model.waveformDurationSeconds, seek: false),
                model.canMoveGroup, model.selectedRow?.groupID == track.group
            else { return }
            dragSession = AlignmentWaveformDrag(
                startX: drag.startLocation.x, width: width,
                durationSeconds: model.waveformDurationSeconds,
                initialMilliseconds: model.groupDraftMilliseconds,
                group: track.group, snapshot: model.waveformSnapshotID
            )
            refreshHandCursor()
        }
        guard let session = dragSession else { return }
        guard session.group == track.group, session.snapshot == model.waveformSnapshotID,
              model.canMoveGroup, model.selectedRow?.groupID == session.group,
              let preview = session.previewMilliseconds(at: drag.location.x)
        else {
            cancelGroupDrag()
            return
        }
        model.groupDraftMilliseconds = preview
    }

    private func finishGroupDrag(_ drag: DragGesture.Value) {
        guard let session = dragSession else { return }
        guard session.snapshot == model.waveformSnapshotID, model.canMoveGroup,
              model.selectedRow?.groupID == session.group,
              let preview = session.previewMilliseconds(at: drag.location.x)
        else {
            cancelGroupDrag()
            return
        }
        model.groupDraftMilliseconds = preview
        dragSession = nil
        refreshHandCursor()
        model.commitGroupMove()
        updateHandHover(false)
    }

    private func cancelGroupDrag() {
        if let session = dragSession {
            model.groupDraftMilliseconds = session.snapshot == model.waveformSnapshotID
                && model.selectedRow?.groupID == session.group ? session.initialMilliseconds : 0
        }
        dragSession = nil
        refreshHandCursor()
    }

    private func canGrab(_ track: AlignmentWaveformTrack, at x: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, model.listening.effectiveTool == .move else { return false }
        let time = model.waveformStartSeconds + Double(x / width) * model.waveformDurationSeconds
        guard let stroke = AlignmentWaveformProjection.selectedStroke(
            at: time, strokes: model.waveformInteractionStrokes(for: track.id),
            draftEpoch: model.waveformTimingIsDraft ? model.selection : nil,
            ratePPM: model.waveformRatePPM, offsetMilliseconds: model.waveformOffsetMilliseconds
        ) else { return false }
        return model.canMoveWaveform(source: track.id, group: track.group, epoch: stroke.epoch)
    }

    private func updateHandHover(_ hovering: Bool) {
        hoveringMovableWaveform = hovering
        refreshHandCursor()
    }

    private func refreshHandCursor() {
        let cursor: NSCursor? = dragSession != nil ? .closedHand : hoveringMovableWaveform ? .openHand : nil
        if let cursor {
            if handCursorPushed {
                cursor.set()
            } else {
                cursor.push()
                handCursorPushed = true
            }
        } else if handCursorPushed {
            NSCursor.pop()
            handCursorPushed = false
        }
    }

    private func clearHandCursor() {
        hoveringMovableWaveform = false
        if handCursorPushed {
            NSCursor.pop()
            handCursorPushed = false
        }
    }

    @ViewBuilder
    private var dragPreview: some View {
        if dragSession != nil {
            Text("Move \(model.groupDraftMilliseconds / 1_000, specifier: "%+.3f") s · release to save")
                .font(.caption.monospacedDigit())
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityIdentifier("alignment.waveforms.dragPreview")
        }
    }

    @ViewBuilder
    private func retainedWaveformDrawing(track: AlignmentWaveformTrack, size: CGSize) -> some View {
        let index = model.retainedWaveformIndex(for: track.id)
        if model.waveformDurationSeconds <= 30, !index.isEmpty {
            let activeGroup = model.selectedRow?.groupID == track.group
            let shift = ((activeGroup ? model.groupDraftMilliseconds : 0)
                + (model.pendingWaveformMove?.displayShift(for: track.group) ?? 0)) / 1_000
            WaveformTrackDrawing(
                snapshot: model.waveformTilesVersion, index: index, size: size,
                start: model.waveformStartSeconds - shift, duration: model.waveformDurationSeconds,
                color: model.trackIdentity(track.id).color, lineWidth: 1.5,
                gain: normalizeView ? model.waveformDisplayGains[track.id] ?? 1 : 1,
                draftEpoch: !activeGroup && model.waveformTimingIsDraft ? model.selection : nil,
                draftRatePPM: model.waveformRatePPM,
                draftOffsetMilliseconds: model.waveformOffsetMilliseconds, displayScale: displayScale
            )
            .equatable()
        }
    }

    @ViewBuilder
    private func proposedWaveformDrawing(track: AlignmentWaveformTrack, size: CGSize) -> some View {
        if showProposedAlignment, model.hasWaveformProposal, model.groupDraftMilliseconds == 0,
           !model.waveformTimingIsDraft, let input = model.waveformProposalInput(for: track) {
            AudioTimelineWaveformProposalDrawing(input: input, size: size,
                start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
                normalized: normalizeView, displayScale: displayScale)
        }
    }

    @ViewBuilder
    private func cachedOverviewDrawing(track: AlignmentWaveformTrack, size: CGSize, overlay: Bool) -> some View {
        if let index = model.waveformOverviewIndices[track.id], !index.isEmpty {
            let activeGroup = model.selectedRow?.groupID == track.group
            let shift = ((activeGroup ? model.groupDraftMilliseconds : 0)
                + (model.pendingWaveformMove?.displayShift(for: track.group) ?? 0))
                / 1_000
            WaveformTrackDrawing(
                snapshot: model.waveformOverviewSnapshotID, index: index,
                size: size, start: model.waveformStartSeconds - shift, duration: model.waveformDurationSeconds,
                color: model.trackIdentity(track.id).color.opacity(overlay ? 0.8 : 1),
                lineWidth: overlay ? (model.selectedWaveformSource == track.id ? 2 : 1.3) : 1.5,
                gain: normalizeView ? model.waveformOverviewDisplayGains[track.id] ?? 1 : 1,
                draftEpoch: !activeGroup && model.waveformTimingIsDraft ? model.selection : nil,
                draftRatePPM: model.waveformRatePPM,
                draftOffsetMilliseconds: model.waveformOffsetMilliseconds,
                displayScale: displayScale
            )
            .equatable()
        }
    }

    @ViewBuilder
    private func waveformDrawing(
        track: AlignmentWaveformTrack,
        slice: EpisodeAlignmentModel.WaveformTileSlice, size: CGSize, overlay: Bool
    ) -> some View {
        let activeGroup = model.selectedRow?.groupID == track.group
        let previewShift = model.pendingWaveformMove?.displayShift(for: track.group) ?? 0
        let groupShift = ((activeGroup ? model.groupDraftMilliseconds : 0) + previewShift)
            / 1_000
        if let index = slice.indices[track.id],
           let clip = AlignmentWaveformProjection.viewportClip(range: slice.range,
            start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
            width: size.width, shift: groupShift) {
            WaveformTrackDrawing(
                snapshot: slice.snapshot, index: index, size: size,
                start: clip.drawingStart, duration: model.waveformDurationSeconds,
                color: model.trackIdentity(track.id).color.opacity(overlay ? 0.8 : 1),
                lineWidth: overlay ? (model.selectedWaveformSource == track.id ? 2 : 1.3) : 1.5,
                gain: normalizeView ? slice.gains[track.id] ?? 1 : 1,
                draftEpoch: !activeGroup && model.waveformTimingIsDraft ? model.selection : nil,
                draftRatePPM: model.waveformRatePPM, draftOffsetMilliseconds: model.waveformOffsetMilliseconds,
                displayScale: displayScale
            )
            .equatable()
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(width: clip.width)
                    .offset(x: clip.origin)
            }
        }
    }

    private func x(_ time: Double, width: Double) -> Double {
        guard time.isFinite, model.waveformStartSeconds.isFinite,
              model.waveformDurationSeconds > 0 else { return -1 }
        return (time - model.waveformStartSeconds) / model.waveformDurationSeconds * width
    }

    @discardableResult
    private func pick(
        _ track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke],
        time: Double, seek: Bool = true
    ) -> Bool {
        guard let selected = AlignmentWaveformProjection.selectedStroke(
            at: time, strokes: strokes,
            draftEpoch: model.waveformTimingIsDraft ? model.selection : nil,
            ratePPM: model.waveformRatePPM, offsetMilliseconds: model.waveformOffsetMilliseconds
        ) else { return false }
        if let sourceSeconds = AlignmentWaveformProjection.anchorSourceSeconds(at: time, stroke: selected) {
            model.selectWaveformAnchorPoint(track, position: selected, sourceSeconds: sourceSeconds)
        }
        if model.waveformMap?.reference.group == track.group {
            model.waveformReferencePoint = model.cutTimeline.alignedTime(forEditedTime: time)
        } else {
            model.selectWaveform(track, epoch: selected.epoch)
            if let point = model.waveformPickedPoint, point.source == track.id {
                model.waveformTargetPoint = point.sourceSeconds
            } else {
                model.waveformTargetPoint = selected.sourceSeconds
            }
        }
        if seek { model.seekEnabledTracks(to: time) }
        return true
    }

}
