import SwiftUI
import WWCore
import WWSpeech

struct EpisodeCleanupContent: View {
    @Bindable var state: ShowWindowState
    @State private var model: EpisodeCleanupModel
    @State private var showsPrecisionRange = false
    @Environment(\.displayScale) private var displayScale

    private let headerWidth: CGFloat = 190

    init(state: ShowWindowState, episodeID: EpisodeID, runtime: AlignmentRuntime? = nil) {
        self.state = state
        _model = State(initialValue: EpisodeCleanupModel(state: state, episodeID: episodeID, runtime: runtime))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Edit & Cleanup")
                        .wwFont(.title2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ww.cleanup.heading")
                    Spacer()
                    Text("Aligned Primaries · nondestructive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                readiness
                engineControls
                transport
                navigation
                markerControls
                FillerTimingReviewSummary(model: model)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        showsPrecisionRange.toggle()
                    } label: {
                        Label("Precise Tracks In / Out",
                              systemImage: showsPrecisionRange ? "chevron.down" : "chevron.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .accessibilityValue(showsPrecisionRange ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("ww.cleanup.range.precision")
                    if showsPrecisionRange { workingRange }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("ww.cleanup.error")
                }
                VStack(spacing: 0) {
                    ruler
                    if let plan = model.plan {
                        ForEach(plan.lanes) { lane in
                            laneView(lane)
                            Divider()
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ww.cleanup.timeline")
                if model.isLoadingOverview {
                    ProgressView("Preparing full Primary waveforms…").controlSize(.small)
                }
                Text(model.waveformMessage).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ww.cleanup.loadedWindow")
                if !model.isBusy {
                    Text(model.message)
                        .wwFont(.caption)
                        .accessibilityIdentifier("ww.cleanup.status")
                }
                Text("Recognizer timing is approximate, not cut-qualified. Filler review captures audible-word bounds only; this view never applies a cut.")
                    .wwFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isBusy { transcriptionProgress }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .wwFont(.body)
        .onAppear { state.cleanupModel = model }
        .task(id: state.store.modelGeneration) { await model.refresh(skippingReviewOnlyChange: true) }
        .onDisappear {
            model.cancel()
            if state.cleanupModel === model { state.cleanupModel = nil }
        }
        .accessibilityIdentifier("ww.cleanup.workspace")
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 5) {
                if model.isRefreshing {
                    ProgressView("Verifying accepted timing and source access…").controlSize(.small)
                } else if model.plan?.isReady == true {
                    Label("Every Primary is aligned in the working range", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("ww.cleanup.ready")
                } else {
                    ForEach(model.plan?.blockers ?? ["Source and timing verification is required."], id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    Button("Go to Alignment") { state.select(.alignment) }
                    Button("Manage Recordings") { state.select(.setup) }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.isBusy)
                }
                .controlSize(.small)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workingRange: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { inField; outField }
                VStack(alignment: .leading) { inField; outField }
            }
            HStack {
                Button("Apply Range") { model.applyRangeText() }
                    .accessibilityIdentifier("ww.cleanup.range.apply")
                Button("Reset Range") { model.saveRange(inValue: nil, outValue: nil) }
                    .accessibilityIdentifier("ww.cleanup.range.reset")
            }
            Text("Blank ends include the available recording. A timing change requires resetting or re-setting these markers.")
                .wwFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy || !state.canEdit || model.episode?.alignment?.acceptedRevision == nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inField: some View {
        HStack {
            TextField("Tracks In", text: $model.inText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tracks In, aligned seconds")
                .accessibilityIdentifier("ww.cleanup.tracksIn")
                .onSubmit { model.applyRangeText() }
            Button("In at Playhead", systemImage: "arrow.right.to.line") {
                model.markIn()
            }
        }
    }

    private var outField: some View {
        HStack {
            TextField("Tracks Out", text: $model.outText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tracks Out, aligned seconds")
                .accessibilityIdentifier("ww.cleanup.tracksOut")
                .onSubmit { model.applyRangeText() }
            Button("Out at Playhead", systemImage: "arrow.left.to.line") {
                model.markOut()
            }
        }
    }

    private var engineControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { modelControls; transcriptionControls }
                VStack(alignment: .leading) { modelControls; transcriptionControls }
            }
            if model.transcriptionSettings.selectedURL == nil {
                Text("Download the selected model in Settings > Transcription before transcribing.")
                    .wwFont(.caption).foregroundStyle(.secondary)
            }
            if let error = model.transcriptionSettings.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
    }

    private var modelControls: some View {
        HStack {
            Text(model.transcriptionSettings.selection.title).font(.callout)
                .accessibilityIdentifier("ww.cleanup.model")
            Button("Transcription Settings…", systemImage: "gearshape") {
                SettingsWindowController.show(pane: .transcription)
            }
            .accessibilityIdentifier("ww.cleanup.settings")
        }
    }

    private var transcriptionControls: some View {
        HStack {
            Button("Transcribe Episode") { model.transcribe() }
                .disabled(!model.canTranscribe)
                .help("Transcribe every aligned Primary locally, retaining fillers. No uploads or automatic cuts.")
                .accessibilityIdentifier("ww.cleanup.transcribe")
        }
    }

    private var transcriptionProgress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(model.message).font(.callout.weight(.semibold))
                        .accessibilityIdentifier("ww.cleanup.status")
                    Spacer()
                    Button("Cancel Transcription") {
                        model.cancel()
                        model.message = "Transcription canceled. No partial result was saved."
                    }
                    .accessibilityIdentifier("ww.cleanup.cancel")
                }
                let status = model.transcriptionStatus
                let update = status?.progress
                ProgressView(value: update?.fraction ?? 0)
                    .accessibilityLabel("Episode transcription: completed aligned audio across all speakers")
                    .accessibilityIdentifier("ww.cleanup.progress")
                if let update {
                    Text("\(Int(update.fraction * 100))% audio processed | \(CleanupTranscriptionStatus.time(update.completedSeconds)) of \(CleanupTranscriptionStatus.time(update.totalSeconds)) across all speakers")
                        .monospacedDigit()
                    if update.stage != .verifying {
                        Text("\(update.activeSpeakers.count) active speakers | Up to \(update.workerLimit) workers for this job | \(update.speakerCount) speakers total")
                        ForEach(update.activeSpeakers) { speaker in
                            if speaker.stage == .loading {
                                Text("\(speaker.speaker) | Verifying and loading local weights")
                            } else {
                                Text("\(speaker.speaker) | \(speaker.stage == .rendering ? "Preparing" : "Transcribing") chunk \(speaker.chunkDescription) | Aligned \(AlignmentPresentation.formatTime(speaker.alignedStart)) to \(AlignmentPresentation.formatTime(speaker.alignedEnd))")
                            }
                        }
                    }
                }
                if let status {
                    let estimate = status.estimatedRemaining(at: timeline.date)
                    Text("Elapsed \(CleanupTranscriptionStatus.time(status.elapsed(at: timeline.date))) | \(update?.stage == .verifying ? "Finishing verification…" : estimate.map { "About \(CleanupTranscriptionStatus.time($0)) remaining" } ?? "Estimating remaining time…") | \(model.activeModelName ?? "Whisper")")
                        .monospacedDigit()
                }
                Text("Progress advances after each completed audio chunk. Remaining time is an estimate; no partial transcript is saved.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .accessibilityIdentifier("ww.cleanup.progressPanel")
    }

    private var transport: some View {
        AudioTimelineTransport(
            prefix: "ww.cleanup", isPlaying: model.isPlaying, isPreparing: model.isPreparingPlayback,
            canPlay: model.canNavigate, canNavigate: model.canNavigate,
            playhead: model.playhead, status: model.transportMessage,
            back: { model.seek(to: model.playhead - 5) },
            playPause: {
                model.isPlaying || model.isPreparingPlayback ? model.stopPlayback() : model.play()
            },
            stop: { model.stop() }, forward: { model.seek(to: model.playhead + 5) },
            seek: { model.seek(to: $0) }
        )
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack { normalization; navigationControls }
            VStack(alignment: .leading) { normalization; navigationControls }
        }
    }

    private var normalization: some View {
        Toggle("Normalize view", isOn: $model.normalizeView)
            .toggleStyle(.checkbox)
            .help("Scales displayed peaks only. Playback and original audio are unchanged.")
            .accessibilityIdentifier("ww.cleanup.normalizeView")
    }

    private var navigationControls: some View {
        AudioTimelineNavigation(
            prefix: "ww.cleanup", maximumDuration: model.maximumDuration,
            duration: Binding(get: { model.windowDuration }, set: { value in
                model.zoomTimeline(duration: value)
            }),
            laneHeight: $model.laneHeight, showsLaneHeight: true,
            isLoading: model.isLoadingWaveforms || model.isLoadingOverview, canNavigate: model.canNavigate,
            zoomEditing: { editing in if !editing { model.loadWaveforms() } },
            fit: { model.fitTimeline() },
            refresh: {
                model.isLoadingWaveforms || model.isLoadingOverview
                    ? model.cancelWaveforms() : model.refreshWaveforms()
            }
        )
    }

    private var markerControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                markerTools
                markerAtPlayhead
                Spacer(minLength: 0)
                rangeSummary
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack { markerTools; Spacer(minLength: 0); rangeSummary }
                markerAtPlayhead
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!model.canNavigate || !state.canEdit)
    }

    private var markerTools: some View {
        HStack(spacing: 8) {
            ForEach(CleanupTimelineTool.allCases, id: \.self) { tool in
                Button(tool.rawValue, systemImage: tool == .seek ? "cursorarrow"
                       : tool == .markIn ? "arrow.right.to.line" : "arrow.left.to.line") {
                    model.timelineTool = tool
                }
                .tint(model.timelineTool == tool ? .accentColor : .secondary)
                .accessibilityAddTraits(model.timelineTool == tool ? .isSelected : [])
                .accessibilityIdentifier("ww.cleanup.tool.\(tool == .seek ? "seek" : tool == .markIn ? "in" : "out")")
                .help(tool == .seek ? "Click a waveform or ruler to seek."
                      : "Select this tool, then click a waveform or ruler to set \(tool.rawValue) on every Primary.")
            }
        }
        .labelStyle(.iconOnly)
    }

    private var markerAtPlayhead: some View {
        HStack(spacing: 8) {
            Button("In at Playhead", systemImage: "arrow.right.to.line") { model.markIn() }
                .accessibilityIdentifier("ww.cleanup.range.markIn")
            Button("Out at Playhead", systemImage: "arrow.left.to.line") { model.markOut() }
                .accessibilityIdentifier("ww.cleanup.range.markOut")
        }
    }

    private var rangeSummary: some View {
        Text("IN \(rangeTime(model.episode?.cleanup?.workingRange?.tracksIn))  OUT \(rangeTime(model.episode?.cleanup?.workingRange?.tracksOut))")
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("ww.cleanup.range.summary")
    }

    private func rangeTime(_ time: Double?) -> String {
        time.map { String(format: "%.3f", $0) } ?? "—"
    }

    private var ruler: some View {
        AudioTimelineRuler(
            prefix: "ww.cleanup", headerWidth: headerWidth,
            start: model.windowStart, duration: model.windowDuration, playhead: model.playhead,
            bounds: model.bounds, seekBounds: model.bounds, maximumDuration: model.maximumDuration,
            isPlaying: model.isPlaying, canNavigate: model.canNavigate, markers: rangeMarkers,
            clicked: { model.timelineClick(at: $0) },
            previewSeek: { model.previewSeek(to: $0) }, resumePlayback: { model.play() },
            previewPan: { model.setWindow(start: $0, duration: model.windowDuration) },
            setWindow: { _, duration in model.zoomTimeline(duration: duration) },
            commitWindow: { model.loadWaveforms() }
        )
    }

    private var rangeMarkers: [AudioTimelineMarker] {
        let range = model.episode?.cleanup?.workingRange
        return [
            range?.tracksIn.map { AudioTimelineMarker(id: "in", time: $0, title: "IN", color: .orange) },
            range?.tracksOut.map { AudioTimelineMarker(id: "out", time: $0, title: "OUT", color: .orange) },
        ].compactMap { $0 }
    }

    private func laneView(_ lane: CleanupSpeakerLane) -> some View {
        let uncertainIDs = model.uncertainWordIDs(for: lane)
        return AudioTimelineTrackRow(headerWidth: headerWidth) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Toggle("", isOn: Binding(
                        get: { !model.mutedSpeakers.contains(lane.speaker) },
                        set: { model.setSpeaker(lane.speaker, enabled: $0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Hear \(lane.name)")
                    .accessibilityIdentifier("ww.cleanup.enabled.\(lane.id)")
                    Text(lane.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !uncertainIDs.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Contains uncertain repetitive recognition")
                            .help(EpisodeCleanupModel.repetitionReviewExplanation)
                    }
                }
                Text("\(lane.sourceName) · Primary · Channel \((lane.primary.channel.value ?? 0) + 1)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("Details", systemImage: "info.circle") {
                        model.selectedSpeaker = lane.speaker
                        model.selectedWord = nil
                        model.selectedFillerID = nil
                        state.inspectorPresented = true
                    }
                    .buttonStyle(.plain)
                    if model.mutedSpeakers.contains(lane.speaker) {
                        Text("Muted").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            .padding(.vertical, 6)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                CleanupWaveform(strokes: model.strokes(for: lane.speaker), snapshot: model.waveformSnapshot,
                    start: model.windowStart,
                    duration: model.visibleDuration,
                    playhead: model.playhead, range: model.episode?.cleanup?.workingRange,
                    selectedRange: model.selectedSpeaker == lane.speaker ? selectedWordRange : nil,
                    regions: lane.regions, normalized: model.normalizeView,
                    muted: model.mutedSpeakers.contains(lane.speaker), displayScale: displayScale) {
                    guard model.canNavigate else { return }
                    model.selectedSpeaker = lane.speaker
                    model.selectedWord = nil
                    model.selectedFillerID = nil
                    model.timelineClick(at: $0)
                }
                .frame(height: model.laneHeight)
                .overlay {
                    FillerTimingOverlay(model: model, reviews: model.visibleFillers(for: lane))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(lane.name), aligned Primary waveform")
                .accessibilityValue("Measured Primary channel; hatched intervals have no accepted timing. Click to seek or set In/Out. Dotted filler rails have independent timing handles; no track dragging or cuts.")
                .accessibilityIdentifier("ww.cleanup.waveform.\(lane.id)")
                if let transcript = model.transcript(for: lane) {
                    let visibleWords = model.visibleWords(for: lane)
                    let untimed = transcript.words.filter { $0.alignedStart == nil }
                    if !visibleWords.isEmpty {
                        wordStrip(lane, words: visibleWords, uncertainIDs: uncertainIDs)
                    }
                    if (visibleWords + untimed).contains(where: { uncertainIDs.contains($0.id) }) {
                        Label("Uncertain recognition: repetitive output. Listen to verify; raw text is preserved.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .help(EpisodeCleanupModel.repetitionReviewExplanation)
                            .accessibilityIdentifier("ww.cleanup.recognition.warning.\(lane.id)")
                    }
                    DisclosureGroup("Transcript for visible window") {
                        Text(visibleWords.map(\.text).joined(separator: " "))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !untimed.isEmpty {
                        DisclosureGroup("\(untimed.count) untimed segments — overlapping windows may repeat text") {
                            Text(untimed.map(\.text).joined(separator: " ")).textSelection(.enabled)
                        }
                    }
                } else {
                    Text(model.episode?.cleanup?.transcripts.contains(where: { $0.speaker == lane.speaker }) == true
                        ? "Transcript stale or outside its analyzed range. Verify sources/timing, then transcribe again."
                        : "Not transcribed yet")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.cleanup.speaker.\(lane.id)")
    }

    private func wordStrip(_ lane: CleanupSpeakerLane, words: [TranscriptWord],
                           uncertainIDs: Set<UUID>) -> some View {
        AudioTimelineWords(words: words, start: model.windowStart,
            duration: model.visibleDuration, selectedWord: model.selectedWord?.id,
            select: { model.select($0, speaker: lane.speaker) },
            zoom: { time in
                model.seek(to: time)
                model.zoomTimeline(duration: min(5, model.maximumDuration))
            }, uncertainWordIDs: uncertainIDs)
            .accessibilityIdentifier("ww.cleanup.words.\(lane.id)")
    }

    private var selectedWordRange: ClosedRange<Double>? {
        guard let a = model.selectedWord?.alignedStart, let b = model.selectedWord?.alignedEnd,
              a.isFinite, b.isFinite, b > a else { return nil }
        return a...b
    }
}

private struct CleanupWaveform: View {
    let strokes: [AlignmentWaveformStroke]
    let snapshot: UUID
    let start: Double
    let duration: Double
    let playhead: Double
    let range: EpisodeWorkingRange?
    let selectedRange: ClosedRange<Double>?
    let regions: [CleanupTimingRegion]
    let normalized: Bool
    let muted: Bool
    let displayScale: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.025)
                AudioTimelineWaveformDrawing(
                    snapshot: snapshot, strokes: strokes, size: geometry.size,
                    start: start, duration: duration,
                    color: muted ? .secondary : .accentColor, lineWidth: 1,
                    gain: AlignmentWaveformProjection.displayGain(for: strokes, normalized: normalized),
                    displayScale: displayScale
                )
                .equatable()
                Canvas { context, size in
                    guard size.width > 0, start.isFinite, duration.isFinite, duration > 0 else { return }
                    let x: (Double) -> Double = { ($0 - start) / duration * size.width }
                    if let selectedRange {
                        let lo = max(0, x(selectedRange.lowerBound)), hi = min(size.width, x(selectedRange.upperBound))
                        if hi > lo {
                            context.fill(Path(CGRect(x: lo, y: 0, width: hi - lo, height: size.height)),
                                         with: .color(.accentColor.opacity(0.16)))
                        }
                    }
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                    baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    for marker in [range?.tracksIn, range?.tracksOut].compactMap({ $0 }) {
                        context.fill(Path(CGRect(x: x(marker), y: 0, width: 2, height: size.height)),
                                     with: .color(.orange))
                    }
                    if let markIn = range?.tracksIn {
                        context.fill(Path(CGRect(x: 0, y: 0, width: max(0, min(size.width, x(markIn))), height: size.height)),
                                     with: .color(.secondary.opacity(0.15)))
                    }
                    if let markOut = range?.tracksOut {
                        let lower = max(0, min(size.width, x(markOut)))
                        context.fill(Path(CGRect(x: lower, y: 0, width: size.width - lower, height: size.height)),
                                     with: .color(.secondary.opacity(0.15)))
                    }
                    if (start...(start + duration)).contains(playhead) {
                        context.fill(Path(CGRect(x: x(playhead), y: 0, width: 1.5, height: size.height)),
                                     with: .color(.primary))
                    }
                    var gaps = Path()
                    var cursor = start
                    for region in regions.sorted(by: { $0.alignedStart < $1.alignedStart }) {
                        let lo = max(start, region.alignedStart), hi = min(start + duration, region.alignedEnd)
                        guard hi > lo else { continue }
                        if lo > cursor { gaps.addRect(CGRect(x: x(cursor), y: 0, width: x(lo) - x(cursor), height: size.height)) }
                        cursor = max(cursor, hi)
                    }
                    if cursor < start + duration {
                        gaps.addRect(CGRect(x: x(cursor), y: 0, width: size.width - x(cursor), height: size.height))
                    }
                    context.clip(to: gaps)
                    var hatch = Path()
                    for column in stride(from: -size.height, to: size.width, by: 10) {
                        hatch.move(to: CGPoint(x: column, y: size.height))
                        hatch.addLine(to: CGPoint(x: column + size.height, y: 0))
                    }
                    context.stroke(hatch, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { point in
                seek(start + max(0, min(1, point.x / max(1, geometry.size.width))) * duration)
            }
        }
    }
}

struct CleanupInspectorView: View {
    @Bindable var model: EpisodeCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker & Word").wwFont(.headline)
            if let review = model.selectedFiller {
                FillerTimingToolbar(model: model, reviewID: review.id, accessibilityPrefix: "ww.cleanup.filler.inspector")
                DisclosureGroup("Captured review origin") {
                    Text(review.origin == .detected ? "Automatically detected" : "Manually proposed")
                    Text("Source: \(review.primary.sourceID.description)")
                    Text("Source identity: \(review.sourceIdentity)")
                    Text("Alignment revision: \(review.alignmentRevision)")
                    if let transcript = review.transcriptID { Text("Transcript: \(transcript)") }
                    if let word = review.word { Text("Word: \(word.id)") }
                    if let recipe = review.modelRecipe { Text(recipe) }
                    if let recipe = review.detectorRecipe { Text(recipe) }
                    Text("Initial source frames: [\(review.initialBounds.sourceStartFrame), \(review.initialBounds.sourceEndFrame))")
                    Text(String(format: "Initial aligned bounds: %.6f–%.6f s",
                                review.initialBounds.alignedStart, review.initialBounds.alignedEnd))
                }
                .font(.caption).textSelection(.enabled)
                Divider()
            }
            if let lane = model.plan?.lanes.first(where: { $0.speaker == model.selectedSpeaker }) {
                Text(lane.name).wwFont(.headline)
                Text(lane.sourceName).textSelection(.enabled)
                Text("Primary · Channel \((lane.primary.channel.value ?? 0) + 1)")
                Text("Source rate: \(lane.sourceRate) Hz")
                Text("Alignment revision: \(model.plan?.alignmentRevision ?? 0)")
                let uncertainIDs = model.uncertainWordIDs(for: lane)
                if !uncertainIDs.isEmpty {
                    Label("\(uncertainIDs.count) words/segments need recognition review",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(EpisodeCleanupModel.repetitionReviewExplanation).font(.caption)
                }
                if let word = model.selectedWord {
                    Divider()
                    Text(word.text).textSelection(.enabled)
                    if uncertainIDs.contains(word.id) {
                        Label("Uncertain recognition: repetitive output", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("ww.cleanup.word.uncertain")
                    }
                    if let a = word.alignedStart, let b = word.alignedEnd {
                        Text("Aligned: \(a, specifier: "%.3f")–\(b, specifier: "%.3f") s")
                    }
                    if let a = word.sourceStartFrame, let b = word.sourceEndFrame {
                        Text("Source frames: [\(a), \(b))")
                    }
                    Text("Approximate recognizer timing. Not a supported cut boundary.")
                }
            } else {
                Text("Select a word or a speaker's Details button.")
            }
            Divider()
            Text("Full cuts will shorten all lanes together. Speaker-only cuts will preserve everyone else's timing. Neither is enabled by transcription.")
        }
        .wwFont(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
