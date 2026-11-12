import Foundation
import Observation
import WWCommonEdit
import WWCore
import WWExport
import WWMix

/// Document-owned export backend. No live effect instance enters the offline job.
@MainActor @Observable
final class EpisodeExportService {
    enum State: Equatable {
        case idle, preparing, running, completed, canceled
        case failed(String)
    }
    private weak var document: ShowDocument?
    @ObservationIgnored private let job = ExportJob()
    private(set) var isRunning = false
    private(set) var progress = ExportJobProgress(phase: .idle, completedFrames: 0, totalFrames: 0)
    private(set) var lastResult: ExportJobResult?
    private(set) var state = State.idle
    private var cancellationRequested = false

    init(document: ShowDocument) { self.document = document }

    func cancel() async {
        cancellationRequested = true
        await job.cancel()
    }

    func run(episode id: EpisodeID, runtime: AlignmentRuntime, userSelectedDirectory: URL,
             deliveries: [EpisodeExportDelivery]) async throws -> ExportJobResult {
        guard !isRunning, let document, !document.mixerTransactions.isClosed else {
            throw ExportFailure.invalidState
        }
        isRunning = true
        state = .preparing
        cancellationRequested = false
        defer { isRunning = false }
        lastResult = nil
        progress = .init(phase: .preflight, completedFrames: 0, totalFrames: 0)
        do {
            // Capture fullStateForDocument, stop only this show's transports and retire live effects.
            try await document.mixerTransactions.barrier(replacingInstances: true, capturingAllLoadedState: true) {}
            try await runtime.productionRetirements.wait()
            try checkCancellation()
            let snapshot = document.store.model
            guard let episode = snapshot.episode(id),
                  document.verifiedModel?.hasSameMediaInputs(as: snapshot, in: id) == true else {
                throw MixerFailure.staleDependencies
            }
            let composition = try await runtime.programComposition(model: snapshot, episode: id)
            let production = try EpisodeProductionProjection(episode: episode, composition: composition)
            guard let frames = production.episodeFrames, !frames.isEmpty else {
                throw ExportFailure.invalidSettings("The episode has no resolved Episode Start/End range")
            }
            let recipe = try await runtime.mixerRecipe(model: snapshot, episode: id, programFrames: frames,
                                                       policy: .init(tail: .truncate))
            let metadata = try snapshot.resolvedPublication(for: id)
            let outputs = try deliveries.map { try ExportMetadataAdapter.delivery(metadata, selection: $0) }
            let request = try ExportJobRequest(userSelectedDirectory: userSelectedDirectory,
                protectedLocations: document.fileURL.map { [$0] } ?? [],
                productionFrames: frames, deliveries: outputs)
            let current: ExportJob.Currency = { [weak self, weak document] in
                guard let self, let document else { return false }
                let valid = await MainActor.run {
                    !self.cancellationRequested && !document.mixerTransactions.isClosed
                        && document.store.model == snapshot
                        && document.verifiedModel?.hasSameMediaInputs(as: snapshot, in: id) == true
                }
                guard valid else { return false }
                try await runtime.validateProduction(recipe: recipe, model: snapshot)
                return await MainActor.run { !self.cancellationRequested && document.store.model == snapshot }
            }
            try checkCancellation()
            state = .running
            let result = try await job.run(request, isCurrent: current, render: { sink in
                try await runtime.renderProductionOffline(recipe: recipe, model: snapshot, isCurrent: current) { output in
                    try await sink(output.firstFrame, output.channels)
                }
            }, progress: { [weak self] value in
                await MainActor.run { self?.progress = value }
            })
            lastResult = result
            state = result.succeeded ? .completed : result.problem?.kind == .canceled ? .canceled
                : .failed(result.problem?.message ?? "Export cleanup failed")
            return result
        } catch {
            if error is CancellationError {
                state = .canceled
                progress = .init(phase: .canceled, completedFrames: 0, totalFrames: 0)
            } else {
                state = .failed(error.localizedDescription)
                progress = .init(phase: .failed, completedFrames: 0, totalFrames: 0)
            }
            throw error
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellationRequested { throw CancellationError() }
    }
}
