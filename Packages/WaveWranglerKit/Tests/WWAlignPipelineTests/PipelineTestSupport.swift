import Accelerate
import Darwin
import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

// Synthetic fixtures only: every source is a 4 KiB placeholder file (so the decoder's metadata preflight sees a
// real regular file) whose audio is generated in code by `ProceduralContentIO`. No recording is read.

// MARK: - Synthetic signals

/// A deterministic "scene" (band-limited hashed noise) and how one recorder hears it.
enum Signal: Sendable {
    /// The recorder at source time `u` hears `scene(seed, rate·u + offset)`, plus `stepBy` seconds of extra
    /// offset from source time `stepAt` on (a discontinuity).
    case scene(seed: UInt64, rate: Double = 1, offset: Double = 0, stepAt: Double? = nil, stepBy: Double = 0)
    /// Two independent scenes: the reference hears only the first; the second dominates peer-to-peer.
    case dualScene(seed: UInt64, secondSeed: UInt64, rate: Double, offset: Double, secondDelay: Double)
    case gap(seed: UInt64, rate: Double, offset: Double, start: Double, end: Double)
    /// The scene plus an equal copy `delay` seconds later (two equally good alignments).
    case echo(seed: UInt64, delay: Double)
    case silence
    case sine(hz: Double)

    static let sceneRate = 2000.0

    static func hash(_ seed: UInt64, _ index: Int64) -> Float {
        var z = seed &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53) - 0.5)
    }

    /// The scene at scene time `t` seconds: hashed values at 2 kHz, linearly interpolated.
    static func scene(_ seed: UInt64, _ t: Double) -> Float {
        let x = t * sceneRate
        let i = x.rounded(.down)
        let f = Float(x - i)
        let k = Int64(i)
        return hash(seed, k) * (1 - f) + hash(seed, k + 1) * f
    }

    func value(atSourceSeconds u: Double) -> Float {
        switch self {
        case let .scene(seed, rate, offset, stepAt, stepBy):
            var t = rate * u + offset
            if let stepAt, u >= stepAt { t += stepBy }
            return Self.scene(seed, t)
        case let .dualScene(seed, secondSeed, rate, offset, secondDelay):
            let t = rate * u + offset
            return Self.scene(seed, t) + 1.6 * Self.scene(secondSeed, t - secondDelay)
        case let .gap(seed, rate, offset, start, end):
            return start <= u && u < end ? 0 : Self.scene(seed, rate * u + offset)
        case let .echo(seed, delay):
            return 0.7 * (Self.scene(seed, u) + Self.scene(seed, u - delay))
        case .silence:
            return 0
        case let .sine(hz):
            return Float(0.4 * sin(2 * Double.pi * hz * u))
        }
    }
}

/// Channel `c` carries the signal at this gain, so every channel is distinguishable.
func channelGain(_ c: Int) -> Float { 1 / (1 + Float(c) * 0.25) }

// MARK: - Procedural content gateway (recording test double)

/// Serves generated float32 WAVE streams for registered placeholder files and records every open, read and
/// close, per file. The opened-file identity is taken from `stat` at open, so a rewritten placeholder is
/// seen as a changed file (the decoder's own preflight checks still apply).
final class ProceduralContentIO: SourceContentIO, @unchecked Sendable {
    struct Stream: Sendable {
        var channels: Int
        var frames: Int64
        var signal: Signal
        var sampleRate = 48_000
    }

    struct Record: Sendable, Equatable {
        var opens = 0
        var reads = 0
        var closes = 0
        var readsOnMainThread = 0
        /// Highest frame position any reader of the file reached.
        var furthestFrame: Int64 = 0
    }

    private let lock = NSLock()
    private var streams: [String: Stream] = [:]
    private var records: [String: Record] = [:]
    private var openNow = 0
    private var _peakOpen = 0
    private var _onRead: (@Sendable (String, Int) -> Void)?

    static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    func register(_ url: URL, _ stream: Stream) { lock.withLock { streams[Self.path(url)] = stream } }

    /// Called (outside the lock) on every read with the file's path and the reader's read index.
    func setOnRead(_ action: (@Sendable (String, Int) -> Void)?) { lock.withLock { _onRead = action } }

