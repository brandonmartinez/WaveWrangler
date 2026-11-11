import Synchronization
import WWCore
import WWCommonEdit
import WWDerived
import WWRender

/// Non-realtime native preparation belongs outside MixerProcessor and its effect graph.
public struct SupplementalClipScheduler: Sendable {
    private struct Source: Sendable {
        let snapshot: MixerSourceSnapshot
        let admission: SourceReadAdmission
        let requiresRetention: Bool
    }
    public let recipe: MixerRecipe
    private let preparation: NativeSourcePreparation
    private let sources: [SourceID: Source]

    public init(recipe: MixerRecipe, preparation: NativeSourcePreparation,
                admissions: [SourceID: SourceReadAdmission]) async throws {
        var sources: [SourceID: Source] = [:]
        var admissionRetentions: [PreparedSourceRetention] = []
        do {
            for snapshot in recipe.audioSources {
                guard let admission = admissions[snapshot.source],
                      admission.source == snapshot.source, admission.witness == snapshot.witness else {
                    throw MixerFailure.staleDependencies
                }
                let retention = try await preparation.prepareForPlayback(admission, expectedFormat: snapshot.interpretation)
                if let retention { admissionRetentions.append(retention) }
                sources[snapshot.source] = .init(snapshot: snapshot, admission: admission,
                    requiresRetention: retention != nil)
            }
            try Task.checkCancellation()
        } catch {
            for retention in admissionRetentions { await retention.release() }
            throw error
        }
        for retention in admissionRetentions { await retention.release() }
        try Task.checkCancellation()
        self.recipe = recipe
        self.preparation = preparation
        self.sources = sources
    }

    /// Cached scheduling metadata owns no storage receipts. Each active play/render admits and
    /// releases only its own receipts, independently of other consumers using the same metadata.
    public func makeConsumer() async throws -> SupplementalClipConsumer {
        var retentions: [PreparedSourceRetention] = []
        do {
            try Task.checkCancellation()
            for source in sources.values where source.requiresRetention {
                if let retention = try await preparation.prepareForPlayback(
                    source.admission, expectedFormat: source.snapshot.interpretation) {
                    retentions.append(retention)
                }
            }
            try Task.checkCancellation()
            return SupplementalClipConsumer(scheduler: self, retentions: retentions)
        } catch {
            for retention in retentions { await retention.release() }
            throw error
        }
    }

    public func withConsumer<Value: Sendable>(
        _ operation: @Sendable (SupplementalClipConsumer) async throws -> Value
    ) async throws -> Value {
        let consumer = try await makeConsumer()
        do {
            let value = try await operation(consumer)
            await consumer.release()
            try Task.checkCancellation()
            return value
        } catch {
            await consumer.release()
            throw error
        }
    }

    /// Ordered occurrences are rendered independently, then summed before stereo track inserts.
    /// Empty intervals alone are silence. Active failed media always throws.
    public func read(_ frames: Range<Int64>) async throws -> [AudioTrackID: [[Float]]] {
        try requireFrames(frames)
        return try await withConsumer { try await $0.read(frames) }
    }

