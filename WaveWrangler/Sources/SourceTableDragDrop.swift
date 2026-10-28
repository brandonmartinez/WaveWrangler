import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import WWCore
import WWEpisodeSetup

struct SetupSourceDrag: Codable, Sendable, Transferable {
    static let contentType = UTType(exportedAs: "com.brandonmartinez.wavewrangler.source-drag", conformingTo: .data)
    let version: Int
    let showID: ShowID
    let episodeID: EpisodeID
    let sourceID: SourceID

    init(showID: ShowID, episodeID: EpisodeID, sourceID: SourceID) {
        version = 1
        self.showID = showID
        self.episodeID = episodeID
        self.sourceID = sourceID
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<Self>(contentType: contentType, exporting: { try JSONEncoder().encode($0) }, importing: {
            guard $0.count <= 4096 else { throw SetupSourceDropFailure.invalidSelection }
            return try JSONDecoder().decode(Self.self, from: $0)
        })
        .visibility(.ownProcess)
    }
}

/// Requests the file location, never a file representation that might copy or download its contents.
struct SetupFileDrop: Sendable, Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<Self>(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw SetupSourceDropFailure.invalidLocation
            }
            return Self(url: url)
        }
    }
}

enum SetupSourceDrop: Sendable, Transferable {
    case recording(SetupSourceDrag)
    case file(SetupFileDrop)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (value: SetupSourceDrag) in Self.recording(value) })
        ProxyRepresentation(importing: { (value: SetupFileDrop) in Self.file(value) })
    }
}

private enum SetupSourceDropFailure: LocalizedError {
    case invalidLocation, invalidSelection

    var errorDescription: String? {
        switch self {
        case .invalidLocation: "The dropped file or folder location could not be read."
        case .invalidSelection: "The dragged recording selection could not be read."
        }
    }
}

extension EpisodeSetupModel {
    var sourceActionUnavailableReason: String? {
        if episode == nil { return "This episode is no longer available." }
        if !store.canEdit { return "This show is read-only. Open an editable copy before changing recordings." }
        if isScanning || sheet != nil || confirmation != nil || isAuthorizingOriginals {
            return "Finish the current source action before importing or moving recordings."
        }
        return nil
    }

    var canImportSources: Bool {
        sourceActionUnavailableReason == nil
    }

    @discardableResult
    func importDroppedURLs(_ urls: [URL]) -> Bool {
        guard canImportSources else {
            message = sourceActionUnavailableReason
            return false
        }
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            message = "Drop recording files or folders from Finder to import them."
            return false
        }
        scan(urls)
        return true
    }

    @discardableResult
    func acceptSourceRowDrop(_ items: [SetupSourceDrop], on target: SetupRowID) -> Bool {
        guard !items.isEmpty else {
            message = "The drop did not contain any recordings."
            return false
        }
        let files = items.compactMap { item -> URL? in
            if case let .file(file) = item { return file.url }
            return nil
        }
        if files.count == items.count { return importDroppedURLs(files) }
        guard files.isEmpty else {
            message = "Drop either new files or existing recording rows, not both at once."
            return false
        }
        guard canImportSources, let episode else {
            message = sourceActionUnavailableReason
            return false
        }
        let recordings = items.compactMap { item -> SetupSourceDrag? in
            if case let .recording(recording) = item { return recording }
            return nil
        }
        guard recordings.allSatisfy({
            $0.version == 1 && $0.showID == store.model.show.id && $0.episodeID == episodeID
        }) else {
            message = "Only recordings from this episode can be moved between its recorder groups."
            return false
        }
        let group: RecorderGroupID?
        switch target {
        case let .group(id):
            guard id == nil || episode.recorderGroups.contains(where: { $0.id == id }) else {
                message = "That recorder group is no longer available."
                return false
            }
            group = id
        case let .source(id), let .channel(id, _):
            guard let source = episode.source(id) else {
                message = "That target recording is no longer available."
                return false
            }
            group = source.placement.recorderGroupID
        }
        let requested = Set(recordings.map(\.sourceID))
        let sources = episode.sources.filter { requested.contains($0.id) }
        guard sources.count == requested.count else {
            message = "One of the dragged recordings is no longer in this episode."
            return false
        }
        let moving = sources.filter { $0.placement.recorderGroupID != group }.map(\.id)
        guard !moving.isEmpty else {
            message = "The dragged recordings are already in this recorder group."
            return false
        }
        guard assign(moving, toGroup: group) else {
            if message == nil { message = "The recorder group could not be changed. Check whether the show is read-only." }
            return false
        }
        collapsedRows.remove(.group(group))
        selection = Set(sources.map { .source($0.id) })
        inspectorFollowsSpeakers = false
        announce("Assigned \(moving.count) recording\(moving.count == 1 ? "" : "s") to \(groupName(group)).")
        return true
    }
}
