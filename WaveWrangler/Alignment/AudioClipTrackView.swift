import AppKit
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
                let blocks = clips.compactMap { placement($0, size: geometry.size) }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
                    ForEach(blocks) { item in block(item, size: geometry.size) }
                    AudioClipAccessibilityCanvas(size: geometry.size, items: accessibilityItems(blocks, size: geometry.size)) { id in
                        editor.select(id)
                        showInspector()
                    }
                    if duration > 0, playhead >= start, playhead <= start + duration {
                        Rectangle().fill(.red.opacity(0.8)).frame(width: 1)
                            .offset(x: (playhead - start) / duration * geometry.size.width)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
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

    private struct ClipBlock: Identifiable {
        let projected: ProgramAudioClip
        let renderedClip: AudioClip
        let frame: CGRect
        let first: Double
        let displayEnd: Double
        let programFirst: Double
        let count: Double
        let selected: Bool
        let invalid: Bool
        let dimmed: Bool
        let name: String

        var id: AudioClipID { projected.clip.id }
        var accessibilityValue: String {
            "Program start \(programFirst.formatted(.number.precision(.fractionLength(3)))) seconds; duration \(count.formatted(.number.precision(.fractionLength(3)))) seconds; \(renderedClip.envelope.points.count) fade points"
        }
    }

    private func placement(_ projected: ProgramAudioClip, size: CGSize) -> ClipBlock? {
        guard duration > 0, size.width > 0, size.height > 0 else { return nil }
        let preview = editor.gesture?.clip.clip.id == projected.clip.id ? editor.gesture : nil
        let programFirst = Double(preview?.startFrame ?? projected.programFrames.lowerBound) / 48_000
        let first = projection.displayTime(forProgramTime: programFirst)
        let count = Double(preview?.localFrames?.count ?? projected.programFrames.count) / 48_000
        let displayEnd = projection.displayTime(forProgramTime: programFirst + count)
        let left = max(0, (first - start) / duration * size.width)
        let right = min(size.width, (displayEnd - start) / duration * size.width)
        guard right >= left, displayEnd > start, first < start + duration else { return nil }
        return .init(projected: projected, renderedClip: preview?.previewClip ?? projected.clip,
                     frame: CGRect(x: left, y: 2, width: max(6, right - left), height: max(40, size.height - 4)),
                     first: first, displayEnd: displayEnd, programFirst: programFirst, count: count,
                     selected: editor.selectedClip == projected.clip.id, invalid: preview?.previewError != nil,
                     dimmed: preview != nil && projected.clip.track == track.id && preview?.track != track.id,
                     name: name(projected))
    }

    private func accessibilityItems(_ blocks: [ClipBlock], size: CGSize) -> [AudioClipAccessibilityCanvas.Item] {
        let bounds = CGRect(origin: .zero, size: size)
        return blocks.compactMap { item in
            let frame = item.frame.intersection(bounds)
            guard !frame.isNull, !frame.isEmpty else { return nil }
            return .init(id: item.id, frame: frame, label: "Audio Clip: \(item.name)",
                         value: item.accessibilityValue, selected: item.selected)
        }
    }

    @ViewBuilder private func block(_ item: ClipBlock, size: CGSize) -> some View {
        let projected = item.projected, renderedClip = item.renderedClip
        let selected = item.selected, programFirst = item.programFirst
        let left = item.frame.minX, blockWidth = item.frame.width, blockHeight = item.frame.height
        Button {
                editor.select(projected.clip.id)
                showInspector()
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.teal.opacity(selected ? 0.28 : 0.13))
                    .frame(width: blockWidth, height: blockHeight)
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
                            Text(item.name).lineLimit(1)
                        }.font(.caption2).padding(5).allowsHitTesting(false)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(item.invalid ? Color.red : selected ? Color.accentColor : Color.teal.opacity(0.6),
                                    lineWidth: selected ? 2 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if item.invalid {
                            Text("Invalid edge or placement").font(.caption2).foregroundStyle(.red).padding(5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(width: blockWidth, height: blockHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(moveGesture(projected, width: size.width))
            .overlay(alignment: .leading) {
                if selected, editor.store.canEdit, item.first >= start { edge(projected, leading: true, width: size.width) }
            }
            .overlay(alignment: .trailing) {
                if selected, editor.store.canEdit, item.displayEnd <= start + duration { edge(projected, leading: false, width: size.width) }
            }
            .padding(.leading, left)
            .padding(.top, 2)
            .zIndex(selected ? 1 : 0)
            .opacity(item.dimmed ? 0.35 : 1)
            .allowsHitTesting(projected.clip.track == track.id)
            .accessibilityHidden(true)
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

@MainActor
private struct AudioClipAccessibilityCanvas: NSViewRepresentable {
    struct Item {
        let id: AudioClipID
        let frame: CGRect
        let label: String
        let value: String
        let selected: Bool
    }

    let size: CGSize
    let items: [Item]
    let select: @MainActor (AudioClipID) -> Void

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CanvasView, context: Context) -> CGSize? { size }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.update(items, enabled: context.environment.isEnabled, select: select)
    }

    final class CanvasView: NSView {
        private var buttons: [AudioClipID: ClipButton] = [:]
        private var orderedButtons: [ClipButton] = []

        override var isFlipped: Bool { true }
        // Pointer input stays with SwiftUI; these native children serve assistive controls.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityChildren() -> [Any]? {
            let children: [ClipButton] = MainActor.assumeIsolated { orderedButtons }
            return children
        }

        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            let button: ClipButton? = MainActor.assumeIsolated {
                let candidates = orderedButtons.filter { $0.selectedClip } + orderedButtons.filter { !$0.selectedClip }
                return candidates.first { $0.accessibilityFrame().contains(point) }
            }
            return button
        }

        func update(_ items: [Item], enabled: Bool, select: @escaping @MainActor (AudioClipID) -> Void) {
            let live = Set(items.map(\.id))
            for id in Array(buttons.keys) where !live.contains(id) {
                buttons.removeValue(forKey: id)?.removeFromSuperview()
            }
            orderedButtons = items.map { item in
                let button: ClipButton
                if let existing = buttons[item.id] {
                    button = existing
                } else {
                    button = ClipButton(select: { select(item.id) })
                    buttons[item.id] = button
                    addSubview(button)
                }
                let changed = button.programValue != item.value || button.selectedClip != item.selected
                button.frame = item.frame
                button.selectAction = { select(item.id) }
                button.programValue = item.value
                button.selectedClip = item.selected
                button.isEnabled = enabled
                button.setAccessibilityLabel(item.label)
                button.setAccessibilityIdentifier("ww.audioClip.\(item.id)")
                if changed { NSAccessibility.post(element: button, notification: .valueChanged) }
                return button
            }
        }
    }

    final class ClipButton: NSButton {
        var programValue = ""
        var selectedClip = false
        var selectAction: @MainActor () -> Void

        init(select: @escaping @MainActor () -> Void) {
            selectAction = select
            super.init(frame: .zero)
            title = ""
            isBordered = false
            setButtonType(.momentaryPushIn)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            target = self
            action = #selector(performSelection(_:))
        }

        required init?(coder: NSCoder) { nil }

        override func accessibilityValue() -> Any? {
            let value: String = MainActor.assumeIsolated { programValue }
            return value
        }
        override func isAccessibilitySelected() -> Bool {
            MainActor.assumeIsolated { selectedClip }
        }
        override func accessibilityFrame() -> NSRect {
            MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: self, rect: bounds) }
        }

        @objc private func performSelection(_ sender: NSButton) {
            guard isEnabled else { return }
            selectAction()
        }
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
