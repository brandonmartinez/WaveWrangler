import Darwin
import Foundation
import UniformTypeIdentifiers
import WWCore

/// The production `SourceIO`. This is the only file in WWSources allowed to touch source URLs through
/// platform APIs, and it only uses metadata, bookmark, scope and download-request APIs.
public struct SystemSourceIO: SourceIO {
    public var provenance: ObservationProvenance { .observed }

    /// How long `downloadFraction` waits for an `NSMetadataQuery` to report before answering `.unknown`.
    public var progressQueryTimeout: Duration

    public init(progressQueryTimeout: Duration = .seconds(2)) {
        self.progressQueryTimeout = progressQueryTimeout
    }

    static let metadataKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isReadableKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey, .fileIdentifierKey,
        .volumeUUIDStringKey, .volumeIsLocalKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadRequestedKey, .ubiquitousItemDownloadingErrorKey,
    ]

    public func metadata(at url: URL) -> MetadataResult {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try fresh.resourceValues(forKeys: Self.metadataKeys)
        } catch {
            return .failure(Self.metadataFailure(error))
        }
        var status: Knowledge<UbiquitousDownloadingStatus> = .unknown
        switch values.ubiquitousItemDownloadingStatus {
        case .notDownloaded?: status = .known(.notDownloaded)
        case .downloaded?: status = .known(.downloaded)
        case .current?: status = .known(.current)
        default: break
        }
        return .success(SourceMetadata(
            url: url,
            isRegularFile: Knowledge(values.isRegularFile),
            isDirectory: Knowledge(values.isDirectory),
            isPackage: Knowledge(values.isPackage),
            isHidden: Knowledge(values.isHidden),
            isSymbolicLink: Knowledge(values.isSymbolicLink),
            isReadable: Knowledge(values.isReadable),
            volumeIsLocal: Knowledge(values.volumeIsLocal),
            isDataless: Self.datalessFlag(url),
            fingerprint: FileSystemFingerprint(
                fileSize: Knowledge(values.fileSize.map(Int64.init)),
                creationDate: Knowledge(values.creationDate),
                contentModificationDate: Knowledge(values.contentModificationDate),
                fileIdentifier: Knowledge(values.fileIdentifier),
                volumeUUID: Knowledge(values.volumeUUIDString),
                contentType: Self.contentTypeFromExtension(url)
            ),
            ubiquitous: UbiquitousObservation(
                isUbiquitousItem: Knowledge(values.isUbiquitousItem),
                downloadingStatus: status,
                isDownloading: Knowledge(values.ubiquitousItemIsDownloading),
                downloadRequested: Knowledge(values.ubiquitousItemDownloadRequested),
                downloadingError: values.ubiquitousItemDownloadingError.map(SourceErrorDescriptor.init)
            )
        ))
    }

    /// WWSources cannot open the source: O_EVTONLY was proven content-readable on macOS.
    /// Until a content-gateway confirmation seam exists, no URL-only observation mints a witness.
    package func rawIdentity(at url: URL) -> RawSourceIdentity? {
        nil
    }

    /// Called only with a source descriptor already held open by the content gateway.
    /// Opens metadata for its mount, not source bytes.
    package static func rawIdentity(onDescriptor fd: Int32) -> RawSourceIdentity? {
        guard let mountPoint = RawSourceIdentity.mountPoint(onDescriptor: fd) else { return nil }
        let rootFD = Darwin.open(mountPoint, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard rootFD >= 0 else { return nil }
        defer { _ = Darwin.close(rootFD) }
        return RawSourceIdentity.onDescriptor(fd, volumeRootDescriptor: rootFD)
    }

    public func listItems(under directory: URL) -> DirectoryListing {
        final class ErrorCounter: @unchecked Sendable { var count = 0 }
        let counter = ErrorCounter()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                counter.count += 1
                return true
            }
        ) else {
            return DirectoryListing(items: [], unreadableEntryCount: 1)
        }
        var items: [ListedItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            items.append(ListedItem(
                url: url,
                isDirectory: Knowledge(values?.isDirectory),
                isPackage: Knowledge(values?.isPackage),
                isHidden: Knowledge(values?.isHidden),
                isSymbolicLink: Knowledge(values?.isSymbolicLink)
            ))
        }
        return DirectoryListing(items: items, unreadableEntryCount: counter.count)
    }

    public func makeReadOnlyBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmark(_ data: Data) -> BookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return .resolved(url, isStale: isStale)
        } catch {
            let nsError = error as NSError
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
                return .failed(.unresolvable)
            case (NSCocoaErrorDomain, NSFileReadCorruptFileError):
                return .failed(.corrupt)
            default:
                return .failed(.other(SourceErrorDescriptor(error)))
            }
        }
    }

    public func startAccessingSecurityScope(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessingSecurityScope(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    public func requestDownload(of url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public func downloadFraction(of url: URL) async -> Knowledge<Double> {
        await UbiquitousPercentQuery(url: url, timeout: progressQueryTimeout).run()
    }

    // MARK: - Helpers

    static func metadataFailure(_ error: any Error) -> MetadataFailure {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [underlying, nsError].compactMap({ $0 }) where candidate.domain == NSPOSIXErrorDomain {
            switch Int32(candidate.code) {
            case ENOENT, ENOTDIR: return .notFound
            case EACCES, EPERM: return .permissionDenied
            default: break
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            case NSFileReadNoPermissionError: return .permissionDenied
            default: break
            }
        }
        return .other(SourceErrorDescriptor(error))
    }

    static func datalessFlag(_ url: URL) -> Knowledge<Bool> {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .unknown }
        return .known(info.st_flags & UInt32(SF_DATALESS) != 0)
    }

    /// Type from the filename extension via the system type database (no content sniffing).
    public static func contentTypeFromExtension(_ url: URL) -> Knowledge<String> {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return .unknown }
        return .known(type.identifier)
    }
}

