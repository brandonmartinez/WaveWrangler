import Foundation
import WWPersistence

enum ShowDocumentOriginGuard {
    static func readPinned(at url: URL, afterRead: () throws -> Void = {}) throws -> (data: Data, item: FileItemIdentity?) {
        let item = FileItemIdentity.observe(at: url.resolvingSymlinksInPath())
        let data = try Data(contentsOf: url)
        try afterRead()
        guard item == FileItemIdentity.observe(at: url.resolvingSymlinksInPath()) else {
            throw PublicationError.originConflict("The originating file changed while it was being opened. Reopen the show before updating it.")
        }
        return (data, item)
    }

    static func isOriginatingDestination(_ destination: URL, originURL: URL?, originatingItem: FileItemIdentity?) -> Bool {
        guard let originURL else { return false }
        let originalPath = originURL.resolvingSymlinksInPath().standardizedFileURL
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL
        if destinationPath == originalPath || FileItemIdentity.observe(at: destinationPath) == originatingItem && originatingItem != nil {
            return true
        }
        if (try? destination.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
            guard let target = try? URL(resolvingAliasFileAt: destination, options: [.withoutUI, .withoutMounting]) else {
                return true
            }
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL
            return resolved == originalPath || FileItemIdentity.observe(at: resolved) == originatingItem && originatingItem != nil
        }
        return false
    }
}
