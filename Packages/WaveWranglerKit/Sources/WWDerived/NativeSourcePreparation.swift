import Foundation
import WWCore
import WWDecode
import WWSources

/// Frozen evidence, NOT an access grant. The app supplies its live selection/consent/device-record
/// validator; neither this value nor a prepared cache entry replaces that authority boundary.
public struct SourceReadAdmission: Sendable {
    public let source: SourceID
    public let location: URL
    public let witness: RawSourceIdentity
    public let authorization: ContentWorkAuthorization?
    public let availability: SourceAvailabilitySetting
    public let validateCurrentAccess: @Sendable () async throws -> Void

    public init(
        source: SourceID, location: URL, witness: RawSourceIdentity,
        authorization: ContentWorkAuthorization?, availability: SourceAvailabilitySetting,
        validateCurrentAccess: @escaping @Sendable () async throws -> Void
    ) {
        self.source = source
        self.location = location
        self.witness = witness
        self.authorization = authorization
        self.availability = availability
        self.validateCurrentAccess = validateCurrentAccess
    }

    fileprivate func validate() async throws {
        try Task.checkCancellation()
        guard authorization?.source == source, availability == .on else {
            throw NativeSourcePreparationFailure.notAuthorized
        }
        try await validateCurrentAccess()
        try Task.checkCancellation()
    }
}

public enum NativeSourcePreparationFailure: Error, Sendable, Equatable {
    case notAuthorized
    case sourceMismatch
    case formatMismatch
    case unsupportedChannelLayout
    case invalidRange
    case storageBudgetExceeded
    case preparationInProgress
    case incompleteOrInvalidPCM
    case cacheMissingOrDamaged
}

/// Opaque evidence of one complete native-rate decode, never a permission token. Eviction makes old
/// handles fail explicitly. All windows are half-open source-frame ranges after declared delay/padding.
public struct PreparedSourceAudio: Sendable {
    public let interpretation: FormatInterpretation
    public let tileFrames: Int
    public let witness: RawSourceIdentity
    fileprivate let identity: String
    fileprivate let session: String
    fileprivate let manifestKey: DerivedAssetKey

    public var sourceFrameCount: Int64 { interpretation.frames.validFrames }
    public var sampleRate: Int { interpretation.sourceSampleRate }
    public var channelCount: Int { interpretation.channelCount }

    fileprivate func tileKey(_ index: Int) -> DerivedAssetKey {
        let start = Int64(index) * Int64(tileFrames)
        let end = min(sourceFrameCount, start + Int64(tileFrames))
        return DerivedAssetKey(
            asset: AssetSpec(kind: "native-source-pcm-tile", revision: 1),
            sources: [SourceRevision(source: interpretation.source, token: identity)],
            format: FormatRevision(
                interpretationVersion: interpretation.formatInterpretationVersion,
                envelopeVersion: interpretation.envelopeVersion),
            coverage: "\(start)..<\(end)",
            upstream: [DerivedAssetKey(asset: AssetSpec(kind: session, revision: 1))]
        )
    }
}

public struct PreparedSourceWindow: Sendable, Equatable {
    public let source: SourceID
    public let range: Range<Int64>
    public let sampleRate: Int
    public let channelCount: Int
    /// Planar, in original file channel order; no resampling, gain, padding, or substitute silence.
    public let samples: [Float]
    public let isAtEndOfSource: Bool
    /// Useful for measuring late seeks: independent of the number of frames preceding the window.
    public let tilesRead: Int
}

