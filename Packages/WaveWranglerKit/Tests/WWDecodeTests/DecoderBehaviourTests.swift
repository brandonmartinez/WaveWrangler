import Darwin
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

// MARK: - Scripted content gateway (recording test double)

/// Blocks a decode at a chosen point until the test opens it. Liveness-guarded: a gate that is never
/// opened records an issue instead of hanging the run.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let arrivals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (arrivals, continuation) = AsyncStream.makeStream(of: Void.self) }

    /// Called by the blocked side.
    func arriveAndWait() {
        continuation.yield()
        if semaphore.wait(timeout: .now() + 60) == .timedOut { Issue.record("liveness guard: gate never opened") }
    }

    func waitForArrival() async {
        for await _ in arrivals { return }
    }

    func open() { semaphore.signal() }
}

/// Produces a synthetic codec stream whose sample at stream frame `s`, channel `c`, is `s + c / 4`, so
/// every published sample states exactly which stream frame produced it.
final class ScriptedContentIO: SourceContentIO, @unchecked Sendable {
    struct Script: Sendable {
        var facts: EncodedStreamFacts
        /// Total codec-stream frames the reader produces before end of stream.
        var streamFrames: Int64
        var maximumFramesPerRead = Int.max
        var overrunAtRead: Int?
        var failure: (read: Int, error: DecodeFailure)?
        var openFailure: DecodeFailure?
        /// The open descriptor's state after decoding (default: unchanged).
        var stateAfterDecode: OpenedFileState?
        var onRead: (@Sendable (Int) -> Void)?
    }

    struct Record {
        var opens = 0
        var closes = 0
        var reads = 0
        var bufferIdentities = Set<ObjectIdentifier>()
        var bufferCapacities = Set<Int>()
        var readsOnMainThread = 0
    }

    let script: Script
    private let lock = NSLock()
    private var _record = Record()
    var record: Record { lock.withLock { _record } }

    init(_ script: Script) { self.script = script }

    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        lock.withLock { _record.opens += 1 }
        if let failure = script.openFailure { throw failure }
        return Reader(owner: self)
    }

    fileprivate func update(_ body: (inout Record) -> Void) { lock.withLock { body(&_record) } }

    private final class Reader: DecodingContentReader {
        let owner: ScriptedContentIO
        var position: Int64 = 0
        var readIndex = 0
        var closed = false

        init(owner: ScriptedContentIO) { self.owner = owner }

        var facts: EncodedStreamFacts { owner.script.facts }

        func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
            let index = readIndex
            readIndex += 1
            owner.update {
                $0.reads += 1
                $0.bufferIdentities.insert(ObjectIdentifier(buffer))
                $0.bufferCapacities.insert(buffer.capacityFrames)
                if pthread_main_np() != 0 { $0.readsOnMainThread += 1 }
            }
            owner.script.onRead?(index)
            if let failure = owner.script.failure, failure.read == index { throw failure.error }
            if owner.script.overrunAtRead == index { return buffer.capacityFrames + 1 }
            let count = Int(min(Int64(min(buffer.capacityFrames, owner.script.maximumFramesPerRead)), owner.script.streamFrames - position))
            for channel in 0..<buffer.channelCount {
                let samples = buffer.channel(channel)
                for frame in 0..<count { samples[frame] = Float(position + Int64(frame)) + Float(channel) / 4 }
            }
            position += Int64(count)
            return count
        }

        func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState {
            owner.script.stateAfterDecode ?? owner.script.facts.openedFile
        }

        func close() {
            guard !closed else { return }
            closed = true
            owner.update { $0.closes += 1 }
        }
    }
}

/// A real (content-irrelevant) file whose metadata the system gateway reports, plus stream facts whose
/// opened-file identity matches it.
struct ScriptedSource {
    let directory: FixtureDirectory
    let url: URL
    let opened: OpenedFileState

