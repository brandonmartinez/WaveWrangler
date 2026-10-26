import AppKit
import SwiftUI
import WWCore

struct AudioWorkspaceActions: View {
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel
    @State private var listeningPresetError: String?
    @State private var reviewingWorkingRange = false
    @State private var workingRangeToReview: EpisodeWorkingRange?
    @State private var workingRangeRevision: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AudioTimelineAdaptiveRow {
                recordingActions
                if let cleanup = state.cleanupModel {
                    HStack {
                        Text(cleanup.transcriptionSettings.selection.title).font(.caption).lineLimit(1)
                        Button("Transcription Settings…", systemImage: "gearshape") {
                            SettingsWindowController.show(pane: .transcription)
                        }.labelStyle(.iconOnly)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if alignment.isWorking {
                HStack {
                    ProgressView(alignment.message).controlSize(.small)
                    if alignment.isAnalyzingTracks {
                        Button("Cancel alignment") { alignment.cancelTracksAnalysis() }
                    }
                }
            } else {
                Text(alignment.message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = alignment.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let listeningPresetError {
                Label(listeningPresetError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let cleanup = state.cleanupModel {
                if cleanup.isBusy {
                    HStack {
                        ProgressView(value: cleanup.transcriptionStatus?.progress?.fraction ?? 0)
                        Text(cleanup.message).font(.caption).lineLimit(2)
                        Button("Cancel transcription", systemImage: "xmark.circle") {
                            cleanup.cancelTranscription()
                            cleanup.message = "Transcription canceled. No partial result was saved."
                        }
                    }
                } else if let error = cleanup.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                } else if !cleanup.canTranscribe {
                    Text("Transcription: \(cleanup.transcriptionReadinessMessage)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if cleanup.hasStaleWorkingRange {
                    Button("Review episode IN/OUT…") {
                        guard let range = cleanup.episode?.cleanup?.workingRange,
                              let revision = cleanup.episode?.alignment?.acceptedRevision else { return }
                        workingRangeToReview = range
                        workingRangeRevision = revision
                        reviewingWorkingRange = true
                    }
                        .disabled(cleanup.isBusy || alignment.isWorking || !state.canEdit)
                        .accessibilityIdentifier("ww.audioWorkspace.reviewWorkingRange")
                }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.audioWorkspace.actions")
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
        .confirmationDialog("Use these episode boundaries with the current alignment?",
                            isPresented: $reviewingWorkingRange) {
            Button("Keep existing IN/OUT") { resolveWorkingRange(keeping: true) }
            Button("Reset IN/OUT to include all available audio") {
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

    private var recordingActions: some View {
        HStack {
            Text("Listen now").font(.caption).foregroundStyle(.secondary)
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
            Divider().frame(height: 20)
            Button("Add recordings or speakers", systemImage: "plus") { state.recordingsPresented = true }
                .labelStyle(.iconOnly).accessibilityIdentifier("ww.audioWorkspace.add")
            if let cleanup = state.cleanupModel {
                NativeActionMenu(label: "Episode boundaries", symbol: "arrow.left.and.right",
                    identifier: "ww.audioWorkspace.boundaries",
                    isEnabled: !cleanup.isBusy && !alignment.isWorking && state.canEdit,
                    actions: [
                        .init(title: "IN at playhead") {
                            cleanup.saveRange(inValue: alignment.waveformPlayheadSeconds,
                                outValue: cleanup.episode?.cleanup?.workingRange?.tracksOut)
                        },
                        .init(title: "OUT at playhead") {
                            cleanup.saveRange(inValue: cleanup.episode?.cleanup?.workingRange?.tracksIn,
                                outValue: alignment.waveformPlayheadSeconds)
                        },
                        .init(title: "Reset IN/OUT") { cleanup.saveRange(inValue: nil, outValue: nil) },
                    ])
                .frame(width: 44, height: 24)
                .help("Persistent episode working boundaries; independent from temporary selection and cycle.")
            }
        }
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
        HStack {
            Button("Align Tracks", systemImage: "waveform.path") { alignment.requestAlignTracks() }
                .disabled(alignment.isWorking || !state.canEdit || state.cleanupModel?.isBusy == true)
                .accessibilityIdentifier("ww.workflow.alignTracks")
                .help("Analyze all eligible recorder groups using shared speaker channels, then review proposals before acceptance. Resolve grouping, channels and source access in Recordings & Speakers.")
            Button("Reset Alignment…", systemImage: "arrow.counterclockwise") { alignment.requestResetAlignment() }
                .disabled(!alignment.canResetAlignment || !state.canEdit || state.cleanupModel?.isBusy == true)
                .accessibilityIdentifier("ww.workflow.resetAlignment")
                .help("Return all recorder groups to zero offset and normal speed, removing active automatic, adaptive and manual timing. Also resets active transcription, reviews, cuts and episode IN/OUT. Requires confirmation; Undo restores the previous work.")
            if let cleanup = state.cleanupModel {
                let help = alignment.isWorking
                    ? "Alignment is running. Wait for accepted timing to finish saving before transcription."
                    : cleanup.transcriptionReadinessMessage
                TranscriptionActionButton(help: help) {
                    cleanup.requestTranscription()
                }
                .disabled(!cleanup.canTranscribe || alignment.isWorking)
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
