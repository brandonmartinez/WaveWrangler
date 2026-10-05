import CryptoKit
import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

// M1-REF-019 holdout ("Run D", m1-freeze-1): recorder groups, epochs, channels, speakers, primary/backup.
//
// Recipe (frozen): episodes with 1-6 groups, 1-8 clips per group, unknown/known channel counts from
// synthetic safe metadata, speakers, primary/backup assignments and corrections with undo.
// Truth (frozen): group clock distinct from clip start; UNKNOWN duration/channels stay UNKNOWN;
// provisional vs user-confirmed labels honest; primary change marks dependents stale; named undo
// restores exact state.
//
// Every edit goes through the product command layer (`SetupEditCommands`) and a real `UndoManager`
// via `ProductMirrorEditor`, which mirrors the app's `ShowDocumentStore.apply` (no-op edits register no
// undo; one named undo step per applied edit holding the exact prior value). Refusals are predicted by an
// independent oracle written from the operations' documented rules, not from their output.
//
// The holdout split runs once, only when WW_REF019_HOLDOUT=1; ordinary test runs (and CI) execute the
// calibration split only, so the frozen holdout is not re-executed on every build.

enum RunD {
    static let fixtureID = "M1-REF-019"
    static let calibration = 10
    static let holdout = 100
    static let holdoutEnabled = ProcessInfo.processInfo.environment["WW_REF019_HOLDOUT"] == "1"

