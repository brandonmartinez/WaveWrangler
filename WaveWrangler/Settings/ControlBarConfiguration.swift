import Foundation
import WWCommonEdit

struct ControlBarConfiguration: Codable, Equatable {
    enum Group: String, Codable, CaseIterable {
        case episode, tools, view
        var title: String {
            switch self {
            case .episode: "Episode"
            case .tools: "Timeline tools"
            case .view: "View"
            }
        }
        var width: Double {
            switch self {
            case .episode: 115
            case .tools: 120
            case .view: 165
            }
        }
    }

    enum Readout: String, Codable, CaseIterable {
        case none, duration, remaining, selection
        var title: String { rawValue.capitalized }
    }

    enum Preset: String, CaseIterable {
        case editing = "Editing", review = "Review", mixing = "Mixing"
    }

    var version = 1
    var groups = Group.allCases
    var visible = Set(Group.allCases)
    var showsLabels = true
    var primaryClock = EpisodeClock.episode
    var secondaryClock: EpisodeClock?
    var readout = Readout.none

    var isValid: Bool {
        version == 1 && groups.count == Group.allCases.count && Set(groups) == Set(Group.allCases)
            && visible.isSubset(of: Set(Group.allCases))
    }

    static func preset(_ preset: Preset) -> Self {
        var result = Self()
        switch preset {
        case .editing: break
        case .review:
            result.visible = [.episode, .view]
            result.secondaryClock = .speaker
            result.readout = .selection
        case .mixing:
            result.groups = [.view, .episode, .tools]
            result.visible = [.view, .episode]
            result.readout = .remaining
        }
        return result
    }

    func displayedGroups(width: Double) -> [Group] {
        var remaining = max(0, width - 750)
        return groups.filter { group in
            guard visible.contains(group), remaining >= group.width else { return false }
            remaining -= group.width
            return true
        }
    }
}
