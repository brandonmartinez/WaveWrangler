import Foundation
import WWCore
import WWSources

/// One decode's read loop: reads raw codec frames, enforces the reader/stream-length guards and trims
/// priming and remainder frames. Shared by `SourceDecoder.decode` (push into a sink) and
/// `DecodingCursor` (pull). Not `Sendable`: it owns the reader and its buffer.
struct ChunkPump {
    enum Step {
        /// One read produced frames; `nil` when every frame read was priming or remainder.
        case frames(DecodedChunk?)
        case end
    }

    let reader: any DecodingContentReader
    private let buffer: RawDecodeBuffer
    private let channels: Int
    private let capacity: Int
    private let priming: Int64
    private let valid: Int64
    private let validEnd: Int64
    private let declaredStreamEnd: Int64
    private let streamLimit: Int64
    private(set) var streamPosition: Int64 = 0
    private(set) var published: Int64 = 0
    private(set) var reads = 0

    init(reader: any DecodingContentReader, interpretation: FormatInterpretation, chunkFrames: Int) {
        self.reader = reader
        channels = interpretation.channelCount
        capacity = chunkFrames
        buffer = RawDecodeBuffer(channelCount: channels, capacityFrames: capacity)
        priming = interpretation.frames.primingFrames
        valid = interpretation.frames.validFrames
        validEnd = priming + valid
        declaredStreamEnd = validEnd + interpretation.frames.remainderFrames
        // One packet of slack: codecs may emit up to a packet beyond the declared remainder.
        streamLimit = declaredStreamEnd + Int64(interpretation.packets.framesPerPacket)
    }

    /// Exactly one reader call.
    mutating func step() throws(DecodeFailure) -> Step {
        let got = try reader.readRawFrames(into: buffer)
        reads += 1
        guard got >= 0, got <= capacity else { throw .inconsistentStream(.readerOverran(requested: capacity, returned: got)) }
        if got == 0 { return .end }
        let start = streamPosition
        streamPosition += Int64(got)
        guard streamPosition <= streamLimit else {
            throw .inconsistentStream(.streamExceedsDeclaredLength(declaredStreamFrames: declaredStreamEnd, observedAtLeast: streamPosition))
        }
        let low = max(start, priming)
        let high = min(streamPosition, validEnd)
        guard high > low else { return .frames(nil) }
        let count = Int(high - low)
        let offset = Int(low - start)
        let channels = channels
        let buffer = buffer
        let samples = [Float](unsafeUninitializedCapacity: count * channels) { destination, initialized in
            for channel in 0..<channels {
                let source = buffer.channel(channel)
                (destination.baseAddress! + channel * count).initialize(from: source.baseAddress! + offset, count: count)
            }
            initialized = count * channels
        }
        published += Int64(count)
        return .frames(DecodedChunk(firstSourceFrame: low - priming, frameCount: count, channelCount: channels, samples: samples))
    }

    /// After `.end`: every declared valid frame must have been produced.
    func completedReport() throws(DecodeFailure) -> DecodeReport {
        guard published == valid else { throw .incompleteContent(expectedFrames: valid, decodedFrames: published) }
        return DecodeReport(
            codecStreamFramesRead: streamPosition,
            leadingStreamFramesDiscarded: priming,
            trailingStreamFramesDiscarded: streamPosition - validEnd,
            readCalls: reads,
            chunkCapacityFrames: capacity
        )
    }
}

