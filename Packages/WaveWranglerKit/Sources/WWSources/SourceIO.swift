import Foundation
import WWCore

/// The single gateway for every interaction with referenced originals.
///
/// It deliberately exposes **only** metadata reads, read-only bookmark create/resolve, security-scope
/// start/stop and (for source availability) a provider download request. There is no API to open,
/// read, hash, preview, decode, write, rename, move, copy, trash or delete a source, so no WWSources
/// component can do so. A source-level test forbids content-capable or mutating APIs anywhere else in
/// WWSources, and tests inject a recording gateway to count every call.
public protocol SourceIO: Sendable {
    /// `.observed` for the system gateway; `.simulated` for test doubles.
    var provenance: ObservationProvenance { get }

    /// URL resource values and `lstat` flags only. Never triggers a download or reads content.
    func metadata(at url: URL) -> MetadataResult

    /// Metadata-only recursive listing (directory entries; package contents are not descended into).
    func listItems(under directory: URL) -> DirectoryListing

    /// Creates a read-only security-scoped bookmark (`.withSecurityScope` +
    /// `.securityScopeAllowOnlyReadAccess`).
    func makeReadOnlyBookmark(for url: URL) throws -> Data

    /// Resolves a bookmark without UI and without mounting volumes.
    func resolveBookmark(_ data: Data) -> BookmarkResolution

    func startAccessingSecurityScope(_ url: URL) -> Bool
    func stopAccessingSecurityScope(_ url: URL)

    /// Asks the provider to make an item local. Content transfer: called only when source availability
    /// is ON or the user explicitly asked for this item. Never evicts or modifies the original.
    func requestDownload(of url: URL) throws

    /// Download fraction where a provider API reports it; `.unknown` otherwise.
    func downloadFraction(of url: URL) async -> Knowledge<Double>
}

/// Why metadata could not be read.
public enum MetadataFailure: Sendable, Equatable, Error {
    case notFound
    case permissionDenied
    case other(SourceErrorDescriptor)
}

public enum MetadataResult: Sendable, Equatable {
    case success(SourceMetadata)
    case failure(MetadataFailure)
}

public enum BookmarkFailure: Sendable, Equatable, Error {
    /// Resolution reports "no such file". On macOS this is also what an unreadable parent directory
    /// produces, so it is *not* evidence of a missing file on its own.
    case unresolvable
    case corrupt
    case other(SourceErrorDescriptor)
}

public enum BookmarkResolution: Sendable, Equatable {
    case resolved(URL, isStale: Bool)
    case failed(BookmarkFailure)
}

/// One directory entry with the type flags the enumerator prefetched (metadata only).
public struct ListedItem: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Knowledge<Bool>
    public var isPackage: Knowledge<Bool>
    public var isHidden: Knowledge<Bool>
    public var isSymbolicLink: Knowledge<Bool>

    public init(
        url: URL,
        isDirectory: Knowledge<Bool> = .unknown,
        isPackage: Knowledge<Bool> = .unknown,
        isHidden: Knowledge<Bool> = .unknown,
        isSymbolicLink: Knowledge<Bool> = .unknown
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct DirectoryListing: Sendable, Equatable {
    public var items: [ListedItem]
    /// Entries the enumerator reported as unreadable (permission or I/O errors), counted not hidden.
    public var unreadableEntryCount: Int

    public init(items: [ListedItem], unreadableEntryCount: Int) {
        self.items = items
        self.unreadableEntryCount = unreadableEntryCount
    }
}

/// iCloud resource values exactly as reported (absent = unknown).
public enum UbiquitousDownloadingStatus: String, Sendable, Codable, Equatable {
    case notDownloaded
    case downloaded
    case current
}

public struct UbiquitousObservation: Sendable, Equatable {
    public var isUbiquitousItem: Knowledge<Bool>
    public var downloadingStatus: Knowledge<UbiquitousDownloadingStatus>
    public var isDownloading: Knowledge<Bool>
    public var downloadRequested: Knowledge<Bool>
    public var downloadingError: SourceErrorDescriptor?

    public init(
        isUbiquitousItem: Knowledge<Bool> = .unknown,
        downloadingStatus: Knowledge<UbiquitousDownloadingStatus> = .unknown,
        isDownloading: Knowledge<Bool> = .unknown,
        downloadRequested: Knowledge<Bool> = .unknown,
        downloadingError: SourceErrorDescriptor? = nil
    ) {
        self.isUbiquitousItem = isUbiquitousItem
        self.downloadingStatus = downloadingStatus
        self.isDownloading = isDownloading
        self.downloadRequested = downloadRequested
        self.downloadingError = downloadingError
    }
}

/// Metadata snapshot of one item. Duration/channels/sample rate are intentionally absent.
public struct SourceMetadata: Sendable, Equatable {
    public var url: URL
    public var isRegularFile: Knowledge<Bool>
    public var isDirectory: Knowledge<Bool>
    public var isPackage: Knowledge<Bool>
    public var isHidden: Knowledge<Bool>
    public var isSymbolicLink: Knowledge<Bool>
    public var isReadable: Knowledge<Bool>
    public var volumeIsLocal: Knowledge<Bool>
    /// `SF_DATALESS` from `lstat` flags: the file system reports the content is not materialized.
    public var isDataless: Knowledge<Bool>
    public var fingerprint: FileSystemFingerprint
    public var ubiquitous: UbiquitousObservation

    public init(
        url: URL,
        isRegularFile: Knowledge<Bool> = .unknown,
        isDirectory: Knowledge<Bool> = .unknown,
        isPackage: Knowledge<Bool> = .unknown,
        isHidden: Knowledge<Bool> = .unknown,
        isSymbolicLink: Knowledge<Bool> = .unknown,
        isReadable: Knowledge<Bool> = .unknown,
        volumeIsLocal: Knowledge<Bool> = .unknown,
        isDataless: Knowledge<Bool> = .unknown,
        fingerprint: FileSystemFingerprint = FileSystemFingerprint(),
        ubiquitous: UbiquitousObservation = UbiquitousObservation()
    ) {
        self.url = url
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
        self.volumeIsLocal = volumeIsLocal
        self.isDataless = isDataless
        self.fingerprint = fingerprint
        self.ubiquitous = ubiquitous
    }

    /// Residency strictly from reported values. No provider is inferred from a path.
    public var residency: (ResidencyState, ObservationEvidence) {
        if ubiquitous.isUbiquitousItem.value == true {
            if ubiquitous.isDownloading.value == true { return (.downloading, .ubiquitousResourceValues) }
            switch ubiquitous.downloadingStatus.value {
            case .notDownloaded: return (.cloudPlaceholder, .ubiquitousResourceValues)
            case .downloaded, .current: return (.local, .ubiquitousResourceValues)
            case nil: return (.unknown, .ubiquitousResourceValues)
            }
        }
        switch isDataless.value {
        case true?:
            return (.cloudPlaceholder, .fileSystemDatalessFlag)
        case false? where volumeIsLocal.value == true && ubiquitous.isUbiquitousItem.value != true:
            return (.local, .fileSystemDatalessFlag)
        default:
            return (.unknown, .notObserved)
        }
    }

    /// Only iCloud items have an evidenced download request API in M1.
    public var supportsDownloadRequest: Bool { ubiquitous.isUbiquitousItem.value == true }
}
