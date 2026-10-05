import Foundation
import UniformTypeIdentifiers
import WWCore

/// How an enumerated item was treated. Only `.audio` items become sources; nothing else is opened.
public enum ImportItemCategory: String, Sendable, Codable, Equatable, CaseIterable {
    case audio
    /// DAW/editor project or session files and bundles. Never opened or read.
    case projectOrSession
    /// Transcripts, notes and documents. Never opened or read.
    case transcriptOrDocument
    /// Peak files, caches, other files.
    case otherFile
    case hidden
    case directory
    case symbolicLink
}

/// Counts of what the import saw but did not import.
public struct ImportSkippedCounts: Sendable, Equatable {
    public var byCategory: [ImportItemCategory: Int] = [:]
    /// Entries the enumerator could not read (counted, never retried with elevated access).
    public var unreadableEntries = 0
    /// Same file object selected twice (e.g. a file plus its folder).
    public var duplicateSelections = 0

    public init() {}

    public var totalIgnoredFiles: Int {
        [.projectOrSession, .transcriptOrDocument, .otherFile, .hidden, .symbolicLink].reduce(0) { $0 + (byCategory[$1] ?? 0) }
    }
}

public enum ImportFailureReason: Sendable, Equatable {
    case permissionDenied
    case notFound
    case bookmarkFailed(SourceErrorDescriptor)
    case metadataUnavailable(SourceErrorDescriptor)
}

public struct ImportFailure: Sendable, Equatable {
    /// File name only, for the UI; never persisted by WWSources.
    public var displayName: String
    public var reason: ImportFailureReason
}

/// One source the user chose, ready to be added to an episode once the caller commits it.
public struct ImportedSource: Sendable, Equatable {
    public var sourceRecord: SourceRecord
    public var accessRecord: DeviceAccessRecord
    /// Path components relative to the selected folder (used only for provisional suggestions).
    public var relativePathComponents: [String]
    /// An existing access record whose identity evidence names the same file object (never merged automatically).
    public var possibleDuplicateOf: SourceID?
}

/// The result of an import. Nothing is persisted and no source is touched until the caller commits.
public struct ImportPlan: Sendable, Equatable {
    public var items: [ImportedSource]
    public var skipped: ImportSkippedCounts
    public var failures: [ImportFailure]
    public var suggestions: ProvisionalOrganization
    public var provenance: ObservationProvenance

    public var accessRecords: [DeviceAccessRecord] { items.map(\.accessRecord) }
    public var sourceRecords: [SourceRecord] { items.map(\.sourceRecord) }
}

/// Imports user-chosen files or folders (from `NSOpenPanel` in the app) as *referenced* sources.
///
/// Metadata only: items are classified by the system type database from their filename extension,
/// identity evidence comes from resource values, and each source gets a read-only security-scoped
/// bookmark. Sources are never copied, opened, read, hashed, previewed, decoded or modified. Duration,
/// channel count and sample rate stay `unknown`.
public struct SourceImporter: Sendable {
    public let context: SourceAccessContext

    public init(context: SourceAccessContext) {
        self.context = context
    }

