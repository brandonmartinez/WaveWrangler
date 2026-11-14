import Foundation
import WWCore
import WWPersistence

/// Disk assertions read package documents without a flat-file compatibility path.
enum ShowStorage {
    static func read(_ url: URL) throws -> Data {
        try LocalFileOperations().read(url)
    }

    static func envelope(_ url: URL) throws -> [String: Any] {
        let document = try ShowPackageCoder().decode(read(url))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [
            "payload": try JSONSerialization.jsonObject(with: encoder.encode(document.payload)),
            "schemaVersion": document.payload.schemaVersion,
            "revision": document.revision,
            "publicationID": document.publication.publicationID.uuidString,
            "checksum": document.publication.checksum,
        ]
    }

    /// Only for explicit generated-fixture corruption/unknown-newer tests, not normal reads.
    static func contentURL(_ url: URL) throws -> URL {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            ? url.appending(path: ShowPackage.manifestName) : url
    }
}
