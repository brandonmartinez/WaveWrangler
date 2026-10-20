import AppKit
import SwiftUI
import WWCore

struct AudioWorkspaceActions: View {
    @Bindable var state: ShowWindowState
    @Bindable var alignment: EpisodeAlignmentModel
    @State private var listeningPresetError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack { recordingActions; Spacer(minLength: 8); transcriptionActions }
                VStack(alignment: .leading, spacing: 8) { recordingActions; transcriptionActions }
            }
            if alignment.isWorking {
                ProgressView(alignment.message).controlSize(.small)
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
            Text("Listen now").font(.caption).foregroundStyle(.secondary)
            listeningPreset(.muteNonPrimaries, title: "Mute backups", symbol: "speaker.slash")
            listeningPreset(.soloPrimaries, title: "Primaries", symbol: "person.fill")
            listeningPreset(.soloBackups, title: "Backups", symbol: "person.2")
            if alignment.listening.previousPlayback != nil {
                Button("Restore listening choices", systemImage: "arrow.uturn.backward") {
                    alignment.restoreListeningChoices()
                }
                .labelStyle(.iconOnly)
                .help("Restore the captured listening choices. Begin editing can establish a new restore point.")
                .accessibilityIdentifier("ww.listening.restore")
            }
            Divider().frame(height: 20)
            Button("Add recordings or speakers", systemImage: "plus") { state.recordingsPresented = true }
                .labelStyle(.iconOnly).accessibilityIdentifier("ww.audioWorkspace.add")
            if let cleanup = state.cleanupModel {
                EpisodeBoundaryMenu(model: cleanup, alignment: alignment,
                    isEnabled: !cleanup.isBusy && !alignment.isWorking && state.canEdit)
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
        .help("\(policy.title). Listen now only; preserves explicit Mute choices and does not change the saved After alignment policy.")
        .accessibilityLabel("Listen now: \(title)")
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier("ww.listening.preset.\(policy.rawValue)")
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

@MainActor
private struct EpisodeBoundaryMenu: NSViewRepresentable {
    let model: EpisodeCleanupModel
    let alignment: EpisodeAlignmentModel
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model, alignment: alignment) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Episode boundaries", action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)
        menu.addItem(heading)
        for (title, action) in [
            ("IN at playhead", #selector(Coordinator.markIn(_:))),
            ("OUT at playhead", #selector(Coordinator.markOut(_:))),
            ("Reset IN/OUT", #selector(Coordinator.reset(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        button.isEnabled = isEnabled
        button.setAccessibilityLabel("Episode boundaries")
        button.setAccessibilityIdentifier("ww.audioWorkspace.boundaries")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.model = model
        context.coordinator.alignment = alignment
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: EpisodeCleanupModel
        var alignment: EpisodeAlignmentModel

        init(model: EpisodeCleanupModel, alignment: EpisodeAlignmentModel) {
            self.model = model
            self.alignment = alignment
        }

        @objc func markIn(_ sender: NSMenuItem) {
            model.saveRange(inValue: alignment.waveformPlayheadSeconds,
                            outValue: model.episode?.cleanup?.workingRange?.tracksOut)
        }

        @objc func markOut(_ sender: NSMenuItem) {
            model.saveRange(inValue: model.episode?.cleanup?.workingRange?.tracksIn,
                            outValue: alignment.waveformPlayheadSeconds)
        }

        @objc func reset(_ sender: NSMenuItem) {
            model.saveRange(inValue: nil, outValue: nil)
        }
    }
}
