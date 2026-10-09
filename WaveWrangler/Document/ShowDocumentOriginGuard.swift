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
        guard let original = resolvedPath(at: originURL, allowMissing: false),
              let target = resolvedPath(at: destination, allowMissing: true) else {
            return true
        }
        return target.path == original.path ||
            (originatingItem != nil && FileItemIdentity.observe(at: target.url) == originatingItem)
    }

    private static func resolvedPath(at url: URL, allowMissing: Bool) -> (url: URL, path: String)? {
        var resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var visited = Set<URL>()
        for _ in 0..<8 {
            guard visited.insert(resolved).inserted else { return nil }
            let values: URLResourceValues?
            do {
                values = try resolved.resourceValues(forKeys: [.isAliasFileKey, .canonicalPathKey])
            } catch {
                let error = error as NSError
                guard allowMissing, error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError else {
                    return nil
                }
                values = nil
            }
            if values?.isAliasFile == true {
                guard let target = try? URL(resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting]) else {
                    return nil
                }
                resolved = target.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
                continue
            }
            if let values, values.isAliasFile == nil { return nil }
            let path = values?.canonicalPath ?? resolved.path(percentEncoded: false)
            guard !path.isEmpty else { return nil }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            let folded = canonical.path(percentEncoded: false).precomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            return (canonical, folded)
        }
        return nil
    }
}
