import CryptoKit
import Foundation
import Testing
@testable import WWCore

// M1-REF-019 (frozen in m1-freeze-1): recorder groups, epochs, channels, speakers, primary/backup.
//
// Recipe: episodes with 1-6 groups and 1-8 clips per group, unknown/known channel counts from synthetic
// safe metadata, speakers, primary/backup assignments and corrections with undo.
// Truth: group clock distinct from clip start; UNKNOWN duration/channels stay UNKNOWN; provisional vs
// user-confirmed labels honest; primary change marks dependents stale; named undo restores exact state.
//
// Expected refusals are computed by an independent oracle in this file from the recipe, not from the
// code under test. Every episode is recorded (including failures).
//
// This WWCore phase uses a harness snapshot editor, so its undo/redo checks are not product-undo evidence
// and it is NOT the REF-019 holdout. The single holdout run drives WWEpisodeSetup's SetupEditCommands
// with a real UndoManager.

enum REF019 {
    static let fixtureID = "M1-REF-019"
    static let frozenCalibration = 10
    static let frozenHoldout = 100

    static func seed(split: String, index: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m1-fixture|v1|\(fixtureID)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

struct REF019RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The edit surface REF-019 drives: apply a pure operation as one named undo step; undo/redo.
@MainActor
protocol OrganizationEditing: AnyObject {
    var model: ShowDocumentModel { get }
    var undoActionName: String? { get }
    var redoActionName: String? { get }
    /// Applies `operation` as one named undo step. Returns the refusal, if any (model unchanged).
    func apply(_ name: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> DomainError?
    func undo()
    func redo()
}

/// WWCore-only editor: one undo step per applied pure operation, names recorded in `EditHistory`
/// (the durable naming skeleton), inverse = the exact prior value.
@MainActor
final class SnapshotEditor: OrganizationEditing {
    private(set) var model: ShowDocumentModel
    private var undoStack: [(name: String, before: ShowDocumentModel)] = []
    private var redoStack: [(name: String, after: ShowDocumentModel)] = []
    private var history = EditHistory()

    init(_ model: ShowDocumentModel) { self.model = model }

    var undoActionName: String? { history.undoActionName }
    var redoActionName: String? { history.redoActionName }

    func apply(_ name: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> DomainError? {
        do {
            let updated = try operation(model)
            undoStack.append((name, model))
            redoStack.removeAll()
            history = history.recording(EditRecord(actionName: name, timestamp: Date(timeIntervalSince1970: 0)))
            model = updated
            return nil
        } catch {
            return error
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((last.name, model))
        model = last.before
        history.cursor -= 1
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((next.name, model))
        model = next.after
        history.cursor += 1
    }
}

struct REF019Record: Codable, Sendable {
    var split: String
    var index: Int
    var seed: String
    var groups: Int
    var clips: Int
    var knownChannelCounts: Int
    var speakers: Int
    var appliedEdits: Int
    var expectedRefusals: Int
    var undoSteps: Int
    var redoSteps: Int
    var passed: Bool
    var failures: [String]
}

/// Generated episode truth, independent of the code under test.
struct REF019Truth {
    var showID: ShowID
    var episodeID: EpisodeID
    var groups: [RecorderGroup]
    var sources: [SourceRecord]
    var speakers: [Speaker]
}

@MainActor
struct REF019Case {
    let split: String
    let index: Int
    var rng: REF019RNG
    var failures: [String] = []

    init(split: String, index: Int) {
        self.split = split
        self.index = index
        rng = REF019RNG(state: REF019.seed(split: split, index: index))
    }

    mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append("\(REF019.fixtureID)/\(split)/\(index): \(message())") }
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }

    mutating func generate() -> REF019Truth {
        var groups: [RecorderGroup] = []
        var sources: [SourceRecord] = []
        for g in 0..<int(1...6) {
            let epochs = (0..<int(1...3)).map { RecordingEpoch(label: "\($0 + 1)", note: "take \($0 + 1)") }
            let group = RecorderGroup(name: "Recorder \(g + 1)", deviceName: chance(50) ? "Device \(g)" : "", clockNote: "clock note \(g)", epochs: epochs)
            groups.append(group)
            for c in 0..<int(1...8) {
                let channels: Knowledge<Int> = chance(50) ? .known(int(1...8)) : .unknown
                sources.append(SourceRecord(
                    displayNameHint: "g\(g)-clip\(c).wav",
                    observations: SourceObservations(channelCount: channels),
                    placement: SourcePlacement(recorderGroupID: group.id, epochID: epochs[int(0...(epochs.count - 1))].id)
                ))
            }
        }
        let speakers = (0..<int(1...6)).map { Speaker(name: "Speaker \($0 + 1)") }
        return REF019Truth(showID: ShowID(), episodeID: EpisodeID(), groups: groups, sources: sources, speakers: speakers)
    }

    /// Builds the episode through WWCore operations (each an undoable named edit).
    mutating func build(_ truth: REF019Truth, editor: some OrganizationEditing) {
        let episode = Episode(id: truth.episodeID, title: "Episode \(index)")
        check(editor.apply("Add Episode") { model throws(DomainError) in try model.addingEpisode(episode) } == nil, "add episode refused")
        for speaker in truth.speakers {
            check(editor.apply("Add Speaker") { model throws(DomainError) in try model.addingSpeaker(speaker) } == nil, "add speaker refused")
        }
        for group in truth.groups {
            check(editor.apply("New Recorder Group") { model throws(DomainError) in try model.addingRecorderGroup(group, to: truth.episodeID) } == nil, "add group refused")
        }
        for source in truth.sources {
            check(editor.apply("Import Source") { model throws(DomainError) in try model.addingSource(source, to: truth.episodeID) } == nil, "add source refused")
        }
    }

    enum Correction {
        case assignPrimary(ChannelReference, SpeakerID, WWCore.Confirmation)
        case clearPrimary(SpeakerID)
        case addBackup(ChannelReference, SpeakerID)
        case removeBackup(ChannelReference, SpeakerID)
        case setRole(SourceID, SourceRole, WWCore.Confirmation)

        var name: String {
            switch self {
            case .assignPrimary: "Use as Primary"
            case .clearPrimary: "Clear Primary"
            case .addBackup: "Use as Backup"
            case .removeBackup: "Remove Backup"
            case .setRole: "Set Source Role"
            }
        }
    }

    mutating func randomCorrection(_ truth: REF019Truth, _ model: ShowDocumentModel) -> Correction {
        let source = truth.sources[int(0...(truth.sources.count - 1))]
        let known = source.observations.channelCount.value
        // Mostly valid channels; sometimes deliberately out of range (refusal expected when known).
        let channelIndex = chance(15) ? (known ?? 0) + int(0...2) : int(0...max(0, (known ?? 2) - 1))
        let channel = ChannelReference(sourceID: source.id, channel: channelIndex)
        let speaker = truth.speakers[int(0...(truth.speakers.count - 1))].id
        let confirmation: WWCore.Confirmation = chance(40) ? .userConfirmed : .provisional
        switch int(0...9) {
        case 0...3: return .assignPrimary(channel, speaker, confirmation)
        case 4: return .clearPrimary(speaker)
        case 5...6: return .addBackup(channel, speaker)
        case 7:
            let assignment = model.episode(truth.episodeID)?.assignment(for: speaker)
            if let existing = assignment?.backups.first, chance(80) { return .removeBackup(existing, speaker) }
            return .removeBackup(channel, speaker)
        default:
            return .setRole(source.id, [SourceRole.unassigned, .primary, .backup][int(0...2)], confirmation)
        }
    }

    /// Independent oracle: should WWCore refuse this correction on `model`?
    static func expectedRefusal(_ correction: Correction, _ model: ShowDocumentModel, _ truth: REF019Truth) -> Bool {
        guard let episode = model.episode(truth.episodeID) else { return true }
        func channelInvalid(_ channel: ChannelReference) -> Bool {
            guard let source = truth.sources.first(where: { $0.id == channel.sourceID }) else { return true }
            if channel.channel < 0 { return true }
            if let count = source.observations.channelCount.value, channel.channel >= count { return true }
            return false
        }
        switch correction {
        case let .assignPrimary(channel, speaker, _):
            if channelInvalid(channel) { return true }
            if let source = episode.source(channel.sourceID), source.role == .backup, source.roleConfirmation == .userConfirmed { return true }
            return episode.speakerAssignments.contains { $0.speakerID != speaker && $0.primary == channel }
        case .clearPrimary:
            return false
        case let .addBackup(channel, speaker):
            if channelInvalid(channel) { return true }
            let assignment = episode.assignment(for: speaker)
            return assignment?.primary == channel || assignment?.backups.contains(channel) == true
        case let .removeBackup(channel, speaker):
            return episode.assignment(for: speaker)?.backups.contains(channel) != true
        case .setRole:
            return false
        }
    }

    static func operation(_ correction: Correction, _ episodeID: EpisodeID) -> (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel {
        switch correction {
        case let .assignPrimary(channel, speaker, confirmation):
            return { model throws(DomainError) in try model.assigningPrimary(channel, to: speaker, in: episodeID, confirmation: confirmation) }
        case let .clearPrimary(speaker):
            return { model throws(DomainError) in try model.clearingPrimary(of: speaker, in: episodeID) }
        case let .addBackup(channel, speaker):
            return { model throws(DomainError) in try model.addingBackup(channel, to: speaker, in: episodeID) }
        case let .removeBackup(channel, speaker):
            return { model throws(DomainError) in try model.removingBackup(channel, from: speaker, in: episodeID) }
        case let .setRole(source, role, confirmation):
            return { model throws(DomainError) in try model.settingSourceRole(role, confirmation: confirmation, source: source, in: episodeID) }
        }
    }

    /// Truth checks after each applied correction.
    mutating func checkInvariants(before: ShowDocumentModel, after: ShowDocumentModel, correction: Correction, truth: REF019Truth) {
        guard let pre = before.episode(truth.episodeID), let post = after.episode(truth.episodeID) else {
            check(false, "episode vanished")
            return
        }
        // Group clock distinct from clip start: corrections never touch groups (clock note, epochs) or
        // source placement; schema v1 has no clip-start field that could absorb a group clock.
        check(post.recorderGroups == truth.groups, "recorder groups / group clock changed")
        check(post.sources.map(\.placement) == pre.sources.map(\.placement), "source placement changed")
        // UNKNOWN stays UNKNOWN: observations equal the generated metadata (duration/sample rate always
        // unknown; channel count unknown unless generated as known).
        for source in post.sources {
            let generated = truth.sources.first { $0.id == source.id }
            check(source.observations == generated?.observations, "observations changed for \(source.displayNameHint)")
            check(source.observations.durationSeconds == .unknown && source.observations.sampleRate == .unknown, "duration/sample rate became known")
        }
        // Channel references stay within known channel counts.
        for assignment in post.speakerAssignments {
            for channel in [assignment.primary].compactMap({ $0 }) + assignment.backups {
                if let count = truth.sources.first(where: { $0.id == channel.sourceID })?.observations.channelCount.value {
                    check(channel.channel < count, "channel \(channel.channel) beyond known count \(count)")
                }
            }
        }
        // Labels honest: nothing becomes user-confirmed unless this edit explicitly confirmed that item.
        let (targetSpeaker, targetSource, confirmedByEdit): (SpeakerID?, SourceID?, Bool) = switch correction {
        case let .assignPrimary(channel, speaker, confirmation): (speaker, channel.sourceID, confirmation == .userConfirmed)
        case let .setRole(source, _, confirmation): (nil, source, confirmation == .userConfirmed)
        case let .clearPrimary(speaker): (speaker, nil, false)
        case let .addBackup(channel, speaker), let .removeBackup(channel, speaker): (speaker, channel.sourceID, false)
        }
        for assignment in post.speakerAssignments {
            let previous = pre.assignment(for: assignment.speakerID)
            if assignment.primaryConfirmation == .userConfirmed && previous?.primaryConfirmation != .userConfirmed {
                check(confirmedByEdit && assignment.speakerID == targetSpeaker, "primary silently became user-confirmed")
            }
            // Primary change never retargets other speakers (no dependents are moved).
            if assignment.speakerID != targetSpeaker {
                check(assignment == previous ?? SpeakerAssignment(speakerID: assignment.speakerID), "another speaker's assignment changed")
            }
        }
        check(post.speakerAssignments.count >= pre.speakerAssignments.count, "speaker assignment removed")
        for source in post.sources {
            let previous = pre.source(source.id)
            if source.roleConfirmation == .userConfirmed && previous?.roleConfirmation != .userConfirmed {
                check(confirmedByEdit && source.id == targetSource, "source role silently became user-confirmed")
            }
            if source.id != targetSource {
                check(source == previous, "untargeted source changed")
            }
        }
    }

    mutating func run(editor: some OrganizationEditing, truth: REF019Truth) -> REF019Record {
        build(truth, editor: editor)
        var states: [ShowDocumentModel] = [editor.model]
        var names: [String] = []
        var expectedRefusals = 0
        for _ in 0..<int(10...40) {
            let correction = randomCorrection(truth, editor.model)
            let before = editor.model
            let expectRefusal = Self.expectedRefusal(correction, before, truth)
            let refusal = editor.apply(correction.name, Self.operation(correction, truth.episodeID))
            check((refusal != nil) == expectRefusal, "\(correction.name): refusal \(String(describing: refusal)) expected \(expectRefusal)")
            if refusal != nil {
                expectedRefusals += 1
                check(editor.model == before, "refused edit mutated the model")
                continue
            }
            check(editor.undoActionName == correction.name, "undo name \(String(describing: editor.undoActionName)) != \(correction.name)")
            checkInvariants(before: before, after: editor.model, correction: correction, truth: truth)
            states.append(editor.model)
            names.append(correction.name)
        }
        // Named undo restores the exact prior state at every step; redo restores the exact later state.
        var undoSteps = 0
        for step in stride(from: names.count - 1, through: 0, by: -1) {
            check(editor.undoActionName == names[step], "undo name at step \(step)")
            editor.undo()
            undoSteps += 1
            check(editor.model == states[step], "undo step \(step) did not restore the exact state")
        }
        var redoSteps = 0
        for step in 0..<names.count {
            check(editor.redoActionName == names[step], "redo name at step \(step)")
            editor.redo()
            redoSteps += 1
            check(editor.model == states[step + 1], "redo step \(step) did not restore the exact state")
        }
        let known = truth.sources.filter { $0.observations.channelCount.isKnown }.count
        return REF019Record(
            split: split, index: index, seed: String(format: "%016llx", REF019.seed(split: split, index: index)),
            groups: truth.groups.count, clips: truth.sources.count, knownChannelCounts: known,
            speakers: truth.speakers.count, appliedEdits: names.count, expectedRefusals: expectedRefusals,
            undoSteps: undoSteps, redoSteps: redoSteps, passed: failures.isEmpty, failures: failures
        )
    }
}

@MainActor
@Suite("M1-REF-019 generator and WWCore model operations (not holdout; holdout is Run D with product undo)")
struct OrganizationFixtureTests {
    @Test func refusalOracleMatchesKnownCases() {
        let group = RecorderGroup(name: "G", epochs: [RecordingEpoch(label: "1")])
        let two = SourceRecord(displayNameHint: "a.wav", observations: SourceObservations(channelCount: .known(2)), placement: SourcePlacement(recorderGroupID: group.id))
        let unknown = SourceRecord(displayNameHint: "b.wav", placement: SourcePlacement(recorderGroupID: group.id))
        let speaker = Speaker(name: "S")
        let truth = REF019Truth(showID: ShowID(), episodeID: EpisodeID(), groups: [group], sources: [two, unknown], speakers: [speaker])
        let model = ShowDocumentModel(show: Show(title: "T"), speakers: [speaker], episodes: [Episode(id: truth.episodeID, title: "E", recorderGroups: [group], sources: [two, unknown])])
        #expect(REF019Case.expectedRefusal(.assignPrimary(ChannelReference(sourceID: two.id, channel: 2), speaker.id, .provisional), model, truth))
        #expect(!REF019Case.expectedRefusal(.assignPrimary(ChannelReference(sourceID: unknown.id, channel: 7), speaker.id, .provisional), model, truth))
        #expect(REF019Case.expectedRefusal(.removeBackup(ChannelReference(sourceID: two.id, channel: 0), speaker.id), model, truth))
    }

    @Test func ref019() throws {
        var records: [REF019Record] = []
        for (split, count) in [("calibration", REF019.frozenCalibration), ("holdout", REF019.frozenHoldout)] {
            for index in 0..<count {
                var testCase = REF019Case(split: split, index: index)
                let truth = testCase.generate()
                let editor = SnapshotEditor(ShowDocumentModel(show: Show(id: truth.showID, title: "Synthetic")))
                records.append(testCase.run(editor: editor, truth: truth))
            }
        }
        let holdout = records.filter { $0.split == "holdout" }
        let calibration = records.filter { $0.split == "calibration" }
        let failed = records.filter { !$0.passed }
        for record in failed.prefix(10) { print("M1-REF-019-FAILURE \(record.failures.prefix(3))") }
        print("M1-REF-019-WWCORE (not holdout) editor=harness-snapshot holdoutSeeds=\(holdout.count) calibrationSeeds=\(calibration.count) failedEpisodes=\(failed.count) groups=\(holdout.map(\.groups).reduce(0, +)) clips=\(holdout.map(\.clips).reduce(0, +)) knownChannelCounts=\(holdout.map(\.knownChannelCounts).reduce(0, +)) speakers=\(holdout.map(\.speakers).reduce(0, +)) appliedEdits=\(holdout.map(\.appliedEdits).reduce(0, +)) expectedRefusals=\(holdout.map(\.expectedRefusals).reduce(0, +)) undoSteps=\(holdout.map(\.undoSteps).reduce(0, +)) redoSteps=\(holdout.map(\.redoSteps).reduce(0, +))")

        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = records.compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("m1-ref-019-cases.jsonl"), atomically: true, encoding: .utf8)

        #expect(holdout.count >= REF019.frozenHoldout)
        #expect(calibration.count >= REF019.frozenCalibration)
        #expect(failed.isEmpty)
    }
}
