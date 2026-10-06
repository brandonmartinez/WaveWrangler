import Foundation
import WWPersistence

/// Relays `LibraryStore.onMoveStep` reports to main-actor UI state, in order (ST-33 step 3). Also compiled into the
/// unhosted WaveWranglerTests target, which drives it from a real `LibraryStore` move.
enum MoveStepRelay {
    /// Each reported step is shown on the main actor; a late hop never shows an older step over a newer one.
    /// `holdAfterChecking` (UI tests only; zero otherwise) keeps a shown "checking" step that long before the end.
    static func handler(
        holdAfterChecking: Duration,
        current: @escaping @MainActor () -> LibraryMoveStep?,
        show: @escaping @MainActor (LibraryMoveStep?) -> Void
    ) -> @Sendable (LibraryMoveStep?) -> Void {
        let order = Order()
        return { step in
            let sequence = order.next()
            Task { @MainActor in
                if step == nil, holdAfterChecking > .zero, current() == .checking {
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
        func next() -> Int { lock.withLock { issued += 1; return issued } }
        func isLatest(_ sequence: Int) -> Bool { lock.withLock { sequence == issued } }
    }
}
