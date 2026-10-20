import SwiftUI
import WWCore
import WWSpeech

enum FillerMarkerDetail {
    case boundaries, pole, dot

    static func make(width: Double, neighborDistance: Double = .infinity) -> Self {
        if width < 3 || neighborDistance < 14 { return .dot }
        return width < 36 ? .pole : .boundaries
    }
}

struct FillerTimingOverlay: View {
    @Bindable var model: EpisodeCleanupModel
    let reviews: [FillerTimingReview]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if reviews.count > max(40, Int(geometry.size.width / 8)) {
                    denseOverview(size: geometry.size)
                } else {
                    ForEach(reviews) { review in
                        FillerTimingRegionView(model: model, review: review, size: geometry.size,
                            start: model.windowStart, duration: model.visibleDuration,
                            neighborDistance: nearestDistance(to: review, width: geometry.size.width))
                            .zIndex(model.selectedFillerID == review.id ? 1 : 0)
                    }
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.cleanup.fillers.rails")
    }

    private func nearestDistance(to review: FillerTimingReview, width: Double) -> Double {
        reviews.filter { $0.id != review.id }.map {
            abs($0.bounds.alignedStart - review.bounds.alignedStart) / model.visibleDuration * width
        }.min() ?? .infinity
    }

    private func denseOverview(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for review in reviews {
                    let lo = max(0, (review.bounds.alignedStart - model.windowStart) / model.visibleDuration * size.width)
                    let hi = min(size.width, (review.bounds.alignedEnd - model.windowStart) / model.visibleDuration * size.width)
                    let color: Color = review.decision == .rejected ? .secondary
                        : review.decision == .reviewed ? .green : .orange
                    for x in hi - lo >= 36 ? [lo, hi] : [lo] {
                        var rail = Path()
                        rail.move(to: CGPoint(x: x, y: 0))
                        rail.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(rail, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                }
            }
            .allowsHitTesting(false)
            Text("Zoom in to review \(reviews.count) filler intervals")
                .font(.caption2).padding(3).background(.regularMaterial)
                .allowsHitTesting(false)
            Color.clear.contentShape(denseHitArea(size: size)).onTapGesture { point in
                let time = model.windowStart + point.x / max(1, size.width) * model.visibleDuration
                if let closest = reviews.min(by: {
                    max($0.bounds.alignedStart - time, time - $0.bounds.alignedEnd, 0)
                        < max($1.bounds.alignedStart - time, time - $1.bounds.alignedEnd, 0)
                }) {
                    model.selectFiller(closest.id, reveal: false)
                    model.zoomTimeline(duration: min(5, model.maximumDuration))
                    model.state.inspectorPresented = true
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(reviews.count) filler timing intervals. Zoom in to review individual handles.")
            .accessibilityAction {
                if let first = reviews.first {
                    model.selectFiller(first.id)
                    model.zoomTimeline(duration: min(5, model.maximumDuration))
                    model.state.inspectorPresented = true
                }
            }
        }
        .accessibilityIdentifier("ww.cleanup.fillers.density")
    }

    private func denseHitArea(size: CGSize) -> Path {
        var path = Path()
        for review in reviews {
            let lo = max(0, (review.bounds.alignedStart - model.windowStart) / model.visibleDuration * size.width - 3)
            let hi = min(size.width, (review.bounds.alignedEnd - model.windowStart) / model.visibleDuration * size.width + 3)
            path.addRect(CGRect(x: lo, y: 0, width: max(1, hi - lo), height: size.height))
        }
        return path
    }
}

private struct FillerTimingRegionView: View {
    @Bindable var model: EpisodeCleanupModel
    let review: FillerTimingReview
    let size: CGSize
    let start: Double
    let duration: Double
    var neighborDistance: Double = .infinity
    @State private var dragOrigin: FillerTimingBounds?
    @State private var dragTime: Double?
    @State private var dragEdge: FillerTimingEdge?
    @State private var showsToolbar = false
    @State private var toolbarEdge: FillerTimingEdge?

    private var bounds: FillerTimingBounds {
        guard let dragTime, let dragEdge, let dragOrigin,
              let value = model.mappedFillerBounds(review,
                start: dragEdge == .start ? dragTime : dragOrigin.alignedStart,
                end: dragEdge == .end ? dragTime : dragOrigin.alignedEnd) else { return review.bounds }
        return value
    }
    private var color: Color {
        review.decision == .rejected ? .secondary : review.decision == .reviewed ? .green : .orange
    }
    private func x(_ time: Double) -> Double { (time - start) / duration * size.width }

    var body: some View {
        let bounds = self.bounds
        let lo = max(0, x(bounds.alignedStart)), hi = min(size.width, x(bounds.alignedEnd))
        let detail = FillerMarkerDetail.make(width: hi - lo, neighborDistance: neighborDistance)
        let anchor = toolbarEdge.map { edge in
            handleFrame(edge, time: edge == .start ? bounds.alignedStart : bounds.alignedEnd)
        } ?? CGRect(x: lo, y: 0, width: max(1, hi - lo), height: size.height)
        ZStack(alignment: .topLeading) {
            if hi > lo, detail == .boundaries {
                Button {
                    model.selectFiller(review.id, reveal: false)
                    toolbarEdge = nil
                    showsToolbar = true
                } label: {
                    Rectangle().fill(color.opacity(model.selectedFillerID == review.id ? 0.23 : 0.1))
                        .frame(width: max(1, hi - lo), height: size.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: lo)
                .help("\(review.word?.text ?? "Manual filler") · \(review.status) · audible-word timing, not cut boundaries")
                .accessibilityLabel("\(review.word?.text ?? "Manual filler"), \(review.status), audible-word timing")
                .accessibilityValue(String(format: "%.6f to %.6f aligned seconds", bounds.alignedStart, bounds.alignedEnd))
                .accessibilityIdentifier("ww.cleanup.filler.\(review.id)")
            }
            Canvas { context, _ in
                for time in detail == .boundaries ? [bounds.alignedStart, bounds.alignedEnd] : [bounds.alignedStart] {
                    var rail = Path()
                    rail.move(to: CGPoint(x: x(time), y: 0))
                    rail.addLine(to: CGPoint(x: x(time), y: size.height))
                    context.stroke(rail, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
            }
            .allowsHitTesting(false)
            if detail == .boundaries {
                handle(.start, time: bounds.alignedStart)
                handle(.end, time: bounds.alignedEnd)
            } else if lo >= 0, lo <= size.width {
                Button {
                    model.selectFiller(review.id, reveal: false)
                    model.state.workspaceInspector = .transcript
                    model.state.inspectorPresented = true
                    if detail == .pole { showsToolbar = true }
                } label: {
                    Image(systemName: detail == .dot ? "circle.fill" : "text.bubble.fill")
                        .font(.system(size: detail == .dot ? 5 : 12))
                        .foregroundStyle(color)
                        .frame(width: detail == .dot ? 8 : 18, height: 18)
                }
                .buttonStyle(.plain).offset(x: lo - (detail == .dot ? 4 : 9))
                .accessibilityLabel("\(review.word?.text ?? "Manual filler"), \(review.status). Review in inspector or zoom in for timing handles.")
                .accessibilityIdentifier("ww.cleanup.filler.\(review.id)")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: review.id)
        .popover(isPresented: $showsToolbar, attachmentAnchor: .rect(.rect(anchor)), arrowEdge: .bottom) {
            FillerTimingToolbar(model: model, reviewID: review.id)
                .padding(12).frame(width: 370)
        }
        .onChange(of: model.selectedFillerID) { _, id in
            if id != review.id { showsToolbar = false }
        }
    }

    private func handleFrame(_ edge: FillerTimingEdge, time: Double) -> CGRect {
        CGRect(x: min(max(0, x(time) - 9), max(0, size.width - 18)),
               y: edge == .start ? 0 : max(0, size.height - 18),
               width: 18, height: 18)
    }

    @ViewBuilder
    private func handle(_ edge: FillerTimingEdge, time: Double) -> some View {
        if dragEdge == edge || (time >= start && time <= start + duration) {
            let frame = handleFrame(edge, time: time)
            Button {
                model.selectFiller(review.id, reveal: false)
                toolbarEdge = edge
                showsToolbar = true
            } label: {
                Image(systemName: edge == .start ? "arrow.right.to.line" : "arrow.left.to.line")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: frame.minX, y: frame.minY)
            .disabled(!model.canReviewFillers)
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(review.id))
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = review.bounds
                        dragEdge = edge
                        toolbarEdge = edge
                        showsToolbar = false
                        model.selectFiller(review.id, reveal: false)
                    }
                    if let dragOrigin {
                        let origin = edge == .start ? dragOrigin.alignedStart : dragOrigin.alignedEnd
                        dragTime = origin + value.translation.width / max(1, size.width) * duration
                    }
                }
                .onEnded { value in
                    if let dragOrigin {
                        let origin = edge == .start ? dragOrigin.alignedStart : dragOrigin.alignedEnd
                        let time = origin + value.translation.width / max(1, size.width) * duration
                        model.setFillerBounds(review.id,
                            start: edge == .start ? time : dragOrigin.alignedStart,
                            end: edge == .end ? time : dragOrigin.alignedEnd)
                    }
                    dragOrigin = nil
                    dragTime = nil
                    dragEdge = nil
                    showsToolbar = true
                })
            .onKeyPress(.leftArrow) { model.nudgeFiller(review.id, edge: edge, seconds: -0.001); return .handled }
            .onKeyPress(.rightArrow) { model.nudgeFiller(review.id, edge: edge, seconds: 0.001); return .handled }
            .accessibilityLabel("Filler audible-word \(edge == .start ? "start" : "end") handle")
            .accessibilityValue(String(format: "%.6f aligned seconds", time))
            .accessibilityAdjustableAction { direction in
                model.nudgeFiller(review.id, edge: edge, seconds: direction == .increment ? 0.001 : -0.001)
            }
            .accessibilityIdentifier("ww.cleanup.filler.\(review.id).\(edge == .start ? "start" : "end")")
            .help("Drag independently, or focus and use Left/Right for 1 ms. No amplitude snapping.")
        }
    }
}

struct FillerTimingToolbar: View {
    @Bindable var model: EpisodeCleanupModel
    let reviewID: UUID
    var accessibilityPrefix = "ww.cleanup.filler"

    var body: some View {
        if let review = model.fillerReviews.first(where: { $0.id == reviewID }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(review.word?.text ?? "Manual missed filler").font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(review.status).font(.caption)
                }
                Text("Audible-word bounds · not editorial cut boundaries").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "Current: %.6f–%.6f s", review.bounds.alignedStart, review.bounds.alignedEnd))
                if let issue = model.fillerIssue(review) {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    HStack {
                        Button("Word") { model.auditionFiller(review.id, context: 0) }
                            .accessibilityIdentifier("\(accessibilityPrefix).audition")
                        Button("With context") { model.auditionFiller(review.id) }
                            .help("Listen with up to 0.5 seconds of supported context on each side.")
                            .accessibilityIdentifier("\(accessibilityPrefix).context")
                    }
                    HStack {
                        Toggle("Loop", isOn: $model.loopsFillerAudition).toggleStyle(.checkbox)
                            .accessibilityIdentifier("\(accessibilityPrefix).loop")
                        if model.isPlaying || model.isPreparingPlayback {
                            Button("Stop") { model.stopPlayback() }
                                .accessibilityIdentifier("\(accessibilityPrefix).stop")
                        }
                    }
                    VStack(spacing: 5) {
                        edgeControls(.start)
                        edgeControls(.end)
                    }
                    Button("Apply audible-word bounds") { model.applyFillerText(reviewID: review.id) }
                        .accessibilityIdentifier("\(accessibilityPrefix).apply")
                    HStack {
                        Button(review.isAdjusted ? "Mark reviewed" : "Reviewed unchanged") {
                            model.decideFiller(review.id, decision: .reviewed)
                        }
                        .accessibilityIdentifier("\(accessibilityPrefix).reviewed")
                        Button("Not a filler") { model.decideFiller(review.id, decision: .rejected) }
                            .accessibilityIdentifier("\(accessibilityPrefix).reject")
                    }
                    HStack {
                        if review.detectedBounds != nil {
                            Button("Revert to detected") { model.revertFiller(review.id) }
                                .accessibilityIdentifier("\(accessibilityPrefix).revert")
                        }
                        Button("Needs review") { model.decideFiller(review.id, decision: .pending) }
                    }
                }
                if let detected = review.detectedBounds {
                    Text(String(format: "Detected: %.6f–%.6f s", detected.alignedStart, detected.alignedEnd))
                    Text("Detected source frames: [\(detected.sourceStartFrame), \(detected.sourceEndFrame))")
                    Text(String(format: "Human offset: start %+.3f ms · end %+.3f ms",
                        (review.bounds.alignedStart - detected.alignedStart) * 1000,
                        (review.bounds.alignedEnd - detected.alignedEnd) * 1000))
                } else {
                    Text("Manual proposal. No detected timing exists.")
                }
                Text("Current source frames: [\(review.bounds.sourceStartFrame), \(review.bounds.sourceEndFrame))")
                Text("Human reference data, not proof of phonetic ground truth. No audio or raw transcript is changed.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).controlSize(.small)
            .disabled(!model.canReviewFillers)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(accessibilityPrefix).toolbar")
        }
    }

