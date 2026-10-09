import Foundation
import WWCore
import WWSources

/// One run of decoded frames, published in source order. `firstSourceFrame` is the source frame of
/// the chunk's first frame (see `DecodedFrameOrigin`).
public struct DecodedChunk: Sendable, Equatable {
    public let firstSourceFrame: Int64
    public let frameCount: Int
    public let channelCount: Int
    /// Planar: channel `c` occupies `c * frameCount ..< (c + 1) * frameCount`.
    public let samples: [Float]

    public init(firstSourceFrame: Int64, frameCount: Int, channelCount: Int, samples: [Float]) {
        precondition(samples.count == frameCount * channelCount)
        self.firstSourceFrame = firstSourceFrame
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.samples = samples
    }

    public func channel(_ index: Int) -> ArraySlice<Float> {
        samples[index * frameCount ..< (index + 1) * frameCount]
    }
}

/// Receives decoded chunks. The decoder creates the sink inside the decode task (it never crosses
/// isolation). It calls `append` in source order, then exactly one of `finish` (the decode is complete
/// and verified) or `abandon` (any failure or cancellation after the sink was made). Only the value
/// returned by `finish` is ever published.
public protocol DecodedAudioSink {
    associatedtype Product: Sendable
    mutating func append(_ chunk: DecodedChunk) throws
    mutating func finish() throws -> Product
    /// Discard everything appended. Sinks that stage output elsewhere must remove it here.
    mutating func abandon()
}

extension DecodedAudioSink {
    public mutating func abandon() {}
}

/// What one completed decode observed.
public struct DecodeReport: Sendable, Equatable {
    public var codecStreamFramesRead: Int64
    public var leadingStreamFramesDiscarded: Int64
    public var trailingStreamFramesDiscarded: Int64
    public var readCalls: Int
    public var chunkCapacityFrames: Int
}

/// A complete, verified decode.
public struct DecodedSource<Product: Sendable>: Sendable {
    public let interpretation: FormatInterpretation
    public let report: DecodeReport
    public let product: Product
}

/// Decodes one referenced original into a sink, off the main thread, in fixed-size chunks.
///
/// Order: security scope (WWSources ledger) → metadata preflight (WWSources' metadata gateway: regular
/// file, local content, size and date known) → read-only open (`SourceContentIO`) → check that the open
/// file is the checked file → envelope interpretation → chunked decode with priming/remainder removal
/// → frame-count check → staleness check (descriptor and path metadata unchanged) → `finish`.
/// Cancellation is checked before every read and before every publication; any failure abandons the
/// sink, closes the reader and releases the scope, so nothing partial or stale is published.
///
/// Memory: one `RawDecodeBuffer` of `channelCount × chunkFrames` floats plus one chunk in flight.
public struct SourceDecoder: Sendable {
    public struct Configuration: Sendable, Equatable {
        public static let maximumChunkFrames = 1 << 20
        public var chunkFrames: Int

        public init(chunkFrames: Int = 16_384) {
            self.chunkFrames = min(max(chunkFrames, 1), Self.maximumChunkFrames)
        }
    }

    public let access: SourceAccessContext
    /// The content gateway. Production decodes always use `SystemSourceContentIO`; only package code
    /// (tests) may substitute a double.
    package let content: any SourceContentIO
    public let configuration: Configuration

    public init(access: SourceAccessContext, configuration: Configuration = Configuration()) {
        self.init(access: access, content: SystemSourceContentIO(), configuration: configuration)
    }

    package init(access: SourceAccessContext, content: any SourceContentIO, configuration: Configuration = Configuration()) {
        self.access = access
        self.content = content
        self.configuration = configuration
    }

    /// Captures non-authorizing kernel evidence at an explicit confirmation boundary. This never
    /// opens an audio parser or reads source bytes; the caller must separately record consent.
    @concurrent
    public func captureRawIdentity(
        _ url: URL,
        matching fingerprint: FileSystemFingerprint
    ) async throws(DecodeFailure) -> RawSourceIdentity {
        try Self.checkCancellation()
        do {
            return try await access.withScopedAccess(to: url) { scoped in
                let before = try preflight(scoped)
                guard before.fingerprint == fingerprint else { throw DecodeFailure.sourceIdentityMismatch }
                let raw = try SystemSourceContentIO().captureRawIdentity(scoped, matching: before, io: access.io)
                try Self.checkCancellation()
                return raw
            }
        } catch let failure as DecodeFailure {
            throw failure
        } catch {
            throw .sinkFailed("unexpected identity capture error: \(error)")
        }
    }

    @concurrent
    public func decode<Sink: DecodedAudioSink>(
        _ url: URL,
        source: SourceID,
        makeSink: @escaping @Sendable (FormatInterpretation) throws -> Sink
    ) async throws(DecodeFailure) -> DecodedSource<Sink.Product> {
        try Self.checkCancellation()
        do {
            return try await access.withScopedAccess(to: url) { scopedURL in
                try await run(scopedURL, source: source, makeSink: makeSink)
            }
        } catch let failure as DecodeFailure {
            throw failure
        } catch {
            throw .sinkFailed("unexpected error: \(error)")
        }
    }

