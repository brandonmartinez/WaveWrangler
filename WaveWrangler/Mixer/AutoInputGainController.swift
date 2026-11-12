import AppKit
import Observation
import WWCore
import WWMix

@MainActor
@Observable
final class AutoInputGainController {
    struct Key: Hashable {
        let episode: EpisodeID
        let speaker: SpeakerID
    }

    private(set) var active: Key?
    private(set) var progress: Double = 0
    private(set) var messages: [Key: String] = [:]
    private(set) var results: [Key: AutoInputGainResult] = [:]
    @ObservationIgnored private weak var store: ShowDocumentStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: UUID?

    init(store: ShowDocumentStore) { self.store = store }

    func refusal(for key: Key) -> String? {
        guard let store, store.canEdit, store.document != nil else { return "Open an editable show first." }
        guard store.document?.mixerTransactions.isBusy != true else { return "Wait for the mixer transaction to finish." }
        guard let episode = store.model.episode(key.episode),
              let assignment = episode.assignment(for: key.speaker),
              assignment.primaryConfirmation == .userConfirmed,
              let primary = assignment.primary, let channel = primary.channel.value, channel >= 0,
              let source = episode.source(primary.sourceID), source.isRecording,
              source.role == .primary, source.roleConfirmation == .userConfirmed else {
            return "Choose and confirm this speaker's Primary recording and channel in Recordings & Speakers."
        }
        if let count = source.observations.channelCount.value, channel >= count {
            return "Choose a channel that exists in this speaker's Primary recording."
        }
        return nil
    }

    func start(_ key: Key, targetDBFS: Double, runtime suppliedRuntime: AlignmentRuntime? = nil) {
        guard active == nil else {
            messages[key] = "Another speaker's gain analysis is running. Finish or cancel it first."
            return
        }
        if let reason = refusal(for: key) {
            messages[key] = reason
            return
        }
        guard let store, let document = store.document else { return }
        let generation = store.modelGeneration
        let model = store.model
        let id = UUID()
        request = id
        active = key
        progress = 0
        messages[key] = nil
        results[key] = nil
        task = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer {
                if self.request == id {
                    self.active = nil
                    self.task = nil
                    self.request = nil
                }
            }
            do {
                let runtime: AlignmentRuntime
                if let suppliedRuntime { runtime = suppliedRuntime }
                else { runtime = try await AlignmentRuntimeProvider.runtime(for: document, episode: key.episode) }
                try self.validate(key, request: id, generation: generation, document: document)
                let result = try await runtime.analyzeInputGain(
                    model: model, episode: key.episode, speaker: key.speaker, targetDBFS: targetDBFS,
                    validateSelection: { [weak self, weak document] in
                        guard let self else { throw GainApplicationFailure.changed }
                        try await self.validate(key, request: id, generation: generation, document: document)
                    },
                    progress: { [weak self] value in
                        await self?.updateProgress(value, request: id)
                    })
                try self.validate(key, request: id, generation: generation, document: document)
                guard let primary = store.model.episode(key.episode)?.assignment(for: key.speaker)?.primary else {
                    throw GainApplicationFailure.changed
                }
                store.endCoalescing()
                guard store.apply("Auto Input Gain", { model throws(DomainError) in
                    try model.settingInputGain(result.gainDB, for: primary, in: key.episode)
                }) else {
                    throw GainApplicationFailure.edit(store.lastError.map(EpisodeSetupModel.describe)
                        ?? "The document could not apply the gain.")
                }
                self.results[key] = result
                let gain = result.gainDB.formatted(.number.precision(.fractionLength(1)))
                let peak = result.predictedTruePeakDBFS.formatted(.number.precision(.fractionLength(1)))
                var message = "Set input gain to \(gain) dB. Estimated resulting true peak: \(peak) dBTP."
                if result.peakLimited { message += " Peak-limited; the target level could not be reached without reducing headroom." }
                if result.gainLimited { message += " Limited by the maximum input gain; the target level was not reached." }
                if result.samplePeakDBFS >= 0 { message += " The source reaches digital full scale; gain cannot repair existing clipping." }
                self.messages[key] = message
            } catch {
                guard self.request == id else { return }
                if Task.isCancelled {
                    self.messages[key] = "Analysis canceled. No gain was changed."
                } else {
                    self.messages[key] = "Auto Input Gain: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancel(_ key: Key) {
        guard active == key else { return }
        task?.cancel()
        messages[key] = "Canceling analysis..."
    }

    private func updateProgress(_ value: Double, request id: UUID) {
        guard request == id else { return }
        if Int(value * 100) != Int(progress * 100) { progress = value }
    }

    private func validate(_ key: Key, request id: UUID, generation: UInt64, document: ShowDocument?) throws {
        try Task.checkCancellation()
        guard request == id, let store, store.modelGeneration == generation,
              let document, store.document === document,
              NSDocumentController.shared.documents.contains(where: { $0 === document }),
              refusal(for: key) == nil else { throw GainApplicationFailure.changed }
    }
}

private enum GainApplicationFailure: LocalizedError {
    case changed
    case edit(String)

    var errorDescription: String? {
        switch self {
        case .changed: "The show or its input settings changed during analysis. No gain was changed; run the analysis again."
        case .edit(let message): message
        }
    }
}
