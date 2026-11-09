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
    }

    enum Control: String, Codable, CaseIterable {
        case boundaries, primaryTool, commandTool, anchors
        case zoom, fit, height, fillSpace, layout, normalize

        var group: Group {
            switch self {
            case .boundaries: .episode
            case .primaryTool, .commandTool, .anchors: .tools
            case .zoom, .height, .layout, .fit, .fillSpace, .normalize: .view
            }
        }

        var title: String {
            switch self {
            case .boundaries: "Episode and speaker boundaries"
            case .primaryTool: "Primary tool"
            case .commandTool: "Command-click tool"
            case .anchors: "Anchor points"
            case .zoom: "Horizontal zoom scale"
            case .height: "Track height scale"
            case .layout: "Track view"
            case .fit: "Fit timeline"
            case .fillSpace: "Fill Space"
            case .normalize: "Normalize view"
            }
        }

        var width: Double {
            switch self {
            case .boundaries: 110
            case .primaryTool: 50
            case .commandTool: 64
            case .anchors: 40
            case .zoom: 130
            case .height: 95
            case .layout: 95
            case .fit, .fillSpace: 28
            case .normalize: 120
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

    var version = 2
    var groups: [Group] = [.view, .episode, .tools]
    var controls: Set<Control> = [.boundaries, .primaryTool, .commandTool, .zoom, .height, .layout, .fit]
    var showsLabels = true
    var primaryClock = EpisodeClock.episode
    var secondaryClock: EpisodeClock?
    var readout = Readout.none

    var isValid: Bool {
        version == 2 && groups.count == Group.allCases.count && Set(groups) == Set(Group.allCases)
            && controls.isSubset(of: Set(Control.allCases))
    }

    static func preset(_ preset: Preset) -> Self {
        var result = Self()
        switch preset {
        case .editing: break
        case .review:
            result.controls.subtract([.primaryTool, .commandTool])
            result.secondaryClock = .speaker
            result.readout = .selection
        case .mixing:
            result.groups = [.view, .episode, .tools]
            result.controls.subtract([.primaryTool, .commandTool])
            result.readout = .remaining
        }
        return result
    }

    func selectedControls(in group: Group) -> [Control] {
        Control.allCases.filter { $0.group == group && controls.contains($0) }
    }

    func displayedControls(width: Double, available: Set<Control> = Set(Control.allCases)) -> [Control] {
        var remaining = max(0, width)
        var previousGroup: Group?
        return groups.flatMap { selectedControls(in: $0) }.filter { control in
            let spacing = previousGroup == nil ? 0.0 : (previousGroup == control.group ? 6.0 : 17.0)
            guard available.contains(control), remaining >= control.width + spacing else { return false }
            remaining -= control.width + spacing
            previousGroup = control.group
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, groups, visible, controls, showsLabels, primaryClock, secondaryClock, readout
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try container.decode(Int.self, forKey: .version)
        guard savedVersion == 1 || savedVersion == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                debugDescription: "Unsupported control bar preferences version.")
        }
        groups = try container.decode([Group].self, forKey: .groups)
        showsLabels = try container.decode(Bool.self, forKey: .showsLabels)
        primaryClock = try container.decode(EpisodeClock.self, forKey: .primaryClock)
        secondaryClock = try container.decodeIfPresent(EpisodeClock.self, forKey: .secondaryClock)
        readout = try container.decode(Readout.self, forKey: .readout)
        if savedVersion == 1 {
            let visible = try container.decode(Set<Group>.self, forKey: .visible)
            controls = Set(Control.allCases.filter {
                visible.contains($0.group) && ![Control.anchors, .fillSpace, .normalize].contains($0)
            })
        } else {
            controls = try container.decode(Set<Control>.self, forKey: .controls)
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .groups, in: container,
                debugDescription: "Invalid control bar ordering or selection.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(groups, forKey: .groups)
        try container.encode(controls, forKey: .controls)
        try container.encode(showsLabels, forKey: .showsLabels)
        try container.encode(primaryClock, forKey: .primaryClock)
        try container.encodeIfPresent(secondaryClock, forKey: .secondaryClock)
        try container.encode(readout, forKey: .readout)
    }
}
