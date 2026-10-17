import SwiftUI
import WWCore

struct AlignmentTrackAssignmentControls: View {
    @Bindable var model: EpisodeAlignmentModel
    let track: AlignmentWaveformTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Speaker", selection: Binding(
                get: { model.trackSpeakerID(track.id) },
                set: { model.assignSpeaker($0, to: track) }
            )) {
                Text("Unassigned").tag(Optional<SpeakerID>.none)
                ForEach(model.availableSpeakers, id: \.id) { speaker in
                    Text(speaker.name).tag(Optional(speaker.id))
                }
            }
            .pickerStyle(.menu)
            .help("Shared with Setup. One speaker channel per source; assignment changes are undoable.")
            .accessibilityLabel("Speaker assigned to \(track.name)")
            .accessibilityIdentifier("alignment.waveforms.speaker.\(track.id)")
            if track.envelope.channelCount == 1 {
                if model.statedChannel(for: track.id) == 0 {
                    Text("Mono · channel 1")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alignment.waveforms.mono.\(track.id)")
                } else {
                    Button("Use mono channel 1") { model.setChannel(0, for: track) }
                        .help("States the only measured channel in Setup; undoable.")
                        .accessibilityIdentifier("alignment.waveforms.mono.\(track.id)")
                }
            } else {
                Picker("Channel", selection: Binding(
                    get: { model.statedChannel(for: track.id) },
                    set: { model.setChannel($0, for: track) }
                )) {
                    Text("Unknown").tag(Optional<Int>.none)
                    ForEach(0..<track.envelope.channelCount, id: \.self) { channel in
                        Text("Channel \(channel + 1)").tag(Optional(channel))
                    }
                }
                .pickerStyle(.menu)
                .help("State the speaker's channel. Unknown is not channel 1.")
                .accessibilityLabel("Speaker channel in \(track.name)")
                .accessibilityIdentifier("alignment.waveforms.channel.\(track.id)")
            }
            Toggle("Prefer this recorder as timing reference", isOn: Binding(
                get: { model.prefersTimingReference(track.group) },
                set: { model.preferTimingReference($0, group: track.group) }
            ))
            .toggleStyle(.checkbox)
            .help("Your preference, not clock certification. Already accepted timeline references stay fixed. Multiple preferred recorders may be used once aligned.")
            .accessibilityIdentifier("alignment.waveforms.preferredReference.\(track.id)")
        }
        .disabled(model.isWorking || model.pendingWaveformMove != nil)
    }
}

struct AlignmentAnchorControls: View {
    @Bindable var model: EpisodeAlignmentModel
    let track: AlignmentWaveformTrack

    var body: some View {
        if let point = model.waveformPickedPoint, point.source == track.id {
            Text("Source point: \(AlignmentPresentation.formatTime(point.sourceSeconds))")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("alignment.waveforms.anchor.point.\(track.id)")
            if point.mapped && model.sourceHasAcceptedTiming(track.id) {
                Button("Mark reference point") { model.markWaveformReference(track) }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("alignment.waveforms.anchor.mark.\(track.id)")
            }
            let markers = model.referenceMarkers(for: track)
            if !markers.isEmpty && model.canCorrect {
                Menu("Link to reference marker…") {
                    ForEach(markers) { marker in
                        Button("\(marker.trackName) · \(AlignmentPresentation.formatTime(marker.alignedSeconds))") {
                            model.linkWaveformAnchor(marker, to: track)
                        }
                    }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("alignment.waveforms.anchor.link.\(track.id)")
            }
        }
        if model.selectedWaveformSource == track.id, !model.waveformDraftAnchors.isEmpty {
            Text("\(model.waveformDraftAnchors.count) linked \(model.waveformDraftAnchors.count == 1 ? "point" : "points")")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply anchors") { model.applyWaveformAnchors() }
                .disabled(model.waveformDraftAnchors.count < 2 || !model.canCorrect)
                .accessibilityIdentifier("alignment.waveforms.anchor.apply.\(track.id)")
            if model.waveformDraftAnchors.count < 2 {
                Text("Link a second point on this epoch to calculate offset and drift.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AlignmentTimingControls: View {
    @Bindable var model: EpisodeAlignmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.canMoveGroup {
                HStack {
                    Button("Nudge earlier 10 ms", systemImage: "arrow.left") {
                        model.groupDraftMilliseconds = -10
                        model.commitGroupMove()
                    }
                    Button("Nudge later 10 ms", systemImage: "arrow.right") {
                        model.groupDraftMilliseconds = 10
                        model.commitGroupMove()
                    }
                }
                .labelStyle(.iconOnly)
                .help("Move the whole recorder group by 10 milliseconds; undoable.")
                numberField("Group move (ms)", value: $model.groupDraftMilliseconds, identifier: "groupMove")
                Button("Apply group move") { model.commitGroupMove() }
                    .disabled(model.groupDraftMilliseconds == 0)
                Button("Reset group preview") { model.groupDraftMilliseconds = 0 }
                    .help("The unsaved preview is not audible until applied.")
            }
            DisclosureGroup("Advanced timing") {
                VStack(alignment: .leading, spacing: 8) {
                    numberField("Offset (ms)", value: $model.waveformOffsetMilliseconds, identifier: "offset")
                    numberField("Rate (ppm)", value: $model.waveformRatePPM, identifier: "rate")
                    Button("Apply epoch timing") {
                        model.applyNumeric(
                            ratePPM: model.waveformRatePPM,
                            offsetMilliseconds: model.waveformOffsetMilliseconds
                        )
                    }
                    .disabled(!model.canCorrect)
                    .accessibilityIdentifier("alignment.waveforms.apply")
                    Button("Reset timing preview") { model.resetWaveformTiming() }
                    numberField("Reference point (s)", value: $model.waveformReferencePoint, identifier: "referencePoint")
                    numberField("Target source point (s)", value: $model.waveformTargetPoint, identifier: "targetPoint")
                    Button("Match Anchor") { model.addWaveformAnchor() }
                    Button("Apply \(model.waveformDraftAnchors.count) Anchors") { model.applyWaveformAnchors() }
                        .disabled(model.waveformDraftAnchors.count < 2 || !model.canCorrect)
                }
            }
            .padding(.leading, 24)
        }
        .disabled(model.isWorking)
    }

    private func numberField(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
            TextField(title, value: value, format: .number)
                .accessibilityIdentifier("alignment.waveforms.\(identifier)")
        }
    }
}

struct AlignmentPlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}
