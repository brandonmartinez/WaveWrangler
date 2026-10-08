import Foundation
import Testing
import WWCore
import WWSpeech

@Suite("Local speech admission")
struct AdmissionTests {
    private func episode(role: SourceRole = .primary, sourceConfirmed: WWCore.Confirmation = .userConfirmed,
                         primaryConfirmed: WWCore.Confirmation = .userConfirmed, channel: Int? = 0) -> (Episode, SpeakerID) {
        let source = SourceRecord(displayNameHint: "synthetic",
                                  observations: SourceObservations(channelCount: .known(1)),
                                  placement: SourcePlacement(channelLabels: [ChannelLabel(channel: channel ?? 0, label: "")]),
                                  role: role, roleConfirmation: sourceConfirmed)
        let speaker = SpeakerID()
        let reference = ChannelReference(sourceID: source.id, statedChannel: channel)
        return (Episode(title: "synthetic", sources: [source],
                        speakerAssignments: [SpeakerAssignment(speakerID: speaker, primary: reference,
                                                                primaryConfirmation: primaryConfirmed)]), speaker)
    }

    @Test func admitsOnlyConfirmedPrimary() throws {
        let (value, speaker) = episode()
        let selection = try PrimarySpeechSelection(episode: value, speakerID: speaker)
        #expect(selection.sourceID == value.sources[0].id)
        #expect(selection.channel == 0)
        for (blocked, blockedSpeaker) in [
            episode(role: .backup), episode(role: .unassigned),
            episode(sourceConfirmed: .provisional), episode(primaryConfirmed: .provisional),
            episode(channel: nil), episode(channel: -1), episode(channel: 1),
        ] {
            #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
                try PrimarySpeechSelection(episode: blocked, speakerID: blockedSpeaker)
            }
        }
        var duplicate = value
        duplicate.speakerAssignments.append(duplicate.speakerAssignments[0])
        #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
            try PrimarySpeechSelection(episode: duplicate, speakerID: speaker)
        }
        var selfBackup = value
        selfBackup.speakerAssignments[0].backups = [selfBackup.speakerAssignments[0].primary!]
        #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
            try PrimarySpeechSelection(episode: selfBackup, speakerID: speaker)
        }
        var duplicateSource = value
        duplicateSource.sources.append(value.sources[0])
        #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
            try PrimarySpeechSelection(episode: duplicateSource, speakerID: speaker)
        }
        var unknownChannels = value
        unknownChannels.sources[0].observations.channelCount = .unknown
        #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
            try PrimarySpeechSelection(episode: unknownChannels, speakerID: speaker)
        }
        var otherBackup = value
        otherBackup.speakerAssignments.append(SpeakerAssignment(
            speakerID: SpeakerID(), backups: [value.speakerAssignments[0].primary!]
        ))
        #expect(throws: SpeechAdmissionRefusal.primaryNotConfirmed) {
            try PrimarySpeechSelection(episode: otherBackup, speakerID: speaker)
        }
    }

    @Test func verifierRefusesMissingTamperedAndSymlinkedModels() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-model")
        let pin = LocalSpeechAssetPin(name: "synthetic", version: "1", sizeBytes: 3,
                                          sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                          license: "test", source: "synthetic")
        #expect(throws: SpeechAdmissionRefusal.assetNotLocalRegularFile) { try pin.verify(at: file) }
        try Data("abc".utf8).write(to: file)
        try pin.verify(at: file)
        try Data("abd".utf8).write(to: file)
        #expect(throws: SpeechAdmissionRefusal.assetDigestMismatch) { try pin.verify(at: file) }
        try Data("abcd".utf8).write(to: file)
        #expect(throws: SpeechAdmissionRefusal.assetSizeMismatch) { try pin.verify(at: file) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: SpeechAdmissionRefusal.assetNotLocalRegularFile) { try pin.verify(at: link) }
        let parentLink = root.deletingLastPathComponent().appendingPathComponent("speech-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: parentLink) }
        #expect(throws: SpeechAdmissionRefusal.assetNotLocalRegularFile) {
            try pin.verify(at: parentLink.appendingPathComponent("synthetic-model"))
        }
    }

    @Test func dependencyReplacementAndMissingTransitiveFailClosed() throws {
        let root = URL(fileURLWithPath: "/private/tmp/speech-pins-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        let dependency = root.appendingPathComponent("lib")
        let pin = LocalSpeechAssetPin(name: "fixture", version: "1", sizeBytes: 3,
                                      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                      license: "synthetic", source: "fixture")
        let closure = [("cli", pin), ("lib", pin)]
        try Data("abc".utf8).write(to: cli)
        #expect(throws: SpeechAdmissionRefusal.runtimeDependencyMismatch) {
            try ApprovedWhisperRuntime.verify(artifacts: closure, at: root)
        }
        try Data("abc".utf8).write(to: dependency)
        try ApprovedWhisperRuntime.verify(artifacts: closure, at: root)
        try Data("abd".utf8).write(to: dependency)
        #expect(throws: SpeechAdmissionRefusal.runtimeDependencyMismatch) {
            try ApprovedWhisperRuntime.verify(artifacts: closure, at: root)
        }
        try Data("abc".utf8).write(to: dependency)
        try Data("abd".utf8).write(to: cli)
        #expect(throws: SpeechAdmissionRefusal.runtimeDependencyMismatch) {
            try ApprovedWhisperRuntime.verify(artifacts: closure, at: root)
        }
        #expect(throws: SpeechAdmissionRefusal.runtimeNotStaged) {
            try ApprovedWhisperRuntime.verify(at: root)
        }
    }

    @Test func denyDefaultProfileBlocksUnrelatedReadAndWrite() throws {
        let root = URL(fileURLWithPath: "/private/tmp/speech-boundary-\(UUID())")
        let stage = root.appendingPathComponent("stage")
        let scratch = root.appendingPathComponent("scratch")
        let proxy = root.appendingPathComponent("proxy")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = proxy.appendingPathComponent("input.wav")
        let unrelated = root.appendingPathComponent("other")
        try Data("abc".utf8).write(to: input)
        try Data("private".utf8).write(to: unrelated)
        let cat = URL(fileURLWithPath: "/bin/cat")
        let readProfile = try OfflineWhisperPlan.profile(stage: stage, input: input, scratch: scratch, executable: cat)
        #expect(readProfile.contains("(deny default)"))
        #expect(readProfile.contains("(deny network*)"))
        #expect(!readProfile.contains("(allow default)"))
        #expect(throws: SpeechAdmissionRefusal.primaryProxyNotProven) {
            try OfflineWhisperPlan.profile(stage: stage, input: scratch.appendingPathComponent("input.wav"),
                                           scratch: scratch, executable: cat)
        }
        func invoke(_ executable: URL, _ profile: String, _ args: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, executable.path] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try invoke(cat, readProfile, [input.path]) == 0)
        #expect(try invoke(cat, readProfile, [unrelated.path]) != 0)
        let dataAlias = "/System/Volumes/Data" + unrelated.path
        #expect(FileManager.default.fileExists(atPath: dataAlias))
        #expect(try invoke(cat, readProfile, [dataAlias]) != 0)
        let touch = URL(fileURLWithPath: "/usr/bin/touch")
        let writeProfile = try OfflineWhisperPlan.profile(stage: stage, input: input, scratch: scratch, executable: touch)
        #expect(try invoke(touch, writeProfile, [unrelated.path]) != 0)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "private")
        let unrelatedNew = root.appendingPathComponent("new")
        #expect(try invoke(touch, writeProfile, [unrelatedNew.path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: unrelatedNew.path))
        #expect(try invoke(touch, writeProfile, [input.path]) != 0)
        #expect(try invoke(touch, writeProfile, [scratch.appendingPathComponent("other").path]) != 0)
        #expect(try invoke(touch, writeProfile, [scratch.appendingPathComponent("result.json").path]) == 0)

        let hardlink = scratch.appendingPathComponent("input-alias")
        let symlink = scratch.appendingPathComponent("input-link")
        try FileManager.default.linkItem(at: input, to: hardlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        #expect(try invoke(touch, writeProfile, [hardlink.path]) != 0)
        #expect(try invoke(touch, writeProfile, [symlink.path]) != 0)
        #expect(try String(contentsOf: input, encoding: .utf8) == "abc")
    }

    @Test func unprovenProxyRefusesAliasesSymlinksRacesAndMismatchedSelection() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/speech-admission-\(UUID())")
        let scratch = root.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage")
        let original = root.appendingPathComponent("original")
        try Data("synthetic".utf8).write(to: original)
        let hardlink = scratch.appendingPathComponent("input.wav")
        try FileManager.default.linkItem(at: original, to: hardlink)
        let (selectedEpisode, speaker) = episode()
        let selection = try PrimarySpeechSelection(episode: selectedEpisode, speakerID: speaker)
        func refused(_ input: URL, _ selected: PrimarySpeechSelection) {
            #expect(throws: SpeechAdmissionRefusal.primaryProxyNotProven) {
                try OfflineWhisperPlan(selection: selected, stage: stage, inputWAV: input, scratch: scratch)
            }
        }
        refused(hardlink, selection)
        try FileManager.default.removeItem(at: hardlink)
        try FileManager.default.createSymbolicLink(at: hardlink, withDestinationURL: original)
        refused(hardlink, selection)
        try FileManager.default.removeItem(at: hardlink)
        try Data("proxy".utf8).write(to: hardlink)
        refused(hardlink, selection)
        try FileManager.default.moveItem(at: hardlink, to: scratch.appendingPathComponent("old-input.wav"))
        try FileManager.default.createSymbolicLink(at: hardlink, withDestinationURL: original)
        refused(hardlink, selection)

        let (otherEpisode, otherSpeaker) = episode()
        let otherSelection = try PrimarySpeechSelection(episode: otherEpisode, speakerID: otherSpeaker)
        #expect(otherSelection != selection)
        refused(hardlink, otherSelection)
        let swapping = Task.detached {
            let files = FileManager.default
            for _ in 0..<20 {
                try files.removeItem(at: hardlink)
                try Data("proxy".utf8).write(to: hardlink)
                await Task.yield()
                try files.removeItem(at: hardlink)
                try files.createSymbolicLink(at: hardlink, withDestinationURL: original)
                await Task.yield()
            }
        }
        for _ in 0..<80 {
            refused(hardlink, selection)
            await Task.yield()
        }
        try await swapping.value
        refused(hardlink, selection)
        #expect(try String(contentsOf: original, encoding: .utf8) == "synthetic")
    }
}
