import Foundation
import Testing
@testable import WWAlignPipeline

@Suite("Flattened listening PCM payloads")
struct ListeningPCMTests {
    @Test func binaryRoundTripPreservesEveryFloatBitAndSignedFrame() throws {
        let samples: [Float] = [0, -0.0, 0.1, -0.5, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        let pcm = ListeningPCM(firstFrame: -17, sampleRate: 48_000, channels: [samples, Array(samples.reversed())])
        let bytes = try pcm.encode()
        #expect(bytes.count == 32 + samples.count * 2 * 4)
        #expect(Array(bytes[32..<36]) == [0, 0, 0, 0])
        let restored = try ListeningPCM.decode(bytes)
        #expect(restored.firstFrame == -17 && restored.sampleRate == 48_000)
        #expect(restored.channels.map { $0.map(\.bitPattern) } == pcm.channels.map { $0.map(\.bitPattern) })
    }

    @Test func malformedShapeLengthsHeadersAndNonfiniteSamplesRefuse() throws {
        let shapes: [[[Float]]] = [[], [[]], [[0], []], [[.nan]], [[.infinity]]]
        for channels in shapes {
            #expect(throws: ListeningPCM.Failure.self) {
                try ListeningPCM(firstFrame: 0, sampleRate: 48_000, channels: channels).encode()
            }
        }
        let valid = try ListeningPCM(firstFrame: 0, sampleRate: 48_000, channels: [[0.1, -0.2]]).encode()
        var malformed = [Data(), valid.dropLast(), valid + Data([0])]
        for (offset, bits) in [(0, UInt32(0)), (8, UInt32(0)), (12, UInt32(33)), (32, Float.nan.bitPattern)] {
            var bytes = valid
            let replacement = [bits.littleEndian].withUnsafeBytes { Data($0) }
            bytes.replaceSubrange(offset..<(offset + 4), with: replacement)
            malformed.append(bytes)
        }
        for bytes in malformed {
            #expect(throws: ListeningPCM.Failure.self) { try ListeningPCM.decode(Data(bytes)) }
        }
        #expect(throws: ListeningPCM.Failure.self) {
            try ListeningPCM(firstFrame: .max, sampleRate: 48_000, channels: [[0]]).encode()
        }
    }

    private actor Probe {
        var calls = 0
        private var continuation: CheckedContinuation<Int, Never>?
        func prepare() async -> Int {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning: 7); continuation = nil }
    }

    @Test func oneListenerCancelDoesNotCancelSharedPreparation() async throws {
        let shared = SharedAudioWork<String, Int>()
        let probe = Probe()
        let first = Task { try await shared.value(for: "same") { await probe.prepare() } }
        while await shared.clientCount != 1 { await Task.yield() }
        let second = Task { try await shared.value(for: "same") { await probe.prepare() } }
        while await shared.clientCount != 2 { await Task.yield() }
        while await probe.calls == 0 { await Task.yield() }
        first.cancel()
        while await shared.clientCount != 1 { await Task.yield() }
        await probe.finish()
        #expect(try await second.value == 7)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await probe.calls == 1)
        #expect(await shared.clientCount == 0)
    }
}
