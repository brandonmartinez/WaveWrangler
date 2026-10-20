import SwiftUI
import WWCore

struct AudioTimelineTransport: View {
    let prefix: String
    let isPlaying: Bool
    let isPreparing: Bool
    let canPlay: Bool
    let canNavigate: Bool
    let playhead: Double
    let status: String
    let back: () -> Void
    let playPause: () -> Void
    let stop: () -> Void
    let forward: () -> Void
    let seek: (Double) -> Void

    @State private var timeDraft = ""
    @FocusState private var editingTime: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: back) { Label("Back 5 seconds", systemImage: "gobackward.5") }
                    .disabled(!canNavigate)
                    .accessibilityIdentifier("\(prefix).transport.back")
                Button(action: playPause) {
                    Label(
                        isPlaying || isPreparing ? "Pause" : "Play",
                        systemImage: isPlaying || isPreparing ? "pause.fill" : "play.fill")
                }
                .disabled(!canPlay && !isPlaying && !isPreparing)
                .accessibilityIdentifier("\(prefix).transport.play")
                Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!canNavigate && !isPlaying && !isPreparing)
                    .accessibilityIdentifier("\(prefix).transport.stop")
                Button(action: forward) { Label("Forward 5 seconds", systemImage: "goforward.5") }
                    .disabled(!canNavigate)
                    .accessibilityIdentifier("\(prefix).transport.forward")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 1) {
                Text("ALIGNED TIME").font(.caption2).foregroundStyle(.secondary)
                TextField("Aligned seconds", text: $timeDraft)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .frame(width: 104)
                    .focused($editingTime)
                    .disabled(!canNavigate)
                    .onSubmit { editingTime = false }
                    .onChange(of: editingTime) { _, focused in
                        if !focused { commitTime() }
                    }
                    .accessibilityIdentifier("\(prefix).playhead")
                    .accessibilityLabel("Aligned playhead time in seconds")
            }
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("\(prefix).transport.status")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .frame(minHeight: 36)
        .onAppear { updateTime() }
        .onChange(of: playhead) { _, _ in if !editingTime { updateTime() } }
    }

    private func updateTime() { timeDraft = String(format: "%.3f", playhead) }

    private func commitTime() {
        guard let value = Double(timeDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            value.isFinite
        else {
            seek(.nan)
            updateTime()
            return
        }
        seek(value)
        updateTime()
    }
}

struct AudioTimelineNavigation: View {
    let prefix: String
    let maximumDuration: Double
    @Binding var duration: Double
    @Binding var laneHeight: Double
    let showsLaneHeight: Bool
    let isLoading: Bool
    let canNavigate: Bool
    let zoomEditing: (Bool) -> Void
    let fit: () -> Void
    let refresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                zoomControls
                fitButton
                if showsLaneHeight { heightControls }
                Spacer(minLength: 0)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) { zoomControls; fitButton }
                HStack(spacing: 12) {
                    if showsLaneHeight { heightControls }
                    Spacer(minLength: 0)
                    refreshButton
                }
            }
        }
        .controlSize(.small)
    }

    private var zoomControls: some View {
        HStack(spacing: 5) {
            Image(systemName: "minus.magnifyingglass")
            Slider(
                value: Binding(
                    get: {
                        AlignmentWaveformProjection.zoomLevel(
                            for: duration, maximum: maximumDuration) ?? 0
                    },
                    set: {
                        if let value = AlignmentWaveformProjection.zoomDuration(
                            for: $0, maximum: maximumDuration) { duration = value }
                    }
                ), in: 0...1, onEditingChanged: zoomEditing
            ) { Text("Horizontal zoom") }
            .frame(minWidth: 90, maxWidth: 220)
            .disabled(!canNavigate)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Horizontal zoom")
            .accessibilityIdentifier("\(prefix).zoom")
            Image(systemName: "plus.magnifyingglass")
            Text(AlignmentPresentation.formatTime(duration))
                .font(.caption).monospacedDigit().frame(minWidth: 54)
        }
    }

    private var fitButton: some View {
        Button("Fit timeline", systemImage: "arrow.left.and.right", action: fit)
            .labelStyle(.iconOnly)
            .help("Fit the complete aligned timeline.")
            .disabled(!canNavigate)
            .accessibilityIdentifier("\(prefix).fitTimeline")
    }

    private var heightControls: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform")
            Slider(value: $laneHeight, in: 64...220) { Text("Track height") }
                .frame(minWidth: 70, maxWidth: 130)
                .disabled(!canNavigate)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Track height")
                .accessibilityIdentifier("\(prefix).laneHeight")
        }
    }

    private var refreshButton: some View {
        Button(
            isLoading ? "Cancel" : "Refresh audio",
            systemImage: isLoading ? "xmark.circle" : "arrow.clockwise", action: refresh
        )
        .labelStyle(.iconOnly)
        .help(isLoading ? "Cancel waveform loading." : "Refresh measured waveforms.")
        .disabled(!canNavigate && !isLoading)
        .accessibilityIdentifier("\(prefix).load")
    }
}

