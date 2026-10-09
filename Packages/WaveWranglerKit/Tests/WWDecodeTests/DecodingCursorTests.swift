import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// `SourceDecoder.withDecodingCursor`: the pull path shares the push path's gateway, guards and trims,
/// closes the reader and releases the scope on every path, and never returns an unverified result.
final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [DecodeFailure?] = []
    var values: [DecodeFailure?] { lock.withLock { _values } }
    func append(_ value: DecodeFailure?) { lock.withLock { _values.append(value) } }
}

final class AsyncStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if open { return true }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            open = true
            return self.continuation
        }
        continuation?.resume()
    }
}

final class TaskCancellationTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelBody: (@Sendable () -> Void)?

    func install<T, E>(_ task: Task<T, E>) where E: Error {
        lock.withLock { cancelBody = { task.cancel() } }
    }

    func cancel() {
        lock.withLock { cancelBody?() }
    }
}

@Suite("Decoding cursor")
struct DecodingCursorTests {
    struct Probe: Error, Equatable {}

    static func collect(_ cursor: DecodingCursor) async throws -> CollectedAudio {
        var sink = CollectingSink(channelCount: cursor.interpretation.channelCount)
        while let chunk = try await cursor.next() { try sink.append(chunk) }
        return try sink.finish()
    }

    static func failure(_ body: () async throws -> Void) async -> DecodeFailure? {
        do {
            try await body()
            return nil
        } catch {
            return error as? DecodeFailure
        }
    }

    @Test("The cursor yields exactly the frames and chunking that decode publishes", arguments: [1000, 1024, 4096, 16_384])
    func matchesDecode(chunkFrames: Int) async throws {
        let source = try ScriptedSource()
        let pushed = await runAttempt(source.url, content: ScriptedContentIO(source.script()), chunkFrames: chunkFrames)
        let expected = try pushed.result.get()
        let content = ScriptedContentIO(source.script())
        let ledger = SecurityScopeLedger()
        let decoder = makeDecoder(chunkFrames: chunkFrames, io: AdjustableIO(), content: content, ledger: ledger)
        let (audio, reads) = try await decoder.withDecodingCursor(source.url, source: SourceID()) { cursor in
            (try await Self.collect(cursor), await cursor.readCalls)
        }
        #expect(audio == expected.product)
        #expect(reads == expected.report.readCalls)
        #expect(audio.channels[0].count == Int(ScriptedSource.aacValid))
        // Priming removed: the first published frame is codec-stream frame 2112.
        #expect(audio.channels[0].first == Float(ScriptedSource.aacPriming))
        #expect(content.record.closes == content.record.opens)
        #expect(content.record.readsOnMainThread == 0)
        #expect(content.record.contentCallsInsideTask == 0, "blocking content calls run only on the cursor's Dispatch worker")
        #expect(ledger.snapshot.openScopes == 0)
    }

