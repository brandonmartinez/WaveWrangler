import Foundation
import Testing
@testable import WWDecode

@Suite("Bounded nominal multichannel PCM conversion", .serialized)
struct PCMResamplingTests {
    @Test(arguments: [8000, 11025, 44100, 48000, 192000])
    func pulseTimingAndChannelIdentity(inputRate: Int) async throws {
        let count = inputRate
        var pulse = [Float](repeating: 0, count: count)
        pulse[inputRate / 2] = 0.5
        let output = try await PCMResampling.convert([pulse, pulse.map { -0.5 * $0 }], inputRate: inputRate, outputRate: 48000)
        #expect(output.count == 2 && output[0].count == 48000)
        let peak = try #require(output[0].indices.max(by: { output[0][$0] < output[0][$1] }))
        #expect(abs(peak - Int((Double(inputRate / 2) * 48000 / Double(inputRate)).rounded())) <= 1)
        #expect(zip(output[0], output[1]).allSatisfy { abs($0 * 0.5 + $1) < 0.00001 })
    }

    @Test(arguments: [8, 16, 32])
    func discreteTracksAreNotSurroundRemixed(count: Int) async throws {
        let input = (0..<count).map { channel -> [Float] in
            var samples = [Float](repeating: 0, count: 8000)
            samples[1000 + channel * 100] = Float(channel + 1) / 64
            return samples
        }
        let output = try await PCMResampling.convert(input, inputRate: 8000, outputRate: 48000)
        #expect(output.count == count)
        for channel in 0..<count {
            #expect(output[channel].count == 48000)
            let peak = try #require(output[channel].indices.max(by: { output[channel][$0] < output[channel][$1] }))
            #expect(abs(peak - (1000 + channel * 100) * 6) <= 1)
            #expect(output[channel][peak] > 0.001)
        }
    }

    @Test func invalidPCMAndCancellationRefuse() async throws {
        await #expect(throws: PCMResampling.Failure.self) {
            try await PCMResampling.convert([[]], inputRate: 8000, outputRate: 48000)
        }
        await #expect(throws: PCMResampling.Failure.self) {
            try await PCMResampling.convert([[.nan]], inputRate: 8000, outputRate: 48000)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PCMResampling.convert([[0, 1]], inputRate: 8000, outputRate: 48000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
