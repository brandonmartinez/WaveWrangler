import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

@Suite("Exact bounded cursor seeking")
struct DecodingCursorSeekTests {
    @Test func seekPreservesPrimingOriginAndAbsolutePositionWithoutDecodingPrefix() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.supportsRandomAccess = true
        let content = ScriptedContentIO(script)
        let ledger = SecurityScopeLedger()
        let decoder = makeDecoder(chunkFrames: 1_024, io: AdjustableIO(), content: content, ledger: ledger)
        let chunk = try await decoder.withDecodingCursor(source.url, source: SourceID()) { cursor in
            try await cursor.seek(toSourceFrame: 8_765)
            let chunk = try #require(try await cursor.next(upToSourceFrame: 8_782))
            #expect(await cursor.position == 8_782)
            #expect(await cursor.readCalls == 1)
            return chunk
        }
        #expect(content.record.seeks == [ScriptedSource.aacPriming + 8_765])
        #expect(chunk.firstSourceFrame == 8_765 && chunk.frameCount == 17)
        #expect(chunk.samples[0] == Float(ScriptedSource.aacPriming + 8_765))
        #expect(chunk.samples[17] == Float(ScriptedSource.aacPriming + 8_765) + 0.25)
        #expect(content.record.contentCallsInsideTask == 0)
        #expect(content.record.closes == 1 && ledger.snapshot.openScopes == 0)
    }

    @Test func backwardSeekAfterEndStartsANewExactlyCountedSuffix() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.supportsRandomAccess = true
        let content = ScriptedContentIO(script)
        try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
            try await cursor.seek(toSourceFrame: ScriptedSource.aacValid)
            #expect(try await cursor.next() == nil)
            try await cursor.seek(toSourceFrame: ScriptedSource.aacValid - 10)
            let chunk = try #require(try await cursor.next(upToSourceFrame: ScriptedSource.aacValid))
            #expect(chunk.firstSourceFrame == ScriptedSource.aacValid - 10 && chunk.frameCount == 10)
            #expect(try await cursor.next() == nil)
        }
        #expect(content.record.closes == 1)
    }

    @Test func truncatedSuffixIsNotReportedAsACompleteSource() async throws {
        let source = try ScriptedSource()
        var script = source.script(streamFrames: ScriptedSource.aacPriming + ScriptedSource.aacValid - 4)
        script.supportsRandomAccess = true
        let failure = await DecodingCursorTests.failure {
            try await makeDecoder(io: AdjustableIO(), content: ScriptedContentIO(script))
                .withDecodingCursor(source.url, source: SourceID()) { cursor in
                    try await cursor.seek(toSourceFrame: ScriptedSource.aacValid - 10)
                    while try await cursor.next() != nil {}
                }
        }
        #expect(failure == .incompleteContent(expectedFrames: 10, decodedFrames: 6))
    }

    @Test(arguments: [-1, ScriptedSource.aacValid + 1])
    func invalidSeekIsTerminalEvenIfSwallowed(_ frame: Int64) async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.supportsRandomAccess = true
        let content = ScriptedContentIO(script)
        let failure = await DecodingCursorTests.failure {
            try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                #expect(await DecodingCursorTests.failure { try await cursor.seek(toSourceFrame: frame) } == .invalidSourceFrame(frame))
            }
        }
        #expect(failure == .invalidSourceFrame(frame))
        #expect(content.record.seeks.isEmpty && content.record.reads == 0 && content.record.closes == 1)
    }

    @Test func unsupportedSeekFailsClosedWithoutASequentialFallback() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(source.script())
        let failure = await DecodingCursorTests.failure {
            try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                #expect(!cursor.supportsRandomAccess)
                try await cursor.seek(toSourceFrame: 5_000)
            }
        }
        #expect(failure == .seekUnavailable)
        #expect(content.record.reads == 0 && content.record.closes == 1)
    }

    @Test func sourceChangedDuringSeekCannotReturnEvenAHeaderResult() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.supportsRandomAccess = true
        var changed = source.opened
        changed.modificationNanoseconds += 1
        script.stateAfterSeek = changed
        let content = ScriptedContentIO(script)
        let failure = await DecodingCursorTests.failure {
            _ = try await makeDecoder(io: AdjustableIO(), content: content).withDecodingCursor(source.url, source: SourceID()) { cursor in
                try await cursor.seek(toSourceFrame: 1_000)
                return cursor.interpretation
            }
        }
        #expect(failure == .sourceChangedDuringDecode)
        #expect(content.record.reads == 0 && content.record.closes == 1)
    }

    @Test func seekOnlyResultsStillReceiveAFinalSourceCheck() async throws {
        let source = try ScriptedSource()
        var script = source.script()
        script.supportsRandomAccess = true
        let io = AdjustableIO { result, call in
            if call == 3 { result.modify { $0.fingerprint.fileSize = .known(($0.fingerprint.fileSize.value ?? 0) + 1) } }
        }
        let failure = await DecodingCursorTests.failure {
            _ = try await makeDecoder(io: io, content: ScriptedContentIO(script))
                .withDecodingCursor(source.url, source: SourceID()) { cursor in
                    try await cursor.seek(toSourceFrame: 1_000)
                    return 7
                }
        }
        #expect(failure == .sourceChangedDuringDecode)
        #expect(io.metadataCalls == 4)
    }

    @Test func cancellationDuringSeekClosesTheSourceWithoutReturningAudio() async throws {
        let source = try ScriptedSource()
        let target = TaskCancellationTarget()
        var script = source.script()
        script.supportsRandomAccess = true
        script.onSeek = { _ in target.cancel() }
        let content = ScriptedContentIO(script)
        let gate = AsyncStartGate()
        let task = Task {
            await gate.wait()
            return await DecodingCursorTests.failure {
                try await makeDecoder(io: AdjustableIO(), content: content)
                    .withDecodingCursor(source.url, source: SourceID()) { cursor in
                        try await cursor.seek(toSourceFrame: 1_000)
                        _ = try await cursor.next()
                    }
            }
        }
        target.install(task)
        gate.release()
        #expect(await task.value == .canceled)
        #expect(content.record.seeks.count == 1 && content.record.reads == 0 && content.record.closes == 1)
    }

    @Test(arguments: [ContainerKind.wave, .aiff, .aifc, .caf])
    func actualPCMSeekMatchesWrittenSamplesAndKeepsTheOriginal(_ container: ContainerKind) async throws {
        let dir = try FixtureDirectory("exact-seek")
        let signal = LandmarkSignal(channelCount: 2, seed: 448)
        let format: SourceSampleFormat = container == .aifc
            ? .float(32, bigEndian: true) : .int(16, bigEndian: container == .aiff)
        let url = try dir.write(FixtureSpec(
            container: container, codec: .linearPCM, sampleFormat: format,
            sampleRate: 48_000, channelCount: 2
        ), signal: signal)
        let original = try Data(contentsOf: url)
        let decoder = SourceDecoder(access: SourceAccessContext())
        try await decoder.withDecodingCursor(url, source: SourceID()) { cursor in
            #expect(cursor.supportsRandomAccess)
            for first in [Int64(18_123), 37, Int64(signal.frames - 11)] {
                try await cursor.seek(toSourceFrame: first)
                let chunk = try #require(try await cursor.next(upToSourceFrame: first + 11))
                #expect(chunk.firstSourceFrame == first && chunk.frameCount == 11)
                for channel in 0..<2 {
                    #expect(Array(chunk.samples[(channel * 11)..<((channel + 1) * 11)])
                        == Array(signal.channels[channel][Int(first)..<(Int(first) + 11)]))
                }
            }
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
