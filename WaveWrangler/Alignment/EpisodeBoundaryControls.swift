import SwiftUI
import WWCommonEdit
import WWCore

struct EpisodeBoundaryControls: View {
    @Bindable var model: EpisodeAlignmentModel
    var cleanup: EpisodeCleanupModel?
    @State private var editing = false

    private var editor: AudioClipEditorModel { model.audioEditor }
    private var writable: Bool {
        editor.store.canEdit && !model.isWorking && cleanup?.isBusy != true
    }

    var body: some View {
        Menu("Boundaries", systemImage: "arrow.left.and.right") {
            boundaryMenu(start: true)
            boundaryMenu(start: false)
            Divider()
            speakerMenu(start: true)
            speakerMenu(start: false)
            Divider()
            Toggle("Restrict spoken tracks to Speaker In/Out", isOn: Binding(
                get: { editor.episode?.productionRange?.restrictSpeech == true },
                set: { enabled in
                    var range = editor.episode?.productionRange ?? .init()
                    range.restrictSpeech = enabled
                    _ = editor.setProductionRange(range)
                }))
                .disabled(!writable)
                .accessibilityIdentifier("ww.boundaries.restrictSpeech")
            Button("Edit Boundary Times…") { editing = true }
                .disabled(!writable || editor.production == nil)
                .accessibilityIdentifier("ww.boundaries.edit")
        }
        .fixedSize()
        .accessibilityIdentifier("ww.audioWorkspace.boundaries")
        .help("Episode Start/End bounds the mix. Optional speech restriction silences spoken tracks outside Speaker In/Out; music and master effect tails may continue. Stop silences everything immediately.")
        .popover(isPresented: $editing) { EpisodeBoundaryEditor(model: model, cleanup: cleanup) }
    }

    private func boundaryMenu(start: Bool) -> some View {
        let name = start ? "Episode Start" : "Episode End"
        let frame = start ? editor.production?.episodeFrames?.lowerBound : editor.production?.episodeFrames?.upperBound
        let automatic = (start ? editor.episode?.productionRange?.start : editor.episode?.productionRange?.end) == nil
        return Menu(name + (automatic ? " · Automatic" : " · Manual")) {
            Button("Set \(name) at Playhead") {
                guard let program = model.productionProgramTime(atDisplayTime: model.waveformPlayheadSeconds) else { return }
                editor.setEpisodeBoundary(start: start, programSeconds: program)
            }
            .disabled(!writable)
            .accessibilityIdentifier("ww.boundaries.\(start ? "start" : "end").set")
            Button("Go to \(name)") {
                guard let frame else { return }
                model.seekEnabledTracks(to: model.presentationTimeline.displayTime(forProgramTime: Double(frame) / 48_000))
            }
            .disabled(frame == nil)
            Button("Reset \(name) to Automatic") { editor.setEpisodeBoundary(start: start, programSeconds: nil) }
                .disabled(!writable || automatic)
        }
    }

    private func speakerMenu(start: Bool) -> some View {
        let name = start ? "Speaker In" : "Speaker Out"
        let range = cleanup?.episode?.cleanup?.workingRange
        let seconds = start ? range?.tracksIn : range?.tracksOut
        let projected = start ? editor.production?.speakerProgramFrames?.lowerBound : editor.production?.speakerProgramFrames?.upperBound
        return Menu(name) {
            Button("Set \(name) at Playhead") {
                guard let cleanup, let aligned = model.speakerBoundaryTime(
                    atDisplayTime: model.waveformPlayheadSeconds, start: start) else { return }
                cleanup.saveRange(inValue: start ? aligned : range?.tracksIn,
                                  outValue: start ? range?.tracksOut : aligned)
            }
            .disabled(!writable || cleanup == nil)
            .accessibilityIdentifier("ww.boundaries.\(start ? "speakerIn" : "speakerOut").set")
            Button("Go to \(name)") {
                guard let projected else { return }
                model.seekEnabledTracks(to: model.presentationTimeline.displayTime(forProgramTime: Double(projected) / 48_000))
            }
            .disabled(projected == nil)
            Button("Reset \(name) to Automatic") {
                cleanup?.saveRange(inValue: start ? nil : range?.tracksIn,
                                   outValue: start ? range?.tracksOut : nil)
            }
            .disabled(!writable || seconds == nil)
        }
    }
}

private struct EpisodeBoundaryEditor: View {
    @Bindable var model: EpisodeAlignmentModel
    var cleanup: EpisodeCleanupModel?
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @State private var speakerIn = ""
    @State private var speakerOut = ""
    @State private var generation: UInt64 = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episode Boundaries").font(.headline)
            Text("Episode times use Timeline Time; speaker times use original aligned time. Blank means Automatic.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Episode Start"); TextField("Automatic", text: $start).accessibilityIdentifier("ww.boundaries.start") }
                GridRow { Text("Episode End"); TextField("Automatic", text: $end).accessibilityIdentifier("ww.boundaries.end") }
                GridRow { Text("Speaker In"); TextField("Automatic", text: $speakerIn).accessibilityIdentifier("ww.boundaries.speakerIn") }
                GridRow { Text("Speaker Out"); TextField("Automatic", text: $speakerOut).accessibilityIdentifier("ww.boundaries.speakerOut") }
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ww.boundaries.apply")
            }
        }
        .padding(16).frame(width: 420)
        .onAppear {
            let production = model.audioEditor.production
            start = model.audioEditor.episode?.productionRange?.start == nil ? "" : seconds(production?.episodeFrames?.lowerBound)
            end = model.audioEditor.episode?.productionRange?.end == nil ? "" : seconds(production?.episodeFrames?.upperBound)
            speakerIn = cleanup?.episode?.cleanup?.workingRange?.tracksIn.map { String($0) } ?? ""
            speakerOut = cleanup?.episode?.cleanup?.workingRange?.tracksOut.map { String($0) } ?? ""
            generation = model.audioEditor.store.modelGeneration
        }
    }

    private func seconds(_ frame: Int64?) -> String { frame.map { String(Double($0) / 48_000) } ?? "" }

    private func parse(_ text: String) throws -> Double? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try EpisodeTimeDisplay.parse(text)
    }

    private func apply() {
        do {
            guard generation == model.audioEditor.store.modelGeneration else {
                throw ManualCutReviewFailure(reason: "The episode changed. Close and reopen boundary editing before applying.")
            }
            let startTime = try parse(start), endTime = try parse(end)
            let inTime = try parse(speakerIn), outTime = try parse(speakerOut)
            guard let episode = model.audioEditor.episode, let composition = model.audioEditor.composition else {
                throw EpisodeProductionError.staleComposition
            }
            var range = episode.productionRange ?? .init()
            range.start = try startTime.map {
                try composition.timeline.unpinnedAnchor(atProgramFrame: AudioClipEditorModel.programFrame($0))
            }
            range.end = try endTime.map {
                try composition.timeline.unpinnedAnchor(atProgramFrame: AudioClipEditorModel.programFrame($0))
            }
            guard model.audioEditor.setBoundaryTimes(range: range, speakerIn: inTime, speakerOut: outTime) else {
                error = model.audioEditor.error
                return
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
