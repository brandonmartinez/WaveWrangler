import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

@Suite("Listening render startup", .serialized)
struct ListeningRenderStartupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LISTENING_BENCHMARK"] == "1"))
    func syntheticPreparationTiming() async throws {
        let clock = ContinuousClock()
        for (name, ratio, frames) in [
            ("identity-5s", q(1), Int64(240_000)),
            ("identity-500ms", q(1), Int64(24_000)),
            ("drift-500ms", q(10_001, 10_000), Int64(24_000)),
        ] {
            let epoch = RecordingEpochID()
            let input = occurrence(frames: 480_000, rate: 48_000)
            let map = try groupMap(
                epochs: [mapped(epoch, [seg(q(0), q(10), ratio, .zero)])],
                placements: [OccurrencePlacement(occurrence: input, spans: [span(0, 480_000, epoch)])]
            )
            let request = RenderRequest(groupMap: map, outputRate: rate(48_000), outputFrames: 0..<frames,
                channels: channels(input.id, 1), inputAssets: assets([input.id]))
            var elapsed: [Double] = []
            for _ in 0..<3 {
                let start = clock.now
                let result = try await renderToArrays(request, provider: FunctionProvider { _, _, frame in
                    Float(frame % 100) / 100
                })
                let duration = start.duration(to: clock.now).components
                elapsed.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                #expect(result.product[0].count == Int(frames))
            }
            print("LISTENING_RENDER \(name) seconds=\(elapsed)")
        }
    }
}
