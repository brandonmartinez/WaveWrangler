import Dispatch
import Foundation
import WWCore
import WWSources

/// One decode's read loop: reads raw codec frames, enforces the reader/stream-length guards and trims
/// priming and remainder frames. Shared by `SourceDecoder.decode` (push into a sink) and
/// `DecodingCursor` (pull). Not `Sendable`: it owns the reader and its buffer.
struct ChunkPump {
    enum Step: Sendable {
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
    private var firstSourceFrame: Int64 = 0
    private var firstStreamFrame: Int64 = 0

    var position: Int64 { firstSourceFrame + published }

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
    mutating func step(maximumFrames: Int? = nil) throws(DecodeFailure) -> Step {
        let request = min(capacity, maximumFrames ?? capacity)
        let readBuffer = request == capacity ? buffer : RawDecodeBuffer(channelCount: channels, capacityFrames: request)
        let got = try reader.readRawFrames(into: readBuffer)
        reads += 1
        guard got >= 0, got <= request else { throw .inconsistentStream(.readerOverran(requested: request, returned: got)) }
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
        let buffer = readBuffer
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

    mutating func seek(toSourceFrame frame: Int64) throws(DecodeFailure) {
        guard frame >= 0, frame <= valid else { throw .invalidSourceFrame(frame) }
        guard reader.supportsRandomAccess else { throw .seekUnavailable }
        try reader.seekRawFrame(to: priming + frame)
        streamPosition = priming + frame
        firstStreamFrame = streamPosition
        firstSourceFrame = frame
        published = 0
    }

    /// After `.end`: every declared valid frame must have been produced.
    func completedReport() throws(DecodeFailure) -> DecodeReport {
        let expected = valid - firstSourceFrame
        guard published == expected else { throw .incompleteContent(expectedFrames: expected, decodedFrames: published) }
        return DecodeReport(
            codecStreamFramesRead: streamPosition - firstStreamFrame,
            leadingStreamFramesDiscarded: max(0, priming - firstStreamFrame),
            trailingStreamFramesDiscarded: streamPosition - validEnd,
            readCalls: reads,
            chunkCapacityFrames: capacity
        )
    }
}

private final class CursorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false