    private func edgeControls(_ edge: FillerTimingEdge) -> some View {
        HStack {
            Text(edge == .start ? "Start" : "End").frame(width: 34, alignment: .leading)
            TextField("Aligned seconds", text: edge == .start ? $model.fillerStartText : $model.fillerEndText)
                .textFieldStyle(.roundedBorder).monospacedDigit()
                .accessibilityLabel("Filler audible-word \(edge == .start ? "start" : "end"), aligned seconds")
                .accessibilityIdentifier("\(accessibilityPrefix).\(edge == .start ? "start" : "end").seconds")
                .onSubmit { model.applyFillerText(reviewID: reviewID) }
            Button("-1 ms") { model.nudgeFiller(reviewID, edge: edge, seconds: -0.001) }
            Button("+1 ms") { model.nudgeFiller(reviewID, edge: edge, seconds: 0.001) }
        }
    }
}

struct FillerTimingReviewSummary: View {
    @Bindable var model: EpisodeCleanupModel
    @State private var showsSavedReviews = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); actions }
                VStack(alignment: .leading, spacing: 6) { heading; actions }
            }
            Text("Dotted rails mark proposed audible-word starts/ends for um, uh, erm and er. Click a region to review; drag each handle independently. Untimed text has no automatic rails.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.fillerReviews.isEmpty {
                Button {
                    showsSavedReviews.toggle()
                } label: {
                    Label("Saved reviews and retained history (\(model.fillerReviews.count))",
                          systemImage: showsSavedReviews ? "chevron.down" : "chevron.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsSavedReviews ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("ww.cleanup.fillers.history")
                if showsSavedReviews {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.fillerReviews) { review in
                            let issue = model.fillerIssue(review)
                            Button {
                                model.selectFiller(review.id)
                                model.state.inspectorPresented = true
                            } label: {
                                VStack(alignment: .leading) {
                                    let speaker = model.state.store.model.speaker(review.speaker)?.name ?? "Removed speaker"
                                    Text("\(speaker) · \(review.word?.text ?? "Manual filler") · \(review.status)")
                                    Text(String(format: "%.6f–%.6f s", review.bounds.alignedStart, review.bounds.alignedEnd))
                                        .monospacedDigit()
                                    if let issue { Text("Inactive: \(issue)").foregroundStyle(.orange) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ww.cleanup.filler.review.\(review.id)")
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.cleanup.fillers.review")
    }

    private var heading: some View {
        HStack {
            Text("Filler timing review").font(.callout.weight(.semibold))
            Text("\(model.fillerReviews.count) saved").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { findButton; manualButton }
            VStack(alignment: .leading) { findButton; manualButton }
        }
    }

    private var findButton: some View {
        Button("Find in saved transcript") { model.proposeFillers() }
            .disabled(!model.canReviewFillers)
            .help("Add exact-token suggestions to an existing current transcript without running inference. Existing decisions are preserved.")
            .accessibilityIdentifier("ww.cleanup.filler.find")
    }

    private var manualButton: some View {
        Button("Mark missed filler") { model.markMissedFiller() }
            .disabled(!model.canReviewFillers)
            .help("Select a word to mark its interval manually, or a speaker waveform to start a 200 ms manual interval at the playhead. Then adjust by listening.")
            .accessibilityIdentifier("ww.cleanup.filler.manual")
    }
}
