import Foundation

/// Coalesces identical cache preparations. One listener cannot cancel another listener's read.
actor SharedAudioWork<Key: Sendable & Equatable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let key: Key
        let task: Task<Value, any Error>
        var clients: Set<UUID>
    }

    private var entries: [Entry] = []
    var clientCount: Int { entries.reduce(0) { $0 + $1.clients.count } }

    func value(for key: Key, prepare: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let client = UUID()
        let id: UUID
        let task: Task<Value, any Error>
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].clients.insert(client)
            id = entries[index].id
            task = entries[index].task
        } else {
            id = UUID()
            task = Task { try await prepare() }
            entries.append(Entry(id: id, key: key, task: task, clients: [client]))
        }
        defer { release(id, client: client) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.release(id, client: client) }
        }
    }

    private func release(_ id: UUID, client: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].clients.subtract([client])
        if entries[index].clients.isEmpty {
            entries.remove(at: index).task.cancel()
        }
    }
}
