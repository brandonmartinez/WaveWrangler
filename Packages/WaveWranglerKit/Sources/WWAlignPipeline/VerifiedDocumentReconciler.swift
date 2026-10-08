import WWCore

/// Tracks the last successful (or in-flight) open for each episode. A failed open retains its
/// document registration so verified save/undo can still find it, but permits the same stamp to retry.
public struct OpenedDocumentPublications {
    private struct Version: Equatable {
        var documentID: ObjectIdentifier
        var publication: PublicationStamp?
    }

    private var versions: [EpisodeID: Version] = [:]

    public init() {}

    public mutating func begin(
        episode: EpisodeID, documentID: ObjectIdentifier, publication: PublicationStamp
    ) -> Bool {
        let version = Version(documentID: documentID, publication: publication)
        guard versions[episode] != version else { return false }
        versions[episode] = version
        return true
    }

    public func owns(
        episode: EpisodeID, documentID: ObjectIdentifier, publication: PublicationStamp
    ) -> Bool {
        versions[episode] == Version(documentID: documentID, publication: publication)
    }

    public mutating func retry(
        episode: EpisodeID, documentID: ObjectIdentifier, publication: PublicationStamp
    ) {
        guard owns(episode: episode, documentID: documentID, publication: publication) else { return }
        versions[episode] = Version(documentID: documentID, publication: nil)
    }

    public func episodes(for documentID: ObjectIdentifier) -> [EpisodeID] {
        versions.compactMap { episode, version in version.documentID == documentID ? episode : nil }
    }
}

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
        try Task.checkCancellation()
        guard generation == current else { return false }
        let previous = publication
        let next = Task { [self] () -> Result<Bool, any Error> in
            _ = await previous?.value
            do {
                try Task.checkCancellation()
            } catch {
                return .failure(error)
            }
            guard generation == current else { return .success(false) }
            do {
                try Task.checkCancellation()
                try await publish()
                return .success(generation == current)
            } catch {
                return .failure(error)
            }
        }
        publication = next
        return try await withTaskCancellationHandler {
            try await next.value.get()
        } onCancel: {
            next.cancel()
        }
    }
}
