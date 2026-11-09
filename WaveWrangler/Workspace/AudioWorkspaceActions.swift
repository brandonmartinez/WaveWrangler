import AppKit
import SwiftUI
import WWCore

struct AudioWorkspaceActions: View {
    enum Surface { case status, add, listening }
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel
    var surface: Surface = .status
    @State private var listeningPresetError: String?
    @State private var reviewingWorkingRange = false
    @State private var workingRangeToReview: EpisodeWorkingRange?
    @State private var workingRangeRevision: Int?

    var body: some View {
        switch surface {
        case .status: status
        case .add: addMenu
        case .listening: listeningMenu
        }
    }

    private var status: some View {
        let operation = TrackProcessingOperation.current(alignment: alignment, cleanup: state.cleanupModel)
        return VStack(alignment: .leading, spacing: 5) {
            if let error = alignment.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let error = alignment.audioEditor.importer.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("ww.addAudio.error")
            }
            if let error = alignment.audioEditor.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("ww.audioEditor.error")
            }
            if let listeningPresetError {
                Label(listeningPresetError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let cleanup = state.cleanupModel {
                if !cleanup.isBusy, let error = cleanup.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                if cleanup.hasStaleWorkingRange {
                    Button("Review Speaker In/Out…") {
                        guard let range = cleanup.episode?.cleanup?.workingRange,
                              let revision = cleanup.episode?.alignment?.acceptedRevision else { return }
                        workingRangeToReview = range
                        workingRangeRevision = revision
                        reviewingWorkingRange = true
                    }
                        .disabled(operation != nil || !state.canEdit)
                        .accessibilityIdentifier("ww.audioWorkspace.reviewWorkingRange")
                }
            }
        }
        .padding(.horizontal, 10)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.audioWorkspace.actions")
        .sheet(item: Binding(get: { alignment.audioEditor.insertionSession },
                            set: { _ in alignment.audioEditor.dismissInsertion() })) { session in
            AudioInsertionSheet(editor: alignment.audioEditor, session: session)
        }
        .sheet(item: Binding(get: { alignment.audioEditor.fadeSession },
                            set: { _ in alignment.audioEditor.dismissFade() })) { session in
            AudioFadeSheet(editor: alignment.audioEditor, session: session)
        }
        .sheet(isPresented: $alignment.tracksReviewPresented, onDismiss: {
            alignment.discardTracksReview()
        }) {
            TracksAlignmentReviewView(model: alignment, setup: {
                alignment.discardTracksReview()
                state.recordingsPresented = true
            }, advanced: { row in
                alignment.discardTracksReview()
                alignment.selection = row.epochID
                state.workspaceInspector = .alignment
                state.inspectorPresented = true
            })
        }
        .confirmationDialog("Use these speaker boundaries with the current alignment?",
                            isPresented: $reviewingWorkingRange) {
            Button("Keep existing Speaker In/Out") { resolveWorkingRange(keeping: true) }
            Button("Reset Speaker In/Out to include all available dialogue") {
                resolveWorkingRange(keeping: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let range = workingRangeToReview {
                Text("IN: \(range.tracksIn.map(AlignmentPresentation.formatTime) ?? "Recording start"); OUT: \(range.tracksOut.map(AlignmentPresentation.formatTime) ?? "Recording end"). These markers belong to alignment revision \(range.alignmentRevision). Keeping them preserves those exact aligned times on the current revision; it does not revalidate old transcripts, word marks or cuts. This change is saved and undoable.")
            }
        }
    }

    private func resolveWorkingRange(keeping: Bool) {
        guard let range = workingRangeToReview, let revision = workingRangeRevision else { return }
        state.cleanupModel?.resolveStaleWorkingRange(
            keeping: keeping, expectedRange: range, expectedRevision: revision)
    }

    private var addMenu: some View {
        Menu("Add", systemImage: "plus") {
            Button("Add Audio…", systemImage: "plus") {
                alignment.addAudio(in: state)
            }
            .disabled(!state.canEdit)
            .accessibilityIdentifier("ww.audioWorkspace.addAudio")
            Button("New Audio Track") { alignment.audioEditor.addTrack() }
            .disabled(!state.canEdit)
            .accessibilityIdentifier("ww.audioWorkspace.audioTracks")
            AudioInsertionControls(editor: alignment.audioEditor,
                programPlayhead: alignment.presentationTimeline.programTime(forDisplayTime: alignment.waveformPlayheadSeconds))
            Divider()
            Button("Add recordings or speakers…") { state.recordingsPresented = true }
                .accessibilityIdentifier("ww.audioWorkspace.add")
        }
        .fixedSize()
        .disabled(!state.canEdit || TrackProcessingOperation.current(alignment: alignment, cleanup: state.cleanupModel) != nil)
        .accessibilityIdentifier("ww.controlBar.add")
    }

    private var listeningMenu: some View {
        Menu("Listening Presets", systemImage: "ear") {
            if state.selectedEpisode?.alignmentSources.isEmpty == false {
                listeningPreset(.muteNonPrimaries, title: "Mute backups", symbol: "speaker.slash")
                listeningPreset(.soloPrimaries, title: "Primaries", symbol: "person.fill")
                listeningPreset(.soloBackups, title: "Backups", symbol: "person.2")
                if alignment.listening.previousPlayback != nil {
                    Button("Restore listening choices", systemImage: "arrow.uturn.backward") {
                        alignment.restoreListeningChoices()
                    }
                    .labelStyle(.iconOnly)
                    .help("Restore listening choices captured before the last preset or newly accepted alignment.")
                    .accessibilityIdentifier("ww.listening.restore")
                }
            }
        }
        .alert("Listening preset unavailable", isPresented: Binding(
            get: { listeningPresetError != nil }, set: { if !$0 { listeningPresetError = nil } })) {
                Button("OK") { listeningPresetError = nil }
            } message: { Text(listeningPresetError ?? "") }
    }

    private func listeningPreset(_ policy: EditingPlaybackPolicy, title: String, symbol: String) -> some View {
        let episode = state.selectedEpisode
        let active = episode.map { alignment.listening.listeningPresetIsActive(policy, in: $0) } ?? false
        return Button {
            guard let episode else { return }
            do {
                try alignment.listening.applyListeningPreset(policy, in: episode)
                listeningPresetError = nil
                alignment.refreshListeningGains()
            } catch {
                listeningPresetError = String(describing: error)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .disabled(episode.map { !alignment.listening.playback.canApply(policy, in: $0) } ?? true)
        .help("\(policy.title). Listen now only; does not change the app's After alignment preference.")
        .accessibilityLabel("Listen now: \(title)")
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier("ww.listening.preset.\(policy.rawValue)")
    }

}

struct AudioWorkspaceWorkflowActions: View {
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel

    var body: some View {
        let operation = TrackProcessingOperation.current(alignment: alignment, cleanup: state.cleanupModel)
        HStack {
            Button("Align Tracks", systemImage: "waveform.path") { alignment.requestAlignTracks() }
                .disabled(operation != nil || !state.canEdit || state.selectedEpisode?.alignmentSources.isEmpty != false)
                .accessibilityIdentifier("ww.workflow.alignTracks")
                .help("Analyze all eligible recorder groups using shared speaker channels, then review proposals before acceptance. Resolve grouping, channels and source access in Recordings & Speakers.")
            Button("Reset Alignment…", systemImage: "arrow.counterclockwise") { alignment.requestResetAlignment() }
                .disabled(!alignment.canResetAlignment || !state.canEdit || operation != nil)
                .accessibilityIdentifier("ww.workflow.resetAlignment")
                .help("Return all recorder groups to zero offset and normal speed, removing active automatic, adaptive and manual timing. Also resets active transcription, reviews, cuts and episode IN/OUT. Requires confirmation; Undo restores the previous work.")
            if let cleanup = state.cleanupModel {
                let help = operation?.detail ?? cleanup.transcriptionReadinessMessage
                TranscriptionActionButton(help: help) {
                    cleanup.requestTranscription()
                }
                .disabled(!cleanup.canTranscribe || operation != nil)
            }
        }
    }
}

@MainActor
struct TranscriptionActionButton: NSViewRepresentable {
    let help: String
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Transcribe Tracks", target: context.coordinator,
            action: #selector(Coordinator.performAction(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("ww.workflow.transcribeTracks")
        button.setAccessibilityLabel("Transcribe Tracks")
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.toolTip = help
        button.setAccessibilityHelp(help)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) { self.action = action }

        @objc func performAction(_ sender: NSButton) { action() }
    }
}
