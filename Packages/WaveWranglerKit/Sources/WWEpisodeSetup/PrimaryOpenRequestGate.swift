import Foundation
import WWCore

/// A setup-side request, never an authorization to open a source. Only a future decoder-owned,
/// consent-scoped descriptor capture may turn this into a content operation.
public struct PrimaryOpenState: Sendable {
    public let model: ShowDocumentModel
    public let episodeID: EpisodeID
    public let documentGeneration: UUID
    public let selectionGeneration: UUID
    public let relinkGeneration: UUID
    /// Must come from a durable, freshly corroborated device-local record, not a path or bookmark.
    public let accessRecordGeneration: UUID?
    public let outstandingRelink: Bool
    public let selectedSpeakerID: SpeakerID?
    public let selectedChannel: ChannelReference?

    public init(model: ShowDocumentModel, episodeID: EpisodeID, documentGeneration: UUID,
                selectionGeneration: UUID, relinkGeneration: UUID, accessRecordGeneration: UUID?,
                outstandingRelink: Bool, selectedSpeakerID: SpeakerID?, selectedChannel: ChannelReference?) {
        self.model = model
        self.episodeID = episodeID
        self.documentGeneration = documentGeneration
        self.selectionGeneration = selectionGeneration
        self.relinkGeneration = relinkGeneration
        self.accessRecordGeneration = accessRecordGeneration
        self.outstandingRelink = outstandingRelink
        self.selectedSpeakerID = selectedSpeakerID
        self.selectedChannel = selectedChannel
    }
}

public enum PrimaryOpenRefusal: Error, Equatable {
    case unconfirmed
    case invalidPrimary
    case staleRequest
    case outstandingRelink
    case accessRecordUnversioned
    case guardedCaptureUnavailable
}

public struct PrimaryOpenRequestID: Hashable, Sendable {
    fileprivate let value: UUID
}

/// A per-window, one-request-at-a-time confirmation guard. The caller must recheck after every await;
/// this gate does not inspect files, consult a cached path, or provide a positive content-open API.
public final class PrimaryOpenRequestGate {
    private struct Request {
        var showID: ShowID
        var episodeID: EpisodeID
        var speakerID: SpeakerID
        var channel: ChannelReference
        var documentGeneration: UUID
        var selectionGeneration: UUID
        var relinkGeneration: UUID
        var accessRecordGeneration: UUID
        var alignment: EpisodeAlignment?
        var confirmed = false
    }

    private var requests: [PrimaryOpenRequestID: Request] = [:]

    public init() {}

    public func begin(speakerID: SpeakerID, channel: ChannelReference, state: PrimaryOpenState) throws -> PrimaryOpenRequestID {
        guard !state.outstandingRelink else { throw PrimaryOpenRefusal.outstandingRelink }
        guard let generation = state.accessRecordGeneration else { throw PrimaryOpenRefusal.accessRecordUnversioned }
        try Self.validatePrimary(speakerID: speakerID, channel: channel, state: state)
        let id = PrimaryOpenRequestID(value: UUID())
        requests.removeAll()
        requests[id] = Request(showID: state.model.show.id, episodeID: state.episodeID,
                               speakerID: speakerID, channel: channel,
                               documentGeneration: state.documentGeneration,
                               selectionGeneration: state.selectionGeneration,
                               relinkGeneration: state.relinkGeneration,
                               accessRecordGeneration: generation,
                               alignment: state.model.episode(state.episodeID)?.alignment)
        return id
    }

    /// Must be called only by a distinct, explicit person action that confirms this exact request.
    public func confirm(_ id: PrimaryOpenRequestID, state: PrimaryOpenState) throws {
        var request = try current(id, state: state)
        request.confirmed = true
        requests[id] = request
    }

    /// No positive return exists until the versioned-record and guarded WWDecode capture seam lands.
    public func check(_ id: PrimaryOpenRequestID, state: PrimaryOpenState) throws {
        guard try current(id, state: state).confirmed else { throw PrimaryOpenRefusal.unconfirmed }
        throw PrimaryOpenRefusal.guardedCaptureUnavailable
    }

    public func cancel(_ id: PrimaryOpenRequestID) {
        requests.removeValue(forKey: id)
    }

    public func cancelAll() {
        requests.removeAll()
    }

    private func current(_ id: PrimaryOpenRequestID, state: PrimaryOpenState) throws -> Request {
        guard let request = requests[id] else { throw PrimaryOpenRefusal.staleRequest }
        guard !state.outstandingRelink else { throw PrimaryOpenRefusal.outstandingRelink }
        guard let generation = state.accessRecordGeneration else { throw PrimaryOpenRefusal.accessRecordUnversioned }
        guard request.showID == state.model.show.id,
              request.episodeID == state.episodeID,
              request.documentGeneration == state.documentGeneration,
              request.selectionGeneration == state.selectionGeneration,
              request.relinkGeneration == state.relinkGeneration,
              request.accessRecordGeneration == generation,
              request.alignment == state.model.episode(state.episodeID)?.alignment
        else { throw PrimaryOpenRefusal.staleRequest }
        try Self.validatePrimary(speakerID: request.speakerID, channel: request.channel, state: state)
        return request
    }

    private static func validatePrimary(speakerID: SpeakerID, channel: ChannelReference, state: PrimaryOpenState) throws {
        guard state.selectedSpeakerID == speakerID, state.selectedChannel == channel,
              let episode = state.model.episode(state.episodeID),
              state.model.speaker(speakerID) != nil,
              let source = episode.source(channel.sourceID),
              source.role == .primary, source.roleConfirmation == .userConfirmed,
              let index = channel.channel.value, index >= 0,
              let assignment = episode.assignment(for: speakerID),
              assignment.primary == channel,
              assignment.primaryConfirmation == .userConfirmed,
              !assignment.backups.contains(channel)
        else { throw PrimaryOpenRefusal.invalidPrimary }
    }
}
