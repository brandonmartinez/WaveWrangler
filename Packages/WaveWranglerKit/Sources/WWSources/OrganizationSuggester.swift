import Foundation
import WWCore

/// What a provisional suggestion was based on. Names and folders are hints, never identity or facts.
public enum SuggestionBasis: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case folderStructure
    case fileNamePattern
}

public struct SuggestedEpoch: Sendable, Equatable {
    public var label: String
    public var sourceIDs: [SourceID]
    public var basis: Set<SuggestionBasis>
    public let confirmation: Confirmation = .provisional
}

public struct SuggestedRecorderGroup: Sendable, Equatable {
    public var name: String
    public var epochs: [SuggestedEpoch]
    public var basis: Set<SuggestionBasis>
    public let confirmation: Confirmation = .provisional

    public var sourceIDs: [SourceID] { epochs.flatMap(\.sourceIDs) }
}

public struct SuggestedSpeaker: Sendable, Equatable {
    public var name: String
    public var sourceIDs: [SourceID]
    public let basis: Set<SuggestionBasis> = [.fileNamePattern]
    public let confirmation: Confirmation = .provisional
}

/// Per-source provisional hints. Track labels describe a *file*; channel count stays unknown, so no
/// channel indices are suggested.
public struct SourceSuggestion: Sendable, Equatable {
    public var trackLabel: String?
    public var speakerName: String?
    public var role: SourceRole
    public let confirmation: Confirmation = .provisional
}

/// Provisional recorder-group / epoch / speaker suggestions. Nothing here is applied to the show
/// document; the UI presents it and the user confirms or corrects it.
public struct ProvisionalOrganization: Sendable, Equatable {
    public var recorderGroups: [SuggestedRecorderGroup]
    public var speakers: [SuggestedSpeaker]
    public var sourceHints: [SourceID: SourceSuggestion]

    public init(recorderGroups: [SuggestedRecorderGroup] = [], speakers: [SuggestedSpeaker] = [], sourceHints: [SourceID: SourceSuggestion] = [:]) {
        self.recorderGroups = recorderGroups
        self.speakers = speakers
        self.sourceHints = sourceHints
    }
}

public enum OrganizationSuggester {
    public struct Input: Sendable, Equatable {
        public var sourceID: SourceID
        /// Relative to the selected folder; last component is the file name.
        public var relativePathComponents: [String]

        public init(sourceID: SourceID, relativePathComponents: [String]) {
            self.sourceID = sourceID
            self.relativePathComponents = relativePathComponents
        }
    }

    struct ParsedName: Equatable {
        var take: String?
        var recorderPrefix: String?
        var track: String?
        var speaker: String?
        var role: SourceRole
    }

    private static let stopWords: Set<String> = [
        "mic", "mics", "audio", "raw", "track", "tr", "take", "mix", "mixdown", "zoom", "tascam", "riverside",
        "zencastr", "squadcast", "cleanfeed", "rodecaster", "recording", "rec", "wav", "file", "final", "master",
        "backup", "safety", "bkup", "copy", "stereo", "mono", "left", "right", "lr", "ms", "ch", "channel",
        "input", "in", "the", "and", "of", "episode", "ep", "part", "session", "local", "remote", "isolated", "iso",
    ]
    private static let numberedPeople: Set<String> = ["guest", "speaker", "host", "cohost", "person", "caller"]

    static func parse(fileName: String) -> ParsedName {
        let stem = (fileName as NSString).deletingPathExtension
        var take: String?
        var prefix: String?
        var track: String?
        var remainder = stem

        func match(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let result = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
            else { return nil }
            return (0..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: remainder).map { String(remainder[$0]) }
            }
        }

        if let groups = match(#"^((ZOOM|TASCAM|DR|LS|H)[_-]?\d{3,5})(?:[_-]?(Tr\w+|LR|MS|S\d+|\d{1,2}))?$"#) {
            take = groups[1]
            prefix = groups[2]?.uppercased()
            track = groups[3]
            remainder = ""
        } else if let groups = match(#"^(\d{6}[_-]\d{3,4})(?:[_-](Tr\w+|LR|MS|\d{1,2}))?$"#) {
            take = groups[1]
            track = groups[2]
            remainder = ""
        } else if let groups = match(#"^(.*?)[ _-]*(?:tr|track|ch|channel|input|in)[ _-]?(\d{1,2}|LR|L|R)$"#) {
            track = groups[2].map { "Tr\($0)" }
            remainder = groups[1] ?? ""
        }

