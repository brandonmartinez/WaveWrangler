import Foundation
import Testing
@testable import WWRender

@Suite("Absolute nominal PCM phase")
struct NominalPCMRendererTests {
    private func render(_ range: Range<Int64>, rate: Int = 44_100) async throws -> [[Float]] {
        try await NominalPCMRenderer.render(sampleRate: rate, support: 5..<446, outputFrames: range,
                                            channels: [1, 0]) { frames, channels in
            channels.map { channel in
                frames.map { frame in
                    frame == 7 + channel ? Float(0.75) : Float(frame * Int64(channel + 1)) / 4096
                }
            }
        }
    }

    @Test func windowSeeksRetainOriginalTrimSupportAndAbsoluteSourcePhase() async throws {
        let whole = try await render(0..<480)
        let head = try await render(0..<2)
        let tail = try await render(2..<480)
        #expect(zip(head, tail).map(+) == whole)
        #expect(try await render(1..<17) == whole.map { Array($0[1..<17]) })
        let a = try await render(0..<113), b = try await render(113..<479), c = try await render(479..<480)
        #expect(zip(zip(a, b).map(+), c).map(+) == whole)
        #expect(whole[0] != whole[1])
    }

    @Test func unityRateCopiesExactSelectedNativeFramesAndChannelOrder() async throws {
        let output = try await render(3..<19, rate: 48_000)
        let left: [Float] = (8..<24).map { frame in frame == 8 ? Float(0.75) : Float(frame * 2) / 4096 }
        let right: [Float] = (8..<24).map { Float($0) / 4096 }
        #expect(output[0] == left)
        #expect(output[1] == right)
    }

    @Test func invalidShapesNonfiniteMediaAndOutOfSupportOwnershipRefuse() async throws {
        await #expect(throws: NominalPCMFailure.incompletePCM) {
            try await NominalPCMRenderer.render(sampleRate: 44_100, support: 0..<441, outputFrames: 0..<2,
                channels: [0]) { _, _ in [[]] }
        }
        await #expect(throws: NominalPCMFailure.nonfinitePCM) {
            try await NominalPCMRenderer.render(sampleRate: 48_000, support: 0..<441, outputFrames: 0..<2,
                channels: [0]) { frames, _ in [.init(repeating: .nan, count: frames.count)] }
        }
        for range: Range<Int64> in [-1..<2, 0..<481, 1..<1, 0..<4097, (Int64.max - 1)..<Int64.max] {
            await #expect(throws: NominalPCMFailure.invalidRequest) {
                try await render(range)
            }
        }
    }

    @Test func cancellationCannotReturnPreparedSamples() async throws {
        let task = Task {
            try await NominalPCMRenderer.render(sampleRate: 44_100, support: 0..<441, outputFrames: 0..<480,
                channels: [0]) { frames, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return [.init(repeating: 1, count: frames.count)]
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