extension Knowledge {
    /// `nil` (not reported) becomes `.unknown`.
    public init(_ optional: Value?) {
        if let optional { self = .known(optional) } else { self = .unknown }
    }
}

/// One-shot `NSMetadataQuery` for `NSMetadataUbiquitousItemPercentDownloadedKey`. Returns `.unknown`
/// when the query is not permitted, finds nothing or times out; never a guessed value. All query state is
/// touched only on the box's serial operation queue.
final class UbiquitousPercentQuery: @unchecked Sendable {
    private let url: URL
    private let timeout: Duration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Knowledge<Double>, Never>?
    private var query: NSMetadataQuery?
    private var observer: (any NSObjectProtocol)?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(url: URL, timeout: Duration) {
        self.url = url
        self.timeout = timeout
    }

    func run() async -> Knowledge<Double> {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            queue.addOperation { self.start() }
            let timeout = timeout
            Task.detached { [self] in
                try? await Task.sleep(for: timeout)
                self.finish(.unknown)
            }
        }
    }

    private func start() {
        let query = NSMetadataQuery()
        query.operationQueue = queue
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryUbiquitousDataScope,
            NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope,
        ]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, url as NSURL)
        self.query = query
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue
        ) { [self] _ in
            self.gathered()
        }
        if !query.start() { finish(.unknown) }
    }

    private func gathered() {
        var result: Knowledge<Double> = .unknown
        if let query, query.resultCount > 0, let item = query.result(at: 0) as? NSMetadataItem,
           let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber {
            result = .known(min(max(percent.doubleValue / 100, 0), 1))
        }
        finish(result)
    }

    private func finish(_ value: Knowledge<Double>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        queue.addOperation { self.tearDown() }
        continuation.resume(returning: value)
    }

    private func tearDown() {
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        query = nil
        observer = nil
    }
}
