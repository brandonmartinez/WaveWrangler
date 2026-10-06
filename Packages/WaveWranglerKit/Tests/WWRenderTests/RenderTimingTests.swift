import Darwin
import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

/// Seeded noise generated on demand: no decoded buffer is retained between requests.
private struct NoiseProvider: RenderSampleProvider {
    func samples(for request: RenderSampleRequest) async throws -> [[Float]] {
        request.decodedChannels.map { channel in
            request.frames.map { frame in
                var z = UInt64(bitPattern: frame) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(channel) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 31)) &* 0x94D0_49BB_1331_11EB
                return Float(Int64(bitPattern: z >> 11) - (1 << 52)) / Float(1 << 52) * 0.5
            }
        }
    }
}

/// Discards every chunk, keeping only a count and a checksum (so the work cannot be optimised away).
private struct DiscardingSink: RenderOutputSink {
    var frames = 0
    var checksum: Double = 0
    mutating func append(_ chunk: RenderedChunk) throws {
        frames += chunk.frameCount
        checksum += chunk.samples.reduce(0) { $0 + Double($1) }
    }
    mutating func finish() throws -> (frames: Int, checksum: Double) { (frames, checksum) }
    mutating func abandon() {}
}

/// Resident peak of this process, bytes (macOS reports `ru_maxrss` in bytes).
private func residentPeakBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

@Suite("Render timing (WW_TIMING_TESTS)")
struct RenderTimingTests {
    /// Family peak gate: rendering one 6-channel group family (60 s at 48 kHz, a = 1.0001) holds a bounded
    /// working set and the process resident peak stays at or below 1 GiB. Throughput is reported, not gated.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_TIMING_TESTS"] == "1", "timing pass (WW_TIMING_TESTS=1)"))
    func renderFamilyPeakAndThroughput() async throws {
        let seconds: Int64 = 60
        let fixture = try SingleSpan(rate: 48000, frames: 48000 * seconds + 48000, a: q(10001, 10000))
        let request = fixture.request(48000, 0 ..< 48000 * seconds, channels: 6)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await GroupRenderer.render(request, provider: NoiseProvider()) { _ in DiscardingSink() }
        let elapsed = start.duration(to: clock.now)
        let peak = residentPeakBytes()
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18

        #expect(result.product.frames == Int(48000 * seconds))
        #expect(result.product.checksum.isFinite)
        #expect(peak <= RenderGates.familyPeakBytes, "resident peak \(peak) bytes")
        // The renderer's own working set is a few chunks, independent of the render length.
        #expect(result.report.peakWorkingSetBytes <= 1 << 20, "working set \(result.report.peakWorkingSetBytes)")

        let line = String(
            format: "WW-018 timing: 6 ch x %llds @48k a=1.0001: %.2f s wall (%.1fx real time), chunks %d, resident peak %.1f MiB, renderer working set %d bytes, peak window %d frames",
            seconds, elapsedSeconds, Double(seconds) / elapsedSeconds, result.report.chunks,
            Double(peak) / 1_048_576, result.report.peakWorkingSetBytes, result.report.peakWindowFrames
        )
        print(line)
        if let directory = RenderFixture.recordsDirectory {
            try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("ww-018-timing.txt"))
        }
    }
}