    @Test("Opening without reading (a header probe) decodes nothing and closes the reader")
    func headerProbe() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let ledger = SecurityScopeLedger()
        let io = AdjustableIO()
        let interpretation = try await makeDecoder(io: io, content: content, ledger: ledger).withDecodingCursor(source.url, source: SourceID()) { cursor in
            cursor.interpretation
        }
        #expect(interpretation.frames.validFrames == ScriptedSource.aacValid)
        #expect(content.record.reads == 0)
        #expect(content.record.opens == 1 && content.record.closes == 1)
        #expect(io.metadataCalls == 2, "a header-only receipt also requires a closing identity check")
        #expect(ledger.snapshot.openScopes == 0)
    }

    @Test("Overflowing declared codec frame ranges refuse a header and a decode without reading")
    func headerDeclaredFrameOverflow() async throws {
        let source = try ScriptedSource()
        let cases: [(Int64, Int64, Int64)] = [
            (.max, 1, 0),
            (.max - 1, 0, 2),
            (.max - 1023, 0, 0)
        ]
        for (valid, priming, remainder) in cases {
            var facts = source.aacFacts()
            facts.readerLengthFrames = valid
            facts.packetTable = PacketTableFacts(validFrames: valid, primingFrames: priming, remainderFrames: remainder)
            let content = ScriptedContentIO(source.script(facts))
            let decoder = makeDecoder(io: AdjustableIO(), content: content)
            let id = SourceID()
            let interpretation = try DecodeEnvelope.interpret(
                facts, url: source.url, source: id,
                fingerprint: FormatInterpretationTests.fingerprint
            )
            #expect(interpretation.frames.validFrames == valid)
            await #expect(throws: DecodeFailure.inconsistentStream(.invalidDeclaredCount("codec stream frame range overflows Int64"))) {
                try await decoder.probeHeader(source.url, source: id, grant: DecoderHeaderGrant(explicitUserRequestFor: id))
            }
            #expect(content.record.opens == 1 && content.record.closes == 1)
            #expect(content.record.reads == 0)
            let result = await runAttempt(source.url, content: ScriptedContentIO(source.script(facts)))
            #expect(result.failure == .inconsistentStream(.invalidDeclaredCount("codec stream frame range overflows Int64")))
        }
    }

    @Test("A header receipt with a grant for another source refuses before content open")
    func wrongSourceHeaderGrant() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let decoder = makeDecoder(io: AdjustableIO(), content: content)
        await #expect(throws: DecodeFailure.permissionDenied) {
            try await decoder.probeHeader(
                source.url, source: SourceID(), grant: DecoderHeaderGrant(explicitUserRequestFor: SourceID())
            )
        }
        #expect(content.record.opens == 0)
    }

    @Test("A decoder header receipt uses the real read-only gateway on a generated stereo WAVE")
    func systemHeaderReceipt() async throws {
        let directory = try FixtureDirectory("header-receipt")
        let url = try directory.write(
            FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false),
                        sampleRate: 48_000, channelCount: 2),
            signal: LandmarkSignal(channelCount: 2, seed: 81)
        )
        let source = SourceID()
        let receipt = try await SourceDecoder(access: SourceAccessContext(io: SystemSourceIO()))
            .probeHeader(url, source: source, grant: DecoderHeaderGrant(explicitUserRequestFor: source))
        #expect(receipt.interpretation.source == source)
        #expect(receipt.interpretation.channelCount == 2)
        #expect(receipt.interpretation.frames.validFrames == 23_456)
        #expect(receipt.interpretation.frames.primingFrames == 0)
    }

    @Test("A cursor that escapes its call is closed")
    func escapedCursorIsClosed() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let escaped = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { $0 }
        let failure = await Self.failure { _ = try await escaped.next() }
        #expect(failure == .cancelled)
        #expect(content.record.reads == 0)
        #expect(await Self.failure { try await escaped.verifyUnchanged() } == .cancelled)
    }

    @Test("A source changed while reading fails the call, so nothing derived from it is returned")
    func staleSource() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        var changed = source.opened
        changed.modificationNanoseconds += 1
        script.stateAfterDecode = changed
        let content = ScriptedContentIO(script)
        let returned = Counter()
        let failure = await Self.failure {
            _ = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                let audio = try await Self.collect(cursor)
                returned.increment()
                return audio
            }
        }
        #expect(failure == .sourceChangedDuringDecode)
        #expect(returned.count == 1, "the body ran to completion; the wrapper's closing check refused its result")
        #expect(content.record.closes == content.record.opens)

        // Path metadata changed after the first (preflight) call: the explicit check fails too.
        let io = AdjustableIO { result, call in
            if call >= 1 { result.modify { $0.fingerprint.fileSize = .known(($0.fingerprint.fileSize.value ?? 0) + 1) } }
        }
        let explicit = await Self.failure {
            _ = try await makeDecoder(io: io, content: ScriptedContentIO(source.script())).withDecodingCursor(source.url, source: SourceID()) { cursor in
                _ = try await cursor.next()
                try await cursor.verifyUnchanged()
            }
        }
        #expect(explicit == .sourceChangedDuringDecode)
    }

    @Test("A final unchanged check still runs after an explicit check")
    func finalCheckAfterExplicitCheck() async throws {
        let source = try ScriptedSource()
        let io = AdjustableIO { result, call in
            if call == 2 {
                result.modify { $0.fingerprint.fileSize = .known(($0.fingerprint.fileSize.value ?? 0) + 1) }
            }
        }
        let returned = Counter()
        let failure = await Self.failure {
            _ = try await makeDecoder(io: io, content: ScriptedContentIO(source.script()))
                .withDecodingCursor(source.url, source: SourceID()) { cursor in
                    _ = try await cursor.next()
                    try await cursor.verifyUnchanged()
                    returned.increment()
                    return 0
                }
        }
        #expect(failure == .sourceChangedDuringDecode)
        #expect(returned.count == 1, "the body returned; the mandatory final check refused its result")
        #expect(io.metadataCalls == 3, "preflight, explicit check, and final check")
    }

    @Test("A first-read failure the body swallows still fails the cursor call")
    func firstReadFailureIsTerminal() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.failure = (read: 0, error: .readFailed(errno: 5))
        let content = ScriptedContentIO(script)
        let seen = FailureLog()
        let outer = await Self.failure {
            _ = try await makeDecoder(io: AdjustableIO(), content: content)
                .withDecodingCursor(source.url, source: SourceID()) { cursor in
                    seen.append(await Self.failure { _ = try await cursor.next() })
                    return 0
                }
        }
        #expect(seen.values == [.readFailed(errno: 5)])
        #expect(outer == .readFailed(errno: 5), "a swallowed first-read failure must prevent publication")
        #expect(content.record.reads == 1)
        #expect(content.record.closes == 1)
    }

    @Test("A short stream fails at the end and the failure is terminal")
    func incompleteIsTerminal() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script(streamFrames: 9000))
        let seen = FailureLog()
        let outer = await Self.failure {
            _ = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                do {
                    while try await cursor.next() != nil {}
                } catch {
                    seen.append(error as? DecodeFailure)
                }
                seen.append(await Self.failure { _ = try await cursor.next() })
                return 0
            }
        }
        let expected = DecodeFailure.incompleteContent(expectedFrames: ScriptedSource.aacValid, decodedFrames: 9000 - ScriptedSource.aacPriming)
        #expect(seen.values == [expected, expected])
        #expect(outer == expected, "a body that swallows the failure still cannot return a result")
        #expect(content.record.closes == 1)
    }

    @Test("Overrun and over-length streams are refused exactly as decode refuses them")
    func streamGuards() async throws {
        let source = try ScriptedSource()
        var overrun = source.script()
        overrun.overrunAtRead = 1
        var long = source.script(streamFrames: source.aacStreamFrames + 1024 + 1)
        long.maximumFramesPerRead = 1024
        for script in [overrun, long] {
            let pushed = await runAttempt(source.url, content: ScriptedContentIO(script), chunkFrames: 1024)
            let content = ScriptedContentIO(script)
            let pulled = await Self.failure {
                _ = try await makeDecoder(chunkFrames: 1024, io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { try await Self.collect($0) }
            }
            #expect(pushed.failure != nil)
            #expect(pulled == pushed.failure)
            #expect(content.record.closes == content.record.opens)
        }
    }

    @Test("Cancellation stops the next read and closes the reader")
    func cancellation() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let ledger = SecurityScopeLedger()
        let decoder = makeDecoder(chunkFrames: 1000, io: AdjustableIO(), content: content, ledger: ledger)
        let url = source.url
        let task = Task { () -> DecodeFailure? in
            await Self.failure {
                _ = try await decoder.withDecodingCursor(url, source: SourceID()) { cursor in
                    _ = try await cursor.next()
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await cursor.next()
                }
            }
        }
        #expect(await task.value == .cancelled)
        #expect(content.record.reads == 3, "priming-only reads, then the first frames; nothing after the cancel")
        #expect(content.record.closes == 1)
        #expect(ledger.snapshot.openScopes == 0)

        // Already cancelled: no scope, no metadata, no open.
        let io = AdjustableIO()
        let untouched = ScriptedContentIO(source.script())
        let early = Task { () -> DecodeFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.failure {
                _ = try await makeDecoder(io: io, content: untouched).withDecodingCursor(url, source: SourceID()) { _ in 0 }
            }
        }
        #expect(await early.value == .cancelled)
        #expect(untouched.record.opens == 0 && io.metadataCalls == 0)
    }

    @Test("Cancellation during a read discards that read instead of returning a chunk")
    func cancellationDuringRead() async throws {
        let source = try ScriptedSource()
        let target = TaskCancellationTarget()
        var script = source.script()
        script.onRead = { if $0 == 0 { target.cancel() } }
        let content = ScriptedContentIO(script)
        let gate = AsyncStartGate()
        let returned = Counter()
        let task = Task { () -> DecodeFailure? in
            await gate.wait()
            return await Self.failure {
                _ = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                    _ = try await cursor.next()
                    returned.increment()
                }
            }
        }
        target.install(task)
        gate.release()

        #expect(await task.value == .cancelled)
        #expect(returned.count == 0, "the chunk read while cancellation arrived must not reach the cursor body")
        #expect(content.record.reads == 1)
        #expect(content.record.closes == 1)
        #expect(content.record.contentCallsInsideTask == 0)
    }

    @Test("A body error closes the reader and propagates unchanged")
    func bodyError() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let ledger = SecurityScopeLedger()
        do {
            _ = try await makeDecoder(io: AdjustableIO(), content: content, ledger: ledger).withDecodingCursor(source.url, source: SourceID()) { cursor -> Int in
                _ = try await cursor.next()
                throw Probe()
            }
            Issue.record("expected the body's error")
        } catch {
            #expect(error as? Probe == Probe())
        }
        #expect(content.record.closes == 1)
        #expect(ledger.snapshot.openScopes == 0)
    }

    @Test("Pre-read refusals (open failure, identity mismatch) never construct a cursor")
    func preReadRefusals() async throws {
        let source = try ScriptedSource()
        var openFails = source.script()
        openFails.openFailure = .readFailed(errno: 5)
        var mismatched = source.script()
        var other = source.opened
        other.fileNumber += 1
        mismatched.facts.openedFile = other
        for (script, expected) in [(openFails, DecodeFailure.readFailed(errno: 5)), (mismatched, .sourceIdentityMismatch)] {
            let content = ScriptedContentIO(script)
            let ran = Counter()
            let failure = await Self.failure {
                _ = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { _ in ran.increment() }
            }
            #expect(failure == expected)
            #expect(ran.count == 0)
            #expect(content.record.closes == content.record.opens - (script.openFailure == nil ? 0 : 1))
        }
    }
}
