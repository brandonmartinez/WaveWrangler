import SwiftUI
import WWSpeech

struct TranscriptionSettingsView: View {
    @Bindable var settings: TranscriptionSettings = .shared

    var body: some View {
        Form {
            Section("Local Whisper") {
                Picker("Transcription model", selection: $settings.selection) {
                    ForEach(LocalWhisperWeights.allCases, id: \.self) { weights in
                        Text(weights.title).tag(weights)
                    }
                }
                .disabled(settings.isBusy)
                .accessibilityIdentifier("ww.settings.transcription.model")
                Text(settings.selection.detail).wwFont(.callout)
                Text("Applies to every episode. Changing models affects the next transcription, not an active job or saved transcript.")
                    .wwFont(.caption)
                if settings.available.contains(settings.selection) {
                    Label("Available locally. Integrity is checked before every transcription.", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("ww.settings.transcription.installed")
                } else {
                    Label("Not downloaded", systemImage: "arrow.down.circle")
                }
                if settings.isBusy, let weights = settings.downloading {
                    if settings.isVerifying {
                        ProgressView("Verifying downloaded weights…")
                    } else {
                        ProgressView(value: Double(settings.receivedBytes), total: Double(weights.byteCount))
                            .accessibilityLabel("Whisper model download")
                        Text("\(ByteCountFormatter.string(fromByteCount: settings.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(weights.byteCount), countStyle: .file))")
                            .monospacedDigit()
                    }
                    Button("Cancel Download") { settings.cancelDownload() }
                        .accessibilityIdentifier("ww.settings.transcription.cancel")
                } else {
                    Button(settings.available.contains(settings.selection) ? "Download Again" : "Download Model") {
                        settings.download()
                    }
                    .accessibilityIdentifier("ww.settings.transcription.download")
                }
                Text(settings.status).wwFont(.callout)
                if let error = settings.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Performance") {
                Picker("Concurrent transcriptions", selection: $settings.concurrency) {
                    ForEach(TranscriptionConcurrency.allCases, id: \.self) { policy in
                        Text("\(policy.rawValue) \(policy == .one ? "worker" : "workers")").tag(policy)
                    }
                }
                .accessibilityIdentifier("ww.settings.transcription.workers")
                Text("One worker transcribes one speaker's Primary track. Two is a good starting point on a high-memory Mac. Extra workers can serve other episodes; the limit is shared across all windows.")
                    .wwFont(.caption)
                Text("Each worker uses four Whisper threads and its own inference working memory. More workers use more CPU/RAM and may not be faster. New jobs use this parallelism; lowering the app-wide limit lets active tracks finish before admitting more.")
                    .wwFont(.caption)
            }
            Section("Privacy & accuracy") {
                Text("Download fetches only the selected MIT-licensed model from Hugging Face's ggerganov/whisper.cpp repository. Models are kept in this app's Application Support folder. No recording or transcript is uploaded.")
                Text("Both choices use the same English, filler-preserving settings. Turbo was best in our small test, not a guarantee on your recordings. Larger Whisper models are not yet qualified here. Word times remain approximate, and all models can hallucinate.")
                Link("Whisper models and license", destination: URL(string: "https://github.com/openai/whisper#available-models-and-languages")!)
            }
            .wwFont(.caption)
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { settings.refreshAvailability() }
        .accessibilityIdentifier("ww.settings.transcription")
    }
}