    func record(_ url: URL) -> Record { lock.withLock { records[Self.path(url)] ?? Record() } }
    var total: Record {
        lock.withLock {
            records.values.reduce(into: Record()) { sum, r in
                sum.opens += r.opens
                sum.reads += r.reads
                sum.closes += r.closes
                sum.readsOnMainThread += r.readsOnMainThread
                sum.furthestFrame = max(sum.furthestFrame, r.furthestFrame)
            }
        }
    }
    var peakOpenReaders: Int { lock.withLock { _peakOpen } }
    var openReaders: Int { lock.withLock { openNow } }

    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        let path = Self.path(url)
        let stream: Stream? = lock.withLock {
            records[path, default: Record()].opens += 1
            return streams[path]
        }
        guard let stream else { throw .notFound }
        var info = stat()
        guard stat(path, &info) == 0 else { throw .notFound }
        let opened = OpenedFileState(
            fileNumber: UInt64(info.st_ino), sizeBytes: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
        let bytesPerFrame = UInt32(4 * stream.channels)
        let facts = EncodedStreamFacts(
            containerTypeCode: FourCharacterCode.code("WAVE"), formatID: FourCharacterCode.code("lpcm"), formatFlags: 0b1001,
            sampleRate: Double(stream.sampleRate), bytesPerPacket: bytesPerFrame, framesPerPacket: 1, bytesPerFrame: bytesPerFrame,
            channelsPerFrame: UInt32(stream.channels), bitsPerChannel: 32, packetCount: stream.frames, readerLengthFrames: stream.frames,
            containerLength: .consistent(declaredBytes: stream.frames * Int64(bytesPerFrame)), openedFile: opened
        )
        lock.withLock {
            openNow += 1
            _peakOpen = max(_peakOpen, openNow)
        }
        return Reader(owner: self, path: path, stream: stream, facts: facts)
    }

    fileprivate func didRead(_ path: String, index: Int, reached: Int64) {
        let action: (@Sendable (String, Int) -> Void)? = lock.withLock {
            records[path, default: Record()].reads += 1
            if pthread_main_np() != 0 { records[path, default: Record()].readsOnMainThread += 1 }
            records[path, default: Record()].furthestFrame = max(records[path]?.furthestFrame ?? 0, reached)
            return _onRead
        }
        action?(path, index)
    }

    fileprivate func didClose(_ path: String) {
        lock.withLock {
            records[path, default: Record()].closes += 1
            openNow -= 1
        }
    }

    private final class Reader: DecodingContentReader {
        let owner: ProceduralContentIO
        let path: String
        let stream: Stream
        let facts: EncodedStreamFacts
        let gains: [Float]
        var position: Int64 = 0
        var readIndex = 0
        var closed = false

        init(owner: ProceduralContentIO, path: String, stream: Stream, facts: EncodedStreamFacts) {
            self.owner = owner
            self.path = path
            self.stream = stream
            self.facts = facts
            gains = (0 ..< stream.channels).map(channelGain)
        }

        func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
            let count = Int(min(Int64(buffer.capacityFrames), stream.frames - position))
            // Plain while loops and vDSP: generic `Range` iteration dominates heavy suites in debug builds.
            let rate = Double(stream.sampleRate)
            let first = buffer.channel(0).baseAddress!
            var frame = 0
            while frame < count {
                first[frame] = stream.signal.value(atSourceSeconds: Double(position + Int64(frame)) / rate)
                frame += 1
            }
            var c = buffer.channelCount - 1
            while c >= 0 {
                var gain = gains[c]
                vDSP_vsmul(first, 1, &gain, buffer.channel(c).baseAddress!, 1, vDSP_Length(count))
                c -= 1
            }
            position += Int64(count)
            let index = readIndex
            readIndex += 1
            owner.didRead(path, index: index, reached: position)
            return count
        }

        func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState { facts.openedFile }

        func close() {
            guard !closed else { return }
            closed = true
            owner.didClose(path)
        }
    }
}

/// The system metadata gateway, counting metadata calls per file.
final class CountingSourceIO: SourceIO, @unchecked Sendable {
    private let base = SystemSourceIO()
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    func metadataCalls(_ url: URL) -> Int { lock.withLock { calls[ProceduralContentIO.path(url)] ?? 0 } }
    var totalMetadataCalls: Int { lock.withLock { calls.values.reduce(0, +) } }