        let lowered = stem.lowercased()
        let role: SourceRole = ["backup", "safety", "bkup"].contains(where: lowered.contains) ? .backup : .unassigned

        let tokens = remainder
            .split(whereSeparator: { " _-.".contains($0) })
            .map(String.init)
        var nameTokens: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let lower = token.lowercased()
            if numberedPeople.contains(lower), index + 1 < tokens.count, tokens[index + 1].count <= 2, Int(tokens[index + 1]) != nil {
                nameTokens.append("\(token.capitalized) \(tokens[index + 1])")
                index += 2
                continue
            }
            if !stopWords.contains(lower), token.allSatisfy(\.isLetter), token.count >= 2 {
                nameTokens.append(token.capitalized)
            }
            index += 1
        }
        let speaker = (1...3).contains(nameTokens.count) ? nameTokens.joined(separator: " ") : nil
        return ParsedName(take: take, recorderPrefix: prefix, track: track, speaker: speaker, role: role)
    }

    private static let takeFolderPattern = try! NSRegularExpression(pattern: #"^((ZOOM|TASCAM)[_-]?\d{3,5}|\d{6}[_-]\d{3,4})$"#, options: [.caseInsensitive])

    static func isTakeFolder(_ name: String) -> Bool {
        takeFolderPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public static func suggest(for inputs: [Input]) -> ProvisionalOrganization {
        var groupOrder: [String] = []
        var groups: [String: (basis: Set<SuggestionBasis>, epochOrder: [String], epochs: [String: (Set<SuggestionBasis>, [SourceID])])] = [:]
        var hints: [SourceID: SourceSuggestion] = [:]
        var speakerOrder: [String] = []
        var speakers: [String: [SourceID]] = [:]

        for input in inputs {
            let fileName = input.relativePathComponents.last ?? ""
            var folders = Array(input.relativePathComponents.dropLast())
            let parsed = parse(fileName: fileName)

            var epochLabel: String?
            var epochBasis: Set<SuggestionBasis> = []
            if let last = folders.last, isTakeFolder(last) {
                epochLabel = last
                epochBasis.insert(.folderStructure)
                folders.removeLast()
            } else if let take = parsed.take {
                epochLabel = take
                epochBasis.insert(.fileNamePattern)
            }

            let groupName: String
            var groupBasis: Set<SuggestionBasis> = []
            if !folders.isEmpty {
                groupName = folders.joined(separator: "/")
                groupBasis.insert(.folderStructure)
            } else if let prefix = parsed.recorderPrefix {
                groupName = prefix
                groupBasis.insert(.fileNamePattern)
            } else if let epochLabel, epochBasis.contains(.folderStructure) {
                groupName = epochLabel
                groupBasis.insert(.folderStructure)
            } else {
                groupName = "Selected files"
            }

            if groups[groupName] == nil {
                groupOrder.append(groupName)
                groups[groupName] = (groupBasis, [], [:])
            }
            let label = epochLabel ?? "Take 1"
            if groups[groupName]!.epochs[label] == nil {
                groups[groupName]!.epochOrder.append(label)
                groups[groupName]!.epochs[label] = (epochBasis, [])
            }
            groups[groupName]!.epochs[label]!.1.append(input.sourceID)

            hints[input.sourceID] = SourceSuggestion(trackLabel: parsed.track, speakerName: parsed.speaker, role: parsed.role)
            if let speaker = parsed.speaker {
                if speakers[speaker] == nil { speakerOrder.append(speaker) }
                speakers[speaker, default: []].append(input.sourceID)
            }
        }

        let recorderGroups = groupOrder.map { name in
            let group = groups[name]!
            return SuggestedRecorderGroup(
                name: name,
                epochs: group.epochOrder.map { label in
                    let epoch = group.epochs[label]!
                    return SuggestedEpoch(label: label, sourceIDs: epoch.1, basis: epoch.0)
                },
                basis: group.basis
            )
        }
        return ProvisionalOrganization(
            recorderGroups: recorderGroups,
            speakers: speakerOrder.map { SuggestedSpeaker(name: $0, sourceIDs: speakers[$0]!) },
            sourceHints: hints
        )
    }
}
