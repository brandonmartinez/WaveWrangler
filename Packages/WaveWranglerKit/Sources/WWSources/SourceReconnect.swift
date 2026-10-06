import Foundation
import Network

/// T30 (WW-012): which failed transfers WaveWrangler requests again by itself when the network comes back.
public enum ReconnectRetry {
    /// Only a transfer that failed with an **observed** connectivity error (the provider reported a network
    /// or iCloud-server error), only while availability is ON, and never one the user cancelled.
    /// A stall without an observed error, any other failure and cancellations wait for the user's Retry;
    /// with availability OFF nothing is requested automatically.
    public static func shouldRetry(_ state: TransferState?, setting: SourceAvailabilitySetting, userCancelled: Bool) -> Bool {
        guard setting == .on, !userCancelled, case let .offlineOrUnknown(error)? = state else { return false }
        return error != nil
    }
}

/// Reports each time network connectivity comes back after being lost.
public protocol ConnectivitySignal: Sendable {
    /// One element per unreachable → reachable transition. Ends when the signal stops.
    func reconnects() -> AsyncStream<Void>
}

/// Production signal: the system network path (Network framework). Observes reachability only; never
/// touches source files.
public final class NetworkPathConnectivity: ConnectivitySignal {
    public init() {}

    public func reconnects() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let state = PathState()
            monitor.pathUpdateHandler = { path in
                if state.update(satisfied: path.status == .satisfied) { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.brandonmartinez.wavewrangler.connectivity"))
        }
    }

    /// Tracks the last path status; true only on a not-satisfied → satisfied transition.
    private final class PathState: @unchecked Sendable {
        private let lock = NSLock()
        private var wasSatisfied: Bool?

        func update(satisfied: Bool) -> Bool {
            lock.withLock {
                defer { wasSatisfied = satisfied }
                return satisfied && wasSatisfied == false
            }
        }
    }
}
