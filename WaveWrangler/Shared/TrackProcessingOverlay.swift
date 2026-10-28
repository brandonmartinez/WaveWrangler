import SwiftUI

struct TrackProcessingOperation: Equatable {
    enum Kind: String {
        case alignmentAnalysis, adaptiveAnalysis, alignmentAcceptance, timingUpdate
        case waveforms, audioPreparation, transcription
    }

    let kind: Kind
    let title: String
    let detail: String
    let fraction: Double?
    let canCancel: Bool

    @MainActor
    static func current(alignment: EpisodeAlignmentModel, cleanup: EpisodeCleanupModel?) -> Self? {
        let operation = alignment.trackProcessingOperation
        if let operation, operation.kind != .waveforms { return operation }
        if let cleanup, cleanup.isBusy {
            return Self(kind: .transcription, title: "Transcribing tracks", detail: cleanup.message,
                fraction: cleanup.transcriptionStatus?.progress?.fraction, canCancel: true)
        }
        return operation
    }

    @MainActor
    static func cancel(alignment: EpisodeAlignmentModel, cleanup: EpisodeCleanupModel?) {
        if current(alignment: alignment, cleanup: cleanup)?.kind == .transcription {
            cleanup?.cancelTranscription()
            cleanup?.message = "Transcription canceled. No partial result was saved."
        } else {
            alignment.cancelTrackProcessing()
        }
    }
}

struct TrackProcessingPresentation: ViewModifier {
    let operation: TrackProcessingOperation?
    let cancel: () -> Void

    func body(content: Content) -> some View {
        content
            .disabled(operation != nil)
            .allowsHitTesting(operation == nil)
            .accessibilityHidden(operation != nil)
            .overlay {
                if let operation { TrackProcessingOverlay(operation: operation, cancel: cancel) }
            }
    }
}

struct TrackProcessingOverlay: View {
    let operation: TrackProcessingOperation
    let cancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 180
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                VStack(alignment: .leading, spacing: compact ? 6 : 14) {
                    HStack(spacing: 10) {
                        if !compact {
                            Image(systemName: "waveform.path")
                                .font(.title2).foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                        Text(operation.title)
                            .font(compact ? .caption : .headline)
                            .lineLimit(compact ? 1 : 2)
                            .accessibilityIdentifier("ww.trackProcessing.title")
                        Spacer(minLength: 4)
                        Button("Cancel", action: cancel)
                            .buttonStyle(.bordered)
                            .controlSize(compact ? .small : .regular)
                            .keyboardShortcut(.cancelAction)
                            .disabled(!operation.canCancel)
                            .help(operation.canCancel
                                ? "Stop this operation without changing original recordings."
                                : "The final verified timing update cannot be interrupted.")
                            .accessibilityIdentifier("ww.trackProcessing.cancel")
                    }
                    if !compact {
                        Text(operation.detail).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ww.trackProcessing.detail")
                    }
                    ProgressView(value: operation.fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(operation.title)
                        .accessibilityIdentifier("ww.trackProcessing.progress")
                    if !compact, !operation.canCancel {
                        Text("Finishing a verified change. This final step can't be canceled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(compact ? 8 : 20)
                .frame(maxWidth: min(520, max(0, geometry.size.width - (compact ? 12 : 32))))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .padding(compact ? 6 : 16)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(operation.title)
        .accessibilityValue(operation.detail)
        .accessibilityIdentifier("ww.trackProcessing.overlay")
    }
}
