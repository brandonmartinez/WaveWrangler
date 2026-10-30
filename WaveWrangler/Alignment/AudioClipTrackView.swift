import SwiftUI
import WWCommonEdit
import WWCore

struct AudioClipTrackView: View {
    @Bindable var editor: AudioClipEditorModel
    let track: AudioTrack
    let start: Double
    let duration: Double
    let playhead: Double
    let height: Double
    let headerWidth: Double
    let normalized: Bool
    let projection: AudioTimelineProjection
    var workspaceState: ShowWindowState? = nil
    let showInspector: () -> Void
    @GestureState private var dragging = false

    private var clips: [ProgramAudioClip] {
        editor.composition?.clips.filter { clip in
            let destination = editor.gesture?.clip.clip.id == clip.clip.id ? editor.gesture?.track : clip.clip.track
            return clip.clip.track == track.id || destination == track.id
        } ?? []
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    editor.selectedClip = nil
                    editor.selectedTrack = track.id
                    showInspector()
                } label: { Label(track.name, systemImage: "waveform") }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("ww.audioTrack.select.\(track.id)")
                Text("Audio Track").font(.caption).foregroundStyle(.secondary)
                Menu("Clips") {
                    ForEach(editor.composition?.clips.filter { $0.clip.track == track.id } ?? [], id: \.clip.id) { clip in
                        Button("\(name(clip)) · \(Double(clip.programFrames.lowerBound) / 48_000, specifier: "%.3f") s") {
                            editor.select(clip.clip.id)
                            showInspector()
                        }
                    }
                }
                .accessibilityIdentifier("ww.audioTrack.clips.\(track.id)")
                HStack(spacing: 4) {
                    Button("Move track up", systemImage: "arrow.up") { editor.reorderTrack(track.id, by: -1) }
                        .disabled(!editor.store.canEdit || editor.tracks.first?.id == track.id)
                        .accessibilityIdentifier("ww.audioTrack.up.\(track.id)")
                    Button("Move track down", systemImage: "arrow.down") { editor.reorderTrack(track.id, by: 1) }
                        .disabled(!editor.store.canEdit || editor.tracks.last?.id == track.id)
                        .accessibilityIdentifier("ww.audioTrack.down.\(track.id)")
                }.labelStyle(.iconOnly).controlSize(.mini)
            }
            .frame(width: headerWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
                    ForEach(clips, id: \.clip.id) { clip in block(clip, size: geometry.size) }
                    if duration > 0, playhead >= start, playhead <= start + duration {
                        Rectangle().fill(.red.opacity(0.8)).frame(width: 1)
                            .offset(x: (playhead - start) / duration * geometry.size.width)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    editor.trackFrames[track.id] = $0
                }
            }
            .modifier(AudioTimelineFileDropTarget(importer: editor.importer, state: workspaceState,
                start: start, duration: duration, projection: projection, track: .existing(track.id)))
            .frame(height: height)
        }
        .frame(minHeight: height)
        .padding(8)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .onKeyPress(.escape) { editor.cancelGesture(); return .handled }
        .onChange(of: dragging) { _, active in
            if !active {
                Task { @MainActor in
                    await Task.yield()
                    if !dragging { editor.cancelGesture() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio Track: \(track.name)")
        .onDisappear { editor.trackFrames[track.id] = nil }
    }

    @ViewBuilder private func block(_ projected: ProgramAudioClip, size: CGSize) -> some View {
        let preview = editor.gesture?.clip.clip.id == projected.clip.id ? editor.gesture : nil
        let programFirst = Double(preview?.startFrame ?? projected.programFrames.lowerBound) / 48_000
        let first = projection.displayTime(forProgramTime: programFirst)
        let count = Double(preview?.localFrames?.count ?? projected.programFrames.count) / 48_000
        let displayEnd = projection.displayTime(forProgramTime: programFirst + count)
        let left = max(0, (first - start) / duration * size.width)
        let right = min(size.width, (displayEnd - start) / duration * size.width)
        if right >= left, displayEnd > start, first < start + duration {
            let selected = editor.selectedClip == projected.clip.id
            let renderedClip = preview?.previewClip ?? projected.clip
            let blockWidth = max(6, right - left), blockHeight = max(40, size.height - 4)
            Button {
                editor.select(projected.clip.id)
                showInspector()
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.teal.opacity(selected ? 0.28 : 0.13))
                    .overlay {
                        AudioClipWaveformDrawing(clip: projected,
                            renderedClip: renderedClip,
                            waveform: editor.waveforms[projected.clip.source], start: start,
                            duration: duration, programStart: programFirst, viewportWidth: size.width,
                            left: left, normalized: normalized, projection: projection)
                            .equatable()
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        if let frames = renderedClip.durationFrames(asset: projected.asset) {
                            AudioEnvelopeDrawing(cache: editor.envelopeGeometryCache, clip: projected.clip.id,
                                key: .init(envelope: renderedClip.envelope, durationFrames: frames,
                                    programStart: programFirst, viewportStart: start, viewportDuration: duration,
                                    viewportWidth: size.width, left: left, width: blockWidth, height: blockHeight,
                                    projection: projection))
                                .equatable()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            if case .absolute = projected.clip.anchor { Image(systemName: "pin.fill") }
                            Text(name(projected)).lineLimit(1)
                        }.font(.caption2).padding(5).allowsHitTesting(false)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(preview?.previewError != nil ? Color.red : selected ? Color.accentColor : Color.teal.opacity(0.6),
                                    lineWidth: selected ? 2 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if preview?.previewError != nil {
                            Text("Invalid edge or placement").font(.caption2).foregroundStyle(.red).padding(5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(width: blockWidth, height: blockHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(moveGesture(projected, width: size.width))
            .overlay(alignment: .leading) {
                if selected, editor.store.canEdit, first >= start { edge(projected, leading: true, width: size.width) }
            }
            .overlay(alignment: .trailing) {
                if selected, editor.store.canEdit, displayEnd <= start + duration { edge(projected, leading: false, width: size.width) }
            }
            .offset(x: left, y: 2)
            .zIndex(selected ? 1 : 0)
            .opacity(preview != nil && projected.clip.track == track.id && preview?.track != track.id ? 0.35 : 1)
            .allowsHitTesting(projected.clip.track == track.id)
            .accessibilityLabel("Audio Clip: \(name(projected))")
            .accessibilityValue("Program start \(programFirst.formatted(.number.precision(.fractionLength(3)))) seconds; duration \(count.formatted(.number.precision(.fractionLength(3)))) seconds; \(renderedClip.envelope.points.count) fade points")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("ww.audioClip.\(projected.clip.id)")
        }
    }

    private func moveGesture(_ clip: ProgramAudioClip, width: Double) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if editor.gesture?.localFrames != nil { return }
                if editor.gesture == nil { editor.beginGesture(clip) }
                guard let gesture = editor.gesture, width > 0 else { return }
                let display = projection.displayTime(forProgramTime: Double(gesture.clip.programFrames.lowerBound) / 48_000)
                    + value.translation.width / width * duration
                guard let program = projection.programTime(forDisplayTime: display),
                      let position = try? AudioClipEditorModel.programFrame(program) else {
                    editor.refuseGesture("Audio Clips cannot be placed inside Show cut's review-only removed interval.")
                    return
                }
                guard let target = editor.trackFrames.first(where: {
                    value.location.y >= $0.value.minY && value.location.y <= $0.value.maxY
                })?.key else {
                    editor.refuseGesture("Move Audio Clips only to an Audio Track. No placement was changed.")
                    return
                }
                editor.previewGesture(start: position, track: target)
            }
            .onEnded { _ in editor.completeGesture() }
    }

    private func edge(_ clip: ProgramAudioClip, leading: Bool, width: Double) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7))
            .frame(width: 7).padding(.vertical, 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        if editor.gesture == nil { editor.beginGesture(clip) }
                        guard width > 0 else { return }
                        let originalEdge = leading ? clip.programFrames.lowerBound : clip.programFrames.upperBound
                        let display = projection.displayTime(forProgramTime: Double(originalEdge) / 48_000)
                            + value.translation.width / width * duration
                        guard let program = projection.programTime(forDisplayTime: display),
                              let edge = try? AudioClipEditorModel.programFrame(program) else {
                            editor.refuseGesture("Audio Clip edges cannot use a review-only removed interval.")
                            return
                        }
                        let delta = edge - originalEdge
                        let count = Int64(clip.programFrames.count)
                        let lo = leading ? delta : 0, hi = leading ? count : count + delta
                        guard lo < hi else {
                            editor.refuseGesture("Audio Clip edges must leave a positive duration. No trim was changed.")
                            return
                        }
                        editor.previewGesture(start: clip.programFrames.lowerBound + lo, track: clip.clip.track,
                                              localFrames: lo..<hi)
                    }
                    .onEnded { _ in editor.completeGesture() }
            )
            .accessibilityHidden(true)
    }

    private func name(_ clip: ProgramAudioClip) -> String {
        editor.episode?.source(clip.clip.source)?.displayNameHint ?? "Audio Clip"
    }
}

private struct AudioClipWaveformDrawing: View, Equatable {
    let clip: ProgramAudioClip
    let renderedClip: AudioClip
    let waveform: AudioAssetWaveform?
    let start: Double
    let duration: Double
    let programStart: Double
    let viewportWidth: Double
    let left: Double
    let normalized: Bool
    let projection: AudioTimelineProjection

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clip.asset == rhs.clip.asset && lhs.renderedClip.trim == rhs.renderedClip.trim
            && lhs.renderedClip.outputWindow == rhs.renderedClip.outputWindow
            && lhs.renderedClip.channels == rhs.renderedClip.channels
            && lhs.waveform?.id == rhs.waveform?.id && lhs.start == rhs.start
            && lhs.duration == rhs.duration && lhs.programStart == rhs.programStart
            && lhs.viewportWidth == rhs.viewportWidth && lhs.left == rhs.left && lhs.normalized == rhs.normalized
            && lhs.projection == rhs.projection
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard let waveform, duration > 0, viewportWidth > 0 else { return }
            let nativeRate = Double(clip.asset.sampleRate)
            guard let durationFrames = renderedClip.durationFrames(asset: clip.asset) else { return }
            let channels = renderedClip.channels ?? Array(0..<clip.asset.channelCount)
            let offset = Double(renderedClip.outputWindow?.offsetFrames ?? 0)
            let nativeOrigin = Double(renderedClip.trim.startFrame) + offset * nativeRate / 48_000
            let localLo = max(0, (projection.programTime(forDisplayTime: start) ?? programStart) - programStart)
            let localHi = min(Double(durationFrames) / 48_000,
                (projection.programTime(forDisplayTime: start + duration) ?? (programStart + Double(durationFrames) / 48_000)) - programStart)
            guard localLo < localHi else { return }
            let bins = waveform.visibleBins(in: (nativeOrigin + localLo * nativeRate)..<(nativeOrigin + localHi * nativeRate),
                                            channels: channels)
            let columns = max(1, min(16_384, Int(ceil(size.width * 2))))
            var lows = [Float](repeating: .infinity, count: columns)
            var highs = [Float](repeating: -.infinity, count: columns)
            for bin in bins {
                let local = (Double(bin.firstFrame + bin.endFrame) / 2 - nativeOrigin) / nativeRate
                let x = (projection.displayTime(forProgramTime: programStart + local) - start) / duration * viewportWidth - left
                let column = max(0, min(columns - 1, Int(x * 2)))
                lows[column] = min(lows[column], bin.minimum)
                highs[column] = max(highs[column], bin.maximum)
            }
            let gain = normalized ? waveform.normalizedGain(channels: channels) : 1
            var path = Path()
            for column in 0..<columns where lows[column].isFinite {
                let x = Double(column) / 2
                path.move(to: .init(x: x, y: size.height / 2 - Double(highs[column]) * gain * size.height * 0.35))
                path.addLine(to: .init(x: x, y: size.height / 2 - Double(lows[column]) * gain * size.height * 0.35))
            }
            context.stroke(path, with: .color(.teal), lineWidth: 1)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
