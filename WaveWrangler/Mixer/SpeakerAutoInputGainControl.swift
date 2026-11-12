import SwiftUI
import WWCore

struct SpeakerAutoInputGainControl: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    let speakerID: SpeakerID
    let enabled: Bool
    let identifier: String
    @State private var expanded = false
    @Environment(AppSettings.self) private var settings

    private var key: AutoInputGainController.Key { .init(episode: episodeID, speaker: speakerID) }

    var body: some View {
        let controller = store.autoInputGain
        let running = controller.active == key
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Analyze only this speaker's Primary channel and set its input gain. Original audio and dynamics stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Target: \(settings.autoInputGainTargetDBFS.formatted(.number.precision(.fractionLength(1)))) dBFS RMS")
                    .font(.caption).monospacedDigit()
                if running {
                    ProgressView(value: controller.progress)
                        .accessibilityLabel("Analyzing input gain")
                        .accessibilityIdentifier("\(identifier).progress")
                    Button("Cancel Analysis") { controller.cancel(key) }
                        .accessibilityIdentifier("\(identifier).cancel")
                } else {
                    Button("Analyze and Set Input Gain") {
                        controller.start(key, targetDBFS: settings.autoInputGainTargetDBFS)
                    }
                    .disabled(!enabled || controller.active != nil || controller.refusal(for: key) != nil)
                    .accessibilityIdentifier("\(identifier).run")
                    .help("Runs locally for this speaker only. Uses pause-gated RMS and an estimated true-peak ceiling; no compression or effects. Undo restores the previous gain.")
                    if let reason = controller.refusal(for: key) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if controller.active != nil {
                        Text("Another speaker's gain analysis is running. Finish or cancel it first.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let message = controller.messages[key] {
                    Text(message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(identifier).status")
                }
                Button("Target Level Settings...") { SettingsWindowController.show(pane: .sources) }
                    .font(.caption)
                    .accessibilityIdentifier("\(identifier).settings")
            }
            .padding(.top, 4)
        } label: {
            Text("Auto Input Gain").accessibilityIdentifier(identifier)
        }
    }
}