    init() throws {
        directory = try FixtureDirectory("scripted")
        url = try directory.writeBytes(Data(repeating: 0x5A, count: 4096), as: "scripted.m4a")
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        opened = OpenedFileState(
            fileNumber: UInt64(info.st_ino), sizeBytes: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    static let aacPriming: Int64 = 2112
    static let aacValid: Int64 = 10_000
    static let aacPackets: Int64 = 12
    static var aacRemainder: Int64 { aacPackets * 1024 - aacPriming - aacValid }

    /// AAC in M4A, 48 kHz, with the usual 2112-frame priming.
    func aacFacts(channels: UInt32 = 2, priming: Int64 = aacPriming, valid: Int64 = aacValid, remainder: Int64 = aacRemainder, readerLength: Int64? = nil) -> EncodedStreamFacts {
        EncodedStreamFacts(
            containerTypeCode: FourCharacterCode.code("m4af"), formatID: FourCharacterCode.code("aac "), formatFlags: 0,
            sampleRate: 48_000, bytesPerPacket: 0, framesPerPacket: 1024, bytesPerFrame: 0, channelsPerFrame: channels, bitsPerChannel: 0,
            packetCount: (priming + valid + remainder) / 1024, maximumPacketSize: 600, audioDataByteCount: 3000, dataOffset: 100, averageBitRate: 128_000,
            packetTable: PacketTableFacts(validFrames: valid, primingFrames: priming, remainderFrames: remainder),
            readerLengthFrames: readerLength ?? valid, openedFile: opened
        )
    }

    var aacStreamFrames: Int64 { Self.aacPackets * 1024 }

    func script(_ facts: EncodedStreamFacts? = nil, streamFrames: Int64? = nil) -> ScriptedContentIO.Script {
        ScriptedContentIO.Script(facts: facts ?? aacFacts(), streamFrames: streamFrames ?? aacStreamFrames)
    }
}

struct Attempt {
    var result: Result<DecodedSource<CollectedAudio>, DecodeFailure>
    var events: [String]
    var sinksMade: Int
    var ledger: SecurityScopeLedger.Snapshot

    var failure: DecodeFailure? {
        if case let .failure(error) = result { return error }
        return nil
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Decodes through a journaling sink.
func runAttempt(
    _ url: URL,
    content: any SourceContentIO,
    io: any SourceIO = AdjustableIO(),
    chunkFrames: Int = 1000,
    failAfterChunks: Int? = nil,
    sinkError: Bool = false,
    onAppend: (@Sendable (Int) -> Void)? = nil
) async -> Attempt {
    let journal = SinkJournal()
    let sinks = Counter()
    let ledger = SecurityScopeLedger()
    let decoder = makeDecoder(chunkFrames: chunkFrames, io: io, content: content, ledger: ledger)
    let result: Result<DecodedSource<CollectedAudio>, DecodeFailure>
    do {
        result = .success(try await decoder.decode(url, source: SourceID()) { interpretation in
            sinks.increment()
            if sinkError { throw SinkProbeError.refused }
            return JournalingSink(
                inner: CollectingSink(channelCount: interpretation.channelCount, maximumChunk: chunkFrames, failAfterChunks: failAfterChunks),
                journal: journal,
                onAppend: onAppend
            )
        })
    } catch {
        result = .failure(error)
    }
    return Attempt(result: result, events: journal.events, sinksMade: sinks.count, ledger: ledger.snapshot)
}

/// A failed attempt published nothing: no finish, and anything appended was abandoned.
func expectNothingPublished(_ attempt: Attempt, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(attempt.failure != nil, "decode unexpectedly succeeded", sourceLocation: sourceLocation)
    #expect(!attempt.events.contains("finish"), sourceLocation: sourceLocation)
    if attempt.sinksMade > 0 {
        #expect(attempt.events.last == "abandon", "\(attempt.events)", sourceLocation: sourceLocation)
        #expect(attempt.events.filter { $0 == "abandon" }.count == 1, sourceLocation: sourceLocation)
    } else {
        #expect(attempt.events.isEmpty, sourceLocation: sourceLocation)
    }
    #expect(attempt.ledger.openScopes == 0, sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite("Decoder behaviour")
struct DecoderBehaviourTests {
    @Test("Priming and remainder are removed exactly, for any chunk size and read size", arguments: [1, 7, 100, 1023, 1024, 2112, 2113, 4096, 50_000])
    func primingTrim(chunkFrames: Int) async throws {
        let source = try ScriptedSource()
        for maximumRead in [Int.max, 1, 333, 1024] where maximumRead == Int.max || chunkFrames >= 100 {
            var script = source.script()
            script.maximumFramesPerRead = maximumRead
            let content = ScriptedContentIO(script)
            let attempt = await runAttempt(source.url, content: content, chunkFrames: chunkFrames)
            let decoded = try attempt.result.get()
            let audio = decoded.product
            #expect(audio.channels.count == 2)
            #expect(audio.channels[0].count == Int(ScriptedSource.aacValid))
            // Decoded frame d came from codec-stream frame d + priming, and the origin says so.
            let origin = decoded.interpretation.origin
            var mismatches = 0
            for d in 0..<audio.channels[0].count {
                let stream = try #require(origin.codecStreamFrame(forDecodedFrame: Int64(d)))
                if audio.channels[0][d] != Float(stream) || audio.channels[1][d] != Float(stream) + 0.25 { mismatches += 1 }
            }
            #expect(mismatches == 0)
            #expect(audio.channels[0].first == Float(ScriptedSource.aacPriming))
            #expect(audio.channels[0].last == Float(ScriptedSource.aacPriming + ScriptedSource.aacValid - 1))
            #expect(decoded.report.leadingStreamFramesDiscarded == ScriptedSource.aacPriming)
            #expect(decoded.report.trailingStreamFramesDiscarded == ScriptedSource.aacRemainder)
            #expect(decoded.report.codecStreamFramesRead == source.aacStreamFrames)
            #expect(attempt.events.last == "finish")
            #expect(content.record.closes == 1)
        }
    }

    @Test("A stream may run up to one packet past the declared remainder; beyond that it is inconsistent")
    func streamLength() async throws {
        let source = try ScriptedSource()
        let slack = ScriptedContentIO(source.script(streamFrames: source.aacStreamFrames + 1024))
        let tolerated = try await runAttempt(source.url, content: slack).result.get()
        #expect(tolerated.report.trailingStreamFramesDiscarded == ScriptedSource.aacRemainder + 1024)

        let over = ScriptedContentIO(source.script(streamFrames: source.aacStreamFrames + 1025))
        let refused = await runAttempt(source.url, content: over, chunkFrames: 1)
        #expect(refused.failure == .inconsistentStream(.streamExceedsDeclaredLength(declaredStreamFrames: source.aacStreamFrames, observedAtLeast: source.aacStreamFrames + 1025)))
        expectNothingPublished(refused)
        #expect(over.record.closes == 1)
    }

    @Test("A stream that ends early is incomplete and publishes nothing")
    func endsEarly() async throws {
        let source = try ScriptedSource()
        for missing: Int64 in [1, 1000, ScriptedSource.aacValid] {
            let content = ScriptedContentIO(source.script(streamFrames: ScriptedSource.aacPriming + ScriptedSource.aacValid - missing))
            let attempt = await runAttempt(source.url, content: content)
            #expect(attempt.failure == .incompleteContent(expectedFrames: ScriptedSource.aacValid, decodedFrames: ScriptedSource.aacValid - missing))
            expectNothingPublished(attempt)
            #expect(content.record.closes == 1)
        }
    }

    @Test("A read error mid-stream abandons, closes and reports the error")
    func readError() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.failure = (read: 5, error: .readFailed(errno: EIO))
        let content = ScriptedContentIO(script)
        let attempt = await runAttempt(source.url, content: content)
        #expect(attempt.failure == .readFailed(errno: EIO))
        #expect(attempt.events.contains("append"))
        expectNothingPublished(attempt)
        #expect(content.record.closes == 1)
    }

    @Test("A reader that returns more frames than requested is refused")
    func overrun() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.overrunAtRead = 3
        let content = ScriptedContentIO(script)
        let attempt = await runAttempt(source.url, content: content)
        #expect(attempt.failure == .inconsistentStream(.readerOverran(requested: 1000, returned: 1001)))
        expectNothingPublished(attempt)
    }

    @Test("Working memory is one reused buffer of chunkFrames per channel", arguments: [1, 64, 4096, 1 << 20, 1 << 22, 0, -5])
    func boundedBuffer(requested: Int) async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script(source.aacFacts(channels: 6)))
        let decoder = makeDecoder(chunkFrames: requested, content: content)
        let expected = min(max(requested, 1), SourceDecoder.Configuration.maximumChunkFrames)
        #expect(decoder.configuration.chunkFrames == expected)
        let decoded = try await decoder.decode(source.url, source: SourceID()) { CollectingSink(channelCount: $0.channelCount, maximumChunk: expected) }
        let record = content.record
        #expect(record.bufferIdentities.count == 1)
        #expect(record.bufferCapacities == [expected])
        #expect(decoded.report.readCalls == record.reads)
        #expect(decoded.report.chunkCapacityFrames == expected)
        #expect(decoded.product.chunkSizes.allSatisfy { $0 <= expected })
    }

    @MainActor
    @Test("Decoding and publication run off the main thread even when started from the main actor")
    func offMainThread() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let appendsOnMain = Counter()
        let attempt = await runAttempt(source.url, content: content, onAppend: { _ in
            if pthread_main_np() != 0 { appendsOnMain.increment() }
        })
        #expect(attempt.failure == nil)
        #expect(content.record.reads > 1)
        #expect(content.record.readsOnMainThread == 0)
        #expect(appendsOnMain.count == 0)
    }

