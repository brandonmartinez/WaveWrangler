import Foundation
import Testing
@testable import WWMix

@Suite("Mixer actor execution diagnostics")
struct MixerProcessingDiagnosticsTests {
    @Test func submissionWaitIsNotCountedAsRenderOrCaptureTime() {
        let diagnostics = MixerProcessingDiagnostics()
        let submitted = ContinuousClock.now
        let entered = submitted.advanced(by: .milliseconds(150))
        diagnostics.end(.processWait, since: submitted, at: entered)
        _ = diagnostics.begin(.render, at: entered)
        _ = diagnostics.begin(.unitRender, at: entered)
        diagnostics.end(.unitRender, since: entered, at: entered.advanced(by: .milliseconds(3)))
        diagnostics.end(.render, since: entered, at: entered.advanced(by: .milliseconds(4)))
        let capture = entered.advanced(by: .milliseconds(10))
        _ = diagnostics.begin(.stateCapture, at: capture)
        let snapshot = diagnostics.snapshot
        #expect(snapshot[.processWait]?.last == .milliseconds(150))
        #expect(snapshot[.render]?.longest == .milliseconds(4))
        #expect(snapshot[.unitRender]?.longest == .milliseconds(3))
        #expect(snapshot[.stateCapture]?.started == capture)
        #expect(snapshot[.stateCapture]?.count == 0)
        #expect(snapshot.count == MixerProcessingDiagnostics.Stage.allCases.count)
    }

    @Test func failedVendorWorkClosesItsTimingAndPreservesTheFailure() {
        let diagnostics = MixerProcessingDiagnostics()
        #expect(throws: CancellationError.self) {
            try diagnostics.measure(.stateCapture) { throw CancellationError() }
        }
        #expect(diagnostics.snapshot[.stateCapture]?.count == 1)
        #expect(diagnostics.snapshot[.stateCapture]?.started == nil)
    }
}
