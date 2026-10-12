import SwiftUI
import WWAlignPipeline
import WWCore

struct AlignmentWaveformView: View {
    @Bindable var model: EpisodeAlignmentModel
    @State private var dragOrigin: Double?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Audio tracks").font(.headline)
                    Spacer()
                    Button(model.isLoadingWaveforms ? "Cancel" : "Load Audio Window") {
                        model.isLoadingWaveforms ? model.cancelWaveforms() : model.loadWaveforms()
                    }
                    .accessibilityIdentifier("alignment.waveforms.load")
                    .disabled(model.isLoadingOverview)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    numberField("Window start (s)", value: $model.waveformStartSeconds, identifier: "start")
                        .onSubmit { model.loadWaveforms() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Visible span").font(.caption)
                        HStack(spacing: 3) {
                            spanButton(0.5)
                            spanButton(1)
                            spanButton(2)
                        }
                        HStack(spacing: 3) {
                            spanButton(5)
                            spanButton(10)
                            spanButton(30)
                        }
                    }
                }
                .disabled(model.isLoadingWaveforms)
                HStack {
                    Button("Previous") { moveWindow(-1) }
                    Button("Next") { moveWindow(1) }
                }
                .disabled(model.isLoadingWaveforms)
                overview
                Text("Aligned seconds · orange strokes are unplaced source-origin previews, not aligned audio.")
                    .font(.caption).foregroundStyle(.secondary)
                ruler
                ForEach(model.waveformTracks) { track in
                    lane(track)
                }
                ForEach(model.waveformRefusals) { refusal in
                    Label("\(refusal.name): \(refusal.reason)", systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("alignment.waveforms.refusal.\(refusal.id)")
                }
                if model.waveformTracks.isEmpty {
                    Label("See your recordings", systemImage: "waveform").font(.headline)
                    Text("Load Audio Window reads a bounded portion of grouped recordings. Select a track, then drag its waveform to preview an offset or match two anchor points.")
                        .foregroundStyle(.secondary)
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
            }
            .padding(4)
        }
        .accessibilityIdentifier("alignment.waveforms")
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
            let projected = Result {
                try model.waveformOverviewTracks.flatMap {
                    try AlignmentWaveformProjection.strokes(track: $0, map: model.waveformOverviewMap)
                }
            }
            switch projected {
            case let .success(allStrokes):
                if let extent = AlignmentWaveformProjection.overviewExtent(allStrokes) {
                    Text("Episode overview: \(extent.lowerBound, specifier: "%.1f") to \(extent.upperBound, specifier: "%.1f") seconds. Blue uses stored timing; dashed orange is unplaced source time.")
                        .font(.caption)
                    if !AlignmentWaveformProjection.unavailableOverviewRanges(in: extent).isEmpty {
                        Text("Shaded audio outside 0 to 86,400 aligned seconds is unavailable for exact-window navigation. The 24-hour scan limit is in source time; stored timing is unchanged.")
                            .font(.caption)
                            .accessibilityIdentifier("alignment.waveforms.overview.navigationLimit")
                    }
                    ForEach(model.waveformOverviewTracks) { track in
                        overviewLane(track, extent: extent)
                    }
                }
            case let .failure(error):
                Text("Cannot place episode overview: \(error.localizedDescription)")
            }
            ForEach(model.waveformOverviewRefusals) { refusal in
                Label("\(refusal.name): \(refusal.reason)", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("alignment.waveforms.overview.refusal.\(refusal.id)")
            }
        }
    }

    @ViewBuilder
    private func overviewLane(_ track: AlignmentWaveformTrack, extent: ClosedRange<Double>) -> some View {
        let result = Result { try AlignmentWaveformProjection.strokes(track: track, map: model.waveformOverviewMap) }
        switch result {
        case let .success(strokes):
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
                        overviewPath(strokes.filter(\.mapped), extent: extent, scale: scale)
                            .stroke(Color.accentColor, lineWidth: 1)
                        overviewPath(strokes.filter { !$0.mapped }, extent: extent, scale: scale)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
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
        case let .failure(error):
            Text("\(track.name): \(error.localizedDescription)")
        }
    }

    private func overviewPath(
        _ strokes: [AlignmentWaveformStroke], extent: ClosedRange<Double>, scale: Double
    ) -> Path {
        Path { path in
            for stroke in strokes {
                let x = (stroke.displaySeconds - extent.lowerBound) * scale
                path.move(to: CGPoint(x: x, y: 24 - Double(min(1, max(-1, stroke.high))) * 20))
                path.addLine(to: CGPoint(x: x, y: 24 - Double(min(1, max(-1, stroke.low))) * 20))
            }
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

    @ViewBuilder
    private func lane(_ track: AlignmentWaveformTrack) -> some View {
        let result = Result { try AlignmentWaveformProjection.strokes(track: track, map: model.waveformMap) }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button("\(track.groupName) · \(track.name)") { model.selectWaveform(track) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("alignment.waveforms.select.\(track.id)")
                    .font(.callout.weight(model.selection == track.epoch ? .semibold : .regular))
                Spacer()
                Text("\(track.envelope.channelCount) channel envelope")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.rows.first(where: { $0.epochID == track.epoch })?.state.heading ?? "Unmapped")
                .font(.caption)
                .accessibilityIdentifier("alignment.waveforms.state.\(track.id)")
            switch result {
            case let .success(strokes):
                GeometryReader { geometry in
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.04))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                        }.stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        waveformPath(strokes.filter(\.mapped), track: track, size: geometry.size)
                            .stroke(Color.accentColor, lineWidth: 1)
                        waveformPath(strokes.filter { !$0.mapped }, track: track, size: geometry.size)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1)
                            .position(x: x(model.waveformPlayheadSeconds, width: geometry.size.width), y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        pick(track, strokes: strokes, time: model.waveformStartSeconds
                             + Double(point.x / geometry.size.width) * model.waveformDurationSeconds)
                    }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            guard !model.isWorking, model.waveformMap?.reference.group != track.group else { return }
                            if dragOrigin == nil {
                                guard pick(
                                    track, strokes: strokes, time: model.waveformStartSeconds
                                        + Double(drag.startLocation.x / geometry.size.width) * model.waveformDurationSeconds
                                ) else { return }
                                dragOrigin = model.waveformOffsetMilliseconds
                            }
                            if let origin = dragOrigin {
                                model.waveformOffsetMilliseconds = origin
                                    + Double(drag.translation.width / geometry.size.width) * model.waveformDurationSeconds * 1_000
                            }
                        }
                        .onEnded { _ in dragOrigin = nil })
                }
                .frame(height: 80)
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.selection == track.epoch ? Color.accentColor : Color.secondary.opacity(0.3)))
                .accessibilityRepresentation {
                    Button("\(track.groupName), \(track.name), audio waveform. \(strokes.count) measured amplitude bins; \(strokes.filter { !$0.mapped }.count) unplaced. Stored offset \(model.rows.first(where: { $0.epochID == track.epoch })?.offsetMilliseconds ?? 0) milliseconds. Select this track, then use numeric timing as a keyboard alternative.") {
                        model.selectWaveform(track)
                    }
                    .accessibilityIdentifier("alignment.waveforms.track.\(track.id)")
                }
            case let .failure(error):
                Text("Cannot place this waveform: \(error.localizedDescription)")
            }
        }
    }

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text("Selected track: \(model.selectedRow?.groupName ?? "none")")
                Text(model.waveformTimingIsDraft
                     ? "Unsaved timing preview; Apply records an undoable manual map."
                     : "Showing stored timing. Drag or type an offset to preview a correction.")
                    .font(.caption)
            }
            HStack(alignment: .bottom, spacing: 12) {
                numberField("Aligned playhead (s)", value: $model.waveformPlayheadSeconds, identifier: "playhead")
                if let track = model.selectedWaveform {
                    Stepper(value: $model.waveformAuditionChannel,
                            in: 0...(track.envelope.channelCount - 1)) {
                        Text("Channel \(model.waveformAuditionChannel + 1)")
                    }
                    .accessibilityIdentifier("alignment.waveforms.channel")
                }
            }
            Button(model.canStopAudition ? "Stop Comparison" : "Compare Aligned Audio") {
                model.canStopAudition ? model.stopAudition() : model.compareAlignedAtPlayhead()
            }
            .disabled(!model.canCompareAligned && !model.canStopAudition)
            .accessibilityIdentifier("alignment.waveforms.compare")
            Text("Comparison plays up to five aligned seconds from the playhead: reference channel 1 left, selected channel right. Uncovered map regions are silent.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.auditionLabel).font(.caption)
                .accessibilityIdentifier("alignment.waveforms.auditionStatus")
            HStack(alignment: .bottom, spacing: 12) {
                numberField("Offset (ms)", value: $model.waveformOffsetMilliseconds, identifier: "offset")
                numberField("Rate (ppm)", value: $model.waveformRatePPM, identifier: "rate")
            }
            HStack {
                Button("Apply Timing") {
                    model.applyNumeric(ratePPM: model.waveformRatePPM, offsetMilliseconds: model.waveformOffsetMilliseconds)
                }
                .disabled(!model.canCorrect || !model.hasAnalysis)
                .accessibilityIdentifier("alignment.waveforms.apply")
                Button("Reset Preview") { model.resetWaveformTiming() }
            }
            HStack(alignment: .bottom, spacing: 12) {
                numberField("Reference point (s)", value: $model.waveformReferencePoint, identifier: "referencePoint")
                numberField("Target source point (s)", value: $model.waveformTargetPoint, identifier: "targetPoint")
            }
            HStack {
                Button("Match Anchor") { model.addWaveformAnchor() }
                Button("Apply \(model.waveformDraftAnchors.count) Anchors") { model.applyWaveformAnchors() }
                    .disabled(model.waveformDraftAnchors.count < 2 || !model.canCorrect || !model.hasAnalysis)
            }
            Text("Click the reference and the corresponding target event; match at least two distinct target times. Analyse sources first if no timing map has been prepared.")
                .font(.caption).foregroundStyle(.secondary)
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

    private func waveformPath(_ strokes: [AlignmentWaveformStroke], track: AlignmentWaveformTrack, size: CGSize) -> Path {
        Path { path in
            for stroke in strokes {
                let position = x(displayTime(stroke, track: track), width: size.width)
                guard position >= 0, position <= size.width else { continue }
                path.move(to: CGPoint(x: position, y: size.height * (0.5 - Double(min(1, max(-1, stroke.high))) * 0.45)))
                path.addLine(to: CGPoint(x: position, y: size.height * (0.5 - Double(min(1, max(-1, stroke.low))) * 0.45)))
            }
        }
    }

    private func displayTime(_ stroke: AlignmentWaveformStroke, track: AlignmentWaveformTrack) -> Double {
        guard model.selection == stroke.epoch, model.waveformTimingIsDraft else { return stroke.displaySeconds }
        return stroke.groupSeconds * (1 + model.waveformRatePPM / 1_000_000)
            + model.waveformOffsetMilliseconds / 1_000
    }

    private func x(_ time: Double, width: Double) -> Double {
        guard time.isFinite, model.waveformStartSeconds.isFinite,
              model.waveformDurationSeconds > 0 else { return -1 }
        return (time - model.waveformStartSeconds) / model.waveformDurationSeconds * width
    }

    @discardableResult
    private func pick(_ track: AlignmentWaveformTrack, strokes: [AlignmentWaveformStroke], time: Double) -> Bool {
        guard let selected = AlignmentWaveformProjection.selectedStroke(
            at: time, strokes: strokes,
            draftEpoch: model.waveformTimingIsDraft ? model.selection : nil,
            ratePPM: model.waveformRatePPM, offsetMilliseconds: model.waveformOffsetMilliseconds
        ) else { return false }
        model.waveformPlayheadSeconds = time
        if model.waveformMap?.reference.group == track.group {
            model.waveformReferencePoint = time
        } else {
            model.selectWaveform(track, epoch: selected.epoch)
            model.waveformTargetPoint = selected.sourceSeconds
        }
        return true
    }

    private func moveWindow(_ direction: Double) {
        model.waveformStartSeconds = max(0, model.waveformStartSeconds + direction * model.waveformDurationSeconds)
        model.loadWaveforms()
    }
}