    var provenance: ObservationProvenance { .simulated }
    func metadata(at url: URL) -> MetadataResult {
        lock.withLock { calls[ProceduralContentIO.path(url), default: 0] += 1 }
        return base.metadata(at: url)
    }
    func listItems(under directory: URL) -> DirectoryListing { base.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { true }
    func stopAccessingSecurityScope(_ url: URL) {}
    func requestDownload(of url: URL) throws { Issue.record("the pipeline must never request a download") }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { .unknown }
}

// MARK: - Temporary directory

final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wwalignpipeline-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        if let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in items { chmod(item.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: - Ordering gates

/// A one-shot latch. `wait()` suspends (never blocks a thread) and ignores cancellation.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A lock-protected value set from inside jobs.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func update<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&_value) } }
}

/// The coordinator's DEBUG commit hook, scriptable after the coordinator exists.
final class CommitScript: @unchecked Sendable {
    typealias Action = @Sendable (DerivedSlot, DerivedAssetKey) async -> Void
    private let box = Box<Action?>(nil)
    func set(_ action: Action?) { box.value = action }
    var hooks: DerivedCoordinatorTestHooks { hooks(skipCurrencyCheck: false) }
    func hooks(skipCurrencyCheck: Bool) -> DerivedCoordinatorTestHooks {
        DerivedCoordinatorTestHooks(beforeCommit: { [box] slot, key in await box.value?(slot, key) }, skipCurrencyCheck: skipCurrencyCheck)
    }
}

/// Cancels the coordinator job in `slot` from inside a synchronous gateway read, and returns only once the
/// cancel has landed, so cancellation is observed at exactly that read. Gateway reads run on the decode
/// cursor's private serial queue, never on a cooperative-pool thread, so waiting here starves no task.
func cancelSlotDuringRead(_ coordinator: DerivedJobCoordinator, _ slot: DerivedSlot) {
    if Thread.isMainThread { Issue.record("gateway read ran on the main thread") }
    let landed = DispatchSemaphore(value: 0)
    Task.detached {
        await coordinator.cancel(slot)
        landed.signal()
    }
    landed.wait()
}

// MARK: - Fixture

struct SourceSpec: Sendable {
    var name: String
    var channels = 2
    var seconds: Double
    var signal: Signal
    var availability: SourceAvailabilitySetting = .on
    var authorized = true
    var registered = true
    var located = true
    var sampleRate = 48_000

    var frames: Int64 { Int64((seconds * Double(sampleRate)).rounded()) }
}

/// One recorder group (one epoch) per entry.
struct GroupSpec: Sendable {
    var name: String
    var sources: [SourceSpec]
}

/// A synthetic episode on disk (placeholders only), its derived store, coordinator and pipeline.
final class PipelineFixture: @unchecked Sendable {
    /// A document reopened in a new pipeline instance on the same coordinator (no acceptance history).
    func reopenPipeline() {
        pipeline = AlignmentPipeline(coordinator: coordinator, decoder: decoder, configuration: configuration, testHooks: hooks)
    }

    let directory: TemporaryDirectory
    let media: URL
    let content = ProceduralContentIO()
    let metadataIO = CountingSourceIO()
    let script = CommitScript()
    let store: DerivedAssetStore
    let coordinator: DerivedJobCoordinator
    private(set) var pipeline: AlignmentPipeline
    let decoder: SourceDecoder
    let configuration: AlignmentPipelineConfiguration
    let hooks: AlignmentPipelineTestHooks
    let episodeID = EpisodeID()
    let groups: [RecorderGroupID]
    let epochs: [RecordingEpochID]
    /// Source IDs by spec name.
    let ids: [String: SourceID]
    let urls: [String: URL]
    let specs: [String: SourceSpec]
    var model: ShowDocumentModel
    let sources: [AlignmentSource]
    let authorizations: [ContentWorkAuthorization]

    static let smallConfiguration = AlignmentPipelineConfiguration(
        concurrency: 2, targetExcerptSeconds: 20, searchDeviationSeconds: 3, renderSegmentSeconds: 2
    )

    init(
        _ groupSpecs: [GroupSpec],
        configuration: AlignmentPipelineConfiguration = smallConfiguration,
        chunkFrames: Int = 16_384,
        skipCurrencyCheck: Bool = false,
        hooks: AlignmentPipelineTestHooks = AlignmentPipelineTestHooks(),
        label: String = "pipeline"
    ) async throws {
        directory = try TemporaryDirectory(label)
        // Originals and the cache never share a folder (the store refuses a root beside originals).
        media = try directory.folder("originals/media")
        store = try DerivedAssetStore(root: directory.url.appendingPathComponent("cache/DerivedAssets/v1", isDirectory: true), sourceLocations: [media])
        coordinator = DerivedJobCoordinator(store: store, inputs: DerivedInputs(), testHooks: script.hooks(skipCurrencyCheck: skipCurrencyCheck))
        let decoder = SourceDecoder(access: SourceAccessContext(io: metadataIO), content: content, configuration: .init(chunkFrames: chunkFrames))
        self.decoder = decoder
        self.configuration = configuration
        self.hooks = hooks
        pipeline = AlignmentPipeline(coordinator: coordinator, decoder: decoder, configuration: configuration, testHooks: hooks)

        var groups: [RecorderGroupID] = []
        var epochs: [RecordingEpochID] = []
        var recorderGroups: [RecorderGroup] = []
        var records: [SourceRecord] = []
        var ids: [String: SourceID] = [:]
        var urls: [String: URL] = [:]
        var specs: [String: SourceSpec] = [:]
        var sources: [AlignmentSource] = []
        var authorizations: [ContentWorkAuthorization] = []
        for groupSpec in groupSpecs {
            let group = RecorderGroupID()
            let epoch = RecordingEpochID()
            groups.append(group)
            epochs.append(epoch)
            recorderGroups.append(RecorderGroup(id: group, name: groupSpec.name, epochs: [RecordingEpoch(id: epoch, label: "Take 1")]))
            for spec in groupSpec.sources {
                let id = SourceID()
                let url = media.appendingPathComponent("\(spec.name).wav", isDirectory: false)
                try Data(repeating: 0x5A, count: 4096).write(to: url)
                content.register(url, .init(channels: spec.channels, frames: spec.frames, signal: spec.signal, sampleRate: spec.sampleRate))
                ids[spec.name] = id
                urls[spec.name] = url
                specs[spec.name] = spec
                records.append(SourceRecord(id: id, displayNameHint: "\(spec.name).wav", placement: SourcePlacement(recorderGroupID: group, epochID: epoch)))
                if spec.located { sources.append(AlignmentSource(id: id, url: url, availability: spec.availability)) }
                if spec.authorized { authorizations.append(.explicitUserRequest(for: id)) }
                if spec.registered { await coordinator.updateSource(try Self.registration(id, url)) }
            }
        }
        self.groups = groups
        self.epochs = epochs
        self.ids = ids
        self.urls = urls
        self.specs = specs
        self.sources = sources
        self.authorizations = authorizations
        model = ShowDocumentModel(
            show: Show(title: "Synthetic"),
            episodes: [Episode(id: episodeID, title: "Synthetic episode", recorderGroups: recorderGroups, sources: records)]
        )
    }

    /// The metadata-only revision the app registers for a source (no content read).
    static func registration(_ id: SourceID, _ url: URL) throws -> SourceRevision {
        guard case let .success(metadata) = SystemSourceIO().metadata(at: url) else { throw POSIXError(.ENOENT) }
        return SourceRevision.metadata(id, fingerprint: metadata.fingerprint)
    }

    func id(_ name: String) -> SourceID { ids[name]! }
    func url(_ name: String) -> URL { urls[name]! }

    func analyse(preferredReference: String? = nil) async throws -> AlignmentAnalysisReport {
        try #require(await pipeline.analyse(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations,
            preferredReference: preferredReference.map(id)
        ))
    }

