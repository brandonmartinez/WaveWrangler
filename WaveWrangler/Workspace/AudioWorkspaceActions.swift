import AppKit
import SwiftUI
import WWCore

struct AudioWorkspaceActions: View {
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel
    @State private var listeningPresetError: String?

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
                    Text(cleanup.transcriptionReadinessMessage)
                        .font(.caption).foregroundStyle(.secondary)
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
            if let cleanup = state.cleanupModel {
                Button("Transcribe Tracks", systemImage: "waveform.badge.mic") { cleanup.requestTranscription() }
                    .disabled(!cleanup.canTranscribe || alignment.isWorking)
                    .accessibilityIdentifier("ww.workflow.transcribeTracks")
                    .help(cleanup.transcriptionReadinessMessage)
            }
        }
    }
}
