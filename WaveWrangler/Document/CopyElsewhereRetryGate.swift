/// ST-11 × ST-16 (#197 review): while "Save a Copy Elsewhere…" runs (its save panel and the copy's save), nothing saves
/// the original automatically: neither the pending automatic retry nor any autosave. If the original's folder came
/// back meanwhile, an automatic save would write the edits into the original before the copy exists, and the original
/// must keep its last saved version. A retry that was pending, or that a failure asked for meanwhile, is re-armed
/// with a fresh interval (never at once) when the copy is cancelled or fails. After a saved copy the window edits the
/// copy (a separate show), whose own saves decide any later retry.
struct CopyElsewhereRetryGate: Equatable {
    private(set) var isActive = false
    private(set) var retrySuspended = false

    /// Automatic saves of the original are allowed only outside the copy flow.
    var allowsAutomaticSave: Bool { !isActive }

    /// The copy flow starts; `retryPending` is whether an automatic retry was scheduled (the caller cancels it).
    mutating func begin(retryPending: Bool) {
        isActive = true
        retrySuspended = retryPending
    }

    /// A retry was asked for during the copy flow: kept for when it ends.
    mutating func suspendRetry() {
        guard isActive else { return }
        retrySuspended = true
    }

    /// The copy flow ends. Returns whether to re-arm the automatic retry (with a fresh interval).
    mutating func end(copySaved: Bool) -> Bool {
        defer { isActive = false; retrySuspended = false }
        return isActive && retrySuspended && !copySaved
    }
}
