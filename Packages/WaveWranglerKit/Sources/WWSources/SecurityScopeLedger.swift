import Foundation
import Synchronization

/// Counts security-scoped access so every successful start is provably balanced by exactly one stop.
///
/// The only way WWSources starts a scope is `withScopedAccess`, which stops it on return, throw and
/// cancellation. Scopes are held for one operation only — never as locks or long-lived grants.
public final class SecurityScopeLedger: Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// Scopes started and not yet stopped. Must be zero whenever no operation is running.
        public var openScopes: Int
        public var maximumOpenScopes: Int
        public var starts: Int
        public var stops: Int
        /// `startAccessingSecurityScopedResource` returned false (not sandboxed, not scoped or no grant).
        /// Nothing is stopped for these.
        public var unavailableStarts: Int
    }

    private let state = Mutex(Snapshot(openScopes: 0, maximumOpenScopes: 0, starts: 0, stops: 0, unavailableStarts: 0))

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    /// Runs `body` with security-scoped access to `url` (if the platform grants it) and always releases it.
    public func withScopedAccess<T>(to url: URL, using io: any SourceIO, _ body: (URL) throws -> T) rethrows -> T {
        let started = begin(url, io)
        defer { end(url, io, started) }
        return try body(url)
    }

    /// Async variant: the scope is released on return, error and task cancellation.
    public func withScopedAccess<T>(
        to url: URL,
        using io: any SourceIO,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async rethrows -> T {
        let started = begin(url, io)
        defer { end(url, io, started) }
        return try await body(url)
    }

    private func begin(_ url: URL, _ io: any SourceIO) -> Bool {
        let started = io.startAccessingSecurityScope(url)
        state.withLock {
            if started {
                $0.starts += 1
                $0.openScopes += 1
                $0.maximumOpenScopes = max($0.maximumOpenScopes, $0.openScopes)
            } else {
                $0.unavailableStarts += 1
            }
        }
        return started
    }

    private func end(_ url: URL, _ io: any SourceIO, _ started: Bool) {
        guard started else { return }
        io.stopAccessingSecurityScope(url)
        state.withLock {
            $0.stops += 1
            $0.openScopes -= 1
        }
    }
}

/// Everything a WWSources engine component needs: the gateway, the scope ledger and a clock.
public struct SourceAccessContext: Sendable {
    public let io: any SourceIO
    public let ledger: SecurityScopeLedger
    public let now: @Sendable () -> Date

    public init(io: any SourceIO = SystemSourceIO(), ledger: SecurityScopeLedger = SecurityScopeLedger(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.io = io
        self.ledger = ledger
        self.now = now
    }

    public func withScopedAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T {
        try ledger.withScopedAccess(to: url, using: io, body)
    }

    public func withScopedAccess<T>(
        to url: URL,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async rethrows -> T {
        try await ledger.withScopedAccess(to: url, using: io, body)
    }
}