/// A pull-style view of one open, verified decode, for consumers that need frames on demand (streamed
/// rendering, bounded analysis) instead of a push sink. It exists only inside
/// `SourceDecoder.withDecodingCursor`, which owns the security scope, the read-only open and the final
/// staleness check; once that call returns, the cursor is closed and every call throws `.cancelled`.
///
/// Chunks come back in source order, priming and remainder already removed, exactly as `decode` would
/// publish them. Cancellation of the calling task is checked before every read. A consumer that derives
/// a result from what it read must call `verifyUnchanged()` before publishing it (the enclosing call
/// also verifies before returning, if anything was read since the last verification).
public actor DecodingCursor {
    public nonisolated let interpretation: FormatInterpretation
    private let url: URL
    private let io: any SourceIO
    private let before: SourceMetadata
    private var pump: ChunkPump
    private var ended = false
    private var closed = false
    private var failure: DecodeFailure?
    private var verifiedAtRead = 0

    init(url: URL, io: any SourceIO, before: SourceMetadata, interpretation: FormatInterpretation, pump: sending ChunkPump) {
        self.url = url
        self.io = io
        self.before = before
        self.interpretation = interpretation
        self.pump = pump
    }

    /// Valid frames returned so far: the source frame of the next chunk's first frame.
    public var position: Int64 { pump.published }

    /// Reader calls made so far.
    public var readCalls: Int { pump.reads }

    /// The next decoded chunk, or `nil` at the end of the valid frames (after the frame-count check).
    /// A failure is terminal: every later call rethrows it.
    public func next() throws(DecodeFailure) -> DecodedChunk? {
        try checkUsable()
        if ended { return nil }
        do throws(DecodeFailure) {
            while true {
                try SourceDecoder.checkCancellation()
                switch try pump.step() {
                case let .frames(chunk?):
                    return chunk
                case .frames(nil):
                    continue
                case .end:
                    _ = try pump.completedReport()
                    ended = true
                    return nil
                }
            }
        } catch {
            failure = error
            throw error
        }
    }

    /// The open descriptor and the path's metadata must both still match what was checked at open.
    public func verifyUnchanged() throws(DecodeFailure) {
        try checkUsable()
        do throws(DecodeFailure) {
            try SourceDecoder.verifyUnchanged(url, io: io, reader: pump.reader, before: before)
            verifiedAtRead = pump.reads
        } catch {
            failure = error
            throw error
        }
    }

    var hasUnverifiedReads: Bool { pump.reads > verifiedAtRead }

    func close() {
        guard !closed else { return }
        closed = true
        pump.reader.close()
    }

    private func checkUsable() throws(DecodeFailure) {
        if closed { throw .cancelled }
        if let failure { throw failure }
    }
}

extension SourceDecoder {
    /// Opens one source exactly as `decode` does (security scope → metadata preflight → read-only open →
    /// opened-file identity → envelope interpretation) and lends a `DecodingCursor` to `body`. After
    /// `body` returns, any unverified reads are checked for staleness and cancellation is checked, so a
    /// result built from the cursor is returned only if the source was unchanged. The reader is closed
    /// and the scope released on every path.
    ///
    /// Opening without reading (a header probe) decodes nothing.
    @concurrent
    public func withDecodingCursor<T: Sendable>(
        _ url: URL,
        source: SourceID,
        _ body: @Sendable (DecodingCursor) async throws -> T
    ) async throws -> T {
        try Self.checkCancellation()
        return try await access.withScopedAccess(to: url) { scopedURL in
            try await openCursor(scopedURL, source: source, body)
        }
    }

    @concurrent
    private func openCursor<T: Sendable>(
        _ url: URL,
        source: SourceID,
        _ body: @Sendable (DecodingCursor) async throws -> T
    ) async throws -> T {
        let before = try preflight(url)
        try Self.checkCancellation()
        let reader = try content.openForDecoding(url)
        let interpretation: FormatInterpretation
        do throws(DecodeFailure) {
            try Self.verifyOpened(reader.facts.openedFile, matches: before)
            interpretation = try DecodeEnvelope.interpret(reader.facts, url: url, source: source, fingerprint: before.fingerprint)
            try Self.checkCancellation()
        } catch {
            reader.close()
            throw error
        }
        let pump = ChunkPump(reader: reader, interpretation: interpretation, chunkFrames: configuration.chunkFrames)
        let cursor = DecodingCursor(url: url, io: access.io, before: before, interpretation: interpretation, pump: pump)
        let result: T
        do {
            result = try await body(cursor)
            if await cursor.hasUnverifiedReads { try await cursor.verifyUnchanged() }
            try Self.checkCancellation()
        } catch {
            await cursor.close()
            throw error
        }
        await cursor.close()
        return result
    }
}
