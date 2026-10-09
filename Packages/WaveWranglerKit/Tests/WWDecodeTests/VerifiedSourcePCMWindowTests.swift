import Foundation
import Testing
import WWCore
@testable import WWDecode

@Suite("Source-owned bounded PCM window")
struct VerifiedSourcePCMWindowTests {
    private func script(
        _ source: ScriptedSource, valid: Int64 = 40_000
    ) -> ScriptedContentIO.Script {
        let priming = ScriptedSource.aacPriming
        var script = source.script(
            source.aacFacts(valid: valid, remainder: 0, sampleRate: 16_000),
            streamFrames: priming + valid
        )
        script.sampleScale = 1 / 100_000
        return script
    }

    @Test func ownedWindowChecksDecodedOriginAndSelectedChannel() async throws {
        let source = try ScriptedSource()
        let id = SourceID()
        let content = ScriptedContentIO(script(source))
        let window = try await makeDecoder(chunkFrames: 4096, content: content)
            .readVerifiedPCMWindow(source.url, source: id, channel: 1, startingAt: 1234)
        #expect(window.interpretation.source == id)
        #expect(window.interpretation.sourceFingerprint.fileSize.isKnown)
        #expect(window.channel == 1)
        #expect(window.sourceFrames == 1234..<33_234)
        #expect(window.samples.count == 32_000)
        #expect(abs(window.samples[0] - (Float(1234 + ScriptedSource.aacPriming) + 0.25) / 100_000) < 0.000_001)
        #expect(content.record.closes == 1)
        #expect(content.record.reads > 1)
    }

    @Test func malformedRequestRefusesBeforeOpen() async throws {
        let source = try ScriptedSource()
        let content = ScriptedContentIO(script(source))
        let decoder = makeDecoder(content: content)
        for (channel, start) in [(-1, Int64(0)), (0, -1), (0, Int64.max)] {
            await #expect(throws: VerifiedPCMWindowFailure.invalidRequest) {
                try await decoder.readVerifiedPCMWindow(
                    source.url, source: SourceID(), channel: channel, startingAt: start
                )
            }
        }
        #expect(content.record.opens == 0)
    }

    @Test func wrongChannelRateAndInsufficientWindowRefuse() async throws {
        let source = try ScriptedSource()
        let id = SourceID()
        let decoder = makeDecoder(content: ScriptedContentIO(script(source)))
        await #expect(throws: VerifiedPCMWindowFailure.invalidRequest) {
            try await decoder.readVerifiedPCMWindow(
                source.url, source: id, channel: 2, startingAt: 0
            )
        }
        await #expect(throws: VerifiedPCMWindowFailure.invalidRequest) {
            try await decoder.readVerifiedPCMWindow(
                source.url, source: id, channel: 0, startingAt: 9_000
            )
        }
        var wrongRate = script(source)
        wrongRate.facts.sampleRate = 48_000
        await #expect(throws: VerifiedPCMWindowFailure.invalidRequest) {
            try await makeDecoder(content: ScriptedContentIO(wrongRate))
                .readVerifiedPCMWindow(source.url, source: id, channel: 0, startingAt: 0)
        }
    }

    @Test func shortDecoderAndChangedDescriptorNeverPublish() async throws {
        let source = try ScriptedSource()
        var short = script(source)
        short.streamFrames -= 1
        let shortIO = ScriptedContentIO(short)
        await #expect(throws: DecodeFailure.incompleteContent(expectedFrames: 40_000, decodedFrames: 39_999)) {
            try await makeDecoder(content: shortIO)
                .readVerifiedPCMWindow(source.url, source: SourceID(), channel: 0, startingAt: 0)
        }
        #expect(shortIO.record.closes == 1)

        var stale = script(source)
        var changed = source.opened
        changed.modificationNanoseconds += 1
        stale.stateAfterDecode = changed
        let staleIO = ScriptedContentIO(stale)
        await #expect(throws: DecodeFailure.sourceChangedDuringDecode) {
            try await makeDecoder(content: staleIO)
                .readVerifiedPCMWindow(source.url, source: SourceID(), channel: 0, startingAt: 0)
        }
        #expect(staleIO.record.closes == 1)
    }

    @Test func invalidSampleAndCancellationRefuseAfterRead() async throws {
        let source = try ScriptedSource()
        var badSample = script(source)
        badSample.sampleScale = 1
        await #expect(throws: VerifiedPCMWindowFailure.invalidPCM) {
            try await makeDecoder(content: ScriptedContentIO(badSample))
                .readVerifiedPCMWindow(source.url, source: SourceID(), channel: 1, startingAt: 0)
        }

        let cancellation = TaskCancellationTarget()
        let gate = AsyncStartGate()
        var interrupted = script(source)
        interrupted.onRead = { read in if read == 2 { cancellation.cancel() } }
        let content = ScriptedContentIO(interrupted)
        let task = Task {
            await gate.wait()
            try await makeDecoder(chunkFrames: 1000, content: content)
                .readVerifiedPCMWindow(source.url, source: SourceID(), channel: 0, startingAt: 0)
        }
        cancellation.install(task)
        gate.release()
        do {
            _ = try await task.value
            Issue.record("cancelled window unexpectedly returned")
        } catch {
            #expect(error as? DecodeFailure == .cancelled)
        }
        #expect(content.record.closes == 1)
    }
}
