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
                if model.manualCuts.count > model.activeManualCuts.count {
                    Label("Saved cuts are inactive because accepted alignment changed. Undo the timing change to recover their original alignment.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
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
                Text("Recognizer timing is approximate. Cuts are manual: select a marker or interval, then use scissors to ripple every aligned track. Originals and raw transcripts remain unchanged.")
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
        .accessibilityIdentifier("ww.cleanup.workspace")
        .modifier(AudioTimelineFloatingToolbar(listening: model.listening,
            start: model.windowStart, duration: model.visibleDuration,
            play: { context in
                if let review = model.selectedFiller {
                    model.auditionFiller(review.id, context: context)
                } else if let range = model.listening.auditionRange(context: context, within: model.bounds) {
                    model.play(interval: range, loop: false)
                }
            }, cleanup: model))
        .wwFont(.body)
        .onAppear { state.cleanupModel = model }
        .task(id: model.episode.map { EpisodeMediaInputs($0, includingWorkingRange: true) }) {
            await model.refresh(skippingReviewOnlyChange: true)
        }
        .onChange(of: model.listening.playback) { _, _ in model.updateGains() }
        .onChange(of: model.episode?.cleanup?.manualCuts) { _, _ in
            model.modelDidChange()
            model.loadWaveforms()
            if model.overviewStrokes.isEmpty { model.loadWaveforms(overview: true) }
        }
        .onDisappear {
            model.cancelTranscription()
            if state.cleanupModel === model { state.cleanupModel = nil }
        }
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
            seek: { model.seek(to: $0) }, isEdited: !model.cutTimeline.removals.isEmpty
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
            commitWindow: { model.loadWaveforms() }, isEdited: !model.cutTimeline.removals.isEmpty
        )
    }

    private var rangeMarkers: [AudioTimelineMarker] {
        let range = model.episode?.cleanup?.workingRange
        return [
            range?.tracksIn.map { AudioTimelineMarker(id: "in", time: model.cutTimeline.editedTime(forAlignedTime: $0), title: "IN", color: .yellow) },
            range?.tracksOut.map { AudioTimelineMarker(id: "out", time: model.cutTimeline.editedTime(forAlignedTime: $0), title: "OUT", color: .yellow) },
        ].compactMap { $0 }
    }

    private func laneView(_ lane: CleanupSpeakerLane) -> some View {
        let uncertainIDs = model.uncertainWordIDs(for: lane)
        return AudioTimelineTrackRow(headerWidth: headerWidth) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    SpeakerAvatarView(name: lane.name, appearance: state.store.model.speakerAppearance(
                        lane.speaker, in: model.episodeID) ?? .init(color: .defaultColor(for: lane.speaker)))
                    Text(lane.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !uncertainIDs.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Contains uncertain repetitive recognition")
                            .help(EpisodeCleanupModel.repetitionReviewExplanation)
                    }
                }
                AudioTimelineListeningButtons(listening: model.listening, scope: .speaker(lane.speaker),
                                              name: lane.name, changed: { model.updateGains() })
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
                CleanupWaveform(index: model.waveformIndex(for: lane.speaker), snapshot: model.waveformSnapshot,
                    start: model.windowStart,
                    duration: model.visibleDuration,
                    playhead: model.playhead, range: model.episode?.cleanup?.workingRange,
                    selectedRange: model.selectedSpeaker == lane.speaker ? selectedWordRange : nil,
                    regions: lane.regions, normalized: model.normalizeView,
                    muted: model.mutedSpeakers.contains(lane.speaker), displayScale: displayScale,
                    color: state.store.model.speakerAppearance(lane.speaker, in: model.episodeID)?.color.swiftUIColor ?? .accentColor,
                    cuts: model.cutTimeline) {
                    guard model.canNavigate else { return }
                    model.selectedSpeaker = lane.speaker
                    model.selectedWord = nil
                    model.selectedFillerID = nil
                    model.timelineClick(at: $0)
                }
                .frame(height: model.laneHeight)
                .overlay {
                    ManualCutMarkers(model: model) { model.selectedSpeaker = lane.speaker }
                }
                .overlay {
                    FillerTimingOverlay(model: model, reviews: model.visibleFillers(for: lane))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(lane.name), aligned Primary waveform")
                .accessibilityValue("Measured Primary channel; hatched intervals have no accepted timing. Click to seek or set In/Out. Dotted filler rails have independent timing handles; red scissors mark manual cross-track cuts.")
                .accessibilityIdentifier("ww.cleanup.waveform.\(lane.id)")
                .anchorPreference(key: AudioTimelineToolbarAnchor.self, value: .bounds) {
                    (model.selectedSpeaker ?? model.plan?.lanes.first?.speaker) == lane.speaker
                        && (model.listening.selection != nil || model.selectedManualCut != nil) ? $0 : nil
                }
                if let transcript = model.transcript(for: lane) {
                    wordStrip(lane, words: transcript.words, uncertainIDs: uncertainIDs)
                    if !uncertainIDs.isEmpty,
                       (model.visibleWords(for: lane) + transcript.words.filter { $0.alignedStart == nil })
                        .contains(where: { uncertainIDs.contains($0.id) }) {
                        Label("Uncertain recognition: repetitive output. Listen to verify; raw text is preserved.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .help(EpisodeCleanupModel.repetitionReviewExplanation)
                            .accessibilityIdentifier("ww.cleanup.recognition.warning.\(lane.id)")
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
        .zIndex(model.selectedFiller?.speaker == lane.speaker ? 1 : 0)
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
            }, uncertainWordIDs: uncertainIDs, cuts: model.cutTimeline, sourceBounds: lane.start...lane.end,
            selectUnit: { model.select($0, speaker: lane.speaker) })
            .accessibilityIdentifier("ww.cleanup.words.\(lane.id)")
    }

    private var selectedWordRange: ClosedRange<Double>? {
        guard let a = model.selectedWord?.alignedStart, let b = model.selectedWord?.alignedEnd,
              a.isFinite, b.isFinite, b > a else { return nil }
        return model.displayRange(start: a, end: b)
    }
}

