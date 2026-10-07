/// Serializes publication for an episode while allowing a newer verified document to supersede
/// a source reconciliation that is still suspended. A publication already in progress completes
/// before its successor, so an older result cannot be the final identity.
public actor VerifiedDocumentReconciler {
    private var generation: UInt64 = 0
    private var publication: Task<Result<Bool, any Error>, Never>?

    public init() {}

    @discardableResult
    public func reconcile(
        resolve: @escaping @Sendable () async -> Void,
        publish: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        generation &+= 1
        let current = generation
        await resolve()
        guard generation == current else { return false }
        let previous = publication
        let next = Task { [self] () -> Result<Bool, any Error> in
            _ = await previous?.value
            guard generation == current else { return .success(false) }
            do {
                try await publish()
                return .success(generation == current)
            } catch {
                return .failure(error)
            }
        }
        publication = next
        return try await next.value.get()
    }
}
