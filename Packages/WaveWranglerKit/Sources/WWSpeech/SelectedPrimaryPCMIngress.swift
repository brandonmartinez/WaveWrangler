import WWCore
import WWDecode
import WWTimeMap

public enum SelectedPrimaryIngressRefusal: Error, Sendable, Equatable {
    case unselectedPrimary
    case trustedSourceReceiptUnavailable
}

/// No live media ingress exists yet. A confirmed assignment alone cannot attest to the current
/// publication, source revision, occurrence, proxy and opened channel; only a source-owned receipt
/// issued at the decode boundary can do so. In particular, caller-provided IDs are not receipts.
public struct SelectedPrimaryPCMIngress: Sendable {
    public init() {}

    public func requireAuthorization(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SelectedPrimaryIngressRefusal) {
        do {
            try SpeechInference.requireSelectedPrimary(
                model: model, episodeID: episodeID, speakerID: speakerID, channel: channel
            )
        } catch {
            throw .unselectedPrimary
        }
        throw .trustedSourceReceiptUnavailable
    }
}

public enum SyntheticPCMIngressFailure: Error, Sendable, Equatable {
    case invalidMapping
    case cancelled
}

/// A media-free, package-only frame extractor for generated decode chunks. Its inputs are untrusted
/// values, not evidence of selection or source identity. Never use its result to authorize inference.
package enum SyntheticPCMIngress {
    package enum Proxy: Sendable, Equatable {
        case original
        case derived
    }

    package struct Identity: Sendable, Equatable {
        package var source: SourceID
        package var revision: String
        package var occurrence: SourceOccurrenceID
        package var proxy: Proxy
        package var channel: Int

        package init(source: SourceID, revision: String, occurrence: SourceOccurrenceID, proxy: Proxy, channel: Int) {
            self.source = source
            self.revision = revision
            self.occurrence = occurrence
            self.proxy = proxy
            self.channel = channel
        }
    }

    package struct Window: Sendable, Equatable {
        package let sourceFrameRange: Range<Int64>
        package let pcm: [Float]
    }

    package static func extract(
        _ chunks: [DecodedChunk], identity: Identity, expected: Identity,
        sourceFrameStart: Int64, decodedFrameCount: Int64,
        sourceSampleRate: Int, sourceChannelCount: Int,
        isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws(SyntheticPCMIngressFailure) -> Window {
        guard !isCancelled() else { throw .cancelled }
        let (end, overflow) = sourceFrameStart.addingReportingOverflow(32_000)
        guard identity == expected, identity.proxy == .original, !identity.revision.isEmpty,
              !overflow, sourceFrameStart >= 0, end <= decodedFrameCount,
              sourceSampleRate == 16_000, sourceChannelCount > 0,
              identity.channel >= 0, identity.channel < sourceChannelCount
        else { throw .invalidMapping }

        var pcm: [Float] = []
        pcm.reserveCapacity(32_000)
        var next = sourceFrameStart
        for chunk in chunks {
            guard !isCancelled() else { throw .cancelled }
            guard chunk.frameCount > 0, chunk.channelCount == sourceChannelCount,
                  chunk.firstSourceFrame == next
            else { throw .invalidMapping }
            let (chunkEnd, chunkOverflow) = next.addingReportingOverflow(Int64(chunk.frameCount))
            guard !chunkOverflow, chunkEnd <= end else { throw .invalidMapping }
            let channel = chunk.channel(identity.channel)
            guard channel.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw .invalidMapping }
            pcm.append(contentsOf: channel)
            next = chunkEnd
        }
        guard !isCancelled() else { throw .cancelled }
        guard next == end else { throw .invalidMapping }
        return Window(sourceFrameRange: sourceFrameStart..<end, pcm: pcm)
    }
}