/// Fixed native-rate tiles reuse DerivedAssetStore's flushed staging, read-back verification and
/// atomic publication. A dedicated child cache is bounded across assets and has one preparation at a
/// time. It is intentionally session-local: construction removes previous-process entries, so there
/// is no unbounded on-disk index or stale manifest recovery. Repeated clips/windows share this actor.
public actor NativeSourcePreparation {
    public struct Configuration: Sendable {
        public let tileFrames: Int
        public let maximumWindowFrames: Int
        public let maximumStorageBytes: Int64

        public init(
            tileFrames: Int = 16_384, maximumWindowFrames: Int = 65_536,
            maximumStorageBytes: Int64 = 1 << 30
        ) {
            self.tileFrames = min(max(tileFrames, 1024), 65_536)
            self.maximumWindowFrames = min(max(maximumWindowFrames, 1), 1 << 20)
            self.maximumStorageBytes = min(max(maximumStorageBytes, 1), 1 << 30)
        }
    }

    private struct Entry {
        let audio: PreparedSourceAudio
        let keys: [DerivedAssetKey]
        let reservedBytes: Int64
        var lastUse: UInt64
    }

    private let store: DerivedAssetStore
    private let decoder: SourceDecoder
    public nonisolated let configuration: Configuration
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var preparing = false
    private var reservation: Int64 = 0

    public init(
        root: URL, sourceLocations: [URL], access: SourceAccessContext,
        configuration: Configuration = Configuration()
    ) throws {
        let store = try DerivedAssetStore(
            root: root.appendingPathComponent("native-source-pcm-v1", isDirectory: true),
            sourceLocations: sourceLocations
        )
        try self.init(
            store: store,
            decoder: SourceDecoder(access: access, configuration: .init(chunkFrames: configuration.tileFrames)),
            configuration: configuration)
    }

    package init(store: DerivedAssetStore, decoder: SourceDecoder, configuration: Configuration) throws {
        try store.cleanPreparedEntries(keeping: [])
        self.store = store
        self.decoder = decoder
        self.configuration = configuration
    }

    /// `expectedFormat` must be the current admitted interpretation, not one inferred from an extension.
    /// Progress reports processed valid source frames, not a usable partial preparation.
    public func prepare(
        _ admission: SourceReadAdmission, expectedFormat: FormatInterpretation,
        progress: @escaping @Sendable (_ processedFrames: Int64, _ totalFrames: Int64) async throws -> Void = { _, _ in
        }
    ) async throws -> PreparedSourceAudio {
        try await admission.validate()
        try store.checkOutside(sourceLocations: [admission.location])
        guard !preparing else { throw NativeSourcePreparationFailure.preparationInProgress }
        preparing = true
        defer {
            preparing = false
            reservation = 0
        }

        let identity = CanonicalDigest.hex(
            of: PreparationIdentity(
                witness: admission.witness, format: expectedFormat, tileFrames: configuration.tileFrames
            ))
        let key = DerivedAssetKey(
            asset: AssetSpec(kind: "native-source-pcm-manifest", revision: 1),
            sources: [SourceRevision(source: admission.source, token: identity)], format: .current
        )
        let session = PCMPreparationSession(
            store: store, format: expectedFormat,
            witness: admission.witness, identity: identity, manifestKey: key,
            tileFrames: configuration.tileFrames)
        do {
            let (audio, staged) = try await decoder.withWitnessBoundDecodingCursor(
                admission.location, source: admission.source, matching: admission.witness
            ) { cursor in
                try Self.requireFormat(cursor.interpretation, expected: expectedFormat, source: admission.source)
                if let cached = try await self.cached(identity) {
                    try await admission.validate()
                    try await cursor.verifyUnchanged()
                    return (cached, [StagedDerivedAsset]())
                }
                let bytes = try Self.reservationBytes(expectedFormat, tileFrames: self.configuration.tileFrames)
                try await self.reserve(bytes)
                while let chunk = try await cursor.next() {
                    try Task.checkCancellation()
                    try await session.append(chunk)
                    try await progress(
                        chunk.firstSourceFrame + Int64(chunk.frameCount), expectedFormat.frames.validFrames)
                }
                let audio = try await session.complete()
                let staged = await session.stagedAssets()
                try await admission.validate()
                try await cursor.verifyUnchanged()
                return (audio, staged)
            }
            // No suspension between publication and recording the usable preparation. The cursor's
            // terminal-failure and final-unchanged checks have already succeeded.
            try Task.checkCancellation()
            if entries[identity] != nil {
                touch(identity)
                return audio
            }
            var committed: [DerivedAssetKey] = []
            do {
                try Task.checkCancellation()
                for tile in staged {
                    try Task.checkCancellation()
                    try store.commit(tile)
                    committed.append(tile.key)
                }
                try Task.checkCancellation()
                let manifest = try store.stage(Data(audio.session.utf8), for: key)
                do {
                    try Task.checkCancellation()
                    try store.commit(manifest)
                    try Task.checkCancellation()
                } catch {
                    store.discard(manifest)
                    throw error
                }
                clock &+= 1
                entries[identity] = Entry(
                    audio: audio, keys: committed + [key],
                    reservedBytes: reservation, lastUse: clock)
                return audio
            } catch {
                for key in committed { try store.removePreparedEntry(key) }
                throw error
            }
        } catch {
            await session.abandon()
            // Strict cleanup also catches orphaned entries after a partial commit/cleanup failure.
            try store.cleanPreparedEntries(keeping: Set(entries.values.flatMap { $0.keys.map(\.digest) }))
            throw error
        }
    }

    public func readWindow(
        _ range: Range<Int64>, from audio: PreparedSourceAudio, admission: SourceReadAdmission
    ) async throws -> PreparedSourceWindow {
        try await admission.validate()
        guard admission.source == audio.interpretation.source, admission.witness == audio.witness else {
            throw NativeSourcePreparationFailure.sourceMismatch
        }
        guard range.lowerBound >= 0, range.upperBound <= audio.sourceFrameCount,
            range.count <= configuration.maximumWindowFrames
        else {
            throw NativeSourcePreparationFailure.invalidRange
        }
        guard let entry = entries[audio.identity], entry.audio.session == audio.session else {
            throw NativeSourcePreparationFailure.cacheMissingOrDamaged
        }
        touch(audio.identity)
        let window = try await decoder.withWitnessBoundDecodingCursor(
            admission.location, source: admission.source, matching: admission.witness
        ) { cursor in
            try Self.requireFormat(cursor.interpretation, expected: audio.interpretation, source: admission.source)
            let result = try await self.window(range, audio: audio)
            try await admission.validate()
            try await cursor.verifyUnchanged()
            return result
        }
        try Task.checkCancellation()
        return window
    }

    private func cached(_ identity: String) throws -> PreparedSourceAudio? {
        guard let entry = entries[identity] else { return nil }
        guard
            try store.preparedPayload(for: entry.audio.manifestKey, maximumBytes: 16_384)
                == Data(entry.audio.session.utf8)
        else {
            throw NativeSourcePreparationFailure.cacheMissingOrDamaged
        }
        return entry.audio
    }

    private func touch(_ identity: String) {
        clock &+= 1
        entries[identity]?.lastUse = clock
    }

    private func reserve(_ bytes: Int64) throws {
        guard bytes <= configuration.maximumStorageBytes else {
            throw NativeSourcePreparationFailure.storageBudgetExceeded
        }
        var used = entries.values.reduce(Int64(0)) { $0 + $1.reservedBytes }
        for (identity, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse })
        where used + bytes > configuration.maximumStorageBytes {
            for key in entry.keys { try store.removePreparedEntry(key) }
            entries[identity] = nil
            used -= entry.reservedBytes
        }
        reservation = bytes
    }

    private static func reservationBytes(_ format: FormatInterpretation, tileFrames: Int) throws -> Int64 {
        let frames = format.frames.validFrames
        // The fixed 1 GiB ceiling bounds arithmetic, tile metadata and disk use before any decode.
        guard frames > 0, frames <= (1 << 30) / Int64(format.channelCount * 4) else {
            throw NativeSourcePreparationFailure.storageBudgetExceeded
        }
        let tiles = (frames + Int64(tileFrames) - 1) / Int64(tileFrames)
        return frames * Int64(format.channelCount * 4) + tiles * 4096 + 16_384
    }

    private static func requireFormat(
        _ actual: FormatInterpretation, expected: FormatInterpretation,
        source: SourceID
    ) throws {
        guard actual == expected, actual.source == source,
            actual.envelopeVersion == DecodeEnvelope.version,
            actual.formatInterpretationVersion == FormatInterpretation.currentVersion
        else {
            throw NativeSourcePreparationFailure.formatMismatch
        }
        guard
            (actual.channelCount == 1 && actual.channelLayout.channelLabels == [42])
                || (actual.channelCount == 2 && actual.channelLayout.channelLabels == [1, 2])
        else {
            throw NativeSourcePreparationFailure.unsupportedChannelLayout
        }
    }

    private func window(_ range: Range<Int64>, audio: PreparedSourceAudio) throws -> PreparedSourceWindow {
        guard try cached(audio.identity)?.session == audio.session else {
            throw NativeSourcePreparationFailure.cacheMissingOrDamaged
        }
        let count = Int(range.count)
        var samples = [Float](repeating: 0, count: count * audio.channelCount)
        var covered = 0
        var tilesRead = 0
        if !range.isEmpty {
            let first = Int(range.lowerBound / Int64(audio.tileFrames))
            let last = Int((range.upperBound - 1) / Int64(audio.tileFrames))
            for index in first...last {
                try Task.checkCancellation()
                let start = Int64(index) * Int64(audio.tileFrames)
                let frames = Int(min(Int64(audio.tileFrames), audio.sourceFrameCount - start))
                guard
                    let payload = try store.preparedPayload(
                        for: audio.tileKey(index),
                        maximumBytes: frames * audio.channelCount * 4 + 4096),
                    payload.count == frames * audio.channelCount * 4
                else {
                    throw NativeSourcePreparationFailure.cacheMissingOrDamaged
                }
                let low = max(range.lowerBound, start)
                let high = min(range.upperBound, start + Int64(frames))
                try payload.withUnsafeBytes { bytes in
                    for channel in 0..<audio.channelCount {
                        for frame in low..<high {
                            let offset = (channel * frames + Int(frame - start)) * 4
                            let sample = Float(
                                bitPattern: UInt32(
                                    littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                            guard sample.isFinite else { throw NativeSourcePreparationFailure.cacheMissingOrDamaged }
                            samples[channel * count + Int(frame - range.lowerBound)] = sample
                        }
                    }
                }
                covered += Int(high - low)
                tilesRead += 1
            }
        }
        guard covered == count else { throw NativeSourcePreparationFailure.incompleteOrInvalidPCM }
        return PreparedSourceWindow(
            source: audio.interpretation.source, range: range,
            sampleRate: audio.sampleRate, channelCount: audio.channelCount, samples: samples,
            isAtEndOfSource: range.upperBound == audio.sourceFrameCount, tilesRead: tilesRead)
    }
}

private struct PreparationIdentity: Encodable {
    let witness: RawSourceIdentity
    let format: FormatInterpretation
    let tileFrames: Int
    let recipe = "native-planar-float32-le-no-src-v1"
}

private actor PCMPreparationSession {
    private let store: DerivedAssetStore
    private let audio: PreparedSourceAudio
    private var channels: [[Float]]
    private var received: Int64 = 0
    private var tiles: [StagedDerivedAsset] = []

    init(
        store: DerivedAssetStore, format: FormatInterpretation, witness: RawSourceIdentity,
        identity: String, manifestKey: DerivedAssetKey, tileFrames: Int
    ) {
        self.store = store
        audio = PreparedSourceAudio(
            interpretation: format, tileFrames: tileFrames, witness: witness,
            identity: identity, session: UUID().uuidString, manifestKey: manifestKey)
        channels = []
    }

    func append(_ chunk: DecodedChunk) throws {
        guard chunk.firstSourceFrame == received, chunk.channelCount == audio.channelCount,
            chunk.frameCount > 0, chunk.samples.allSatisfy(\.isFinite),
            received + Int64(chunk.frameCount) <= audio.sourceFrameCount
        else {
            throw NativeSourcePreparationFailure.incompleteOrInvalidPCM
        }
        if channels.isEmpty { channels = Array(repeating: [], count: chunk.channelCount) }
        var offset = 0
        while offset < chunk.frameCount {
            let take = min(audio.tileFrames - channels[0].count, chunk.frameCount - offset)
            for channel in channels.indices {
                channels[channel].append(contentsOf: chunk.channel(channel).dropFirst(offset).prefix(take))
            }
            offset += take
            received += Int64(take)
            if channels[0].count == audio.tileFrames { try flush() }
        }
    }

    private func flush() throws {
        guard !channels[0].isEmpty else { return }
        var payload = Data(capacity: channels[0].count * audio.channelCount * 4)
        for channel in channels {
            for sample in channel {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
            }
        }
        let staged = try store.stage(payload, for: audio.tileKey(tiles.count))
        // Reservation includes at most 4 KiB of the existing store envelope per tile.
        guard staged.byteCount <= payload.count + 4096 else {
            store.discard(staged)
            throw NativeSourcePreparationFailure.storageBudgetExceeded
        }
        tiles.append(staged)
        channels = Array(repeating: [], count: audio.channelCount)
    }

    func complete() throws -> PreparedSourceAudio {
        guard received == audio.sourceFrameCount else { throw NativeSourcePreparationFailure.incompleteOrInvalidPCM }
        try flush()
        return audio
    }

    func stagedAssets() -> [StagedDerivedAsset] { tiles }

    func abandon() {
        for tile in tiles { store.discard(tile) }
        tiles = []
        channels = []
    }
}