    // MARK: Cancellation

    @Test("Cancelled before starting: nothing is opened")
    func cancelledBeforeStart() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runAttempt(source.url, content: content)
        }.value
        #expect(result.failure == .cancelled)
        #expect(content.record.opens == 0)
        expectNothingPublished(result)
    }

    /// Where the decode is blocked when it is cancelled.
    enum CancelPoint: String, CaseIterable, Sendable {
        /// Inside a read, after earlier chunks were appended.
        case midRead
        /// Inside a sink append.
        case midAppend
        /// Inside the final (end-of-stream) read: the frame count is complete, so only the pre-finish
        /// check stands between the cancellation and publication.
        case finalRead
    }

    @Test("Cancellation at any point publishes nothing and releases everything", arguments: CancelPoint.allCases)
    func cancellation(_ point: CancelPoint) async throws {
        let source = try ScriptedSource()
        let gate = Gate()
        var script = source.script()
        // 1000-frame reads of a 12288-frame stream: reads 0...12 return data, read 13 returns 0.
        let finalRead = Int(source.aacStreamFrames / 1000) + 1
        switch point {
        case .midRead: script.onRead = { if $0 == 4 { gate.arriveAndWait() } }
        case .finalRead: script.onRead = { if $0 == finalRead { gate.arriveAndWait() } }
        case .midAppend: break
        }
        let content = ScriptedContentIO(script)
        let blockOnAppend = point == .midAppend
        let onAppend: @Sendable (Int) -> Void = { index in
            if blockOnAppend, index == 2 { gate.arriveAndWait() }
        }
        let task = Task { await runAttempt(source.url, content: content, onAppend: onAppend) }
        await gate.waitForArrival()
        task.cancel()
        gate.open()
        let result = await task.value
        #expect(result.failure == .cancelled)
        #expect(result.events.contains("append"))
        expectNothingPublished(result)
        #expect(content.record.closes == 1)
        #expect(content.record.opens == 1)
        if point == .finalRead { #expect(content.record.reads == finalRead + 1) }
    }

    // MARK: Identity and staleness

    @Test("An opened file that isn't the checked file is refused before any sink is made")
    func identityMismatch() async throws {
        let source = try ScriptedSource()
        let changes: [(inout OpenedFileState) -> Void] = [
            { $0.fileNumber += 1 },
            { $0.sizeBytes += 1 },
            { $0.modificationSeconds += 5 },
        ]
        for change in changes {
            var facts = source.aacFacts()
            change(&facts.openedFile)
            let content = ScriptedContentIO(source.script(facts))
            let attempt = await runAttempt(source.url, content: content)
            #expect(attempt.failure == .sourceIdentityMismatch)
            #expect(attempt.sinksMade == 0)
            expectNothingPublished(attempt)
            #expect(content.record.closes == 1)
            #expect(content.record.reads == 0)
        }
    }

    @Test("A change to the open descriptor during decoding is stale and publishes nothing")
    func descriptorChanged() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        var changed = source.opened
        changed.modificationNanoseconds += 1
        script.stateAfterDecode = changed
        let attempt = await runAttempt(source.url, content: ScriptedContentIO(script))
        #expect(attempt.failure == .sourceChangedDuringDecode)
        expectNothingPublished(attempt)
    }

    @Test("A change to the path's metadata during decoding is stale and publishes nothing")
    func pathChanged() async throws {
        let source = try ScriptedSource()
        let adjustments: [@Sendable (inout MetadataResult) -> Void] = [
            { $0.modify { $0.fingerprint.fileSize = .known(($0.fingerprint.fileSize.value ?? 0) + 1) } },
            { $0.modify { $0.fingerprint.fileIdentifier = .known(($0.fingerprint.fileIdentifier.value ?? 0) + 1) } },
            { $0.modify { $0.fingerprint.contentModificationDate = .known(Date(timeIntervalSince1970: 0)) } },
            { $0.modify { $0.fingerprint.fileSize = .unknown } },
            { $0 = .failure(.notFound) },
        ]
        for adjust in adjustments {
            let io = AdjustableIO { result, call in if call == 1 { adjust(&result) } }
            let attempt = await runAttempt(source.url, content: ScriptedContentIO(source.script()), io: io)
            #expect(attempt.failure == .sourceChangedDuringDecode)
            expectNothingPublished(attempt)
            #expect(io.metadataCalls == 2)
            #expect(io.scopeBalance.starts == io.scopeBalance.stops)
        }
        // Unchanged metadata is accepted.
        let io = AdjustableIO()
        #expect(await runAttempt(source.url, content: ScriptedContentIO(source.script()), io: io).failure == nil)
        #expect(io.metadataCalls == 2)
    }

    @Test("A real file touched while decoding is stale and publishes nothing")
    func realFileTouched() async throws {
        let directory = try FixtureDirectory("touched")
        let signal = LandmarkSignal(frames: 6000, channelCount: 2, seed: 52)
        let fixture = try directory.write(FixtureSpec(container: .aiff, codec: .linearPCM, sampleFormat: .int(16, bigEndian: true), sampleRate: 48_000, channelCount: 2), signal: signal)
        let copy = try directory.copy(fixture, as: "touched.aiff")
        let path = copy.path
        let attempt = await runAttempt(copy, content: SystemSourceContentIO(), io: SystemSourceIO(), onAppend: { index in
            if index == 1 {
                var times = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000_000, tv_nsec: 0)]
                _ = utimensat(AT_FDCWD, path, &times, 0)
            }
        })
        #expect(attempt.failure == .sourceChangedDuringDecode)
        expectNothingPublished(attempt)
    }

    // MARK: Preflight (metadata only; nothing opened)

    struct PreflightCase: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var adjust: @Sendable (inout MetadataResult) -> Void
        var expected: DecodeFailure
    }

    static let preflightCases: [PreflightCase] = [
        PreflightCase(testDescription: "dataless", adjust: { $0.modify { $0.isDataless = .known(true) } }, expected: .notMaterialized),
        PreflightCase(testDescription: "residency unknown", adjust: { $0.modify { $0.isDataless = .unknown } }, expected: .residencyUnknown),
        PreflightCase(testDescription: "iCloud not downloaded", adjust: { $0.modify { $0.ubiquitous.downloadingStatus = .known(.notDownloaded) } }, expected: .notMaterialized),
        PreflightCase(testDescription: "iCloud downloading", adjust: { $0.modify { $0.ubiquitous.isDownloading = .known(true) } }, expected: .notMaterialized),
        PreflightCase(testDescription: "unreadable", adjust: { $0.modify { $0.isReadable = .known(false) } }, expected: .permissionDenied),
        PreflightCase(testDescription: "type unknown", adjust: { $0.modify { $0.isRegularFile = .unknown } }, expected: .metadataUnavailable(nil)),
        PreflightCase(testDescription: "not a regular file", adjust: { $0.modify { $0.isRegularFile = .known(false) } }, expected: .notARegularFile),
        PreflightCase(testDescription: "symbolic link", adjust: { $0.modify { $0.isSymbolicLink = .known(true) } }, expected: .notARegularFile),
        PreflightCase(testDescription: "size unknown", adjust: { $0.modify { $0.fingerprint.fileSize = .unknown } }, expected: .metadataUnavailable(nil)),
        PreflightCase(testDescription: "date unknown", adjust: { $0.modify { $0.fingerprint.contentModificationDate = .unknown } }, expected: .metadataUnavailable(nil)),
        PreflightCase(testDescription: "size zero", adjust: { $0.modify { $0.fingerprint.fileSize = .known(0) } }, expected: .emptyFile),
        PreflightCase(testDescription: "not found", adjust: { $0 = .failure(.notFound) }, expected: .notFound),
        PreflightCase(testDescription: "permission", adjust: { $0 = .failure(.permissionDenied) }, expected: .permissionDenied),
    ]

    @Test("Metadata that can't prove a local, readable regular file stops the decode before opening", arguments: preflightCases)
    func preflight(_ planted: PreflightCase) async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let io = AdjustableIO { result, call in if call == 0 { planted.adjust(&result) } }
        let attempt = await runAttempt(source.url, content: content, io: io)
        #expect(attempt.failure == planted.expected)
        #expect(content.record.opens == 0)
        #expect(attempt.sinksMade == 0)
        expectNothingPublished(attempt)
        #expect(io.scopeBalance.starts == 1 && io.scopeBalance.stops == 1)
    }

    @Test("Gateway open failures pass through typed")
    func openFailure() async throws {
        let source = try ScriptedSource()
        for failure: DecodeFailure in [.unreadableContainer(status: 1), .notMaterialized, .permissionDenied, .readFailed(errno: EIO)] {
            var script = source.script()
            script.openFailure = failure
            let attempt = await runAttempt(source.url, content: ScriptedContentIO(script))
            #expect(attempt.failure == failure)
            expectNothingPublished(attempt)
        }
    }

    // MARK: Sink failures

    @Test("A sink that refuses a chunk is abandoned; a sink that can't be made gets nothing")
    func sinkFailures() async throws {
        let source = try ScriptedSource()
        let refusing = ScriptedContentIO(source.script())
        let refused = await runAttempt(source.url, content: refusing, failAfterChunks: 2)
        guard case .sinkFailed = refused.failure else {
            Issue.record("expected sinkFailed, got \(String(describing: refused.failure))")
            return
        }
        expectNothingPublished(refused)
        #expect(refusing.record.closes == 1)

        let unmade = ScriptedContentIO(source.script())
        let failed = await runAttempt(source.url, content: unmade, sinkError: true)
        guard case .sinkFailed = failed.failure else {
            Issue.record("expected sinkFailed, got \(String(describing: failed.failure))")
            return
        }
        #expect(failed.events.isEmpty)
        #expect(unmade.record.reads == 0)
        #expect(unmade.record.closes == 1)
    }

    @Test("Interpretation failures close the reader before any sink is made")
    func interpretationFailure() async throws {
        let source = try ScriptedSource()
        var facts = source.aacFacts()
        facts.packetTable = nil
        let content = ScriptedContentIO(source.script(facts))
        let attempt = await runAttempt(source.url, content: content)
        #expect(attempt.failure == .unsupported(.encoderDelayUnknown))
        #expect(attempt.sinksMade == 0)
        #expect(content.record.closes == 1)
        #expect(content.record.reads == 0)
    }
}