struct AudioTimelineMarker: Identifiable {
    let id: String
    let time: Double
    let title: String
    let color: Color
}

struct AudioTimelineRuler: View {
    let prefix: String
    let headerWidth: CGFloat
    let start: Double
    let duration: Double
    let playhead: Double
    let bounds: ClosedRange<Double>
    let seekBounds: ClosedRange<Double>
    let maximumDuration: Double
    let isPlaying: Bool
    let canNavigate: Bool
    var markers: [AudioTimelineMarker] = []
    var cycleRange: ClosedRange<Double>? = nil
    var cycleEnabled = false
    var changeCycle: ((ClosedRange<Double>) -> Void)? = nil
    var clicked: ((Double) -> Void)? = nil
    let previewSeek: (Double) -> Bool
    let resumePlayback: () -> Void
    let previewPan: (Double) -> Void
    let setWindow: (Double, Double) -> Void
    let commitWindow: () -> Void

    private struct Pan {
        let start: Double
        let duration: Double
        let bounds: ClosedRange<Double>
        let width: Double
    }
    private struct Scrub {
        let start: Double
        let duration: Double
        let bounds: ClosedRange<Double>
        let wasPlaying: Bool
        let time: Double
        let width: Double
    }
    private struct Zoom {
        let start: Double
        let duration: Double
        let anchor: Double
        let bounds: ClosedRange<Double>
        let maximum: Double
    }
    private enum CycleEdge {
        case start, end
    }
    @State private var pan: Pan?
    @State private var scrub: Scrub?
    @State private var zoom: Zoom?
    @State private var cycleDrag: CycleEdge?