private struct CleanupWaveform: View {
    let index: AlignmentWaveformStrokeIndex
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
    var color: Color = .accentColor
    var cuts: ManualCutTimeline = .unedited
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                color.opacity(0.045)
                AudioTimelineWaveformDrawing(
                    snapshot: snapshot, index: index, size: geometry.size,
                    start: start, duration: duration,
                    color: muted ? color.opacity(0.45) : color, lineWidth: 1,
                    gain: normalized ? index.normalizedGain : 1,
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
                    for marker in [range?.tracksIn, range?.tracksOut].compactMap({ $0 }).map({ cuts.editedTime(forAlignedTime: $0) }) {
                        context.fill(Path(CGRect(x: x(marker), y: 0, width: 2, height: size.height)),
                                     with: .color(.yellow))
                    }
                    if let raw = range?.tracksIn {
                        let markIn = cuts.editedTime(forAlignedTime: raw)
                        context.fill(Path(CGRect(x: 0, y: 0, width: max(0, min(size.width, x(markIn))), height: size.height)),
                                     with: .color(.secondary.opacity(0.15)))
                    }
                    if let raw = range?.tracksOut {
                        let markOut = cuts.editedTime(forAlignedTime: raw)
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
                        let lo = max(start, cuts.editedTime(forAlignedTime: region.alignedStart))
                        let hi = min(start + duration, cuts.editedTime(forAlignedTime: region.alignedEnd))
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
            Text("Transcript & Review").wwFont(.headline)
            Picker("Speaker", selection: $model.selectedSpeaker) {
                Text("Choose a speaker").tag(Optional<SpeakerID>.none)
                ForEach(model.episode?.speakerAssignments ?? [], id: \.speakerID) { assignment in
                    Text(model.state.store.model.speaker(assignment.speakerID)?.name ?? "Speaker")
                        .tag(Optional(assignment.speakerID))
                }
            }
            if let text = model.listening.selectedTranscriptText {
                Text(text).textSelection(.enabled)
            }
            if model.listening.selection != nil {
                HStack {
                    Button("Play selection", systemImage: "play.fill") {
                        if let range = model.listening.auditionRange(context: 0, within: model.bounds) {
                            model.play(interval: range, loop: false)
                        }
                    }
                    Button("With context", systemImage: "play.rectangle") {
                        if let range = model.listening.auditionRange(context: 0.5, within: model.bounds) {
                            model.play(interval: range, loop: false)
                        }
                    }
                }.controlSize(.small)
            }
            FillerTimingReviewSummary(model: model)
            if let review = model.selectedFiller {
                Text("\(review.word?.text ?? "Manual filler") · \(review.status)")
                    .font(.callout.weight(.semibold))
                Text("Review with the marker toolbar; drag its audible-word handles to adjust. No audio or transcript is deleted.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Select a transcript phrase, a speaker, or a filler marker to review it.")
            }
            Divider()
            transcriptReading
            Text("Recognition is approximate. Review by listening; no cuts are applied and original recordings remain unchanged.")
        }
        .wwFont(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transcriptReading: some View {
        let active = model.episode?.cleanup?.transcripts.filter {
            model.selectedSpeaker == nil || $0.speaker == model.selectedSpeaker
        } ?? []
        ForEach(active) { transcript in
            Text(model.state.store.model.speaker(transcript.speaker)?.name ?? "Speaker").font(.headline)
            if model.plan?.lanes.first(where: { $0.speaker == transcript.speaker })
                .flatMap({ model.transcript(for: $0) }) == nil {
                Label("Retained transcript: source or timing verification is no longer current.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text(transcript.words.map(\.text).joined(separator: " "))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ww.transcript.full.\(transcript.id)")
            let untimed = transcript.words.filter { $0.alignedStart == nil }
            if !untimed.isEmpty {
                DisclosureGroup("Speech without reliable timing (\(untimed.count))") {
                    Text("This raw recognition cannot be placed on the waveform. It may repeat overlapping recognition windows. Listen to the source, or transcribe again after verifying alignment; the original text is retained.")
                        .font(.caption)
                    Text(untimed.map(\.text).joined(separator: " ")).textSelection(.enabled)
                    Button("Transcribe again") { model.transcribe() }.disabled(!model.canTranscribe)
                }
            }
        }
        let history = model.episode?.cleanup?.transcriptHistory?.filter {
            model.selectedSpeaker == nil || $0.speaker == model.selectedSpeaker
        } ?? []
        if !history.isEmpty {
            DisclosureGroup("Earlier transcripts (\(history.count))") {
                ForEach(history) { transcript in
                    DisclosureGroup("\(model.state.store.model.speaker(transcript.speaker)?.name ?? "Speaker") · revision \(transcript.alignmentRevision) · \(transcript.model)") {
                        Text(transcript.words.map(\.text).joined(separator: " ")).textSelection(.enabled)
                        Text("Historical recognition; not asserted to match current source timing.").font(.caption)
                    }
                }
            }
        }
    }
}
