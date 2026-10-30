import WWCore
import WWCommonEdit
import WWDerived
import WWRender

/// Non-realtime native preparation belongs outside MixerProcessor and its effect graph.
public struct SupplementalClipScheduler: Sendable {
    private struct Source: Sendable {
        let audio: PreparedSourceAudio
        let admission: SourceReadAdmission
    }
    public let recipe: MixerRecipe
    private let preparation: NativeSourcePreparation
    private let sources: [SourceID: Source]

    public init(recipe: MixerRecipe, preparation: NativeSourcePreparation,
                admissions: [SourceID: SourceReadAdmission]) async throws {
        var sources: [SourceID: Source] = [:]
        for snapshot in recipe.audioSources {
            guard let admission = admissions[snapshot.source],
                  admission.source == snapshot.source, admission.witness == snapshot.witness else {
                throw MixerFailure.staleDependencies
            }
            let audio = try await preparation.prepare(admission, expectedFormat: snapshot.interpretation)
            sources[snapshot.source] = .init(audio: audio, admission: admission)
        }
        try Task.checkCancellation()
        self.recipe = recipe
        self.preparation = preparation
        self.sources = sources
    }

    /// Ordered occurrences are rendered independently, then summed before stereo track inserts.
    /// Empty intervals alone are silence. Active failed media always throws.
    public func read(_ frames: Range<Int64>) async throws -> [AudioTrackID: [[Float]]] {
        guard !frames.isEmpty, frames.count <= MixerRecipe.maximumWindowFrames,
              frames.lowerBound >= recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames),
              frames.upperBound <= recipe.programFrames.upperBound else {
            throw MixerFailure.incompletePCM
        }
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
            var next = first
            while next < end {
                try Task.checkCancellation()
                let upper = min(end, next + Int64(NominalPCMRenderer.maximumOutputFrames))
                let local = next - occurrence.programFrames.lowerBound
                let origin = local + (occurrence.clip.outputWindow?.offsetFrames ?? 0)
                let samples = try await NominalPCMRenderer.render(sampleRate: occurrence.asset.sampleRate,
                    support: occurrence.clip.trim.startFrame..<occurrence.clip.trim.endFrame,
                    outputFrames: origin..<(origin + upper - next), channels: occurrence.sourceChannels
                ) { [preparation] range, channels in
                    let window = try await preparation.readWindow(range, from: source.audio, admission: source.admission)
                    return channels.map { channel in
                        let start = channel * window.range.count
                        return Array(window.samples[start..<(start + window.range.count)])
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
        }
        try Task.checkCancellation()
        guard tracks.values.allSatisfy({ $0.allSatisfy({ $0.allSatisfy(\.isFinite) }) }) else {
            throw MixerFailure.nonfinitePCM
        }
        return tracks
    }
}