    public func plan(
        selection: [URL],
        showID: ShowID? = nil,
        existingRecords: [DeviceAccessRecord] = []
    ) async throws -> ImportPlan {
        var items: [ImportedSource] = []
        var skipped = ImportSkippedCounts()
        var failures: [ImportFailure] = []
        var seenObjects: Set<String> = []
        let existingByObject = Dictionary(
            existingRecords.compactMap { record -> (String, SourceID)? in
                guard let key = record.recordedIdentity.flatMap({ Self.objectKey($0.fingerprint) }) else { return nil }
                return (key, record.sourceID)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for root in selection {
            try Task.checkCancellation()
            try context.withScopedAccess(to: root) { scopedRoot in
                let rootMetadata: SourceMetadata
                switch context.io.metadata(at: scopedRoot) {
                case let .success(value): rootMetadata = value
                case .failure(.permissionDenied):
                    failures.append(ImportFailure(displayName: scopedRoot.lastPathComponent, reason: .permissionDenied))
                    return
                case .failure(.notFound):
                    failures.append(ImportFailure(displayName: scopedRoot.lastPathComponent, reason: .notFound))
                    return
                case let .failure(.other(error)):
                    failures.append(ImportFailure(displayName: scopedRoot.lastPathComponent, reason: .metadataUnavailable(error)))
                    return
                }

                let candidates: [(ListedItem, [String])]
                if rootMetadata.isDirectory.value == true && rootMetadata.isPackage.value != true {
                    let listing = context.io.listItems(under: scopedRoot)
                    skipped.unreadableEntries += listing.unreadableEntryCount
                    let rootComponents = scopedRoot.standardizedFileURL.pathComponents
                    candidates = listing.items.map { item in
                        let components = item.url.standardizedFileURL.pathComponents
                        let relative = components.starts(with: rootComponents) ? Array(components.dropFirst(rootComponents.count)) : [item.url.lastPathComponent]
                        return (item, relative)
                    }
                } else {
                    let rootItem = ListedItem(
                        url: scopedRoot,
                        isDirectory: rootMetadata.isDirectory,
                        isPackage: rootMetadata.isPackage,
                        isHidden: rootMetadata.isHidden,
                        isSymbolicLink: rootMetadata.isSymbolicLink
                    )
                    candidates = [(rootItem, [scopedRoot.lastPathComponent])]
                }

                // Project bundles and hidden folders are counted once and never descended into, even when
                // the system does not declare them as packages (e.g. the DAW is not installed).
                var opaqueFolders: [String] = []
                for (item, relative) in candidates {
                    try Task.checkCancellation()
                    let url = item.url
                    let path = url.standardizedFileURL.path
                    if opaqueFolders.contains(where: { path.hasPrefix($0) }) { continue }
                    // Non-audio items are classified from the listing alone: never opened, read or
                    // even re-queried.
                    let category = Self.category(for: item)
                    guard category == .audio else {
                        skipped.byCategory[category, default: 0] += 1
                        if item.isDirectory.value == true, category == .projectOrSession || category == .hidden {
                            opaqueFolders.append(path + "/")
                        }
                        continue
                    }
                    let metadata: SourceMetadata
                    if url == scopedRoot {
                        metadata = rootMetadata
                    } else {
                        switch context.io.metadata(at: url) {
                        case let .success(value): metadata = value
                        case .failure(.permissionDenied):
                            failures.append(ImportFailure(displayName: url.lastPathComponent, reason: .permissionDenied))
                            continue
                        case .failure(.notFound):
                            continue
                        case let .failure(.other(error)):
                            failures.append(ImportFailure(displayName: url.lastPathComponent, reason: .metadataUnavailable(error)))
                            continue
                        }
                    }
                    guard metadata.isRegularFile.value == true else {
                        skipped.byCategory[.otherFile, default: 0] += 1
                        continue
                    }
                    if let key = Self.objectKey(metadata.fingerprint) {
                        guard seenObjects.insert(key).inserted else {
                            skipped.duplicateSelections += 1
                            continue
                        }
                    }
                    let bookmark: Data
                    do {
                        bookmark = try context.io.makeReadOnlyBookmark(for: url)
                    } catch {
                        failures.append(ImportFailure(displayName: url.lastPathComponent, reason: .bookmarkFailed(SourceErrorDescriptor(error))))
                        continue
                    }
                    let resolvedPath: String
                    if case let .resolved(resolved, _) = context.io.resolveBookmark(bookmark) {
                        resolvedPath = resolved.standardizedFileURL.path
                    } else {
                        resolvedPath = url.standardizedFileURL.path
                    }
                    let now = context.now()
                    let sourceID = SourceID()
                    let record = DeviceAccessRecord(
                        sourceID: sourceID,
                        showID: showID,
                        bookmark: bookmark,
                        lastKnownPath: resolvedPath,
                        lastKnownVolumeUUID: metadata.fingerprint.volumeUUID.value,
                        recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint, confirmation: .provisional, recordedAt: now),
                        createdAt: now
                    )
                    items.append(ImportedSource(
                        sourceRecord: SourceRecord(id: sourceID, displayNameHint: url.lastPathComponent),
                        accessRecord: record,
                        relativePathComponents: relative,
                        possibleDuplicateOf: Self.objectKey(metadata.fingerprint).flatMap { existingByObject[$0] }
                    ))
                }
            }
        }

        let suggestions = OrganizationSuggester.suggest(for: items.map {
            OrganizationSuggester.Input(sourceID: $0.sourceRecord.id, relativePathComponents: $0.relativePathComponents)
        })
        return ImportPlan(items: items, skipped: skipped, failures: failures, suggestions: suggestions, provenance: context.io.provenance)
    }

    /// File object key (volume + persistent file identifier), when both are known.
    static func objectKey(_ fingerprint: FileSystemFingerprint) -> String? {
        guard let volume = fingerprint.volumeUUID.value, let file = fingerprint.fileIdentifier.value else { return nil }
        return "\(volume)/\(file)"
    }

    static let projectExtensions: Set<String> = [
        "logicx", "band", "aup", "aup3", "rpp", "rpp-bak", "ptx", "ptf", "pts", "als", "alp", "sesx", "ses",
        "cpr", "npr", "nhsx", "dawproject", "flp", "song", "reason", "ardour", "omf", "aaf", "fcpbundle",
        "fcpxml", "prproj", "drp", "hindenburg", "sessiondata", "tracktionedit", "bwproject", "studioone",
    ]
    static let documentExtensions: Set<String> = [
        "txt", "md", "rtf", "rtfd", "doc", "docx", "pages", "pdf", "srt", "vtt", "sbv", "ass", "ssa",
        "json", "csv", "tsv", "xml", "html", "odt", "xlsx", "numbers",
    ]

    /// Classifies by name and listing flags only.
    public static func category(for item: ListedItem) -> ImportItemCategory {
        let name = item.url.lastPathComponent
        let ext = item.url.pathExtension.lowercased()
        if item.isSymbolicLink.value == true { return .symbolicLink }
        if name.hasPrefix(".") || item.isHidden.value == true { return .hidden }
        if projectExtensions.contains(ext) { return .projectOrSession }
        if item.isDirectory.value == true {
            return item.isPackage.value == true ? .otherFile : .directory
        }
        if documentExtensions.contains(ext) { return .transcriptOrDocument }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .otherFile }
        if type.conforms(to: .midi) { return .otherFile }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .compositeContent) {
            return .transcriptOrDocument
        }
        return .otherFile
    }
}
