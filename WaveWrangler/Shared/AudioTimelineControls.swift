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
    var isEdited = false
    var cycleEnabled: Bool? = nil
    var toggleCycle: () -> Void = {}
    var followPlayhead: Bool? = nil
    var toggleFollowPlayhead: () -> Void = {}
    var jumpSeconds = 5

    @State private var timeDraft = ""
    @FocusState private var editingTime: Bool
    private var jumpDescription: String { jumpSeconds == 1 ? "1 second" : "\(jumpSeconds) seconds" }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: back) { Label("Back \(jumpDescription)", systemImage: jumpSeconds == 5 ? "gobackward.5" : "gobackward") }
                    .disabled(!canNavigate)
                    .help("Jump backward \(jumpDescription). Configure in Settings > General.")
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
                Button(action: forward) { Label("Forward \(jumpDescription)", systemImage: jumpSeconds == 5 ? "goforward.5" : "goforward") }
                    .disabled(!canNavigate)
                    .help("Jump forward \(jumpDescription). Configure in Settings > General.")
                    .accessibilityIdentifier("\(prefix).transport.forward")
                if let cycleEnabled {
                    Button("Cycle", systemImage: "repeat", action: toggleCycle)
                        .tint(cycleEnabled ? .yellow : .secondary)
                        .disabled(!canNavigate)
                        .accessibilityValue(cycleEnabled ? "On" : "Off")
                        .accessibilityAddTraits(cycleEnabled ? [.isSelected] : [])
                        .accessibilityIdentifier("ww.timeline.cycle")
                        .help("Repeat the cycle range. Use the cycle strip or Cycle selection to set its bounds.")
                }
                if let followPlayhead {
                    Button("Follow Playhead", systemImage: "play.rectangle.on.rectangle",
                           action: toggleFollowPlayhead)
                        .tint(followPlayhead ? .accentColor : .secondary)
                        .disabled(!canNavigate)
                        .accessibilityValue(followPlayhead ? "On" : "Off")
                        .accessibilityAddTraits(followPlayhead ? [.isSelected] : [])
                        .accessibilityIdentifier("\(prefix).followPlayhead")
                        .help("Page at the right edge without interrupting audio. Panning turns Follow Playhead off; enable it to return to the current playhead.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 1) {
                Text(isEdited ? "EDITED TIME" : "ALIGNED TIME").font(.caption2).foregroundStyle(.secondary)
                TextField(isEdited ? "Edited seconds" : "Aligned seconds", text: $timeDraft)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .frame(width: 104)
                    .focused($editingTime)
                    .disabled(!canNavigate)
                    .onSubmit { editingTime = false }
                    .onChange(of: editingTime) { _, focused in
                        if !focused { commitTime() }
                    }
                    .accessibilityIdentifier("\(prefix).playhead")
                    .accessibilityLabel(isEdited ? "Edited playhead time in seconds" : "Aligned playhead time in seconds")
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

// Nested ViewThatFits repeatedly probes the entire native-control tree during timeline drags.
// Measure each arrangement once per proposal, without constructing duplicate control hierarchies.
struct AudioTimelineAdaptiveRow: Layout {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 6
    var alignsTrailing = false
    var wraps = false

    struct Plan {
        let size: CGSize
        let frames: [CGRect]
    }

    struct Cache {
        var ideal: [CGSize]
        var plans: [CGFloat: Plan] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        plan(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let plan = plan(width: bounds.width, subviews: subviews, cache: &cache)
        for (subview, frame) in zip(subviews, plan.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func plan(width: CGFloat?, subviews: Subviews, cache: inout Cache) -> Plan {
        let gaps = CGFloat(max(0, subviews.count - 1))
        let idealWidth = cache.ideal.reduce(0) { $0 + $1.width } + horizontalSpacing * gaps
        let width = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth)
        if let plan = cache.plans[width] { return plan }
        let horizontal = idealWidth <= width
        if wraps && !horizontal {
            var rows: [[CGRect]] = [[]]
            var x: CGFloat = 0
            for (index, subview) in subviews.enumerated() {
                let childWidth = min(width, cache.ideal[index].width)
                if x > 0, x + childWidth > width {
                    rows.append([])
                    x = 0
                }
                let size = subview.sizeThatFits(ProposedViewSize(width: childWidth, height: nil))
                rows[rows.count - 1].append(CGRect(x: x, y: 0, width: childWidth, height: size.height))
                x += childWidth + horizontalSpacing
            }
            var frames: [CGRect] = []
            var y: CGFloat = 0
            for row in rows {
                let height = row.map(\.height).max() ?? 0
                let offset = alignsTrailing ? max(0, width - (row.map(\.maxX).max() ?? 0)) : 0
                frames += row.map { $0.offsetBy(dx: offset, dy: y + (height - $0.height) / 2) }
                y += height + verticalSpacing
            }
            let plan = Plan(size: CGSize(width: width, height: max(0, y - verticalSpacing)), frames: frames)
            cache.plans[width] = plan
            return plan
        }
        var frames: [CGRect] = []
        var x: CGFloat = horizontal && alignsTrailing ? max(0, width - idealWidth) : 0
        var y: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let childWidth = horizontal
                ? (index == subviews.count - 1 && !alignsTrailing ? max(0, width - x) : cache.ideal[index].width)
                : width
            let size = subview.sizeThatFits(ProposedViewSize(width: childWidth, height: nil))
            frames.append(CGRect(x: x, y: y, width: childWidth, height: size.height))
            if horizontal { x += childWidth + horizontalSpacing }
            else { y += size.height + verticalSpacing }
        }
        let height = horizontal ? frames.map(\.height).max() ?? 0 : max(0, y - verticalSpacing)
        if horizontal {
            for index in frames.indices { frames[index].origin.y = (height - frames[index].height) / 2 }
        }
        let plan = Plan(size: CGSize(width: width, height: height), frames: frames)
        cache.plans[width] = plan
        return plan
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
    var fillSpace: Binding<Bool>? = nil
    var showsRefresh = true

    var body: some View {
        AudioTimelineAdaptiveRow(alignsTrailing: true) {
            zoomGroup.frame(maxWidth: .infinity, alignment: .trailing)
            heightGroup.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(.small)
    }

    var zoomGroup: some View {
        HStack(spacing: 12) {
            zoomControls
            fitButton
        }
    }

    var heightGroup: some View {
        HStack(spacing: 12) {
            if showsLaneHeight { heightControls }
            if let fillSpace {
                Toggle(isOn: fillSpace) {
                    Label("Fill Space", systemImage: "arrow.up.and.down")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Fit visible tracks to the available height, keeping waveforms at least 64 points tall. Adjusting track height exits Fill Space.")
                .accessibilityIdentifier("\(prefix).fillSpace")
            }
            if showsRefresh {
                Spacer(minLength: 0)
                AudioTimelineRefresh(prefix: prefix, isLoading: isLoading,
                                     canNavigate: canNavigate, refresh: refresh)
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 5) {
            zoomButton(increment: false)
            NativeTimelineSlider(
                value: Binding(
                    get: {
                        AlignmentWaveformProjection.zoomLevel(
                            for: duration, maximum: maximumDuration) ?? 0
                    },
                    set: {
                        if let value = AlignmentWaveformProjection.zoomDuration(
                            for: $0, maximum: maximumDuration) { duration = value }
                    }
                ), range: 0...1, label: "Horizontal zoom", identifier: "\(prefix).zoom",
                onEditingChanged: zoomEditing
            )
            .frame(minWidth: 90, idealWidth: 120, maxWidth: 220)
            .disabled(!canNavigate)
            zoomButton(increment: true)
            Text(AlignmentPresentation.formatTime(duration))
                .font(.caption).monospacedDigit().frame(minWidth: 54)
        }
    }

    private func zoomButton(increment: Bool) -> some View {
        Button(increment ? "Zoom in" : "Zoom out",
               systemImage: increment ? "plus.magnifyingglass" : "minus.magnifyingglass") {
            zoomEditing(true)
            if let next = AlignmentWaveformProjection.steppedZoomDuration(
                duration: duration, maximum: maximumDuration, zoomIn: increment) {
                duration = next
            }
            zoomEditing(false)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(!canNavigate || (increment ? duration <= 0.5 : duration >= maximumDuration))
        .accessibilityIdentifier("\(prefix).\(increment ? "zoomIn" : "zoomOut")")
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
            NativeTimelineSlider(
                value: $laneHeight, range: 64...220,
                label: "Track height", identifier: "\(prefix).laneHeight")
                .frame(minWidth: 70, idealWidth: 90, maxWidth: 130)
                .disabled(!canNavigate)
        }
    }

}

struct AudioTimelineRefresh: View {
    let prefix: String
    let isLoading: Bool
    let canNavigate: Bool
    let refresh: () -> Void

    var body: some View {
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
    var createCycle: ((ClosedRange<Double>) -> Void)? = nil
    var clicked: ((Double) -> Void)? = nil
    let previewSeek: (Double) -> Bool
    let resumePlayback: () -> Void
    let previewPan: (Double) -> Void
    let setWindow: (Double, Double) -> Void
    let commitWindow: () -> Void
    var isEdited = false

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
        let duration: Double
        let playhead: Double
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
    @State private var cycleCreation: (start: Double, duration: Double, width: Double)?
    @FocusState private var timelineFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
            timeRuler
            if createCycle != nil { cycleCreationStrip }
        }
    }

    private var cycleCreationStrip: some View {
        HStack(spacing: 8) {
            Text("CYCLE RANGE").font(.caption2).foregroundStyle(.secondary)
                .frame(width: headerWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.yellow.opacity(0.08))
                    if let cycleRange {
                        let lo = max(0, (cycleRange.lowerBound - start) / duration * geometry.size.width)
                        let hi = min(geometry.size.width, (cycleRange.upperBound - start) / duration * geometry.size.width)
                        if hi > lo {
                            Rectangle().fill(Color.yellow.opacity(cycleEnabled ? 0.4 : 0.16))
                                .frame(width: hi - lo).offset(x: lo)
                        }
                    } else {
                        Text("Drag to create a cycle range").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        guard canNavigate, geometry.size.width > 0 else { return }
                        if cycleCreation == nil {
                            cycleCreation = (start, duration, Double(geometry.size.width))
                        }
                        guard let creation = cycleCreation,
                              let range = Self.cycleSelection(
                                from: Double(drag.startLocation.x), to: Double(drag.location.x),
                                width: creation.width, start: creation.start,
                                duration: creation.duration, bounds: seekBounds) else { return }
                        createCycle?(range)
                    }
                    .onEnded { _ in cycleCreation = nil })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Create cycle range, " + (cycleRange.map {
                    String(format: "%.3f to %.3f seconds", $0.lowerBound, $0.upperBound)
                } ?? "No cycle range"))
                .accessibilityValue(cycleRange.map {
                    String(format: "%.3f to %.3f seconds", $0.lowerBound, $0.upperBound)
                } ?? "No cycle range")
                .accessibilityIdentifier("\(prefix).ruler.cycleArea")
                .help("Drag here to create a loop. The ruler above still seeks, scrubs, pans, and edits cycle locators.")
            }
        }
        .frame(height: 22)
    }

    static func cycleSelection(from: Double, to: Double, width: Double, start: Double,
                               duration: Double, bounds: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard from.isFinite, to.isFinite, width.isFinite, width > 0,
              start.isFinite, duration.isFinite, duration > 0 else { return nil }
        let lo = max(bounds.lowerBound, start + min(max(0, from), max(0, to), width) / width * duration)
        let hi = min(bounds.upperBound, start + max(min(width, from), min(width, to), 0) / width * duration)
        return hi > lo ? lo...hi : nil
    }

    private var timeRuler: some View {
        HStack(spacing: 8) {
            Text(isEdited ? "EDITED SECONDS" : "ALIGNED SECONDS")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: headerWidth, alignment: .leading)
                .accessibilityLabel(
                    String(
                        format: "Visible %@ time ruler: %.3f to %.3f seconds", isEdited ? "edited" : "aligned", start,
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
                        .accessibilityRepresentation {
                            Stepper(
                                "Aligned playhead",
                                onIncrement: { adjustPlayhead(.increment) },
                                onDecrement: { adjustPlayhead(.decrement) }
                            )
                            .accessibilityValue(AlignmentPresentation.formatTime(playhead))
                            .accessibilityIdentifier("\(prefix).ruler.playhead")
                            .disabled(!canNavigate)
                        }
                        .offset(x: x - 10)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(prefix).ruler.surface")
                .focusable(interactions: .edit)
                .focused($timelineFocused)
                .focusEffectDisabled()
                .onTapGesture { point in
                    guard canNavigate, cycleEdge(at: point, width: Double(width)) == nil,
                        let time = AlignmentWaveformProjection.rulerTime(
                            at: Double(point.x), width: Double(width), start: start,
                            duration: duration, bounds: seekBounds
                        )
                    else { return }
                    timelineFocused = true
                    if let clicked { clicked(time) } else { seek(time) }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            guard canNavigate, width > 0, zoom == nil else { return }
                            if pan == nil, scrub == nil, cycleDrag == nil {
                                timelineFocused = true
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
                                zoom = Zoom(
                                    duration: duration, playhead: playhead,
                                    bounds: bounds, maximum: maximumDuration)
                            }
                            guard let zoom,
                                let result = AlignmentWaveformProjection.rulerZoom(
                                    duration: zoom.duration, playhead: zoom.playhead,
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

    func adjustPlayhead(_ direction: AccessibilityAdjustmentDirection) {
        guard canNavigate else { return }
        let step = max(0.1, duration / 20) * (direction == .increment ? 1 : -1)
        seek(playhead + step)
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
    let index: AlignmentWaveformStrokeIndex
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
            && lhs.index.id == rhs.index.id
            && (lhs.draftEpoch == nil
                || (lhs.draftRatePPM == rhs.draftRatePPM
                    && lhs.draftOffsetMilliseconds == rhs.draftOffsetMilliseconds))
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            let strokes = index.visible(start: start, duration: duration,
                draftEpoch: draftEpoch, ratePPM: draftRatePPM, offsetMilliseconds: draftOffsetMilliseconds)
            let columns = AlignmentWaveformProjection.displayColumns(
                strokes: strokes, start: start, duration: duration,
                width: size.width, pixelsPerPoint: displayScale,
                draftEpoch: draftEpoch, ratePPM: draftRatePPM,
                offsetMilliseconds: draftOffsetMilliseconds)
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [color.mix(with: .white, by: 0.16), color, color.mix(with: .black, by: 0.16)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            if ghost {
                context.stroke(path(columns: columns, mapped: true), with: gradient,
                    style: StrokeStyle(lineWidth: lineWidth, dash: [4, 3]))
            } else {
                context.fill(path(columns: columns, mapped: true), with: gradient)
            }
            context.stroke(path(columns: columns, mapped: false), with: .color(.orange),
                style: StrokeStyle(lineWidth: lineWidth, dash: [3, 2]))
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

struct AudioTimelineWaveformProposalDrawing: View {
    let input: AlignmentWaveformProjection.ProposalInput
    let size: CGSize
    let start: Double
    let duration: Double
    let normalized: Bool
    let displayScale: Double
    @State private var prepared: (input: AlignmentWaveformProjection.ProposalInput, index: AlignmentWaveformStrokeIndex)?

    var body: some View {
        Group {
            if let prepared, prepared.input == input {
                AudioTimelineWaveformDrawing(
                    snapshot: prepared.index.id, index: prepared.index, size: size, start: start, duration: duration,
                    color: .teal.opacity(0.65), lineWidth: 1.5,
                    gain: normalized ? prepared.index.normalizedGain : 1,
                    displayScale: displayScale, ghost: true)
                    .equatable()
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
        .task(id: input) {
            let index = await input.prepare()
            guard !Task.isCancelled else { return }
            prepared = (input, index)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
