import Foundation
import WWCore
import WWDecode
import WWRender

/// Why a cursor-backed stream could not serve a render request.
enum SampleStreamFailure: Error, Sendable, Equatable {
    /// The request starts before the retained history (requests must only ever move forward, apart from
    /// the kernel overlap between consecutive segment renders).
    case historyExhausted(requested: Int64, retainedFrom: Int64)
    /// The source ended before the requested frames.
    case endOfSource(requested: Int64, available: Int64)
    case invalidChannel(Int)
    /// The cursor returned a chunk that does not continue where the last one ended.
    case discontinuity(expected: Int64, actual: Int64)
}

/// Serves ascending frame requests for one source from a `DecodingCursor`, keeping only a short history so
/// consecutive renders (which overlap by the kernel's reach) can be served without seeking. Frames the
/// renderer skips are decoded and dropped, never retained. Memory: history + one request + one chunk.
actor SourceSampleStream {
    let cursor: DecodingCursor
    let channelCount: Int
    /// Frames kept below each request's first frame.
    let history: Int64
    /// First retained frame. Invariant: the retained frames are exactly `start ..< next`.
    private var start: Int64 = 0
    /// The cursor's position: the first frame not yet taken from it.
    private var next: Int64 = 0
    private var channels: [[Float]]
    private(set) var peakHeldFrames = 0

    init(cursor: DecodingCursor, channelCount: Int, history: Int64) {
        self.cursor = cursor
        self.channelCount = channelCount
        self.history = history
        channels = Array(repeating: [], count: channelCount)
    }

    func samples(frames: Range<Int64>, decodedChannels: [Int]) async throws -> [[Float]] {
        for channel in decodedChannels where channel < 0 || channel >= channelCount { throw SampleStreamFailure.invalidChannel(channel) }
        guard frames.lowerBound >= start else {
            throw SampleStreamFailure.historyExhausted(requested: frames.lowerBound, retainedFrom: start)
        }
        let keepFrom = frames.lowerBound - history
        drop(below: keepFrom)
        while next < frames.upperBound {
            guard let chunk = try await cursor.next() else {
                throw SampleStreamFailure.endOfSource(requested: frames.upperBound, available: next)
            }
            guard chunk.firstSourceFrame == next else {
                throw SampleStreamFailure.discontinuity(expected: next, actual: chunk.firstSourceFrame)
            }
            guard chunk.channelCount == channelCount else { throw SampleStreamFailure.invalidChannel(chunk.channelCount) }
            let chunkEnd = chunk.firstSourceFrame + Int64(chunk.frameCount)
            next = chunkEnd
            if chunkEnd <= keepFrom {
                // Entirely before anything still needed (the retained frames are already empty): skip it.
                start = chunkEnd
                continue
            }
            // Non-zero only when nothing is retained (retained frames end at the chunk's first frame).
            let skip = Int(Swift.max(0, keepFrom - chunk.firstSourceFrame))
            start += Int64(skip)
            for c in 0 ..< channelCount {
                let base = c * chunk.frameCount
                channels[c].append(contentsOf: chunk.samples[(base + skip) ..< (base + chunk.frameCount)])
            }
            peakHeldFrames = Swift.max(peakHeldFrames, channels.first?.count ?? 0)
        }
        let lo = Int(frames.lowerBound - start)
        let hi = Int(frames.upperBound - start)
        return decodedChannels.map { Array(channels[$0][lo ..< hi]) }
    }

    private func drop(below frame: Int64) {
        let held = Int64(channels.first?.count ?? 0)
        let count = Swift.min(Swift.max(0, frame - start), held)
        if count > 0 {
            for c in channels.indices { channels[c].removeFirst(Int(count)) }
            start += count
        }
    }

    func verifyUnchanged() async throws(DecodeFailure) {
        try await cursor.verifyUnchanged()
    }
}

/// A `RenderSampleProvider` over one stream per source. Valid only inside the `withDecodingCursor` bodies
/// that lent the cursors.
struct CursorSampleProvider: RenderSampleProvider {
    let streams: [SourceID: SourceSampleStream]

    func samples(for request: RenderSampleRequest) async throws -> [[Float]] {
        guard let stream = streams[request.source] else {
            throw AlignmentWorkFailure.sourceFactsUnavailable(request.source)
        }
        return try await stream.samples(frames: request.frames, decodedChannels: request.decodedChannels)
    }

    /// Frames each stream must keep below a request so the next segment's first request (which reaches back
    /// by at most the kernel's support, scaled by the largest decimation) can still be served.
    static func history(for recipe: RenderRecipe) -> Int64 {
        Int64(2 * (recipe.kernel.halfWidth * recipe.maximumDecimation + 2) + 64)
    }
}