    private func requireFrames(_ frames: Range<Int64>) throws {
        guard !frames.isEmpty, frames.count <= MixerRecipe.maximumWindowFrames,
              frames.lowerBound >= recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames),
              frames.upperBound <= recipe.programFrames.upperBound else {
            throw MixerFailure.incompletePCM
        }
    }

    fileprivate func readPrepared(_ frames: Range<Int64>) async throws -> [AudioTrackID: [[Float]]] {
        try requireFrames(frames)
        var tracks = Dictionary(uniqueKeysWithValues: recipe.audioTracks.map {
            ($0.track, Array(repeating: [Float](repeating: 0, count: frames.count), count: 2))
        })
        for occurrence in recipe.composition?.clips ?? [] {
            let first = max(frames.lowerBound, occurrence.programFrames.lowerBound)
            let end = min(frames.upperBound, occurrence.programFrames.upperBound)
            guard first < end else { continue }
            guard let source = sources[occurrence.clip.source], tracks[occurrence.clip.track] != nil else {
                throw MixerFailure.staleDependencies
            }
            let envelope = try AudioEnvelopeEvaluator(envelope: occurrence.clip.envelope,
                durationFrames: Int64(occurrence.programFrames.count))
            let support = occurrence.clip.trim.startFrame..<occurrence.clip.trim.endFrame
            let outputOffset = occurrence.clip.outputWindow?.offsetFrames ?? 0
            let firstOutput = first - occurrence.programFrames.lowerBound + outputOffset
            let endOutput = end - occurrence.programFrames.lowerBound + outputOffset
            let sourceEnd = try NominalPCMRenderer.sourceFrames(sampleRate: occurrence.asset.sampleRate,
                support: support, outputFrames: firstOutput..<endOutput).upperBound
            var prepared: PreparedSourceWindow?
            var next = first
            while next < end {
                try Task.checkCancellation()
                let upper = min(end, next + Int64(NominalPCMRenderer.maximumOutputFrames))
                let local = next - occurrence.programFrames.lowerBound
                let origin = local + outputOffset
                let outputFrames = origin..<(origin + upper - next)
                let needed = try NominalPCMRenderer.sourceFrames(sampleRate: occurrence.asset.sampleRate,
                    support: support, outputFrames: outputFrames)
                let containsNeeded = prepared.map {
                    $0.range.lowerBound <= needed.lowerBound && $0.range.upperBound >= needed.upperBound
                } ?? false
                if !containsNeeded {
                    let limit = preparation.configuration.maximumWindowFrames
                    guard needed.count <= limit else { throw NativeSourcePreparationFailure.invalidRange }
                    // Retain only this occurrence's bounded native window, never a cross-read access grant.
                    prepared = try await preparation.readWindow(
                        needed.lowerBound..<min(sourceEnd, needed.lowerBound + Int64(limit)),
                        expectedFormat: source.snapshot.interpretation, admission: source.admission)
                }
                guard let window = prepared else { throw MixerFailure.incompletePCM }
                let samples = try await NominalPCMRenderer.render(sampleRate: occurrence.asset.sampleRate,
                    support: support, outputFrames: outputFrames, channels: occurrence.sourceChannels
                ) { range, channels in
                    guard range.lowerBound >= window.range.lowerBound, range.upperBound <= window.range.upperBound
                    else { throw MixerFailure.incompletePCM }
                    return channels.map { channel in
                        let start = channel * window.range.count + Int(range.lowerBound - window.range.lowerBound)
                        return Array(window.samples[start..<(start + range.count)])
                    }
                }

                let mono = samples.count == 1
                let monoGain = recipe.panLaw.gains(pan: 0).left
                for index in 0..<Int(upper - next) {
                    let gain = Float(try envelope.amplitude(atLocalFrame: local + Int64(index)))
                    let offset = Int(next - frames.lowerBound) + index
                    tracks[occurrence.clip.track]?[0][offset] += samples[0][index] * gain * (mono ? monoGain : 1)
                    tracks[occurrence.clip.track]?[1][offset] += samples[mono ? 0 : 1][index] * gain * (mono ? monoGain : 1)
                }
                next = upper
            }
            try await source.admission.validateCurrentAccess()
        }
        try Task.checkCancellation()
        guard tracks.values.allSatisfy({ $0.allSatisfy({ $0.allSatisfy(\.isFinite) }) }) else {
            throw MixerFailure.nonfinitePCM
        }
        return tracks
    }
}

/// One active consumer, not a cached scheduler. Release must follow its final awaited read.
public final class SupplementalClipConsumer: Sendable {
    private let scheduler: SupplementalClipScheduler
    private let retentions: [PreparedSourceRetention]
    private let released = Atomic<Bool>(false)

    public var recipe: MixerRecipe { scheduler.recipe }

    fileprivate init(scheduler: SupplementalClipScheduler, retentions: [PreparedSourceRetention]) {
        self.scheduler = scheduler
        self.retentions = retentions
    }

    public func read(_ frames: Range<Int64>) async throws -> [AudioTrackID: [[Float]]] {
        guard !released.load(ordering: .acquiring) else { throw MixerFailure.staleDependencies }
        defer { withExtendedLifetime(retentions) {} }
        return try await scheduler.readPrepared(frames)
    }

    public func release() async {
        released.store(true, ordering: .releasing)
        for retention in retentions { await retention.release() }
    }
}