    static func seed(split: String, index: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m1-fixture|v1|\(fixtureID)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

struct RunDRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Mirrors `ShowDocumentStore.apply` / `replace(with:actionName:)` in the app target (which the package
/// tests cannot link): a refused operation changes nothing; an operation that returns an equal model
/// registers no undo; otherwise the model is replaced and one named undo step holding the exact prior
/// value is registered on a real `UndoManager` (one group per user command, as one menu event).
@MainActor
final class ProductMirrorEditor: SetupEditing {
    private(set) var showModel: ShowDocumentModel
    private(set) var lastSetupError: DomainError?
    let undoManager = UndoManager()
    private(set) var registrations = 0

    init(_ model: ShowDocumentModel) {
        showModel = model
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 0
    }

    func applySetupEdit(_ actionName: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool {
        do {
            let updated = try operation(showModel)
            lastSetupError = nil
            guard updated != showModel else { return true }
            undoManager.beginUndoGrouping()
            replace(with: updated, actionName: actionName)
            undoManager.endUndoGrouping()
            registrations += 1
            return true
        } catch {
            lastSetupError = error
            return false
        }
    }

    private func replace(with newModel: ShowDocumentModel, actionName: String) {
        let previous = showModel
        showModel = newModel
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.replace(with: previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }
}

struct RunDRecord: Codable, Sendable {
    var split: String
    var index: Int
    var seed: String
    var groups: Int
    var clips: Int
    var knownChannelCounts: Int
    var speakers: Int
    var commands: Int
    var appliedUndoSteps: Int
    var noOpCommands: Int
    var predictedRefusals: Int
    var refusals: Int
    var undoSteps: Int
    var redoSteps: Int
    var passed: Bool
    var failures: [String]
}

@MainActor
struct RunDCase {
    let split: String
    let index: Int
    var rng: RunDRNG
    var failures: [String] = []

    init(split: String, index: Int) {
        self.split = split
        self.index = index
        rng = RunDRNG(state: RunD.seed(split: split, index: index))
    }

    mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append("\(RunD.fixtureID)/\(split)/\(index): \(message())") }
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

    // MARK: Generated truth (independent of the code under test)

    struct Truth {
        var episodeID: EpisodeID
        var groups: [RecorderGroup]          // as created (name, device, clock note)
        var observations: [SourceID: SourceObservations]
        var sourceIDs: [SourceID]
        var speakerNames: [String]
    }

    enum Command {
        case assignSpeaker(SpeakerID?, [SourceID])
        case useAsPrimary(SpeakerChannelReference)
        case useAsBackup(SpeakerChannelReference)
        case setPrimary(ChannelReference?, SpeakerID)
        case setEpoch(Int, [SourceID])
        case startNewEpoch([SourceID])
        case setChannel(Int?, [SourceID])   // 1-based as typed

        var isPrimaryBackupEdit: Bool {
            switch self {
            case .useAsPrimary, .useAsBackup, .setPrimary: true
            default: false
            }
        }
    }

    // MARK: Build an episode through product commands

    mutating func build(_ editor: ProductMirrorEditor) -> Truth {
        let episodeID = EpisodeID()
        var truth = Truth(episodeID: episodeID, groups: [], observations: [:], sourceIDs: [], speakerNames: [])
        // The episode itself is the document's starting point, not an edit under test.
        let base = (try? editor.showModel.addingEpisode(Episode(id: episodeID, title: "Episode \(index)"))) ?? editor.showModel
        _ = editor.applySetupEdit("Add Episode") { _ throws(DomainError) in base }
        let commands = SetupEditCommands(editor: editor, episodeID: episodeID)

        let speakerCount = int(1...6)
        truth.speakerNames = (0..<speakerCount).map { "Speaker \($0 + 1)" }
        var items: [SourceImportItem] = []
        for g in 0..<int(1...6) {
            let group = RecorderGroup(name: "Recorder \(g + 1)", deviceName: chance(50) ? "Device \(g)" : "", clockNote: "clock \(g): free-running")
            check(commands.createGroup(group, assigning: []), "createGroup refused")
            truth.groups.append(group)
            for c in 0..<int(1...8) {
                let channels: Knowledge<Int> = chance(50) ? .known(int(1...8)) : .unknown
                let source = SourceRecord(displayNameHint: "g\(g)-clip\(c).wav", observations: SourceObservations(channelCount: channels))
                truth.observations[source.id] = source.observations
                truth.sourceIDs.append(source.id)
                items.append(SourceImportItem(source: source, recorderGroupName: group.name, speakerName: chance(60) ? pick(truth.speakerNames) : nil))
            }
        }
        check(commands.importSources(items), "import refused")
        // Distribute clips across 1-3 epochs per group (clip epochs, distinct from the group clock).
        for sourceID in truth.sourceIDs where chance(50) {
            check(commands.setEpoch(int(1...3), for: [sourceID]), "setEpoch refused during build")
        }
        // Speakers named at import but never assigned are still listed when generated as speakers.
        for name in truth.speakerNames where editor.showModel.speakers.first(where: { $0.name == name }) == nil {
            check(commands.createSpeaker(Speaker(name: name), assigning: []), "createSpeaker refused")
        }
        return truth
    }

    // MARK: Corrections

    mutating func randomCommand(_ model: ShowDocumentModel, _ truth: Truth) -> Command {
        let episode = model.episode(truth.episodeID)!
        let speakers = episode.speakerAssignments.map(\.speakerID)
        let sources = truth.sourceIDs
        func someSources() -> [SourceID] { (0..<int(1...3)).map { _ in pick(sources) } }
        func anyReference() -> SpeakerChannelReference? {
            let refs = sources.flatMap { episode.references(to: $0) }
            return refs.isEmpty ? nil : pick(refs)
        }
        func randomReference() -> SpeakerChannelReference {
            SpeakerChannelReference(speakerID: pick(speakers), channel: ChannelReference(sourceID: pick(sources), channel: int(0...2)), isPrimary: false)
        }
        switch int(0...13) {
        case 0...2:
            return .assignSpeaker(chance(85) ? pick(speakers) : nil, someSources())
        case 3...5:
            return .useAsPrimary(chance(80) ? (anyReference() ?? randomReference()) : randomReference())
        case 6...7:
            return .useAsBackup(chance(80) ? (anyReference() ?? randomReference()) : randomReference())
        case 8:
            let speaker = pick(speakers)
            let own = episode.assignment(for: speaker).map { ($0.primary.map { [$0] } ?? []) + $0.backups } ?? []
            return .setPrimary(chance(30) || own.isEmpty ? nil : pick(own), speaker)
        case 9...10:
            return .setEpoch(int(0...4), [pick(sources)])
        case 11:
            return .startNewEpoch([pick(sources)])
        default:
            return .setChannel(chance(25) ? nil : int(0...9), [pick(sources)])
        }
    }

    /// Independent refusal oracle from the documented rules of the setup operations.
    static func expectedRefusal(_ command: Command, _ model: ShowDocumentModel, _ truth: Truth) -> Bool {
        guard let episode = model.episode(truth.episodeID) else { return true }
        func references(_ speaker: SpeakerID) -> [ChannelReference] {
            guard let a = episode.assignment(for: speaker) else { return [] }
            return (a.primary.map { [$0] } ?? []) + a.backups
        }
        switch command {
        case .assignSpeaker:
            return false
        case let .useAsPrimary(ref):
            guard references(ref.speakerID).contains(ref.channel) else { return true }
            return episode.speakerAssignments.contains { $0.speakerID != ref.speakerID && $0.primary == ref.channel }
        case let .useAsBackup(ref):
            return !references(ref.speakerID).contains(ref.channel)
        case let .setPrimary(channel, speaker):
            guard let channel else { return false }
            guard references(speaker).contains(channel) else { return true }
            return episode.speakerAssignments.contains { $0.speakerID != speaker && $0.primary == channel }
        case let .setEpoch(number, sources):
            if number < 1 { return true }
            return sources.contains { episode.source($0)?.placement.recorderGroupID == nil }
        case let .startNewEpoch(sources):
            return sources.contains { episode.source($0)?.placement.recorderGroupID == nil }
        case let .setChannel(typed, sources):
            guard let typed else { return Self.primaryConflictAfterRetarget(episode, sources, to: nil) }
            if typed < 1 { return true }
            for source in sources {
                if let count = truth.observations[source]?.channelCount.value, typed - 1 >= count { return true }
            }
            return Self.primaryConflictAfterRetarget(episode, sources, to: typed - 1)
        }
    }

    /// Stating a channel retargets every reference to the source; two speakers may not end up sharing a primary.
    static func primaryConflictAfterRetarget(_ episode: Episode, _ sources: [SourceID], to channel: Int?) -> Bool {
        var primaries: [ChannelReference] = []
        for assignment in episode.speakerAssignments {
            guard var primary = assignment.primary else { continue }
            if sources.contains(primary.sourceID) { primary = ChannelReference(sourceID: primary.sourceID, channel: channel ?? 0) }
            if primaries.contains(primary) { return true }
            primaries.append(primary)
        }
        return false
    }

    func expectedUndoName(_ command: Command, _ model: ShowDocumentModel) -> String {
        func name(_ id: SpeakerID) -> String { model.speaker(id)?.name ?? "Unknown speaker" }
        switch command {
        case let .assignSpeaker(speaker, _): return SetupUndoName.assignSpeaker(speaker.map(name) ?? "Unassigned")
        case let .useAsPrimary(ref): return SetupUndoName.changePrimary(name(ref.speakerID))
        case let .useAsBackup(ref): return SetupUndoName.changeBackup(name(ref.speakerID))
        case let .setPrimary(_, speaker): return SetupUndoName.changePrimary(name(speaker))
        case .setEpoch: return SetupUndoName.setEpoch
        case .startNewEpoch: return SetupUndoName.startNewEpoch
        case .setChannel: return SetupUndoName.setChannel
        }
    }

    func perform(_ command: Command, _ commands: SetupEditCommands) -> Bool {
        switch command {
        case let .assignSpeaker(speaker, sources): commands.assignSpeaker(speaker, to: sources)
        case let .useAsPrimary(ref): commands.useAsPrimary(ref)
        case let .useAsBackup(ref): commands.useAsBackup(ref)
        case let .setPrimary(channel, speaker): commands.setPrimary(channel, for: speaker)
        case let .setEpoch(number, sources): commands.setEpoch(number, for: sources)
        case let .startNewEpoch(sources): commands.startNewEpoch(for: sources)
        case let .setChannel(typed, sources): commands.setChannel(typed, for: sources)
        }
    }

    // MARK: Truth checks after each applied command

    mutating func checkInvariants(before: ShowDocumentModel, after: ShowDocumentModel, command: Command, truth: Truth) {
        guard let pre = before.episode(truth.episodeID), let post = after.episode(truth.episodeID) else {
            check(false, "episode vanished")
            return
        }
        // Group clock distinct from clip start: the group's clock note/name/device never change, and clip
        // epochs only extend the group's epoch list (existing epochs keep identity and order).
        for created in truth.groups {
            guard let group = post.recorderGroup(created.id), let previous = pre.recorderGroup(created.id) else {
                check(false, "group \(created.name) vanished")
                continue
            }
            check(group.clockNote == created.clockNote && group.name == created.name && group.deviceName == created.deviceName, "group clock/name changed for \(created.name)")
            check(Array(group.epochs.prefix(previous.epochs.count)) == previous.epochs, "existing epochs changed in \(created.name)")
        }
        // UNKNOWN duration/channels stay UNKNOWN: observations always equal the generated metadata.
        for source in post.sources {
            check(source.observations == truth.observations[source.id], "observations changed for \(source.displayNameHint)")
            check(source.observations.durationSeconds == .unknown && source.observations.sampleRate == .unknown, "duration/sample rate became known")
        }
        // Labels honest: only an explicit primary/backup command may make anything user-confirmed, and
        // only for the targeted speaker's own channels.
        let targetSpeaker: SpeakerID? = switch command {
        case let .useAsPrimary(ref), let .useAsBackup(ref): ref.speakerID
        case let .setPrimary(_, speaker): speaker
        default: nil
        }
        for assignment in post.speakerAssignments {
            let previous = pre.assignment(for: assignment.speakerID)
            if assignment.primaryConfirmation == .userConfirmed && previous?.primaryConfirmation != .userConfirmed {
                check(command.isPrimaryBackupEdit && assignment.speakerID == targetSpeaker, "primary silently became user-confirmed")
            }
        }
        let targetChannels: Set<SourceID> = targetSpeaker.map { speaker in
            let a = post.assignment(for: speaker)
            let b = pre.assignment(for: speaker)
            return Set(((a?.primary.map { [$0] } ?? []) + (a?.backups ?? []) + (b?.primary.map { [$0] } ?? []) + (b?.backups ?? [])).map(\.sourceID))
        } ?? []
        for source in post.sources {
            if source.roleConfirmation == .userConfirmed && pre.source(source.id)?.roleConfirmation != .userConfirmed {
                check(command.isPrimaryBackupEdit && targetChannels.contains(source.id), "source role silently became user-confirmed")
            }
        }
    }

    // MARK: Run one episode

    mutating func run() -> RunDRecord {
        let editor = ProductMirrorEditor(ShowDocumentModel(show: Show(title: "Synthetic")))
        let truth = build(editor)
        let commands = SetupEditCommands(editor: editor, episodeID: truth.episodeID)
        // Undo history under test starts here: the corrections.
        editor.undoManager.removeAllActions()
        let registrationsAtStart = editor.registrations

        var states: [ShowDocumentModel] = [editor.showModel]
        var names: [String] = []
        var predicted = 0
        var refusals = 0
        var noOps = 0
        let count = int(10...40)
        for _ in 0..<count {
            let command = randomCommand(editor.showModel, truth)
            let before = editor.showModel
            let registrationsBefore = editor.registrations
            let expectRefusal = Self.expectedRefusal(command, before, truth)
            let expectedName = expectedUndoName(command, before)
            let applied = perform(command, commands)
            if expectRefusal { predicted += 1 }
            check(applied != expectRefusal, "\(command): applied=\(applied) expected refusal=\(expectRefusal) error=\(String(describing: editor.lastSetupError))")
            if !applied {
                refusals += 1
                check(editor.showModel == before, "refused command mutated the model")
                check(editor.registrations == registrationsBefore, "refused command registered undo")
                continue
            }
            if editor.showModel == before {
                noOps += 1
                check(editor.registrations == registrationsBefore, "no-op command registered undo")
                continue
            }
            check(editor.registrations == registrationsBefore + 1, "applied command registered \(editor.registrations - registrationsBefore) undo steps")
            check(editor.undoManager.undoActionName == expectedName, "undo name \(editor.undoManager.undoActionName) != \(expectedName)")
            checkInvariants(before: before, after: editor.showModel, command: command, truth: truth)
            states.append(editor.showModel)
            names.append(expectedName)
        }

        // Named undo restores the exact prior state at every step; redo restores the exact later state.
        var undoSteps = 0
        for step in stride(from: names.count - 1, through: 0, by: -1) {
            check(editor.undoManager.canUndo, "cannot undo step \(step)")
            check(editor.undoManager.undoActionName == names[step], "undo name at step \(step): \(editor.undoManager.undoActionName)")
            editor.undoManager.undo()
            undoSteps += 1
            check(editor.showModel == states[step], "undo step \(step) did not restore the exact state")
        }
        check(!editor.undoManager.canUndo, "undo stack not exhausted")
        var redoSteps = 0
        for step in 0..<names.count {
            check(editor.undoManager.redoActionName == names[step], "redo name at step \(step): \(editor.undoManager.redoActionName)")
            editor.undoManager.redo()
            redoSteps += 1
            check(editor.showModel == states[step + 1], "redo step \(step) did not restore the exact state")
        }
        check(editor.registrations - registrationsAtStart == names.count, "undo registrations \(editor.registrations - registrationsAtStart) != applied \(names.count)")

        let known = truth.observations.values.filter { $0.channelCount.isKnown }.count
        return RunDRecord(
            split: split, index: index, seed: String(format: "%016llx", RunD.seed(split: split, index: index)),
            groups: truth.groups.count, clips: truth.sourceIDs.count, knownChannelCounts: known,
            speakers: truth.speakerNames.count, commands: count, appliedUndoSteps: names.count, noOpCommands: noOps,
            predictedRefusals: predicted, refusals: refusals, undoSteps: undoSteps, redoSteps: redoSteps,
            passed: failures.isEmpty, failures: failures
        )
    }
}

@MainActor
@Suite("M1-REF-019 Run D: SetupEditCommands + UndoManager")
struct OrganizationHoldoutTests {
    @Test func refusalOracleMatchesDocumentedRules() throws {
        let episodeID = EpisodeID()
        let two = SourceRecord(displayNameHint: "a.wav", observations: SourceObservations(channelCount: .known(2)))
        let unknown = SourceRecord(displayNameHint: "b.wav")
        let truth = RunDCase.Truth(episodeID: episodeID, groups: [], observations: [two.id: two.observations, unknown.id: unknown.observations], sourceIDs: [two.id, unknown.id], speakerNames: ["S"])
        let model = ShowDocumentModel(show: Show(title: "T"), episodes: [Episode(id: episodeID, title: "E", sources: [two, unknown])])
        #expect(RunDCase.expectedRefusal(.setChannel(3, [two.id]), model, truth))
        #expect(!RunDCase.expectedRefusal(.setChannel(8, [unknown.id]), model, truth))
        #expect(RunDCase.expectedRefusal(.setChannel(0, [unknown.id]), model, truth))
        #expect(RunDCase.expectedRefusal(.setEpoch(1, [two.id]), model, truth))  // ungrouped
        #expect(RunDCase.expectedRefusal(.useAsPrimary(SpeakerChannelReference(speakerID: SpeakerID(), channel: ChannelReference(sourceID: two.id, channel: 0), isPrimary: false)), model, truth))
    }

    @Test func runD() throws {
        var splits = [("calibration", RunD.calibration)]
        if RunD.holdoutEnabled { splits.append(("holdout", RunD.holdout)) }
        var records: [RunDRecord] = []
        for (split, count) in splits {
            for index in 0..<count {
                var testCase = RunDCase(split: split, index: index)
                records.append(testCase.run())
            }
        }
        for split in ["calibration", "holdout"] {
            let set = records.filter { $0.split == split }
            guard !set.isEmpty else { continue }
            let failed = set.filter { !$0.passed }
            for record in failed.prefix(5) { print("M1-REF-019-RUN-D-FAILURE \(record.failures.prefix(3))") }
            print("M1-REF-019-RUN-D split=\(split) episodes=\(set.count) failedEpisodes=\(failed.count) groups=\(set.map(\.groups).reduce(0, +)) clips=\(set.map(\.clips).reduce(0, +)) knownChannelCounts=\(set.map(\.knownChannelCounts).reduce(0, +)) speakers=\(set.map(\.speakers).reduce(0, +)) commands=\(set.map(\.commands).reduce(0, +)) appliedUndoSteps=\(set.map(\.appliedUndoSteps).reduce(0, +)) noOps=\(set.map(\.noOpCommands).reduce(0, +)) predictedRefusals=\(set.map(\.predictedRefusals).reduce(0, +)) refusals=\(set.map(\.refusals).reduce(0, +)) undoSteps=\(set.map(\.undoSteps).reduce(0, +)) redoSteps=\(set.map(\.redoSteps).reduce(0, +))")
        }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = records.compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("m1-ref-019-run-d-cases.jsonl"), atomically: true, encoding: .utf8)

        #expect(records.filter { $0.split == "calibration" }.count >= RunD.calibration)
        if RunD.holdoutEnabled { #expect(records.filter { $0.split == "holdout" }.count >= RunD.holdout) }
        let failedEpisodes = records.filter { !$0.passed }.count
        #expect(failedEpisodes == 0)
    }
}