    @concurrent
    private func run<Sink: DecodedAudioSink>(
        _ url: URL,
        source: SourceID,
        makeSink: @Sendable (FormatInterpretation) throws -> Sink
    ) async throws(DecodeFailure) -> DecodedSource<Sink.Product> {
        let before = try preflight(url)
        try Self.checkCancellation()
        let reader = try content.openForDecoding(url)
        defer { reader.close() }
        try Self.verifyOpened(reader.facts.openedFile, matches: before)
        let interpretation = try DecodeEnvelope.interpret(reader.facts, url: url, source: source, fingerprint: before.fingerprint)
        try Self.checkCancellation()

        var sink: Sink
        do { sink = try makeSink(interpretation) } catch { throw .sinkFailed(String(describing: error)) }
        do throws(DecodeFailure) {
            let report = try await pump(reader, interpretation, into: &sink)
            try verifyUnchanged(url, reader: reader, before: before)
            try Self.checkCancellation()
            let product: Sink.Product
            do { product = try sink.finish() } catch { throw .sinkFailed(String(describing: error)) }
            return DecodedSource(interpretation: interpretation, report: report, product: product)
        } catch {
            sink.abandon()
            throw error
        }
    }

    private func pump<Sink: DecodedAudioSink>(
        _ reader: any DecodingContentReader,
        _ interpretation: FormatInterpretation,
        into sink: inout Sink
    ) async throws(DecodeFailure) -> DecodeReport {
        var pump = ChunkPump(reader: reader, interpretation: interpretation, chunkFrames: configuration.chunkFrames)
        while true {
            try Self.checkCancellation()
            guard case let .frames(chunk) = try pump.step() else { break }
            if let chunk {
                try Self.checkCancellation()
                do {
                    try sink.append(chunk)
                } catch {
                    throw .sinkFailed(String(describing: error))
                }
            }
            await Task.yield()
        }
        return try pump.completedReport()
    }

    // MARK: - Checks

    static func checkCancellation() throws(DecodeFailure) {
        if Task.isCancelled { throw .cancelled }
    }

    /// Metadata only (WWSources gateway). Refuses anything not proven to be a local regular file.
    func preflight(_ url: URL) throws(DecodeFailure) -> SourceMetadata {
        let metadata: SourceMetadata
        switch access.io.metadata(at: url) {
        case .failure(.notFound): throw .notFound
        case .failure(.permissionDenied): throw .permissionDenied
        case let .failure(.other(descriptor)): throw .metadataUnavailable(descriptor)
        case let .success(value): metadata = value
        }
        guard let isRegular = metadata.isRegularFile.value else { throw .metadataUnavailable(nil) }
        guard isRegular, metadata.isSymbolicLink.value != true else { throw .notARegularFile }
        if metadata.ubiquitous.isDownloading.value == true || metadata.ubiquitous.downloadingStatus.value == .notDownloaded {
            throw .notMaterialized
        }
        switch metadata.isDataless.value {
        case true?: throw .notMaterialized
        case nil: throw .residencyUnknown
        case false?: break
        }
        guard metadata.isReadable.value != false else { throw .permissionDenied }
        guard let size = metadata.fingerprint.fileSize.value, metadata.fingerprint.contentModificationDate.isKnown else {
            throw .metadataUnavailable(nil)
        }
        guard size > 0 else { throw .emptyFile }
        return metadata
    }

    /// The descriptor that was opened must be the file the preflight checked.
    static func verifyOpened(_ opened: OpenedFileState, matches before: SourceMetadata) throws(DecodeFailure) {
        let fingerprint = before.fingerprint
        guard opened.sizeBytes == fingerprint.fileSize.value else { throw .sourceIdentityMismatch }
        if let identifier = fingerprint.fileIdentifier.value, identifier != opened.fileNumber { throw .sourceIdentityMismatch }
        if let modified = fingerprint.contentModificationDate.value {
            let openedModified = Date(timeIntervalSince1970: Double(opened.modificationSeconds) + Double(opened.modificationNanoseconds) / 1e9)
            guard abs(openedModified.timeIntervalSince(modified)) <= FileSystemFingerprint.timestampTolerance else { throw .sourceIdentityMismatch }
        }
    }

    /// After the last frame: the open descriptor and the path's metadata must both be unchanged.
    private func verifyUnchanged(_ url: URL, reader: any DecodingContentReader, before: SourceMetadata) throws(DecodeFailure) {
        try Self.verifyUnchanged(url, io: access.io, reader: reader, before: before)
    }

    static func verifyUnchanged(_ url: URL, io: any SourceIO, reader: any DecodingContentReader, before: SourceMetadata) throws(DecodeFailure) {
        guard try reader.currentOpenedFileState() == reader.facts.openedFile else { throw .sourceChangedDuringDecode }
        guard case let .success(after) = io.metadata(at: url) else { throw .sourceChangedDuringDecode }
        let baseline = before.fingerprint.compare(to: before.fingerprint)
        switch before.fingerprint.compare(to: after.fingerprint) {
        case .matches:
            return
        case .differs:
            throw .sourceChangedDuringDecode
        case let .unknown(fields):
            // Acceptable only if exactly the fields unknown before are unknown now.
            guard case let .unknown(unknownBefore) = baseline, unknownBefore == fields else { throw .sourceChangedDuringDecode }
        }
    }
}
