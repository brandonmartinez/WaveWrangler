import Foundation
import OSLog
import WWCore

struct EpisodeWorkspaceViewState: Codable, Equatable {
    var layout = AlignmentWaveformLayout.defaultValue
    var normalizeView = false
    var showProposedAlignment = true
    var laneHeight = 110.0
    var fillSpace = false
    var followPlayhead = true
    var startSeconds = 0.0
    var durationSeconds = 5.0
    var playheadSeconds = 0.0
    var trackScrollOffset = 0.0
    var collapsedRecorders: Set<RecorderGroupID> = []
    var collapsedSpeakers: Set<SpeakerID> = []
    var destination = "alignment"
    var inspector = "Recording"
    var inspectorPresented = true
    var recordingsPresented = false
    var reviewPanelPresented = false
    var reviewPanelHeight = 240.0
    var expandedManualCutID: UUID?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case layout, normalizeView, showProposedAlignment, laneHeight, fillSpace, followPlayhead
        case startSeconds, durationSeconds, playheadSeconds, trackScrollOffset
        case collapsedRecorders, collapsedSpeakers, destination, inspector, inspectorPresented
        case recordingsPresented, expandedManualCutID, reviewPanelPresented, reviewPanelHeight
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decode(AlignmentWaveformLayout.self, forKey: .layout)
        normalizeView = try values.decode(Bool.self, forKey: .normalizeView)
        showProposedAlignment = try values.decode(Bool.self, forKey: .showProposedAlignment)
        laneHeight = try values.decode(Double.self, forKey: .laneHeight)
        fillSpace = try values.decodeIfPresent(Bool.self, forKey: .fillSpace) ?? false
        followPlayhead = try values.decodeIfPresent(Bool.self, forKey: .followPlayhead) ?? true
        startSeconds = try values.decode(Double.self, forKey: .startSeconds)
        durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        playheadSeconds = try values.decode(Double.self, forKey: .playheadSeconds)
        trackScrollOffset = try values.decode(Double.self, forKey: .trackScrollOffset)
        collapsedRecorders = try values.decode(Set<RecorderGroupID>.self, forKey: .collapsedRecorders)
        collapsedSpeakers = try values.decode(Set<SpeakerID>.self, forKey: .collapsedSpeakers)
        destination = try values.decode(String.self, forKey: .destination)
        inspector = try values.decode(String.self, forKey: .inspector)
        inspectorPresented = try values.decode(Bool.self, forKey: .inspectorPresented)
        recordingsPresented = try values.decode(Bool.self, forKey: .recordingsPresented)
        reviewPanelPresented = try values.decodeIfPresent(Bool.self, forKey: .reviewPanelPresented)
            ?? (inspector == "Transcript & review")
        reviewPanelHeight = try values.decodeIfPresent(Double.self, forKey: .reviewPanelHeight) ?? 240
        expandedManualCutID = try values.decodeIfPresent(UUID.self, forKey: .expandedManualCutID)
    }

    var isValid: Bool {
        startSeconds.isFinite && abs(startSeconds) <= 86_400
            && playheadSeconds.isFinite && abs(playheadSeconds) <= 86_400
            && durationSeconds.isFinite && (0.5...172_800).contains(durationSeconds)
            && laneHeight.isFinite && (64...220).contains(laneHeight)
            && trackScrollOffset.isFinite && trackScrollOffset >= 0
            && reviewPanelHeight.isFinite && (140...1200).contains(reviewPanelHeight)
    }
}

@MainActor
struct EpisodeWorkspaceViewStore {
    private static let logger = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "WorkspaceView")
    private struct Key: Hashable {
        let namespace: String
        let name: String
    }
    private struct Pending {
        let store: EpisodeWorkspaceViewStore
        var value: EpisodeWorkspaceViewState
        let task: Task<Void, Never>
    }
    private static var pending: [Key: Pending] = [:]
    let defaults: UserDefaults
    let show: ShowID
    let episode: EpisodeID
    let namespace: String
    init(defaults: UserDefaults, show: ShowID, episode: EpisodeID, namespace: String = "standard") {
        self.defaults = defaults
        self.show = show
        self.episode = episode
        self.namespace = namespace
    }
    private var key: String { "WWEpisodeWorkspaceView.v1.\(show).\(episode)" }
    private var pendingKey: Key { Key(namespace: namespace, name: key) }

    func load() -> EpisodeWorkspaceViewState? {
        if let pending = Self.pending[pendingKey] { return pending.value }
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let value = try JSONDecoder().decode(EpisodeWorkspaceViewState.self, from: data)
            guard value.isValid else {
                Self.logger.error("Saved episode view contains invalid navigation values; using the default view.")
                return nil
            }
            return value
        } catch {
            Self.logger.error("Could not restore the saved episode view: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ value: EpisodeWorkspaceViewState) {
        guard value.isValid else {
            Self.logger.error("Invalid episode view was not saved.")
            return
        }
        let id = pendingKey
        if Self.pending[id] != nil {
            Self.pending[id]?.value = value
        } else {
            let task = Task {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                Self.flush(id)
            }
            Self.pending[id] = Pending(store: self, value: value, task: task)
        }
    }

    static func flushPending() {
        for key in Array(pending.keys) { flush(key) }
    }

    private static func flush(_ id: Key) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.task.cancel()
        entry.store.write(entry.value)
    }

    private func write(_ value: EpisodeWorkspaceViewState) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Self.logger.error("Could not save the episode view: \(String(describing: error), privacy: .public)")
        }
    }
}
