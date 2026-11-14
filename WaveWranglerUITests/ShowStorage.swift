import Foundation
import WWCore
import WWPersistence

/// Disk assertions accept current packages and deliberately older migration fixtures.
enum ShowStorage {
    static func read(_ url: URL) throws -> Data {
        try LocalFileOperations().read(url)
    }

    static func envelope(_ url: URL) throws -> [String: Any] {
        var bytes = try read(url)
        if ShowPackage.isSnapshot(bytes) {
            let document = try ShowPackageCoder().decode(bytes)
            bytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
                document.payload, revision: document.revision,
                publicationID: document.publication.publicationID
            ).data
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Only for explicit generated-fixture corruption/unknown-newer tests, not normal reads.
    static func contentURL(_ url: URL) throws -> URL {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            ? url.appending(path: ShowPackage.manifestName) : url
    }
}
