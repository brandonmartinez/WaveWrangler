import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWPersistence
import WWSources
import WWTimeMap

// MARK: - Synthetic show

/// One recorder group with one epoch and two sources (host = timeline reference, guest placed `guestOffset`
/// seconds later). Generated in code; no real recordings.
struct AlignmentFixture {
    let group = RecorderGroupID()
    let epoch = RecordingEpochID()
    let host = SourceID()
    let guest = SourceID()
    let hostOccurrence = SourceOccurrenceID()
    let guestOccurrence = SourceOccurrenceID()
    let episodeID = EpisodeID()

    var episode: Episode {
        Episode(
            id: episodeID,
            title: "Episode",
            recorderGroups: [RecorderGroup(id: group, name: "Recorder", epochs: [RecordingEpoch(id: epoch, label: "Take 1")])],
            sources: [
                SourceRecord(id: host, displayNameHint: "host.wav", placement: SourcePlacement(recorderGroupID: group, epochID: epoch)),
                SourceRecord(id: guest, displayNameHint: "guest.wav", placement: SourcePlacement(recorderGroupID: group, epochID: epoch)),
            ]
        )
    }

    var show: ShowDocumentModel { ShowDocumentModel(show: Show(title: "Show"), episodes: [episode]) }

    func map(guestOffset: Int64 = 1) throws -> AlignedTimelineMap {
        let rate = try NominalRate(48000)
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: hostOccurrence)
        let epochMap = EpochClockMap(
            epoch: epoch,
            mapping: .mapped(
                segments: [try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(10), rateRatio: .one, alignedOffset: .zero)],
                provenance: .timelineReference
            )
        )
        let groupMap = try GroupTimeMap(group: group, reference: reference, epochs: [epochMap], placements: [
            OccurrencePlacement(
                occurrence: try SourceOccurrence(id: hostOccurrence, source: host, nominalRate: rate, frameCount: 480_000),
                spans: [EpochSpan(startFrame: 0, endFrame: 480_000, epoch: epoch, groupClockOffset: .zero)]
            ),
            OccurrencePlacement(
                occurrence: try SourceOccurrence(id: guestOccurrence, source: guest, nominalRate: rate, frameCount: 96_000),
                spans: [EpochSpan(startFrame: 0, endFrame: 96_000, epoch: epoch, groupClockOffset: ExactRational(guestOffset))]
            ),
        ])
        return try AlignedTimelineMap(reference: reference, groups: [groupMap])
    }
}

// MARK: - Temporary directories and synthetic audio

final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wwderived-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        if let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in items { chmod(item.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A 16-bit PCM mono WAV with a deterministic synthetic signal, made read-only (0444).
    @discardableResult
    func writeWAV(_ name: String, frames: Int, seed: Int, sampleRate: Int = 48_000) throws -> URL {
        let url = file(name)
        var samples = Data(capacity: frames * 2)
        var state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        for _ in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = Int16(truncatingIfNeeded: Int32(state >> 16) - 32768) / 4
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + samples.count))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Data("data".utf8))
        u32(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url)
        chmod(url.path, 0o444)
        return url
    }
}

/// Bytes, size, mode and modification time: proves an original was not touched.
struct FileSnapshot: Equatable {
    var bytes: Data
    var size: Int64
    var mode: UInt16
    var modified: timespec

    init(_ url: URL) throws {
        bytes = try Data(contentsOf: url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        size = Int64(info.st_size)
        mode = info.st_mode
        modified = info.st_mtimespec
    }

    static func == (a: FileSnapshot, b: FileSnapshot) -> Bool {
        a.bytes == b.bytes && a.size == b.size && a.mode == b.mode
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
    }
}

// MARK: - Recording gateways

/// Wraps the system content gateway and counts every open and read.
final class RecordingContentIO: SourceContentIO, @unchecked Sendable {
    private let base = SystemSourceContentIO()
    private let lock = NSLock()
    private var _opens = 0
    private var _reads = 0

    var opens: Int { lock.withLock { _opens } }
    var reads: Int { lock.withLock { _reads } }
    var calls: Int { lock.withLock { _opens + _reads } }

    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        lock.withLock { _opens += 1 }
        return Reader(try base.openForDecoding(url)) { [weak self] in self?.lock.withLock { self?._reads += 1 } }
    }

    private final class Reader: DecodingContentReader {
        let inner: any DecodingContentReader
        let onRead: () -> Void
        init(_ inner: any DecodingContentReader, onRead: @escaping () -> Void) {
            self.inner = inner
            self.onRead = onRead
        }
        var facts: EncodedStreamFacts { inner.facts }
        func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
            onRead()
            return try inner.readRawFrames(into: buffer)
        }
        func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState { try inner.currentOpenedFileState() }
        func close() { inner.close() }
    }
}

/// The system metadata gateway, counting metadata calls; optionally adjusts results (e.g. dataless).
/// Any download request is a test failure.
final class RecordingSourceIO: SourceIO, @unchecked Sendable {
    private let base = SystemSourceIO()
    private let lock = NSLock()
    private let adjust: (@Sendable (inout SourceMetadata) -> Void)?
    private var _metadataCalls = 0
    private var _downloads = 0

    init(adjust: (@Sendable (inout SourceMetadata) -> Void)? = nil) { self.adjust = adjust }

    var metadataCalls: Int { lock.withLock { _metadataCalls } }
    var downloadRequests: Int { lock.withLock { _downloads } }

    var provenance: ObservationProvenance { .simulated }
    func metadata(at url: URL) -> MetadataResult {
        lock.withLock { _metadataCalls += 1 }
        var result = base.metadata(at: url)
        if let adjust, case var .success(metadata) = result {
            adjust(&metadata)
            result = .success(metadata)
        }
        return result
    }
    func listItems(under directory: URL) -> DirectoryListing { base.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { true }
    func stopAccessingSecurityScope(_ url: URL) {}
    func requestDownload(of url: URL) throws {
        lock.withLock { _downloads += 1 }
        Issue.record("content digests must never request a download")
    }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { .unknown }
}

// MARK: - Ordering gates

/// A one-shot latch. `wait()` ignores task cancellation, so a job blocked on it models work that finishes
/// late even after it was cancelled.
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

/// A boolean set from inside a job's work.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ value: Bool) { lock.withLock { _value = value } }
}

/// Counts invocations of a job's work closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

// MARK: - Keys

extension DerivedAssetKey {
    static func sample(
        kind: String = "waveform",
        revision: Int = 1,
        sources: [SourceRevision] = [],
        format: FormatRevision? = .current,
        epoch: RecordingEpochID? = nil,
        occurrence: SourceOccurrenceID? = nil,
        channel: Int? = nil,
        map: MapRevisionReference? = nil,
        recipe: RecipeReference? = nil,
        upstream: [DerivedAssetKey] = []
    ) -> DerivedAssetKey {
        DerivedAssetKey(
            asset: AssetSpec(kind: kind, revision: revision),
            sources: sources,
            format: format,
            epoch: epoch,
            occurrence: occurrence,
            channel: channel,
            map: map,
            recipe: recipe,
            upstream: upstream
        )
    }
}

func makeStore(_ directory: TemporaryDirectory, sources: [URL] = []) throws -> DerivedAssetStore {
    try DerivedAssetStore(root: directory.url.appendingPathComponent("cache/DerivedAssets/v1", isDirectory: true), sourceLocations: sources)
}
