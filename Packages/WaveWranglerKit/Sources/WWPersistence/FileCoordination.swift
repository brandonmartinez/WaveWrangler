import Foundation

/// Coordinated access to a canonical document location.
///
/// Coordination narrows the window for interleaved writers that also coordinate (other processes using
/// NSFileCoordinator, file-provider extensions). It is **not** a lock and not a provider compare-and-swap:
/// uncoordinated writers and remote devices can still interleave, which is why publication also re-checks the
/// on-disk base and verifies by read-back.
public protocol FileCoordinating: Sendable {
    func coordinateWriting<T>(at url: URL, _ body: (URL) throws -> T) throws -> T
    func coordinateReading<T>(at url: URL, _ body: (URL) throws -> T) throws -> T
}

/// Uses `NSFileCoordinator` (no presenter). Use for locations not already inside a coordinated NSDocument save.
public struct NSFileCoordination: FileCoordinating {
    public init() {}

    public func coordinateWriting<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinate { coordinator, error, accessor in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error, byAccessor: accessor)
        } body: { try body($0) }
    }

    public func coordinateReading<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinate { coordinator, error, accessor in
            coordinator.coordinate(readingItemAt: url, options: [], error: error, byAccessor: accessor)
        } body: { try body($0) }
    }

    private func coordinate<T>(
        _ start: (NSFileCoordinator, NSErrorPointer, (URL) -> Void) -> Void,
        body: (URL) throws -> T
    ) throws -> T {
        try coordinated(presenter: nil, start, body: body)
    }
}

/// Uses `NSFileCoordinator` on behalf of an open document's own file presenter (e.g. an `NSDocument` updating its
/// file outside its save methods), so that presenter isn't asked to relinquish the file to, or told about, its own
/// coordinated access. Other presenters and coordinating processes are coordinated with as usual.
public struct PresenterFileCoordination: FileCoordinating, @unchecked Sendable {
    // Immutable and only handed to NSFileCoordinator, which may be used from any thread.
    private let presenter: any NSFilePresenter

    public init(presenter: any NSFilePresenter) {
        self.presenter = presenter
    }

    public func coordinateWriting<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinated(presenter: presenter, { coordinator, error, accessor in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error, byAccessor: accessor)
        }, body: body)
    }

    public func coordinateReading<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinated(presenter: presenter, { coordinator, error, accessor in
            coordinator.coordinate(readingItemAt: url, options: [], error: error, byAccessor: accessor)
        }, body: body)
    }
}

private func coordinated<T>(
    presenter: (any NSFilePresenter)?,
    _ start: (NSFileCoordinator, NSErrorPointer, (URL) -> Void) -> Void,
    body: (URL) throws -> T
) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: presenter)
    var coordinationError: NSError?
    var result: Result<T, any Error>?
    withoutActuallyEscaping(body) { body in
        start(coordinator, &coordinationError) { actualURL in
            result = Result { try body(actualURL) }
        }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileWriteUnknown) }
    return try result.get()
}

/// For callers that are already inside a coordinated access for the same item (for example NSDocument's own
/// save, which coordinates before calling `writeSafely`). Nesting a second coordinator there could deadlock.
public struct AlreadyCoordinated: FileCoordinating {
    public init() {}

    public func coordinateWriting<T>(at url: URL, _ body: (URL) throws -> T) throws -> T { try body(url) }
    public func coordinateReading<T>(at url: URL, _ body: (URL) throws -> T) throws -> T { try body(url) }
}
