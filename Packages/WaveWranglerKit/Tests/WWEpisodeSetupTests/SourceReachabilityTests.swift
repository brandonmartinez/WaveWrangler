import Foundation
import Testing
@testable import WWEpisodeSetup

@Suite("Reachability classification (denied is never Not found)")
struct SourceReachabilityTests {
    @Test func classifiesErrorCodes() {
        #expect(SourceReachability.classify(nil) == (.known, .granted))
        #expect(SourceReachability.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)).location == .missing(sameNamedFileAtOriginalLocation: false))
        #expect(SourceReachability.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))).location == .missing(sameNamedFileAtOriginalLocation: false))
        #expect(SourceReachability.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)).access == .denied)
        #expect(SourceReachability.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))).access == .denied)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(SourceReachability.classify(wrapped).access == .denied)
        let other = SourceReachability.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        if case .unknown = other.location {} else { Issue.record("other errors must be Unknown, got \(other.location)") }
        if case .missing = other.location { Issue.record("never Not found") }
    }

    /// chmod 000 on the parent folder of a synthetic temp file: reachability fails with EACCES and must
    /// read Access denied, not Not found.
    @Test func permissionDeniedTempFileIsDeniedNotMissing() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "ww-reach-\(UUID().uuidString)")
        let locked = folder.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appending(path: "synthetic.wav")
        try Data([0]).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: folder)
        }
        let result = SourceReachability.probe(file)
        #expect(result.access == .denied, "\(result)")
        if case .missing = result.location { Issue.record("denied shown as Not found") }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        #expect(SourceReachability.probe(file) == (.known, .granted))
        #expect(SourceReachability.probe(locked.appending(path: "absent.wav")).location == .missing(sameNamedFileAtOriginalLocation: false))
    }
}