    func states(_ report: AlignmentAnalysisReport) async -> [RecordingEpochID: EpochAlignmentState] {
        let states = await pipeline.states(model: model, episode: episodeID, report: report)
        return Dictionary(uniqueKeysWithValues: states.map { ($0.epoch, $0) })
    }

    /// Accepts, "saves" (adopts the returned document value) and activates.
    @discardableResult
    func acceptAndActivate(_ report: AlignmentAnalysisReport, _ decisions: [RecordingEpochID: EpochMapDecision]) async throws -> AcceptedAlignment {
        let accepted = try await pipeline.accept(model: model, episode: episodeID, report: report, decisions: decisions)
        model = accepted.model
        try await pipeline.activate(accepted)
        return accepted
    }

    func render() async throws -> AlignedAssetReport {
        try await pipeline.renderAlignedAssets(model: model, episode: episodeID, sources: sources, authorizations: authorizations)
    }

    /// Moves a source into a new epoch of its own recorder group (the person splits a take) and returns it.
    @discardableResult
    func moveToNewEpoch(_ name: String) throws -> RecordingEpochID {
        let epoch = RecordingEpochID()
        let index = try #require(model.episodes.firstIndex { $0.id == episodeID })
        let record = try #require(model.episodes[index].sources.firstIndex { $0.id == id(name) })
        let group = model.episodes[index].sources[record].placement.recorderGroupID
        let groupIndex = try #require(model.episodes[index].recorderGroups.firstIndex { $0.id == group })
        model.episodes[index].recorderGroups[groupIndex].epochs.append(RecordingEpoch(id: epoch, label: "Take 2"))
        model.episodes[index].sources[record].placement = SourcePlacement(recorderGroupID: group, epochID: epoch)
        return epoch
    }

    /// Rewrites a placeholder (new size and identity): the registered metadata revision no longer matches.
    func rewrite(_ name: String) throws {
        let url = url(name)
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0x33, count: 5000).write(to: url)
    }
}

// MARK: - Assertions

extension AlignmentWorkFailure {
    var isCancelled: Bool { self == .cancelled }
}

extension EpochAlignmentStatus {
    var proposal: ProposalRecord? {
        if case let .proposed(record) = self { return record }
        return nil
    }
}

/// Every published aligned-audio payload of a render report, decoded.
func alignedSegments(_ report: AlignedAssetReport, store: DerivedAssetStore) throws -> [(key: DerivedAssetKey, segment: AlignedAudioSegment)] {
    let results = report.groups.flatMap { $0.results }.filter { $0.isAvailable }
    return try results.map { result in
        let payload = try #require(store.payload(for: result.key))
        return (result.key, try AlignedAudioSegment.decode(payload))
    }
}
