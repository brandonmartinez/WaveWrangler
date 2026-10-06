import Foundation
import WWPersistence

/// Relays `LibraryStore.onMoveStep` reports to main-actor UI state, in order (ST-33 step 3). Also compiled into the
/// unhosted WaveWranglerTests target, which drives it from a real `LibraryStore` move.
enum MoveStepRelay {
    /// Each reported step is shown on the main actor; a late hop never shows an older step over a newer one.
    /// `holdAfterChecking` (UI tests only; zero otherwise): when the end is reported right after "checking", the
    /// "checking" step is shown (its own hop may have been superseded on a fast disk) and kept that long first.
    static func handler(
        holdAfterChecking: Duration,
        current: @escaping @MainActor () -> LibraryMoveStep?,
        show: @escaping @MainActor (LibraryMoveStep?) -> Void
    ) -> @Sendable (LibraryMoveStep?) -> Void {
        let order = Order()
        return { step in
            let (sequence, previous) = order.next(step)
            Task { @MainActor in
                if step == nil, holdAfterChecking > .zero, previous == .checking {
                    if current() != .checking { show(.checking) }
                    try? await Task.sleep(for: holdAfterChecking)
                }
                guard order.isLatest(sequence) else { return }
                show(step)
            }
        }
    }

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var issued = 0
        private var lastReported: LibraryMoveStep?
        /// The new report's sequence number and the step reported before it.
        func next(_ step: LibraryMoveStep?) -> (Int, LibraryMoveStep?) {
            lock.withLock {
                issued += 1
                defer { lastReported = step }
                return (issued, lastReported)
            }
        }
        func isLatest(_ sequence: Int) -> Bool { lock.withLock { sequence == issued } }
    }
}