    func cancel() { lock.withLock { canceled = true } }
    var isCanceled: Bool { lock.withLock { canceled } }
}

/// Owns the non-Sendable reader and pump on a serial Dispatch queue. Synchronous AudioToolbox and file
/// calls therefore never block a Swift cooperative-executor thread.
fileprivate final class CursorWorker: @unchecked Sendable {
    struct StepResult: Sendable {
        var step: ChunkPump.Step
        var position: Int64
        var readCalls: Int
    }

    let interpretation: FormatInterpretation
    let supportsRandomAccess: Bool
    private let queue: DispatchQueue
    private let url: URL
    private let io: any SourceIO
    private let before: SourceMetadata
    private var pump: ChunkPump
    private var closed = false

    private init(
        queue: DispatchQueue,
        url: URL,
        io: any SourceIO,
        before: SourceMetadata,
        interpretation: FormatInterpretation,
        pump: consuming ChunkPump
    ) {
        self.queue = queue
        self.url = url
        self.io = io
        self.before = before
        self.interpretation = interpretation
        supportsRandomAccess = pump.reader.supportsRandomAccess
        self.pump = pump
    }

    static func make(
        decoder: SourceDecoder,
        url: URL,
        source: SourceID,
        matching witness: RawSourceIdentity? = nil
    ) async throws(DecodeFailure) -> CursorWorker {
        let queue = DispatchQueue(label: "com.brandonmartinez.wavewrangler.decode-cursor", qos: .userInitiated)
        let cancellation = CursorCancellation()
        let result: Result<CursorWorker, DecodeFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCanceled else {
                        continuation.resume(returning: .failure(.canceled))
                        return
                    }
                    do throws(DecodeFailure) {
                        let before = try decoder.preflight(url)
                        guard !cancellation.isCanceled else { throw .canceled }
                        let reader: any DecodingContentReader
                        if let witness {
                            guard let gateway = decoder.content as? SystemSourceContentIO else {
                                throw .sourceIdentityMismatch
                            }
                            reader = try gateway.openForDecoding(url, matching: witness)
                        } else {
                            reader = try decoder.content.openForDecoding(url)
                        }
                        do throws(DecodeFailure) {
                            try SourceDecoder.verifyOpened(reader.facts.openedFile, matches: before)
                            let interpretation = try DecodeEnvelope.interpret(
                                reader.facts,
                                url: url,
                                source: source,
                                fingerprint: before.fingerprint
                            )
                            guard !cancellation.isCanceled else { throw .canceled }
                            let pump = ChunkPump(
                                reader: reader,
                                interpretation: interpretation,
                                chunkFrames: decoder.configuration.chunkFrames
                            )
                            continuation.resume(returning: .success(CursorWorker(
                                queue: queue,
                                url: url,
                                io: decoder.access.io,
                                before: before,
                                interpretation: interpretation,
                                pump: pump
                            )))
                        } catch {
                            reader.close()
                            throw error
                        }
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    func step(maximumFrames: Int? = nil) async throws(DecodeFailure) -> StepResult {
        let cancellation = CursorCancellation()
        let result: Result<StepResult, DecodeFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !closed, !cancellation.isCanceled else {
                        continuation.resume(returning: .failure(.canceled))
                        return
                    }
                    do throws(DecodeFailure) {
                        let step = try pump.step(maximumFrames: maximumFrames)
                        if case .end = step { _ = try pump.completedReport() }
                        continuation.resume(returning: .success(StepResult(
                            step: step,
                            position: pump.position,
                            readCalls: pump.reads
                        )))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    func seek(toSourceFrame frame: Int64) async throws(DecodeFailure) {
        let cancellation = CursorCancellation()
        let result: Result<Void, DecodeFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !closed, !cancellation.isCanceled else {
                        continuation.resume(returning: .failure(.canceled))
                        return
                    }
                    do throws(DecodeFailure) {
                        try SourceDecoder.verifyUnchanged(url, io: io, reader: pump.reader, before: before)
                        try pump.seek(toSourceFrame: frame)
                        try SourceDecoder.verifyUnchanged(url, io: io, reader: pump.reader, before: before)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    func verifyUnchanged() async throws(DecodeFailure) {
        let cancellation = CursorCancellation()
        let result: Result<Void, DecodeFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !closed, !cancellation.isCanceled else {
                        continuation.resume(returning: .failure(.canceled))
                        return
                    }
                    do throws(DecodeFailure) {
                        try SourceDecoder.verifyUnchanged(url, io: io, reader: pump.reader, before: before)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !closed {
                    closed = true
                    pump.reader.close()
                }
                continuation.resume()
            }
        }
    }
}

/// A pull-style view of one open, verified decode, for consumers that need frames on demand (streamed
/// rendering, bounded analysis) instead of a push sink. It exists only inside
/// `SourceDecoder.withDecodingCursor`, which owns the security scope, the read-only open and the final
/// staleness check; once that call returns, the cursor is closed and every call throws `.canceled`.
///
/// Chunks come back in source order, priming and remainder already removed, exactly as `decode` would
/// publish them. Cancellation of the calling task is checked before and after every read. The body may
/// stage derived work, but must publish it only after `withDecodingCursor` returns successfully; the
/// enclosing call verifies every result derived from reads or seeks, even after an explicit check.
public actor DecodingCursor {
    public nonisolated let interpretation: FormatInterpretation
    public nonisolated let supportsRandomAccess: Bool
    private let worker: CursorWorker
    private var currentPosition: Int64 = 0
    private var currentReadCalls = 0
    private var ended = false
    private var closed = false
    private var failure: DecodeFailure?
    private var hasSought = false

    fileprivate init(worker: CursorWorker) {
        self.worker = worker
        interpretation = worker.interpretation
        supportsRandomAccess = worker.supportsRandomAccess
    }

    /// Source frame of the next chunk's first frame; seeking changes this without decoding a prefix.
    public var position: Int64 { currentPosition }

    /// Reader calls made so far.
    public var readCalls: Int { currentReadCalls }

    /// The next decoded chunk, or `nil` at the end of the valid frames (after the frame-count check).
    /// A failure is terminal: every later call rethrows it.
    public func next() async throws(DecodeFailure) -> DecodedChunk? {
        try await nextChunk(upToSourceFrame: nil)
    }

    /// Package-only bounded read for a waveform viewport. Does not decode beyond this source boundary.
    package func next(upToSourceFrame limit: Int64) async throws(DecodeFailure) -> DecodedChunk? {
        try await nextChunk(upToSourceFrame: limit)
    }

    private func nextChunk(upToSourceFrame limit: Int64?) async throws(DecodeFailure) -> DecodedChunk? {
        try checkUsable()
        if ended { return nil }
        do throws(DecodeFailure) {
            while true {
                try SourceDecoder.checkCancellation()
                let maximum: Int?
                if let limit {
                    guard limit > currentPosition, limit <= interpretation.frames.validFrames else {
                        throw .invalidSourceFrame(limit)
                    }
                    // Before the first read, the pump may still have codec priming to discard.
                    let remaining = limit - currentPosition
                    maximum = Int(min(remaining, Int64(Int.max)))
                } else {
                    maximum = nil
                }
                let result = try await worker.step(maximumFrames: maximum)
                currentPosition = result.position
                currentReadCalls = result.readCalls
                try SourceDecoder.checkCancellation()
                switch result.step {
                case let .frames(chunk?):
                    return chunk
                case .frames(nil):
                    continue
                case .end:
                    ended = true
                    return nil
                }
            }
        } catch {
            failure = error
            throw error
        }
    }

    /// Seeks within the same opened source. Unsupported codecs fail rather than guessing a time origin.
    /// Cancellation and source identity are checked around the seek; failures remain terminal.
    package func seek(toSourceFrame frame: Int64) async throws(DecodeFailure) {
        try checkUsable()
        do throws(DecodeFailure) {
            try SourceDecoder.checkCancellation()
            guard frame >= 0, frame <= interpretation.frames.validFrames else { throw .invalidSourceFrame(frame) }
            try await worker.seek(toSourceFrame: frame)
            try SourceDecoder.checkCancellation()
            currentPosition = frame
            ended = false
            hasSought = true
        } catch {
            failure = error
            throw error
        }
    }

    /// The open descriptor and the path's metadata must both still match what was checked at open.
    public func verifyUnchanged() async throws(DecodeFailure) {
        try checkUsable()
        do throws(DecodeFailure) {
            try SourceDecoder.checkCancellation()
            try await worker.verifyUnchanged()
            try SourceDecoder.checkCancellation()
        } catch {
            failure = error
            throw error
        }
    }

    func verifyForReturn() async throws(DecodeFailure) {
        try checkUsable()
        if currentReadCalls > 0 || hasSought { try await verifyUnchanged() }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await worker.close()
    }

    private func checkUsable() throws(DecodeFailure) {
        if closed { throw .canceled }
        if let failure { throw failure }
    }
}

extension SourceDecoder {
    /// Opens one source exactly as `decode` does (security scope → metadata preflight → read-only open →
    /// opened-file identity → envelope interpretation) and lends a `DecodingCursor` to `body`. After
    /// `body` returns, any terminal cursor failure is rethrown and every result derived from reads receives
    /// a final staleness check, even if the body explicitly checked earlier. Cancellation is also checked,
    /// so a result built from the cursor is returned only if the source was unchanged. The reader is
    /// closed and the scope released on every path.
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

    /// Package-only mechanical decode for an independently confirmed raw identity. This is not an
    /// authority issuer: the caller must separately verify consent and the selected source before
    /// providing the witness. Unlike the ordinary cursor, a mismatched opened descriptor is refused
    /// by the system gateway before the audio parser can read any bytes.
    @concurrent
    package func withWitnessBoundDecodingCursor<T: Sendable>(
        _ url: URL,
        source: SourceID,
        matching witness: RawSourceIdentity,
        _ body: @Sendable (DecodingCursor) async throws -> T
    ) async throws -> T {
        try Self.checkCancellation()
        return try await access.withScopedAccess(to: url) { scopedURL in
            try await openCursor(scopedURL, source: source, matching: witness, body)
        }
    }

    @concurrent
    private func openCursor<T: Sendable>(
        _ url: URL,
        source: SourceID,
        matching witness: RawSourceIdentity? = nil,
        _ body: @Sendable (DecodingCursor) async throws -> T
    ) async throws -> T {
        let worker = try await CursorWorker.make(decoder: self, url: url, source: source, matching: witness)
        do {
            try Self.checkCancellation()
        } catch {
            await worker.close()
            throw error
        }
        let cursor = DecodingCursor(worker: worker)
        let result: T
        do {
            result = try await body(cursor)
            try await cursor.verifyForReturn()
            try Self.checkCancellation()
        } catch {
            await cursor.close()
            throw error
        }
        await cursor.close()
        return result
    }
}