    var body: some View {
        HStack(spacing: 8) {
            Text("ALIGNED SECONDS")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: headerWidth, alignment: .leading)
                .accessibilityLabel(
                    String(
                        format: "Visible aligned time ruler: %.3f to %.3f seconds", start,
                        start + duration)
                )
                .accessibilityIdentifier("\(prefix).ruler")
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.primary.opacity(0.025))
                    if let cycleRange {
                        let lo = (cycleRange.lowerBound - start) / duration * width
                        let hi = (cycleRange.upperBound - start) / duration * width
                        Rectangle().fill(Color.yellow.opacity(cycleEnabled ? 0.24 : 0.06))
                            .frame(width: max(0, hi - lo), height: 8).offset(x: lo, y: 36)
                            .allowsHitTesting(false)
                        cycleLocator(time: cycleRange.lowerBound, isStart: true, width: width)
                        cycleLocator(time: cycleRange.upperBound, isStart: false, width: width)
                    }
                    ForEach(
                        AlignmentWaveformProjection.rulerTicks(
                            start: start, duration: duration, width: Double(width)
                        )
                    ) { tick in
                        let x = (tick.time - start) / duration * width
                        Rectangle().fill(Color.secondary.opacity(tick.major ? 0.5 : 0.22))
                            .frame(width: 1, height: tick.major ? 14 : 7)
                            .offset(x: x, y: 24)
                        if tick.major {
                            Text(AlignmentPresentation.formatTime(tick.time))
                                .font(.caption2).monospacedDigit()
                                .fixedSize()
                                .position(x: min(max(x, 36), max(36, width - 36)), y: 10)
                        }
                    }
                    ForEach(markers) { marker in
                        let x = (marker.time - start) / duration * width
                        if x >= 0, x <= width {
                            Text(marker.title).font(.caption2.bold())
                                .foregroundStyle(marker.color)
                                .position(x: min(max(x, 14), max(14, width - 14)), y: 20)
                            Rectangle().fill(marker.color).frame(width: 2, height: 18)
                                .offset(x: x, y: 26)
                        }
                    }
                    let x = (playhead - start) / duration * width
                    if x >= 0, x <= width {
                        VStack(spacing: 0) {
                            AlignmentPlayheadCap().fill(Color.primary)
                                .frame(width: 16, height: 18)
                            Rectangle().fill(Color.primary).frame(width: 1.5)
                        }
                        .frame(width: 20, height: 44)
                        .offset(x: x - 10)
                        .accessibilityElement()
                        .accessibilityLabel("Aligned playhead")
                        .accessibilityValue(AlignmentPresentation.formatTime(playhead))
                        .accessibilityAdjustableAction { direction in
                            guard canNavigate else { return }
                            let increment = max(0.1, duration / 20)
                            let step = direction == .increment ? increment : -increment
                            seek(playhead + step)
                        }
                        .accessibilityIdentifier("\(prefix).ruler.playhead")
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(prefix).ruler.surface")
                .onTapGesture { point in
                    guard canNavigate, cycleEdge(at: point, width: Double(width)) == nil,
                        let time = AlignmentWaveformProjection.rulerTime(
                            at: Double(point.x), width: Double(width), start: start,
                            duration: duration, bounds: seekBounds
                        )
                    else { return }
                    if let clicked { clicked(time) } else { seek(time) }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            guard canNavigate, width > 0, zoom == nil else { return }
                            if pan == nil, scrub == nil, cycleDrag == nil {
                                cycleDrag = cycleEdge(at: drag.startLocation, width: Double(width))
                                if cycleDrag == nil {
                                    let x = (playhead - start) / duration * width
                                    if abs(drag.startLocation.x - x) <= 14 {
                                        scrub = Scrub(
                                            start: start, duration: duration,
                                            bounds: seekBounds, wasPlaying: isPlaying,
                                            time: playhead, width: Double(width))
                                    } else {
                                        pan = Pan(
                                            start: start, duration: duration, bounds: bounds,
                                            width: Double(width))
                                    }
                                }
                            }
                            if let cycleDrag {
                                moveCycle(cycleDrag, to: start + Double(drag.location.x) / Double(width) * duration)
                            } else if let scrub {
                                let time = min(
                                    scrub.bounds.upperBound,
                                    max(
                                        scrub.bounds.lowerBound,
                                        max(
                                            scrub.start,
                                            min(
                                                scrub.start + scrub.duration,
                                                scrub.time + Double(drag.translation.width)
                                                    / scrub.width * scrub.duration))
                                    ))
                                _ = previewSeek(time)
                            } else if let pan,
                                let value = AlignmentWaveformProjection.rulerPanStart(
                                    from: pan.start, translation: Double(drag.translation.width),
                                    width: pan.width, duration: pan.duration, bounds: pan.bounds
                                )
                            {
                                previewPan(value)
                            }
                        }
                        .onEnded { _ in
                            let resume = scrub?.wasPlaying == true
                            let moved = pan != nil || scrub != nil
                            pan = nil
                            scrub = nil
                            cycleDrag = nil
                            if moved { commitWindow() }
                            if resume { resumePlayback() }
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            guard canNavigate, width > 0, pan == nil, scrub == nil, cycleDrag == nil else { return }
                            if zoom == nil {
                                let fraction = Double(value.startAnchor.x)
                                zoom = Zoom(
                                    start: start, duration: duration,
                                    anchor: min(1, max(0, fraction)),
                                    bounds: bounds, maximum: maximumDuration)
                            }
                            guard let zoom,
                                let result = AlignmentWaveformProjection.rulerZoom(
                                    start: zoom.start, duration: zoom.duration, anchor: zoom.anchor,
                                    magnification: Double(value.magnification), bounds: zoom.bounds,
                                    maximumDuration: zoom.maximum
                                )
                            else { return }
                            setWindow(result.start, result.duration)
                        }
                        .onEnded { _ in
                            if zoom != nil { commitWindow() }
                            zoom = nil
                        })
            }
        }
        .frame(height: 44)
        .help(
            "Click to seek, drag the playhead to scrub, drag cycle locators to set the loop, drag empty ruler space to pan, or pinch to zoom. Audio tracks are not moved."
        )
    }

    private func seek(_ time: Double) {
        let resume = isPlaying
        if previewSeek(min(seekBounds.upperBound, max(seekBounds.lowerBound, time))), resume {
            resumePlayback()
        }
    }

    private func cycleEdge(at point: CGPoint, width: Double) -> CycleEdge? {
        guard let cycleRange, changeCycle != nil, width > 0, duration > 0,
              abs(point.y - 36) <= 10 else { return nil }
        let lo = (cycleRange.lowerBound - start) / duration * width
        let hi = (cycleRange.upperBound - start) / duration * width
        let loDistance = (0...width).contains(lo)
            ? abs(Double(point.x) - min(max(8, lo), max(8, width - 8))) : Double.infinity
        let hiDistance = (0...width).contains(hi)
            ? abs(Double(point.x) - min(max(8, hi), max(8, width - 8))) : Double.infinity
        guard min(loDistance, hiDistance) <= 10 else { return nil }
        return loDistance < hiDistance ? .start : .end
    }

    private func moveCycle(_ edge: CycleEdge, to time: Double) {
        guard canNavigate, time.isFinite, let range = cycleRange, let changeCycle else { return }
        let value = min(seekBounds.upperBound, max(seekBounds.lowerBound, time))
        switch edge {
        case .start:
            if value < range.upperBound { changeCycle(value...range.upperBound) }
        case .end:
            if value > range.lowerBound { changeCycle(range.lowerBound...value) }
        }
    }

    @ViewBuilder
    private func cycleLocator(time: Double, isStart: Bool, width: Double) -> some View {
        let x = (time - start) / duration * width
        if x >= 0, x <= width {
            Image(systemName: isStart ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                .font(.system(size: 10)).foregroundStyle(cycleEnabled ? Color.yellow : Color.secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
                .position(x: min(max(8, x), max(8, width - 8)), y: 36)
                .accessibilityLabel(isStart ? "Cycle start" : "Cycle end")
                .accessibilityValue(AlignmentPresentation.formatTime(time))
                .accessibilityAdjustableAction { direction in
                    let step = max(0.01, duration / 100) * (direction == .increment ? 1 : -1)
                    moveCycle(isStart ? .start : .end, to: time + step)
                }
        }
    }
}

struct AudioTimelineWaveformDrawing: View, Equatable {
    let snapshot: UUID
    let strokes: [AlignmentWaveformStroke]
    let size: CGSize
    let start: Double
    let duration: Double
    let color: Color
    let lineWidth: Double
    let gain: Double
    var draftEpoch: RecordingEpochID? = nil
    var draftRatePPM = 0.0
    var draftOffsetMilliseconds = 0.0
    let displayScale: Double
    var ghost = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.size == rhs.size && lhs.displayScale == rhs.displayScale
            && lhs.start == rhs.start && lhs.duration == rhs.duration
            && lhs.color == rhs.color && lhs.lineWidth == rhs.lineWidth
            && lhs.gain == rhs.gain && lhs.draftEpoch == rhs.draftEpoch
            && lhs.ghost == rhs.ghost
            && (!lhs.ghost || lhs.strokes == rhs.strokes)
            && (lhs.draftEpoch == nil
                || (lhs.draftRatePPM == rhs.draftRatePPM
                    && lhs.draftOffsetMilliseconds == rhs.draftOffsetMilliseconds))
    }

    var body: some View {
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: strokes, start: start, duration: duration,
            width: size.width, pixelsPerPoint: displayScale,
            draftEpoch: draftEpoch, ratePPM: draftRatePPM,
            offsetMilliseconds: draftOffsetMilliseconds)
        let gradient = LinearGradient(
            colors: [color.mix(with: .white, by: 0.16), color, color.mix(with: .black, by: 0.16)],
            startPoint: .top, endPoint: .bottom)
        ZStack {
            if ghost {
                path(columns: columns, mapped: true).stroke(
                    gradient, style: StrokeStyle(lineWidth: lineWidth, dash: [4, 3]))
            } else {
                path(columns: columns, mapped: true).fill(gradient)
            }
            path(columns: columns, mapped: false).stroke(
                Color.orange, style: StrokeStyle(lineWidth: lineWidth, dash: [3, 2]))
        }
        .frame(width: size.width, height: size.height)
    }

    private func path(columns: [AlignmentWaveformProjection.DisplayColumn], mapped: Bool) -> Path {
        Path { path in
            for column in columns where column.mapped == mapped {
                let top = size.height * (0.5 - Double(column.high) * gain * 0.45)
                let bottom = size.height * (0.5 - Double(column.low) * gain * 0.45)
                if mapped && !ghost {
                    path.addRect(CGRect(
                        x: column.x - 0.5 / displayScale, y: top,
                        width: 1 / displayScale, height: max(1 / displayScale, bottom - top)))
                } else {
                    path.move(to: CGPoint(x: column.x, y: top))
                    path.addLine(to: CGPoint(x: column.x, y: bottom))
                }
            }
        }
    }
}

struct AudioTimelineTrackRow<Header: View, Content: View>: View {
    var headerWidth: CGFloat = 190
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            header().frame(width: headerWidth, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }
}
