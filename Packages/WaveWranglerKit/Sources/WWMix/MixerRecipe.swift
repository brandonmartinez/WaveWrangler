import Foundation
import WWCore
import WWDecode
import WWSources

public enum MixerFailure: Error, Sendable, Equatable, LocalizedError {
    case invalidRecipe(String)
    case unconfirmedPrimary(SpeakerID)
    case unresolvedChannel(SourceID)
    case staleDependencies
    case missingUnit(AudioUnitSlotID)
    case loading(AudioUnitSlotID, String)
    case format(AudioUnitSlotID)
    case state(AudioUnitSlotID, String)
    case parameter(AudioUnitSlotID)
    case render(AudioUnitSlotID, Int32)
    case changedLatency(AudioUnitSlotID)
    case changedTail(AudioUnitSlotID)
    case latencyLimit
    case tailLimit
    case incompletePCM
    case nonfinitePCM
    case discontinuousPCM
    case noProgress
    case finished

    public var errorDescription: String? {
        switch self {
        case .invalidRecipe(let reason): "Mixer unavailable: \(reason)"
        case .unconfirmedPrimary(let speaker): "Speaker \(speaker) needs a confirmed Primary."
        case .unresolvedChannel(let source): "Recording \(source) needs a verified, explicit channel."
        case .staleDependencies: "Mixer dependencies changed. Prepared audio was discarded."
        case .missingUnit(let slot): "Audio Unit in slot \(slot) is not installed. No substitute was used."
        case .loading(let slot, let reason): "Audio Unit \(slot) could not load: \(reason)"
        case .format(let slot): "Audio Unit \(slot) does not support the required mono/stereo format."
        case .state(let slot, let reason): "Audio Unit \(slot) document state failed: \(reason)"
        case .parameter(let slot): "Audio Unit \(slot) refused the parameter edit."
        case .render(let slot, let status): "Audio Unit \(slot) rendering failed (\(status))."
        case .changedLatency(let slot): "Audio Unit \(slot) changed latency. Restart the mixer."
        case .changedTail(let slot): "Audio Unit \(slot) changed its declared tail. Restart the mixer."
        case .latencyLimit: "Audio Unit latency exceeds the declared render budget."
        case .tailLimit: "Audio Unit tail exceeds the declared render budget."
        case .incompletePCM: "Mixer input/output PCM is incomplete or has the wrong shape."
        case .nonfinitePCM: "Mixer input/output contains nonfinite samples."
        case .discontinuousPCM: "Mixer PCM does not continue the frozen frame clock."
        case .noProgress: "Audio rendering made no progress within the retry budget."
        case .finished: "This mixer instance is finished; create an independent instance to seek or restart."
        }
    }
}

/// Evidence, not permission. The owner must keep device access and accepted timing verified per read.
public struct MixerSourceSnapshot: Sendable, Equatable {
    public let source: SourceID
    public let witness: RawSourceIdentity
    public let interpretation: FormatInterpretation

    public init(source: SourceID, witness: RawSourceIdentity, interpretation: FormatInterpretation) {
        self.source = source
        self.witness = witness
        self.interpretation = interpretation
    }
}

public struct MixerRoute: Sendable, Equatable {
    public let speaker: SpeakerID
    public let reference: ChannelReference
    public let source: MixerSourceSnapshot
    public let inputGainDB: Double
    public let strip: SpeakerMixState
}

/// Processing is 48 kHz planar Float32. Speakers are mono, Master/output stereo.
/// Equal-power mono pan: center is -3.0103 dB in each output, not two unity copies.
public enum MixerPanLaw: String, Sendable {
    case equalPower

    public func gains(pan: Double) -> (left: Float, right: Float) {
        let angle = (pan + 1) * .pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }
}

/// All values are frozen with the recipe, including the deliberate seek/reset and tail behavior.
public struct MixerRenderPolicy: Sendable, Equatable {
    public let maximumLatencyFrames: Int
    public let maximumTailFrames: Int
    public let prerollFrames: Int
    public let tail: Tail

    public enum Tail: Sendable, Equatable {
        /// Exact program only; latency is removed, effect decay beyond the program is discarded.
        case truncate
        /// Include the reported, serial-chain tail after the program, within maximumTailFrames.
        case includeReported
    }

    public init(maximumLatencyFrames: Int = 96_000, maximumTailFrames: Int = 480_000,
                prerollFrames: Int = 0, tail: Tail = .truncate) {
        self.maximumLatencyFrames = maximumLatencyFrames
        self.maximumTailFrames = maximumTailFrames
        self.prerollFrames = prerollFrames
        self.tail = tail
    }

    var isValid: Bool {
        (0...480_000).contains(maximumLatencyFrames) && (0...2_880_000).contains(maximumTailFrames)
            && (0...480_000).contains(prerollFrames)
    }
}

public struct MixerRecipe: Sendable, Equatable {
    public static let sampleRate = 48_000
    public static let blockFrames = 512
    public static let maximumWindowFrames = 240_000
    public static let maximumSpeakers = 64

