import SwiftUI
import WWAlignPipeline
import WWCore

struct AlignmentWaveformView: View {
    @Bindable var model: EpisodeAlignmentModel
    @Environment(\.displayScale) private var displayScale
    @State private var dragSession: AlignmentWaveformDrag?
    @State private var rulerPan: (start: Double, width: Double, duration: Double)?
    @State private var rulerPlayheadDrag: (
        time: Double, start: Double, duration: Double, width: Double, wasPlaying: Bool
    )?
    @State private var rulerZoom: (start: Double, duration: Double, anchor: Double)?
    @State private var timeDraft = "0.000"
    @FocusState private var editingTime: Bool
    @State private var layout: Layout = .separate
    @State private var normalizeView = false
    @State private var laneHeight = 140.0
    @State private var zoomCenterSeconds: Double?
    @State private var hoveringMovableWaveform = false
    @State private var handCursorPushed = false
    @State private var confirmingExtension = false

    private let headerWidth: CGFloat = 210

    private enum Layout: String, CaseIterable {
        case separate = "Separate lanes"
        case overlay = "Overlay"
    }

    private struct WaveformTrackDrawing: View, Equatable {
        let snapshot: UUID
        let strokes: [AlignmentWaveformStroke]
        let size: CGSize
        let start: Double
        let duration: Double
        let color: Color
        let lineWidth: Double
        let gain: Double
        let draftEpoch: RecordingEpochID?
        let draftRatePPM: Double
        let draftOffsetMilliseconds: Double
        let displayScale: Double

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.snapshot == rhs.snapshot && lhs.size == rhs.size && lhs.displayScale == rhs.displayScale
                && lhs.start == rhs.start && lhs.duration == rhs.duration
                && lhs.color == rhs.color && lhs.lineWidth == rhs.lineWidth
                && lhs.gain == rhs.gain && lhs.draftEpoch == rhs.draftEpoch
                && (lhs.draftEpoch == nil || (
                    lhs.draftRatePPM == rhs.draftRatePPM
                        && lhs.draftOffsetMilliseconds == rhs.draftOffsetMilliseconds
                ))
        }

        var body: some View {
            ZStack {
                path(mapped: true).stroke(color, lineWidth: lineWidth)
                path(mapped: false).stroke(Color.orange, style: StrokeStyle(lineWidth: lineWidth, dash: [3, 2]))
            }
            .frame(width: size.width, height: size.height)
        }

