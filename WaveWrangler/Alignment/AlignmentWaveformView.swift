import SwiftUI
import WWAlignPipeline
import WWCore

struct AlignmentWaveformView: View {
    @Bindable var model: EpisodeAlignmentModel
    @State private var dragSession: AlignmentWaveformDrag?
    @State private var scrubPreviewSeconds: Double?
    @State private var layout: Layout = .separate
    @State private var normalizeView = false

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

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.snapshot == rhs.snapshot && lhs.size == rhs.size
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
                path(mapped: false).stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: [3, 2]))
            }
            .frame(width: size.width, height: size.height)
        }

        private func path(mapped: Bool) -> Path {
            Path { path in
                guard duration.isFinite, duration > 0 else { return }
                for stroke in strokes where stroke.mapped == mapped {
                    let time: Double
                    if stroke.epoch == draftEpoch {
                        time = stroke.groupSeconds * (1 + draftRatePPM / 1_000_000)
                            + draftOffsetMilliseconds / 1_000
                    } else {
                        time = stroke.displaySeconds
                    }
                    let position = (time - start) / duration * size.width
                    guard position.isFinite else { continue }
                    path.move(to: CGPoint(x: position, y: size.height * (0.5 - Double(stroke.high) * gain * 0.45)))
                    path.addLine(to: CGPoint(x: position, y: size.height * (0.5 - Double(stroke.low) * gain * 0.45)))
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

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.snapshot == rhs.snapshot && lhs.extent == rhs.extent
                && lhs.size == rhs.size && lhs.gain == rhs.gain
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
                let scale = size.width / (extent.upperBound - extent.lowerBound)
                for stroke in strokes where stroke.mapped == mapped {
                    let x = (stroke.displaySeconds - extent.lowerBound) * scale
                    path.move(to: CGPoint(x: x, y: 24 - Double(stroke.high) * gain * 20))
                    path.addLine(to: CGPoint(x: x, y: 24 - Double(stroke.low) * gain * 20))
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shared timeline").font(.headline)
                    Spacer()
                    Button(model.isLoadingWaveforms ? "Cancel" : "Refresh audio") {
                        model.isLoadingWaveforms ? model.cancelWaveforms() : model.loadWaveforms()
                    }
                    .accessibilityIdentifier("alignment.waveforms.load")
                    .disabled(model.isLoadingOverview)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    numberField("Window start (s)", value: $model.waveformStartSeconds, identifier: "start")
                        .frame(maxWidth: 160)
                        .onSubmit { model.loadWaveforms() }
                    Button("Previous") { moveWindow(-1) }
                    Button("Next") { moveWindow(1) }
                    HStack(spacing: 3) {
                        ForEach([0.5, 1.0, 2.0, 5.0, 10.0, 30.0], id: \.self) { spanButton($0) }
                    }
                    Spacer(minLength: 0)
                }
                .disabled(model.isLoadingWaveforms)
                transport
                timelineScrubber
                if model.waveformMap == nil, !model.waveformTracks.isEmpty {
                    Button("Place groups at source time") { model.placeGroupsAtSourceTime() }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("alignment.waveforms.placeInitial")
                    Text("This places the first eligible epoch of each recorder at zero offset, without estimating clock drift. Time restarted epochs separately; then move recorder groups while listening. The reference stays fixed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("View").font(.caption)
                    ForEach(Layout.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { layout = mode }
                            .accessibilityIdentifier("alignment.waveforms.layout.\(mode == .overlay ? "overlay" : "separate")")
                            .accessibilityAddTraits(layout == mode ? .isSelected : [])
                    }
                    Toggle("Normalize view", isOn: $normalizeView)
                        .toggleStyle(.checkbox)
                        .help("Scales each recording's displayed peaks in this window; playback and originals are unchanged.")
                        .accessibilityIdentifier("alignment.waveforms.normalizeView")
                    Spacer()
                    Text("Shared seconds · dashed waveforms are unplaced source time")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if normalizeView {
                    Text("Visual gain is per recording and per window. Audio and saved timing are unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.waveforms.normalizeNote")
                }
                ruler
                if model.waveformTracks.isEmpty, model.waveformNavigationEndSeconds > 0 {
                    ContentUnavailableView(
                        "No audio in this window",
                        systemImage: "waveform",
                        description: Text("Scrub to another section of the shared timeline. Unavailable recordings are listed below.")
                    )
                    .frame(minHeight: 200)
                } else if visibleTracks.isEmpty {
                    ContentUnavailableView(
                        "No waveforms showing",
                        systemImage: "waveform",
                        description: Text("Enable a recorder and track below, or refresh audio to load a measured window.")
                    )
                    .frame(minHeight: 200)
                } else if layout == .overlay {
                    overlay
                } else {
                    ForEach(visibleTracks) { track in lane(track) }
                }
                recordings
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
                GroupBox("Episode overview") { overview }
            }
            .padding(4)
        }
        .accessibilityIdentifier("alignment.waveforms")
    }

    private var recordings: some View {
        GroupBox("Recordings · show and hear") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.self) { group in
                    let tracks = model.waveformTracks.filter { $0.group == group }
                    Toggle(tracks.first?.groupName ?? "Recorder group", isOn: Binding(
                        get: { model.groupEnabled(group) },
                        set: { model.setGroup(group, enabled: $0) }
                    ))
                    .accessibilityLabel("Show and hear recorder group \(tracks.first?.groupName ?? "")")
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
                                .accessibilityLabel("Show and hear \(identity.label), \(track.name)")
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

    private var transport: some View {
        HStack {
            Button(model.canStopAudition ? "Pause" : "Play") {
                model.canStopAudition ? model.pauseEnabledTracks() : model.playEnabledTracks()
            }
            .accessibilityIdentifier("alignment.waveforms.transport.play")
            Button("Stop") { model.stopEnabledTracks() }
                .accessibilityIdentifier("alignment.waveforms.transport.stop")
            TextField("Playhead (aligned seconds)", value: $model.waveformPlayheadSeconds, format: .number)
                .frame(width: 110)
                .onSubmit { model.seekEnabledTracks(to: model.waveformPlayheadSeconds) }
                .accessibilityIdentifier("alignment.waveforms.playhead")
            Text(model.auditionLabel).font(.caption).lineLimit(2)
                .accessibilityIdentifier("alignment.waveforms.transport.status")
        }
    }

    private var timelineScrubber: some View {
        let end = min(86_400, max(0, model.waveformNavigationEndSeconds))
        let position = scrubPreviewSeconds ?? model.waveformPlayheadSeconds
        return HStack {
            Text("Timeline").font(.caption)
            Slider(
                value: Binding(
                    get: { min(max(position, 0), max(end, 1)) },
                    set: { scrubPreviewSeconds = $0 }
                ),
                in: 0...max(end, 1),
                onEditingChanged: { editing in if !editing { commitScrub() } }
            ) {
                Text("Scrub shared timeline")
            }
            .accessibilityIdentifier("alignment.waveforms.scrubber")
            .disabled(end <= 0 || model.isWorking || model.isLoadingOverview
                      || model.isLoadingWaveforms || model.groupDraftMilliseconds != 0)
            Text("\(position, specifier: "%.1f") / \(end, specifier: "%.1f") s")
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("alignment.waveforms.scrubPosition")
            Button("Go") { commitScrub() }
                .disabled(end <= 0 || model.isWorking || model.isLoadingOverview || model.isLoadingWaveforms
                          || model.groupDraftMilliseconds != 0)
                .accessibilityIdentifier("alignment.waveforms.scrubGo")
        }
        .help("Release the scrubber, or enter an exact playhead time and press Go, to load this shared aligned window. No timing map is edited.")
    }

    private func commitScrub() {
        let time = scrubPreviewSeconds ?? model.waveformPlayheadSeconds
        scrubPreviewSeconds = nil
        model.navigateWaveformTimeline(to: time)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(model.isLoadingOverview ? "Cancel Overview" : "Build Episode Overview") {
                model.isLoadingOverview ? model.cancelWaveformOverview() : model.loadWaveformOverview()
            }
            .disabled(model.isLoadingWaveforms || model.isWorking)
            .accessibilityIdentifier("alignment.waveforms.overview.load")
            if model.isLoadingOverview {
                ProgressView(value: model.waveformOverviewProgress)
                    .accessibilityLabel("Episode overview progress")
            }
            Text(model.waveformOverviewMessage).font(.caption)
                .accessibilityIdentifier("alignment.waveforms.overview.status")
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
                    Text("Shaded audio outside 0 to 86,400 aligned seconds is unavailable for exact-window navigation. The 24-hour scan limit is in source time; stored timing is unchanged.")
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
                            gain: normalizeView ? model.waveformOverviewDisplayGains[track.id] ?? 1 : 1
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
                                    if (range.upperBound - range.lowerBound) * scale >= 80 {
                                        Text("Unavailable").font(.caption2)
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
                        Text("\(track.groupName), \(track.name), complete measured PCM overview; \(strokes.filter { !$0.mapped }.count) unplaced bins. Use Open Window at Playhead to navigate within covered audio from 0 to 86,400 seconds. Audio outside that range is unavailable; coarse bins do not set anchors.")
                            .accessibilityIdentifier("alignment.waveforms.overview.track.\(track.id)")
                    } else {
                        Text("\(track.groupName), \(track.name), complete measured PCM overview. All covered audio is unavailable for exact-window navigation: stored timing places it outside 0 to 86,400 aligned seconds.")
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
                    .help("Type an aligned playhead within this recording's covered audio, from 0 to 86,400 seconds.")
                }
            }
        } else if let error = model.waveformOverviewProjectionErrors[track.id] {
            Text("\(track.name): \(error)")
        }
    }

    private func openOverviewWindow(at time: Double, strokes: [AlignmentWaveformStroke]) {
        guard AlignmentWaveformProjection.overviewWindowStart(
            at: time, duration: model.waveformDurationSeconds, strokes: strokes
        ) != nil else { return }
        model.navigateWaveformOverview(to: time)
    }

    private var ruler: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<6) { index in
                    let time = model.waveformStartSeconds + model.waveformDurationSeconds * Double(index) / 5
                    Text("\(time, specifier: "%.3f")")
                        .font(.caption.monospacedDigit())
                        .position(x: max(25, min(geometry.size.width - 25, geometry.size.width * Double(index) / 5)), y: 10)
                }
            }
        }
        .frame(height: 24)
        .accessibilityRepresentation {
            Text(String(format: "Visible aligned time ruler: %.3f to %.3f seconds",
                        model.waveformStartSeconds, model.waveformStartSeconds + model.waveformDurationSeconds))
                .accessibilityIdentifier("alignment.waveforms.ruler")
        }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(visibleTracks) { track in
                        let identity = model.trackIdentity(track.id)
                        HStack(spacing: 5) {
                            Circle().fill(identity.color).frame(width: 9, height: 9)
                            Text("\(track.groupName) · \(identity.label)")
                                .font(.caption)
                                .fontWeight(model.selectedWaveformSource == track.id ? .semibold : .regular)
                        }
                    }
                }
            }
            GeometryReader { geometry in
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.04))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    ForEach(visibleTracks) { track in
                        if let strokes = model.waveformStrokes[track.id] {
                            waveformDrawing(track: track, strokes: strokes, size: geometry.size, overlay: true)
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
                    if let track = model.selectedWaveform,
                       let strokes = model.waveformStrokes[track.id],
                       pick(track, strokes: strokes, time: time) { return }
                    model.seekEnabledTracks(to: time)
                }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag in
                        guard let track = model.selectedWaveform,
                              let strokes = model.waveformStrokes[track.id]
                        else { return }
                        dragGroup(track, strokes: strokes, drag: drag, geometry: geometry)
                    }
                    .onEnded { drag in finishGroupDrag(drag) })
            }
            .frame(height: 270)
            .clipped()
            .overlay(alignment: .topLeading) { dragPreview }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .accessibilityRepresentation {
                Text("Overlaid measured waveforms for \(visibleTracks.count) enabled \(visibleTracks.count == 1 ? "track" : "tracks"). Select a track below to move its recorder group; use the numeric group move for keyboard editing.")
                    .accessibilityIdentifier("alignment.waveforms.overlay")
            }
            ForEach(visibleTracks) { track in
                if let error = model.waveformProjectionErrors[track.id] {
                    Label("\(track.name): \(error)", systemImage: "exclamationmark.triangle")
                }
            }
            Text("Select a track below to make its recorder active. Drag its waveform to move the entire recorder group; the reference stays fixed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lane(_ track: AlignmentWaveformTrack) -> some View {
        let identity = model.trackIdentity(track.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button("\(track.groupName) · \(track.name)") { model.selectWaveform(track) }
                    .buttonStyle(.plain)
                    .font(.callout.weight(model.selection == track.epoch ? .semibold : .regular))
                Spacer()
                Text("\(identity.label) · \(track.envelope.channelCount) measured channels")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.rows.first(where: { $0.epochID == track.epoch })?.state.heading ?? "Unmapped")
                .font(.caption)
                .accessibilityIdentifier("alignment.waveforms.state.\(track.id)")
            if let strokes = model.waveformStrokes[track.id] {
                GeometryReader { geometry in
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.04))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                        }.stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        waveformDrawing(track: track, strokes: strokes, size: geometry.size, overlay: false)
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1)
                            .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width), y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        pick(track, strokes: strokes, time: model.waveformStartSeconds
                             + Double(point.x / geometry.size.width) * model.waveformDurationSeconds)
                    }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { drag in
                            dragGroup(track, strokes: strokes, drag: drag, geometry: geometry)
                        }
                        .onEnded { drag in finishGroupDrag(drag) })
                }
                .frame(height: 110)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if dragSession?.group == track.group { dragPreview }
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.selectedWaveformSource == track.id ? Color.accentColor : Color.secondary.opacity(0.3)))
                .accessibilityRepresentation {
                    Button("\(track.groupName), \(track.name), audio waveform. \(strokes.count) measured amplitude bins; \(strokes.filter { !$0.mapped }.count) unplaced. Stored offset \(model.rows.first(where: { $0.epochID == track.epoch })?.offsetMilliseconds ?? 0) milliseconds. Select this track, then use numeric timing as a keyboard alternative.") {
                        model.selectWaveform(track)
                    }
                    .accessibilityIdentifier("alignment.waveforms.track.\(track.id)")
                }
            } else if let error = model.waveformProjectionErrors[track.id] {
                Text("Cannot place this waveform: \(error)")
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
        model.commitGroupMove()
    }

    private func cancelGroupDrag() {
        if let session = dragSession {
            model.groupDraftMilliseconds = session.snapshot == model.waveformSnapshotID
                && model.selectedRow?.groupID == session.group ? session.initialMilliseconds : 0
        }
        dragSession = nil
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let dragSession {
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
        .disabled(model.isWorking || model.isLoadingOverview)
    }

    private func numberField(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
            TextField(title, value: value, format: .number)
                .accessibilityIdentifier("alignment.waveforms.\(identifier)")
        }

        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spanButton(_ duration: Double) -> some View {
        Button("\(duration, specifier: "%g") s") {
            model.waveformDurationSeconds = duration
            if !model.waveformTracks.isEmpty { model.loadWaveforms() }
        }
        .accessibilityLabel("Visible span \(duration, specifier: "%g") seconds")
        .accessibilityAddTraits(model.waveformDurationSeconds == duration ? .isSelected : [])
        .accessibilityIdentifier("alignment.waveforms.span.\(duration)")
    }

    private func waveformDrawing(
        track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke], size: CGSize, overlay: Bool
    ) -> some View {
        let activeGroup = model.selectedRow?.groupID == track.group
        return WaveformTrackDrawing(
            snapshot: model.waveformSnapshotID, strokes: strokes, size: size,
            start: model.waveformStartSeconds, duration: model.waveformDurationSeconds,
            color: model.trackIdentity(track.id).color.opacity(overlay ? 0.8 : 1),
            lineWidth: overlay ? (model.selectedWaveformSource == track.id ? 2 : 1.3) : 1.5,
            gain: normalizeView ? model.waveformDisplayGains[track.id] ?? 1 : 1,
            draftEpoch: !activeGroup && model.waveformTimingIsDraft ? model.selection : nil,
            draftRatePPM: model.waveformRatePPM, draftOffsetMilliseconds: model.waveformOffsetMilliseconds
        )
        .equatable()
        .offset(x: activeGroup ? model.groupDraftMilliseconds / 1_000
                / model.waveformDurationSeconds * size.width : 0)
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

    private func moveWindow(_ direction: Double) {
        model.waveformStartSeconds = max(0, model.waveformStartSeconds + direction * model.waveformDurationSeconds)
        model.loadWaveforms()
    }
}
