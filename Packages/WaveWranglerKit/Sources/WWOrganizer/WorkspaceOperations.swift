import Foundation
import WWCore

/// Episode/show metadata edits for the workspace. Pure and validated like WWCore's `ShowOperations`;
/// proposed to move into WWCore once the foundation settles.
extension ShowDocumentModel {
    public func settingEpisodeNumber(_ id: EpisodeID, to number: Int?) throws(DomainError) -> ShowDocumentModel {
        try updatingEpisodeMetadata(id) { $0.number = number }
    }

    public func settingEpisodeRecordedOn(_ id: EpisodeID, to day: CalendarDay?) throws(DomainError) -> ShowDocumentModel {
        try updatingEpisodeMetadata(id) { $0.recordedOn = day }
    }

    public func settingEpisodeNotes(_ id: EpisodeID, to notes: String) throws(DomainError) -> ShowDocumentModel {
        try updatingEpisodeMetadata(id) { $0.notes = notes }
    }

    public func settingShowNotes(_ notes: String) -> ShowDocumentModel {
        var copy = self
        copy.show.notes = notes
        return copy
    }

    public func canMoveEpisode(_ id: EpisodeID, by offset: Int) -> Bool {
        guard offset != 0, let index = episodes.firstIndex(where: { $0.id == id }) else { return false }
        return episodes.indices.contains(index + offset)
    }

    /// Move Episode Up (−1) / Down (+1). At the list edge the value is returned unchanged.
    public func movingEpisode(_ id: EpisodeID, by offset: Int) throws(DomainError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        let target = index + offset
        guard episodes.indices.contains(target), target != index else { return self }
        var copy = self
        let moved = copy.episodes.remove(at: index)
        copy.episodes.insert(moved, at: target)
        return copy
    }

    public func movingEpisodes(fromOffsets source: IndexSet, toOffset destination: Int) -> ShowDocumentModel {
        var copy = self
        copy.episodes = LibraryModel.moving(episodes, fromOffsets: source, toOffset: destination)
        return copy
    }

    /// The next default episode: "Episode <n+1>" numbered after the highest existing number.
    public func nextNewEpisode(id: EpisodeID = EpisodeID()) -> Episode {
        let number = (episodes.compactMap(\.number).max() ?? episodes.count) + 1
        return Episode(id: id, title: "Episode \(number)", number: number)
    }

    private func updatingEpisodeMetadata(_ id: EpisodeID, _ transform: (inout Episode) -> Void) throws(DomainError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { throw .episodeNotFound(id) }
        var copy = self
        transform(&copy.episodes[index])
        return copy
    }
}

/// Validation for numeric metadata fields (T03: invalid input shows "Enter a whole number").
public enum EpisodeNumberInput {
    public static let invalidMessage = "Enter a whole number"
    public static let range = 0...999_999

    /// Empty text clears the number; otherwise a whole number in `range`.
    public static func parse(_ text: String) -> Result<Int?, EpisodeNumberInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let value = Int(trimmed), range.contains(value) else {
            return .failure(.notAWholeNumber)
        }
        return .success(value)
    }
}

public enum EpisodeNumberInputError: Error, Sendable, Equatable {
    case notAWholeNumber

    public var message: String { EpisodeNumberInput.invalidMessage }
}

/// Named undo actions (commands-keyboard §3).
public enum UndoActionName {
    public static let newEpisode = "New Episode"
    public static let renameEpisode = "Rename Episode"
    public static let deleteEpisode = "Delete Episode"
    public static let moveEpisode = "Move Episode"
    public static let editTitle = "Edit Title"
    public static let editNumber = "Edit Number"
    public static let editRecordingDate = "Edit Recording Date"
    public static let editNotes = "Edit Notes"
    public static let editShowInfo = "Edit Show Info"
    public static let placeAnchor = "Place Anchor"
    public static let editAnchorTime = "Edit Anchor Time"
    public static let deleteAnchor = "Delete Anchor"
    public static let editEpochTiming = "Edit Epoch Timing"
    public static let acceptProposal = "Accept Proposal"
    public static let rejectProposal = "Reject Proposal"
    public static let startNewEpochAtAnchor = "Start New Epoch at Anchor"
    public static let newCollection = "New Collection"
    public static let renameCollection = "Rename Collection"
    public static let deleteCollection = "Delete Collection"
    public static let addToCollection = "Add to Collection"
    public static let removeFromCollection = "Remove from Collection"
    public static let moveCollection = "Move Collection"
    public static let removeFromLibrary = "Remove from Library"
}

/// Show-window sidebar presentation (IA §4.1).
public enum ShowSidebarPresentation {
    public static func episodeRowTitle(_ episode: Episode) -> String {
        episode.number.map { "\($0) \(episode.title)" } ?? episode.title
    }

    public static func episodesValue(_ count: Int) -> String {
        count == 1 ? "1 episode" : "\(count) episodes"
    }

    public static func episodeIdentifier(_ id: EpisodeID) -> String { "ww.show.sidebar.episode.\(id)" }

    /// Window subtitle = the selected episode's title (IA-06).
    public static func windowSubtitle(model: ShowDocumentModel, selectedEpisode: EpisodeID?) -> String {
        selectedEpisode.flatMap { model.episode($0)?.title } ?? ""
    }
}

/// Confirmation wording for removals (commands-keyboard §6, states §5).
public enum ConfirmationWording {
    public static func deleteEpisode(_ title: String) -> (message: String, informative: String, button: String) {
        ("Delete “\(title)”?", "Its setup is removed from this show. Source files aren't deleted.", "Delete")
    }

    public static func deleteCollection(_ name: String) -> (message: String, informative: String, button: String) {
        ("Delete the collection “\(name)”?", "The shows and episodes in it aren't deleted.", "Delete")
    }

    public static func removeFromLibrary(_ names: [String]) -> (message: String, informative: String, button: String) {
        let subject = names.count == 1 ? "“\(names[0])”" : "\(names.count) shows"
        let informative = names.count == 1
            ? "The show file isn't deleted, and you can add it again with File › Open."
            : "The show files aren't deleted, and you can add them again with File › Open."
        return ("Remove \(subject) from the library?", informative, "Remove")
    }
}