        private func path(mapped: Bool) -> Path {
            Path { path in
                for column in AlignmentWaveformProjection.displayColumns(
                    strokes: strokes, start: start, duration: duration,
                    width: size.width, pixelsPerPoint: displayScale,
                    draftEpoch: draftEpoch, ratePPM: draftRatePPM,
                    offsetMilliseconds: draftOffsetMilliseconds
                ) where column.mapped == mapped {
                    path.move(to: CGPoint(x: column.x, y: size.height * (0.5 - Double(column.high) * gain * 0.45)))
                    path.addLine(to: CGPoint(x: column.x, y: size.height * (0.5 - Double(column.low) * gain * 0.45)))
                }
            }
        }
    }

    private struct OverviewTrackDrawing: View, Equatable {
        let snapshot: UUID
        let strokes: [AlignmentWaveformStroke]
        let extent: ClosedRange<Double>
        let size: CGSize
        let gain: Double
        let displayScale: Double

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.snapshot == rhs.snapshot && lhs.extent == rhs.extent
                && lhs.size == rhs.size && lhs.gain == rhs.gain
                && lhs.displayScale == rhs.displayScale
        }

        var body: some View {
            ZStack {
                path(mapped: true).stroke(Color.accentColor, lineWidth: 1)
                path(mapped: false).stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            .frame(width: size.width, height: size.height)
        }

        private func path(mapped: Bool) -> Path {
            Path { path in
                for column in AlignmentWaveformProjection.displayColumns(
                    strokes: strokes, start: extent.lowerBound, duration: extent.upperBound - extent.lowerBound,
                    width: size.width, pixelsPerPoint: displayScale
                ) where column.mapped == mapped {
                    path.move(to: CGPoint(x: column.x, y: 24 - Double(column.high) * gain * 20))
                    path.addLine(to: CGPoint(x: column.x, y: 24 - Double(column.low) * gain * 20))
                }
            }
        }
    }

    private var groups: [RecorderGroupID] {
        var seen: Set<RecorderGroupID> = []
        return model.waveformTracks.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    private var visibleTracks: [AlignmentWaveformTrack] {
        model.waveformTracks.filter { model.groupEnabled($0.group) && model.trackEnabled($0.id) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                transport
                HStack {
                    Label("Aligned timeline", systemImage: "waveform")
                        .font(.headline)
                    Spacer()
                    Button(model.isLoadingWaveforms ? "Cancel" : "Refresh audio") {
                        model.isLoadingWaveforms
                            ? model.cancelWaveforms()
                            : model.loadWaveforms(keepingSnapshot: model.pendingWaveformMove != nil)
                    }
                    .accessibilityIdentifier("alignment.waveforms.load")
                }
                navigationControls
                GroupBox("Automatic alignment · review before applying") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isWorking ? "Analysing…" : "Match selected speaker") {
                                model.analyse()
                            }
                            .disabled(model.isWorking || model.selectedSpeakerMatchOptions.isEmpty)
                            .accessibilityIdentifier("alignment.analyse")
                            Text("Compare assigned speaker channels in different recorder groups. An accepted match moves the target recorder's tracks together; source lengths need not match.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.selectedSpeakerMatchOptions.isEmpty {
                            Picker("Speaker to match", selection: Binding(
                                get: { model.selectedMatchSpeaker ?? model.selectedSpeakerMatchOptions.first?.speaker },
                                set: { model.selectMatchSpeaker($0) }
                            )) {
                                ForEach(model.selectedSpeakerMatchOptions, id: \.speaker) { option in
                                    Text(model.speakerName(option.speaker)).tag(Optional(option.speaker))
                                }
                            }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("alignment.auto.speaker")
                            if model.selectedSpeakerPairs.count > 1 {
                                Picker("Recording pair", selection: Binding(
                                    get: { model.selectedMatchOption ?? model.selectedSpeakerPairs.first },
                                    set: { model.selectMatchOption($0) }
                                )) {
                                    ForEach(model.selectedSpeakerPairs, id: \.self) { option in
                                        Text(model.speakerMatchDescription(option)).tag(Optional(option))
                                    }
                                }
                                .disabled(model.isWorking)
                                .accessibilityIdentifier("alignment.auto.pair")
                            } else if let option = model.selectedSpeakerPairs.first {
                                Text(model.speakerMatchDescription(option))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("alignment.auto.pairSummary")
                            }
                        } else {
                            Text("No identified speaker has an eligible channel in this recorder and an already aligned recorder. Set speaker channels in Setup, align another group first, or use manual placement.")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("alignment.auto.noSpeakerMatch")
                        }
                        if let analysis = model.selectedAnalysis {
                            if let proposal = analysis.proposal {
                                Text("Proposed for \(model.selectedRow?.epochLabel ?? "selected epoch"): \(AlignmentPresentation.offsetLabel(proposal.segment.alignedOffset.approximateDouble * 1_000)); \(AlignmentPresentation.rateLabel(proposal.ppm)).")
                                    .accessibilityIdentifier("alignment.auto.timing")
                                Text("Measured source interval \(AlignmentPresentation.formatTime(proposal.segment.groupClockStart.approximateDouble))–\(AlignmentPresentation.formatTime(proposal.segment.groupClockEnd.approximateDouble)); \(analysis.coverage.eligibleCount)/\(analysis.coverage.windowCount) windows, peak \(proposal.provenance.evidenceScore.map { String(format: "%.3f", $0) } ?? "unavailable"), residual p95 \(String(format: "%.3f", proposal.acousticResidualP95Milliseconds)) ms. These are evidence measures, not a probability or clock proof.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("alignment.auto.evidence")
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
                                Text("No automatic timing was applied. Place the epoch manually or add anchors.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let state = model.selectedAnalysisState {
                            let copy = AlignmentPresentation.copy(for: state.status)
                            Label("\(copy.heading): \(copy.evidence)",
                                  systemImage: copy.isBlocked ? "exclamationmark.triangle" : "info.circle")
                                .accessibilityIdentifier("alignment.auto.refusal")
                        } else {
                            Text("Select a recorder epoch, then find matches. Silence, repetitive peaks, disagreement and gaps are refused; manual alignment remains available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("alignment.auto")
                .confirmationDialog(
                    "Extend the measured timing beyond its evidence?",
                    isPresented: $confirmingExtension
                ) {
                    Button("Extend rate and offset to whole epoch") { model.extendProposalToEpoch() }
                    Button("Keep measured interval", role: .cancel) {}
                } message: {
                    Text("This extrapolates the proposed time stretch into unmeasured audio. It cannot establish continuity, drift or clock accuracy outside the measured interval. Review playback; the decision is undoable and originals remain unchanged.")
                }
                if model.waveformMap == nil, model.pendingWaveformMove == nil,
                   !model.waveformTracks.isEmpty {
                    Button("Place groups at source time") { model.placeGroupsAtSourceTime() }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("alignment.waveforms.placeInitial")
                    Text("This places the first eligible epoch of each recorder at zero offset, without estimating clock drift. Time restarted epochs separately; then move recorder groups while listening. The reference stays fixed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Compare").font(.caption.weight(.semibold))
                    Picker("Compare", selection: $layout) {
                        ForEach(Layout.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Compare waveform layout")
                    .accessibilityIdentifier("alignment.waveforms.layout")
                    Toggle("Normalize view", isOn: $normalizeView)
                        .toggleStyle(.checkbox)
                        .help("Scales each recording's displayed peaks in its measured tile; playback and originals are unchanged.")
                        .accessibilityIdentifier("alignment.waveforms.normalizeView")
                    Spacer()
                    Text("Dashed = unplaced source time")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if normalizeView {
                    Text("Visual gain is per recording and measured tile. Audio and saved timing are unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.waveforms.normalizeNote")
                }
                ruler
                if model.waveformTracks.isEmpty, model.waveformNavigationEndSeconds > 0 {
                    ContentUnavailableView(
                        "No audio in this window",
                        systemImage: "waveform",
                        description: Text("Pan the ruler, enter an aligned time, or open the episode overview. Recordings that failed to load are listed below.")
                    )
                    .frame(minHeight: 200)
                } else if visibleTracks.isEmpty && layout == .overlay {
                    ContentUnavailableView(
                        "No waveforms showing",
                        systemImage: "waveform",
                        description: Text("Enable a recorder and track below, or refresh audio to load a measured window.")
                    )
                    .frame(minHeight: 200)
                } else if layout == .overlay {
                    overlay
                } else {
                    ForEach(groups, id: \.self) { group in
                        groupLane(group)
                    }
                }
                if layout == .overlay { recordings }
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
                if let revision = model.waveformMapRevision {
                    Text("Map revision \(revision). Manual timing changes are undoable; originals stay unchanged.")
                        .font(.caption)
                        .accessibilityIdentifier("alignment.waveforms.revision")
                }
                if !model.waveformTracks.isEmpty { timingControls }
                DisclosureGroup {
                    overview
                } label: {
                    HStack(spacing: 8) {
                        Text("Episode overview")
                        if model.isLoadingOverview {
                            ProgressView(value: model.waveformOverviewProgress)
                                .frame(width: 80)
                                .accessibilityLabel("Episode overview progress")
                        }
                        Text(model.waveformOverviewMessage)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("alignment.waveforms.overview.status")
                    }
                }
            }
            .padding(4)
        }
        .accessibilityIdentifier("alignment.waveforms")
        .onChange(of: model.waveformPlayheadSeconds, initial: true) { _, time in
            if !editingTime { timeDraft = String(format: "%.3f", time) }
        }
        .onChange(of: editingTime) { _, focused in
            if !focused { commitTime() }
        }
        .onChange(of: layout) { _, _ in clearHandCursor() }
        .onDisappear { clearHandCursor() }
    }

    private var recordings: some View {
        GroupBox("Recordings · show and hear timed tracks") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.self) { group in
                    let tracks = model.waveformTracks.filter { $0.group == group }
                    Toggle(tracks.first?.groupName ?? "Recorder group", isOn: Binding(
                        get: { model.groupEnabled(group) },
                        set: { model.setGroup(group, enabled: $0) }
                    ))
                    .accessibilityLabel("Show recorder group \(tracks.first?.groupName ?? ""); only sources with accepted timing can be heard")
                    .accessibilityIdentifier("alignment.waveforms.group.\(group)")
                    if model.groupEnabled(group) {
                        ForEach(tracks) { track in
                            let identity = model.trackIdentity(track.id)
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { model.trackEnabled(track.id) },
                                    set: { model.setTrack(track.id, enabled: $0) }
                                ))
                                .labelsHidden()
                                .accessibilityLabel(model.sourceHasAcceptedTiming(track.id)
                                    ? "Show and hear \(identity.label), \(track.name)"
                                    : "Show \(identity.label), \(track.name); timing not set, not played")
                                .accessibilityIdentifier("alignment.waveforms.enabled.\(track.id)")
                                Button("\(track.groupName) · \(track.name)") { model.selectWaveform(track) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                                    .accessibilityValue(model.selectedWaveformSource == track.id ? "Active for editing" : "Select to edit")
                                    .font(.callout.weight(model.selection == track.epoch ? .semibold : .regular))
                                Circle().fill(identity.color).frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                Text(identity.label).font(.caption).foregroundStyle(.secondary)
                                if !model.trackEnabled(track.id) {
                                    Text("Hidden and muted").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func groupLane(_ group: RecorderGroupID) -> some View {
        let tracks = model.waveformTracks.filter { $0.group == group }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(tracks.first?.groupName ?? "Recorder group", isOn: Binding(
                    get: { model.groupEnabled(group) },
                    set: { model.setGroup(group, enabled: $0) }
                ))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(width: headerWidth, alignment: .leading)
                .accessibilityLabel("Show recorder group \(tracks.first?.groupName ?? ""); only sources with accepted timing can be heard")
                .accessibilityIdentifier("alignment.waveforms.group.\(group)")
                Text("\(tracks.count) \(tracks.count == 1 ? "source" : "sources") · move this recorder as one unit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.groupEnabled(group) {
                ForEach(tracks) { track in lane(track) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transport: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button("Back 5 s", systemImage: "gobackward.5") {
                    model.seekEnabledTracks(to: max(-86_400, model.waveformPlayheadSeconds - 5))
                }
                .accessibilityIdentifier("alignment.waveforms.transport.back")
                Button(model.canStopAudition ? "Pause" : "Play",
                       systemImage: model.canStopAudition ? "pause.fill" : "play.fill") {
                    model.canStopAudition ? model.pauseEnabledTracks() : model.playEnabledTracks()
                }
                .accessibilityIdentifier("alignment.waveforms.transport.play")
                .disabled(model.pendingWaveformMove != nil)
                Button("Stop", systemImage: "stop.fill") { model.stopEnabledTracks() }
                    .accessibilityIdentifier("alignment.waveforms.transport.stop")
                Button("Forward 5 s", systemImage: "goforward.5") {
                    model.seekEnabledTracks(to: min(86_400, model.waveformPlayheadSeconds + 5))
                }
                .accessibilityIdentifier("alignment.waveforms.transport.forward")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
            Text(model.auditionLabel)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: 320, alignment: .trailing)
                .help(model.auditionLabel)
                .accessibilityIdentifier("alignment.waveforms.transport.status")
        }
        .overlay(alignment: .center) {
            VStack(alignment: .center, spacing: 2) {
                Text("ALIGNED TIME").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Aligned time (s)", text: $timeDraft)
                    .focused($editingTime)
                    .onSubmit { editingTime = false }
                    .multilineTextAlignment(.center)
                    .font(.system(.title2, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .frame(width: 130)
                    .accessibilityLabel("Aligned playhead time in seconds")
                    .accessibilityIdentifier("alignment.waveforms.playhead")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var navigationControls: some View {
        HStack(spacing: 10) {
            Text("Zoom").font(.caption.weight(.semibold))
            Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
            Slider(value: Binding(
                get: {
                    AlignmentWaveformProjection.zoomLevel(
                        for: model.waveformDurationSeconds, maximum: model.maximumWaveformDuration
                    ) ?? 0
                },
                set: { level in
                    guard let duration = AlignmentWaveformProjection.zoomDuration(
                        for: level, maximum: model.maximumWaveformDuration
                    ) else { return }
                    let center = zoomCenterSeconds ?? model.waveformStartSeconds + model.waveformDurationSeconds / 2
                    zoomCenterSeconds = center
                    model.waveformDurationSeconds = duration
                    model.waveformStartSeconds = min(
                        model.waveformViewingBounds.upperBound - duration,
                        max(model.waveformViewingBounds.lowerBound, center - duration / 2)
                    )
                }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing {
                    zoomCenterSeconds = nil
                    if model.waveformDurationSeconds <= 30 {
                        model.loadWaveforms(keepingSnapshot: true, preload: true)
                    }
                }
            }) {
                Text("Horizontal zoom, visible span \(model.waveformDurationSeconds, specifier: "%.2f") seconds")
            }
            .frame(minWidth: 110, maxWidth: 240)
            .accessibilityIdentifier("alignment.waveforms.zoom")
            Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
            Text("\(model.waveformDurationSeconds, specifier: "%.2f") s")
                .font(.caption.monospacedDigit())
                .frame(width: 52)
            Button("Fit timeline") { model.fitWaveformTimeline() }
                .disabled(model.waveformFitRange == nil || model.isWorking || model.pendingWaveformMove != nil)
                .accessibilityIdentifier("alignment.waveforms.fitTimeline")
                .help("Show the complete cached episode overview, including negative aligned time.")
            if layout == .separate {
                Text("Height").font(.caption.weight(.semibold))
                Slider(value: $laneHeight, in: 64...220) {
                    Text("Source lane height")
                }
                .frame(minWidth: 70, maxWidth: 160)
                .accessibilityIdentifier("alignment.waveforms.laneHeight")
            }
            Spacer(minLength: 0)
        }
        .disabled(model.isWorking || model.pendingWaveformMove != nil)
        .accessibilityIdentifier("alignment.waveforms.navigation")
    }

    private func commitTime() {
        guard let time = Double(timeDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              time.isFinite else {
            model.seekEnabledTracks(to: .nan)
            timeDraft = String(format: "%.3f", model.waveformPlayheadSeconds)
            return
        }
        model.seekEnabledTracks(to: time)
        timeDraft = String(format: "%.3f", model.waveformPlayheadSeconds)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !model.waveformOverviewRefusals.isEmpty && !model.isLoadingOverview {
                Button("Retry failed overview loads") { model.loadWaveformOverview() }
                    .accessibilityIdentifier("alignment.waveforms.overview.retry")
            }
            let visible = model.waveformOverviewTracks.filter {
                model.groupEnabled($0.group) && model.trackEnabled($0.id)
            }
            let allStrokes = visible.flatMap { model.waveformOverviewStrokes[$0.id] ?? [] }
            if let failed = visible.first(where: { model.waveformOverviewProjectionErrors[$0.id] != nil }),
               let error = model.waveformOverviewProjectionErrors[failed.id] {
                Text("Cannot place episode overview: \(error)")
            } else if let extent = AlignmentWaveformProjection.overviewExtent(allStrokes) {
                Text("Episode overview: \(extent.lowerBound, specifier: "%.1f") to \(extent.upperBound, specifier: "%.1f") seconds. Blue uses stored timing; dashed orange is unplaced source time.")
                    .font(.caption)
                if !AlignmentWaveformProjection.unavailableOverviewRanges(in: extent).isEmpty {
                    Text("Gray shading marks aligned time outside minus 24 to plus 24 hours: its overview still exists, but it cannot be opened as an exact window. This is not a failed recording. The scan limit is in source time; stored timing is unchanged.")
                        .font(.caption)
                        .accessibilityIdentifier("alignment.waveforms.overview.navigationLimit")
                }
                ForEach(model.waveformOverviewTracks.filter { model.groupEnabled($0.group) }) { track in
                    overviewLane(track, extent: extent)
                }
            }
            ForEach(model.waveformOverviewRefusals) { refusal in
                Label("\(refusal.name): \(refusal.reason)", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("alignment.waveforms.overview.refusal.\(refusal.id)")
            }
        }
    }

    @ViewBuilder
    private func overviewLane(_ track: AlignmentWaveformTrack, extent: ClosedRange<Double>) -> some View {
        if !model.trackEnabled(track.id) {
            Text("Hidden and muted").font(.caption).foregroundStyle(.secondary)
        } else if let strokes = model.waveformOverviewStrokes[track.id] {
            let canOpen = AlignmentWaveformProjection.overviewWindowStart(
                at: model.waveformPlayheadSeconds, duration: model.waveformDurationSeconds, strokes: strokes
            ) != nil
            let hasNavigableAudio = strokes.contains {
                $0.displayRange.overlaps(AlignmentWaveformProjection.overviewNavigationRange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(track.groupName) · \(track.name)").font(.caption)
                GeometryReader { geometry in
                    let scale = geometry.size.width / (extent.upperBound - extent.lowerBound)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.04))
                        OverviewTrackDrawing(
                            snapshot: model.waveformOverviewSnapshotID, strokes: strokes,
                            extent: extent, size: geometry.size,
                            gain: normalizeView ? model.waveformOverviewDisplayGains[track.id] ?? 1 : 1,
                            displayScale: displayScale
                        )
                        .equatable()
                        Rectangle().fill(Color.accentColor.opacity(0.2))
                            .frame(width: max(1, model.waveformDurationSeconds * scale))
                            .offset(x: (model.waveformStartSeconds - extent.lowerBound) * scale)
                        ForEach(
                            AlignmentWaveformProjection.unavailableOverviewRanges(in: extent),
                            id: \.lowerBound
                        ) { range in
                            Rectangle().fill(Color.secondary.opacity(0.45))
                                .frame(width: (range.upperBound - range.lowerBound) * scale)
                                .offset(x: (range.lowerBound - extent.lowerBound) * scale)
                                .overlay(alignment: .topLeading) {
                                    if (range.upperBound - range.lowerBound) * scale >= 150 {
                                        Text("Outside navigable time").font(.caption2)
                                            .offset(x: (range.lowerBound - extent.lowerBound) * scale)
                                    }
                                }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        openOverviewWindow(at: extent.lowerBound + point.x / scale, strokes: strokes)
                    }
                }
                .frame(height: 48)
                .clipped()
                .accessibilityRepresentation {
                    if hasNavigableAudio {
                        Text("\(track.groupName), \(track.name), complete measured PCM overview; \(strokes.filter { !$0.mapped }.count) unplaced bins. Use Open Window at Playhead to navigate within covered audio from minus 86,400 to plus 86,400 seconds. Audio outside that range cannot be opened as an exact window; coarse bins do not set anchors.")
                            .accessibilityIdentifier("alignment.waveforms.overview.track.\(track.id)")
                    } else {
                        Text("\(track.groupName), \(track.name), complete measured PCM overview. Stored timing places all covered audio outside minus 86,400 to plus 86,400 aligned seconds, so it cannot be opened as an exact window.")
                            .accessibilityIdentifier("alignment.waveforms.overview.track.\(track.id)")
                    }
                }
                if hasNavigableAudio {
                    Button("Open Window at Playhead") {
                        openOverviewWindow(at: model.waveformPlayheadSeconds, strokes: strokes)
                    }
                    .disabled(!canOpen)
                    .accessibilityLabel("\(track.groupName), \(track.name), open exact window at aligned playhead")
                    .accessibilityIdentifier("alignment.waveforms.overview.open.\(track.id)")
                    .help("Type an aligned playhead within this recording's covered audio, from minus 86,400 to plus 86,400 seconds.")
                }
            }
        } else if let error = model.waveformOverviewProjectionErrors[track.id] {
            Text("\(track.name): \(error)")
        }
    }

    private func openOverviewWindow(at time: Double, strokes: [AlignmentWaveformStroke]) {
        guard AlignmentWaveformProjection.overviewWindowStart(
            at: time, duration: min(30, model.waveformDurationSeconds), strokes: strokes
        ) != nil else { return }
        model.navigateWaveformOverview(to: time)
    }

    private var ruler: some View {
        HStack(spacing: 8) {
            Text("ALIGNED SECONDS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: headerWidth, alignment: .leading)
                .accessibilityLabel(String(
                    format: "Visible aligned time ruler: %.3f to %.3f seconds",
                    model.waveformStartSeconds, model.waveformStartSeconds + model.waveformDurationSeconds
                ))
                .accessibilityIdentifier("alignment.waveforms.ruler")
            GeometryReader { geometry in
                let width = geometry.size.width
                let start = model.waveformStartSeconds
                let duration = model.waveformDurationSeconds
                let bounds = model.waveformViewingBounds
                let seekBounds = -86_400.0...min(86_400, max(0, model.waveformNavigationEndSeconds))
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.primary.opacity(0.04))
                    ForEach(AlignmentWaveformProjection.rulerTicks(
                        start: start, duration: duration, width: width
                    )) { tick in
                        let position = (tick.time - start) / duration * width
                        Path { path in
                            path.move(to: CGPoint(x: position, y: tick.major ? 25 : 36))
                            path.addLine(to: CGPoint(x: position, y: 44))
                        }
                        .stroke(Color.secondary.opacity(tick.major ? 0.7 : 0.35), lineWidth: 1)
                        if tick.major, width >= 92 {
                            Text(AlignmentPresentation.formatTime(tick.time))
                                .font(.caption2.monospacedDigit())
                                .position(x: max(46, min(width - 46, position)), y: 12)
                        }
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Aligned ruler. Click to seek, drag empty space to pan, or pinch to zoom.")
                .accessibilityIdentifier("alignment.waveforms.ruler.surface")
                .onTapGesture { point in
                    guard let time = AlignmentWaveformProjection.rulerTime(
                        at: point.x, width: width, start: start, duration: duration, bounds: seekBounds
                    ) else { return }
                    let wasPlaying = model.canStopAudition
                    if model.previewWaveformPlayhead(to: time), wasPlaying { model.playEnabledTracks() }
                }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        if rulerPan == nil {
                            rulerPan = (start: start, width: width, duration: duration)
                        }
                        guard let pan = rulerPan else { return }
                        guard let window = AlignmentWaveformProjection.rulerPanStart(
                            from: pan.start, translation: drag.translation.width,
                            width: pan.width, duration: pan.duration, bounds: bounds
                        ) else { return }
                        _ = model.previewWaveformWindow(start: window)
                    }
                    .onEnded { _ in
                        if rulerPan != nil, model.waveformDurationSeconds <= 30 {
                            model.loadWaveforms(keepingSnapshot: true)
                        }
                        rulerPan = nil
                    })
                .overlay(alignment: .topLeading) {
                    if width > 0 {
                        let position = (model.waveformPlayheadSeconds - start) / duration * width
                        if position.isFinite, (0...width).contains(position) {
                            Path { path in
                                path.move(to: CGPoint(x: position, y: 33))
                                path.addLine(to: CGPoint(x: position, y: 44))
                            }
                            .stroke(Color.accentColor, lineWidth: 1)
                            .allowsHitTesting(false)
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24, height: 35)
                                .contentShape(Rectangle())
                                .position(x: position, y: 31)
                                .highPriorityGesture(DragGesture(minimumDistance: 1)
                                    .onChanged { drag in
                                        if rulerPlayheadDrag == nil {
                                            rulerPlayheadDrag = (
                                                time: model.waveformPlayheadSeconds, start: start,
                                                duration: duration, width: width,
                                                wasPlaying: model.canStopAudition
                                            )
                                        }
                                        guard let session = rulerPlayheadDrag else { return }
                                        let time = min(seekBounds.upperBound, max(seekBounds.lowerBound,
                                            max(session.start, min(
                                            session.start + session.duration,
                                            session.time + Double(drag.translation.width / session.width)
                                                * session.duration
                                        ))))
                                        if !model.previewWaveformPlayhead(to: time) { rulerPlayheadDrag = nil }
                                    }
                                    .onEnded { _ in
                                        if let session = rulerPlayheadDrag, session.wasPlaying {
                                            model.playEnabledTracks()
                                        }
                                        rulerPlayheadDrag = nil
                                    })
                                .accessibilityLabel("Aligned playhead marker")
                                .accessibilityValue(AlignmentPresentation.formatTime(model.waveformPlayheadSeconds))
                                .accessibilityAdjustableAction { direction in
                                    let increment = max(0.1, duration / 20)
                                    let delta = direction == .increment ? increment : -increment
                                    let time = min(seekBounds.upperBound, max(
                                        seekBounds.lowerBound, model.waveformPlayheadSeconds + delta
                                    ))
                                    let wasPlaying = model.canStopAudition
                                    if model.previewWaveformPlayhead(to: time), wasPlaying {
                                        model.playEnabledTracks()
                                    }
                                }
                                .accessibilityIdentifier("alignment.waveforms.ruler.playhead")
                        }
                    }
                }
                .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02)
                    .onChanged { value in
                        guard !model.isWorking, model.pendingWaveformMove == nil else { return }
                        if rulerZoom == nil {
                            rulerZoom = (
                                start: start, duration: duration,
                                anchor: min(1, max(0, value.startAnchor.x))
                            )
                        }
                        guard let zoom = rulerZoom,
                              let window = AlignmentWaveformProjection.rulerZoom(
                                  start: zoom.start, duration: zoom.duration,
                                  anchor: zoom.anchor, magnification: value.magnification,
                                  bounds: bounds, maximumDuration: model.maximumWaveformDuration
                              ) else { return }
                        model.waveformStartSeconds = window.start
                        model.waveformDurationSeconds = window.duration
                    }
                    .onEnded { _ in
                        if rulerZoom != nil, model.waveformDurationSeconds <= 30 {
                            model.loadWaveforms(keepingSnapshot: true, preload: true)
                        }
                        rulerZoom = nil
                    })
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .help("Click the ruler to seek, drag its marker to move the playhead, drag empty space to pan, or pinch to zoom around the pointer.")
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(AlignmentWaveformProjection.speakerGroups(
                tracks: visibleTracks, speakerForSource: model.trackSpeakerID
            )) { speakerGroup in
                speakerOverlay(speakerGroup)
            }
            ForEach(visibleTracks) { track in
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
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(speakerName.uppercased()) · \(tracks.count) \(tracks.count == 1 ? "SOURCE" : "SOURCES")")
                    .font(.caption2.weight(.semibold))
                ForEach(tracks) { track in
                    let identity = model.trackIdentity(track.id)
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
                    .accessibilityLabel("\(track.groupName), \(track.name), \(identity.label)")
                    .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                }
            }
            .frame(width: headerWidth, alignment: .leading)
            GeometryReader { geometry in
                let slices = model.waveformTileSlices
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.04))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    ForEach(slices) { slice in
                        ForEach(tracks) { track in
                            if model.waveformDurationSeconds <= 30,
                               let strokes = slice.strokes[track.id] {
                                waveformDrawing(
                                    track: track, strokes: strokes, slice: slice,
                                    size: geometry.size, overlay: true
                                )
                            }
                        }
                    }
                    ForEach(tracks) { track in
                        if model.waveformDurationSeconds > 30
                            || model.waveformVisibleStrokes(for: track.id).isEmpty {
                            cachedOverviewDrawing(track: track, size: geometry.size, overlay: true)
                        }
                    }
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1)
                        .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width),
                                  y: geometry.size.height / 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
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
                        guard let track = tracks.first(where: { $0.id == model.selectedWaveformSource }) else { return }
                        dragGroup(
                            track, strokes: dragSession == nil ? model.waveformInteractionStrokes(for: track.id) : [],
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
            .frame(height: max(160, CGFloat(tracks.count * 28 + 92)))
            .clipped()
            .overlay(alignment: .topLeading) {
                if tracks.contains(where: { $0.group == dragSession?.group }) { dragPreview }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .accessibilityRepresentation {
                Text("\(speakerName), \(tracks.count) enabled \(tracks.count == 1 ? "track" : "tracks") overlaid. Select a recording in this speaker's panel to move its entire recorder group; use the numeric group move for keyboard editing.")
                    .accessibilityIdentifier("alignment.waveforms.overlay.\(speakerGroup.id.map { "\($0)" } ?? "unknown")")
            }
        }
    }

    @ViewBuilder
    private func lane(_ track: AlignmentWaveformTrack) -> some View {
        let identity = model.trackIdentity(track.id)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Toggle("", isOn: Binding(
                        get: { model.trackEnabled(track.id) },
                        set: { model.setTrack(track.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel(model.sourceHasAcceptedTiming(track.id)
                        ? "Show and hear \(identity.label), \(track.name)"
                        : "Show \(identity.label), \(track.name); timing not set, not played")
                    .accessibilityIdentifier("alignment.waveforms.enabled.\(track.id)")
                    Circle().fill(identity.color).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Button(track.name) { model.selectWaveform(track) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(model.selectedWaveformSource == track.id ? .semibold : .regular))
                        .lineLimit(2)
                        .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                }
                Text("\(identity.label) · \(track.envelope.channelCount) channels")
                    .font(.caption).foregroundStyle(.secondary)
                if model.trackEnabled(track.id) {
                    Text(model.rows.first(where: { $0.epochID == track.epoch })?.state.heading ?? "Unmapped")
                        .font(.caption)
                        .accessibilityIdentifier("alignment.waveforms.state.\(track.id)")
                    if model.waveformMap != nil, !model.sourceHasAcceptedTiming(track.id) {
                        Text("No accepted timing: shown, not played.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: headerWidth, alignment: .leading)
            if model.trackEnabled(track.id),
               (model.waveformTileSlices.contains(where: { $0.strokes[track.id]?.isEmpty == false })
                   || model.waveformOverviewStrokes[track.id]?.isEmpty == false) {
                GeometryReader { geometry in
                    let slices = model.waveformTileSlices
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.04))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                        }.stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        ForEach(slices) { slice in
                            if model.waveformDurationSeconds <= 30,
                               let drawing = slice.strokes[track.id] {
                                waveformDrawing(
                                    track: track, strokes: drawing, slice: slice,
                                    size: geometry.size, overlay: false
                                )
                            }
                        }
                        if model.waveformDurationSeconds > 30
                            || model.waveformVisibleStrokes(for: track.id).isEmpty {
                            cachedOverviewDrawing(track: track, size: geometry.size, overlay: false)
                        }
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1)
                            .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width), y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        pick(track, strokes: model.waveformInteractionStrokes(for: track.id), time: model.waveformStartSeconds
                             + Double(point.x / geometry.size.width) * model.waveformDurationSeconds)
                    }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { drag in
                            dragGroup(
                                track, strokes: dragSession == nil ? model.waveformInteractionStrokes(for: track.id) : [],
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
                .overlay(alignment: .topLeading) {
                    if dragSession?.group == track.group { dragPreview }
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.selectedWaveformSource == track.id ? Color.accentColor : Color.secondary.opacity(0.3)))
                .accessibilityRepresentation {
                    let strokes = model.waveformStrokes[track.id] ?? []
                    Button("\(track.groupName), \(track.name), audio waveform. \(strokes.count) measured amplitude bins; \(strokes.filter { !$0.mapped }.count) unplaced. Stored offset \(model.rows.first(where: { $0.epochID == track.epoch })?.offsetMilliseconds ?? 0) milliseconds. Select this track, then use numeric timing as a keyboard alternative.") {
                        model.selectWaveform(track)
                    }
                    .accessibilityIdentifier("alignment.waveforms.track.\(track.id)")
                }
            } else if model.trackEnabled(track.id),
                      let error = model.waveformProjectionErrors[track.id] {
                Text("Cannot place this waveform: \(error)")
            } else if !model.trackEnabled(track.id) {
                Color.primary.opacity(0.02)
                    .frame(height: 34)
                    .overlay(alignment: .leading) {
                        Text("Hidden and muted").font(.caption).foregroundStyle(.secondary)
                    }
            } else {
                Color.primary.opacity(0.02)
                    .frame(height: 34)
                    .overlay(alignment: .leading) {
                        Text(model.isLoadingOverview ? "Preparing full-length waveform overview…"
                            : model.isLoadingWaveforms ? "Loading measured waveform…"
                            : "No measured audio in this window")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func dragGroup(
        _ track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke],
        drag: DragGesture.Value, geometry: GeometryProxy
    ) {
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
        guard width > 0 else { return false }
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

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected recorder: \(model.selectedRow?.groupName ?? "select a lane")")
            if model.canMoveGroup {
                HStack {
                    Button("Nudge earlier 10 ms") {
                        model.groupDraftMilliseconds = -10
                        model.commitGroupMove()
                    }
                    Button("Nudge later 10 ms") {
                        model.groupDraftMilliseconds = 10
                        model.commitGroupMove()
                    }
                }
                .accessibilityIdentifier("alignment.waveforms.nudges")
                HStack {
                    numberField("Group move (ms)", value: $model.groupDraftMilliseconds, identifier: "groupMove")
                    Button("Apply group move") { model.commitGroupMove() }
                        .disabled(model.groupDraftMilliseconds == 0)
                    Button("Reset preview") { model.groupDraftMilliseconds = 0 }
                }
                Text("Drag any lane in this recorder to move every mapped epoch and source together. Each committed move is one Undo step. Unsaved preview is not audible until applied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced epoch timing") {
                HStack(alignment: .bottom, spacing: 12) {
                    numberField("Offset (ms)", value: $model.waveformOffsetMilliseconds, identifier: "offset")
                    numberField("Rate (ppm)", value: $model.waveformRatePPM, identifier: "rate")
                }
                HStack {
                    Button("Apply epoch timing") {
                        model.applyNumeric(
                            ratePPM: model.waveformRatePPM,
                            offsetMilliseconds: model.waveformOffsetMilliseconds
                        )
                    }
                    .disabled(!model.canCorrect)
                    .accessibilityIdentifier("alignment.waveforms.apply")
                    Button("Reset preview") { model.resetWaveformTiming() }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    numberField("Reference point (s)", value: $model.waveformReferencePoint, identifier: "referencePoint")
                    numberField("Target source point (s)", value: $model.waveformTargetPoint, identifier: "targetPoint")
                }
                HStack {
                    Button("Match Anchor") { model.addWaveformAnchor() }
                    Button("Apply \(model.waveformDraftAnchors.count) Anchors") { model.applyWaveformAnchors() }
                        .disabled(model.waveformDraftAnchors.count < 2 || !model.canCorrect)
                }
            }
        }
        .disabled(model.isWorking)
    }

    private func numberField(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
            TextField(title, value: value, format: .number)
                .accessibilityIdentifier("alignment.waveforms.\(identifier)")
        }

        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cachedOverviewDrawing(track: AlignmentWaveformTrack, size: CGSize, overlay: Bool) -> some View {
        if let strokes = model.waveformOverviewStrokes[track.id], !strokes.isEmpty {
            let activeGroup = model.selectedRow?.groupID == track.group
            let shift = ((activeGroup ? model.groupDraftMilliseconds : 0)
                + (model.pendingWaveformMove?.displayShift(for: track.group) ?? 0))
                / 1_000 / model.waveformDurationSeconds * size.width
            WaveformTrackDrawing(
                snapshot: model.waveformOverviewSnapshotID, strokes: strokes,
                size: size, start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
                color: model.trackIdentity(track.id).color.opacity(overlay ? 0.8 : 1),
                lineWidth: overlay ? (model.selectedWaveformSource == track.id ? 2 : 1.3) : 1.5,
                gain: normalizeView ? model.waveformOverviewDisplayGains[track.id] ?? 1 : 1,
                draftEpoch: !activeGroup && model.waveformTimingIsDraft ? model.selection : nil,
                draftRatePPM: model.waveformRatePPM,
                draftOffsetMilliseconds: model.waveformOffsetMilliseconds,
                displayScale: displayScale
            )
            .equatable()
            .offset(x: shift)
        }
    }

    @ViewBuilder
    private func waveformDrawing(
        track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke],
        slice: EpisodeAlignmentModel.WaveformTileSlice, size: CGSize, overlay: Bool
    ) -> some View {
        let activeGroup = model.selectedRow?.groupID == track.group
        let tileWidth = size.width * slice.duration / model.waveformDurationSeconds
        let clip = AlignmentWaveformProjection.tileClip(
            range: slice.range, tileStart: slice.start,
            tileDuration: slice.duration, tileWidth: tileWidth
        )
        let previewShift = model.pendingWaveformMove?.displayShift(for: track.group) ?? 0
        let groupShift = ((activeGroup ? model.groupDraftMilliseconds : 0) + previewShift)
            / 1_000 / model.waveformDurationSeconds * size.width
        if let clip, let translation = AlignmentWaveformProjection.tileTranslation(
            tileStart: slice.start, windowStart: model.waveformStartSeconds,
            visible: model.waveformDurationSeconds, width: size.width
        ) {
            WaveformTrackDrawing(
                snapshot: slice.snapshot, strokes: strokes,
                size: CGSize(width: tileWidth, height: size.height),
                start: slice.start, duration: slice.duration,
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
            .frame(width: size.width, alignment: .leading)
            .offset(x: translation + groupShift)
        } else {
            Text("Cannot position measured waveform tile.")
                .font(.caption).foregroundStyle(.secondary)
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
        if model.waveformMap?.reference.group == track.group {
            model.waveformReferencePoint = time
        } else {
            model.selectWaveform(track, epoch: selected.epoch)
            model.waveformTargetPoint = selected.sourceSeconds
        }
        if seek { model.seekEnabledTracks(to: time) }
        return true
    }

}
