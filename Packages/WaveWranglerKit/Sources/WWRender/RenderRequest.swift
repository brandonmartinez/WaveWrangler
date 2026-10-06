import Foundation
import WWCore
import WWTimeMap

// MARK: - Channels and inputs

/// One output channel: exactly one decoded channel of one occurrence, with its stated identity.
///
/// There is no gain, polarity, mix or proxy field: an output channel is the clock-corrected render of its
/// one input channel, nothing else.
public struct RenderChannel: Sendable, Hashable, Codable {
    /// The occurrence whose decoded audio feeds this channel. Must belong to the request's group map.
    public let occurrence: SourceOccurrenceID
    /// Zero-based channel index in the occurrence's decoded (planar) audio.
    public let decodedChannel: Int
    /// The channel the user stated for this source (#63 explicit stated channel), or unknown. When known it
    /// must equal `decodedChannel`; a mismatch is a routing swap and is refused.
    public let statedChannel: Knowledge<Int>

    public init(occurrence: SourceOccurrenceID, decodedChannel: Int, statedChannel: Knowledge<Int>) {
        self.occurrence = occurrence
        self.decodedChannel = decodedChannel
        self.statedChannel = statedChannel
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(occurrence)
        hasher.combine(decodedChannel)
        hasher.combine(statedChannel.value)
    }
}

/// The version of the decoded input asset an occurrence is rendered from (for example the decoder and
/// source-revision identity of the decoded buffers). Opaque to the renderer; recorded in the manifest so
/// a render can be invalidated when its input changes.
public struct RenderInputAsset: Sendable, Hashable, Codable {
    public let occurrence: SourceOccurrenceID
    public let assetVersion: String

    public init(occurrence: SourceOccurrenceID, assetVersion: String) {
        self.occurrence = occurrence
        self.assetVersion = assetVersion
    }
}

/// A render of one recorder group onto an explicit range of the aligned output grid `k / outputRate`.
public struct RenderRequest: Sendable {
    /// The group's time map. Its transform (and nothing else) is applied to every channel.
    public let groupMap: GroupTimeMap
    public let outputRate: NominalRate
    /// Output frames `k` (aligned instant `k / outputRate`). Explicit: the start is the delay, and frames
    /// with no supported source position are explicit zero padding.
    public let outputFrames: Range<Int64>
    public let channels: [RenderChannel]
    /// One entry per occurrence used by `channels`.
    public let inputAssets: [RenderInputAsset]
    public let recipe: RenderRecipe

    public init(groupMap: GroupTimeMap, outputRate: NominalRate, outputFrames: Range<Int64>, channels: [RenderChannel], inputAssets: [RenderInputAsset], recipe: RenderRecipe = .m2Candidate) {
        self.groupMap = groupMap
        self.outputRate = outputRate
        self.outputFrames = outputFrames
        self.channels = channels
        self.inputAssets = inputAssets
        self.recipe = recipe
    }

    /// The largest output range accepted (2^40 frames, the WWTimeMap frame envelope).
    public static let maximumOutputFrames: Int64 = TimeMapEnvelope.maxFrameCount
}

// MARK: - Failures

/// Why a render was refused or stopped. Every failure after the sink was created abandons it, so nothing
/// partial is ever published.
public enum RenderFailure: Error, Sendable, Equatable {
    case cancelled
    case invalidRecipe(String)
    case emptyChannelList
    case invalidOutputRange
    case unknownOccurrence(SourceOccurrenceID)
    case invalidDecodedChannel(RenderChannel)
    /// The same decoded channel of the same occurrence appears twice (a duplicated or swapped route).
    case duplicateChannel(RenderChannel)
    /// The stated channel differs from the decoded channel routed to it.
    case statedChannelMismatch(RenderChannel)
    case missingInputAsset(SourceOccurrenceID)
    case duplicateInputAsset(SourceOccurrenceID)
    /// An input asset names an occurrence no channel uses, or carries an empty version.
    case invalidInputAsset(SourceOccurrenceID)
    /// The span's source-frames-per-output-frame ratio exceeds the recipe's maximum decimation.
    case ratioOutsideEnvelope(SourceOccurrenceID, sourceFramesPerOutputFrame: ExactRational)
    /// Exact position arithmetic would leave `Int128`; refused rather than approximated.
    case arithmeticEnvelopeExceeded
    /// The planned exact source position disagreed with `GroupTimeMap.sourceFrame` (fail closed).
    case mapInverseMismatch(SourceOccurrenceID, outputFrame: Int64)
    case providerFailed(String)
    /// The provider returned the wrong number of channels or frames.
    case providerShapeMismatch(SourceOccurrenceID)
    /// The provider returned NaN or infinity. Never rendered or silently replaced.
    case nonFiniteInput(SourceOccurrenceID)
    case sinkFailed(String)
}