    public let episode: EpisodeID
    public let dependencies: EpisodeProcessingInputs
    public let routes: [MixerRoute]
    public let master: MasterMixState
    public let programFrames: Range<Int64>
    public let panLaw: MixerPanLaw
    public let policy: MixerRenderPolicy

    public init(episode: Episode, sources: [MixerSourceSnapshot], programFrames: Range<Int64>,
                panLaw: MixerPanLaw = .equalPower, policy: MixerRenderPolicy = .init()) throws {
        let mix = episode.mix ?? EpisodeMixState()
        guard policy.isValid, mix.validationIssues(in: episode).isEmpty,
              !programFrames.isEmpty, programFrames.lowerBound >= -ManualEpisodeCut.frameLimit,
              programFrames.lowerBound - Int64(policy.prerollFrames) >= -ManualEpisodeCut.frameLimit,
              programFrames.upperBound <= ManualEpisodeCut.frameLimit,
              !episode.speakerAssignments.isEmpty,
              episode.speakerAssignments.count <= Self.maximumSpeakers,
              Set(sources.map(\.source)).count == sources.count,
              Set(episode.speakerAssignments.map(\.speakerID)).count == episode.speakerAssignments.count
        else { throw MixerFailure.invalidRecipe("invalid mix, program range, policy, or speaker count") }
        var routes: [MixerRoute] = []
        for assignment in episode.speakerAssignments {
            guard assignment.primaryConfirmation == .userConfirmed, let primary = assignment.primary else {
                throw MixerFailure.unconfirmedPrimary(assignment.speakerID)
            }
            guard let source = sources.first(where: { $0.source == primary.sourceID }),
                  source.interpretation.source == primary.sourceID,
                  let channel = primary.resolvedChannel(channelCount: source.interpretation.channelCount),
                  (1...2).contains(source.interpretation.channelCount),
                  episode.source(primary.sourceID) != nil else {
                throw MixerFailure.unresolvedChannel(primary.sourceID)
            }
            let reference = ChannelReference(sourceID: primary.sourceID, statedChannel: channel)
            // A single microphone channel must not be doubled by assigning it to two production strips.
            guard !routes.contains(where: { $0.reference == reference }) else {
                throw MixerFailure.invalidRecipe("a Primary channel is assigned to multiple speakers")
            }
            routes.append(MixerRoute(speaker: assignment.speakerID, reference: reference, source: source,
                inputGainDB: mix.inputGainDB(for: primary.sourceID, channel: channel),
                strip: mix.state(for: assignment.speakerID)))
        }
        self.episode = episode.id
        dependencies = EpisodeProcessingInputs(episode)
        self.routes = routes
        master = mix.master
        self.programFrames = programFrames
        self.panLaw = panLaw
        self.policy = policy
    }

    public func isCurrent(in episode: Episode, sources: [MixerSourceSnapshot]) -> Bool {
        episode.id == self.episode && EpisodeProcessingInputs(episode) == dependencies
            && routes.allSatisfy { route in sources.contains(route.source) }
    }
}

public struct MixerPCMWindow: Sendable {
    public let frames: Range<Int64>
    public let channels: [ChannelReference: [Float]]

    public init(frames: Range<Int64>, channels: [ChannelReference: [Float]]) {
        self.frames = frames
        self.channels = channels
    }
}

/// Long source preparation is raw PCM, never preprocessed effect/fader output.
public enum MixerLiveTiming {
    public static let sourceWindowFrames = 48_000
    public static let processingBlockFrames = MixerRecipe.blockFrames
    public static let maximumScheduledAheadFrames = 4096
    public static let startLeadFrames = 2048
    /// One in-flight block may be added after checking the scheduled horizon.
    public static let maximumPreparedControlFrames = maximumScheduledAheadFrames + processingBlockFrames
}

public struct MixerMeter: Sendable, Equatable {
    public let peak: Float
    public let rms: Float
    public var headroomDB: Double { peak == 0 ? .infinity : -20 * log10(Double(peak)) }
    public var clipped: Bool { peak > 1 }

    init(_ samples: [Float]) {
        peak = samples.reduce(0) { max($0, abs($1)) }
        rms = samples.isEmpty ? 0 : Float(sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            / Double(samples.count)))
    }
}

public struct MixerPCMOutput: Sendable {
    /// Absolute edited program frame, or program end + tail offset.
    public let firstFrame: Int64
    public let channels: [[Float]]
    public let speakerMeters: [SpeakerID: MixerMeter]
    public let masterMeters: [MixerMeter]
    public var frameCount: Int { channels.first?.count ?? 0 }

    public init(firstFrame: Int64, channels: [[Float]], speakerMeters: [SpeakerID: MixerMeter] = [:]) {
        self.firstFrame = firstFrame
        self.channels = channels
        self.speakerMeters = speakerMeters
        masterMeters = channels.map(MixerMeter.init)
    }
}
