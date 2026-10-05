import Foundation

/// Classifies a metadata-only reachability probe of a source location. Only "no such file" is
/// reported as Not found; permission errors are Access denied (never "Not found"); anything else stays
/// Unknown with its reason.
public enum SourceReachability {
    public static func classify(_ error: (any Error)?) -> (location: LocationStatus, access: AccessStatus) {
        guard let error else { return (.known, .granted) }
        let ns = error as NSError
        let posix = posixCode(ns)
        if (ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code))
            || posix == ENOENT || posix == ENOTDIR {
            return (.missing(sameNamedFileAtOriginalLocation: false), .unknown(reason: "the file wasn't found"))
        }
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError) || posix == EACCES || posix == EPERM {
            return (.unknown(reason: "access was denied, so WaveWrangler couldn't check"), .denied)
        }
        let reason = ns.localizedFailureReason ?? ns.localizedDescription
        return (.unknown(reason: reason), .unknown(reason: reason))
    }

    /// Metadata-only probe (no open/read/download).
    public static func probe(_ url: URL) -> (location: LocationStatus, access: AccessStatus) {
        do {
            _ = try url.checkResourceIsReachable()
            return classify(nil)
        } catch {
            return classify(error)
        }
    }

    private static func posixCode(_ error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return posixCode(underlying) }
        return nil
    }
}
