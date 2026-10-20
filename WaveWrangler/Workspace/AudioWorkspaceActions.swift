import SwiftUI
import WWCore

struct AudioWorkspaceActions: View {
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack { recordingActions; Spacer(minLength: 8); transcriptionActions }
                VStack(alignment: .leading, spacing: 8) { recordingActions; transcriptionActions }
            }
            if alignment.isWorking {
                ProgressView(alignment.message).controlSize(.small)
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
                } else if cleanup.plan?.isReady != true {
                    Text(cleanup.plan?.blockers.first ?? "Confirm originals and accept alignment before transcribing Primaries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.audioWorkspace.actions")
    }

    private var recordingActions: some View {
        HStack {
            Button("Add recordings or speakers", systemImage: "plus") { state.recordingsPresented = true }
                .labelStyle(.iconOnly).accessibilityIdentifier("ww.audioWorkspace.add")
            Button("Transcript & review", systemImage: "text.bubble") {
                state.workspaceInspector = .transcript
                state.inspectorPresented = true
            }
            if let cleanup = state.cleanupModel {
                Menu("Episode boundaries") {
                    Button("IN at playhead") {
                        cleanup.saveRange(inValue: alignment.waveformPlayheadSeconds,
                                          outValue: cleanup.episode?.cleanup?.workingRange?.tracksOut)
                    }
                    Button("OUT at playhead") {
                        cleanup.saveRange(inValue: cleanup.episode?.cleanup?.workingRange?.tracksIn,
                                          outValue: alignment.waveformPlayheadSeconds)
                    }
                    Button("Reset IN/OUT") { cleanup.saveRange(inValue: nil, outValue: nil) }
                }
                .disabled(cleanup.isBusy || alignment.isWorking || !state.canEdit)
                .help("Persistent episode working boundaries; independent from temporary selection and cycle.")
            }
        }
    }

    @ViewBuilder
    private var transcriptionActions: some View {
        if let cleanup = state.cleanupModel {
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await cleanup.refresh() }
                }
                .disabled(cleanup.isBusy || cleanup.isRefreshing)
                Button("Transcribe", systemImage: "waveform.badge.mic") { cleanup.transcribe() }
                    .disabled(!cleanup.canTranscribe || alignment.isWorking)
                    .help("Local transcription of assigned Primaries. Solo/Mute only affects listening.")
                Text(cleanup.transcriptionSettings.selection.title).font(.caption).lineLimit(1)
                Button("Transcription Settings…", systemImage: "gearshape") {
                    SettingsWindowController.show(pane: .transcription)
                }.labelStyle(.iconOnly)
            }
        }
    }
}
