import Testing

/// #197 review: while Save a Copy Elsewhere… runs, the original is never saved automatically; a suspended automatic
/// retry is re-armed (with a fresh interval) only when the copy is cancelled or fails.
@Suite("Save a Copy Elsewhere: automatic retry gate")
struct CopyElsewhereRetryGateTests {
    @Test func pendingRetryIsSuspendedDuringTheCopyAndReArmedOnCancel() {
        var gate = CopyElsewhereRetryGate()
        #expect(gate.allowsAutomaticSave)
        gate.begin(retryPending: true)
        #expect(!gate.allowsAutomaticSave, "no automatic save of the original while the panel is open")
        let rearm1 = gate.end(copySaved: false)
        #expect(rearm1, "cancelled: the retry is re-armed")
        #expect(gate.allowsAutomaticSave)
        let rearm2 = gate.end(copySaved: false)
        #expect(!rearm2, "ending twice re-arms nothing")
    }

    @Test func retryAskedForDuringTheCopyIsReArmedWhenTheCopyFails() {
        var gate = CopyElsewhereRetryGate()
        gate.begin(retryPending: false)
        gate.suspendRetry()
        let rearm3 = gate.end(copySaved: false)
        #expect(rearm3, "the copy failed: the original's retry is re-armed")
    }

    @Test func savedCopyReArmsNothing() {
        var gate = CopyElsewhereRetryGate()
        gate.begin(retryPending: true)
        gate.suspendRetry()
        let rearm4 = gate.end(copySaved: true)
        #expect(!rearm4, "the window now edits the copy, a separate show")
        #expect(gate.allowsAutomaticSave)
    }

    @Test func noRetryPendingReArmsNothing() {
        var gate = CopyElsewhereRetryGate()
        gate.begin(retryPending: false)
        let rearm5 = gate.end(copySaved: false)
        #expect(!rearm5)
    }

    @Test func suspendOutsideTheCopyFlowIsIgnored() {
        var gate = CopyElsewhereRetryGate()
        gate.suspendRetry()
        #expect(gate == CopyElsewhereRetryGate())
    }
}
