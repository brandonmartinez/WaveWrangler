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
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = scratch.appendingPathComponent("input.wav")
        let unrelated = root.appendingPathComponent("other")
        try Data("abc".utf8).write(to: input)
        try Data("private".utf8).write(to: unrelated)
        let cat = URL(fileURLWithPath: "/bin/cat")
        let readProfile = OfflineWhisperPlan.profile(stage: stage, input: input, scratch: scratch, executable: cat)
        #expect(readProfile.contains("(deny default)"))
        #expect(readProfile.contains("(deny network*)"))
        #expect(!readProfile.contains("(allow default)"))
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
        #expect(try invoke(cat, readProfile, ["/System/Volumes/Data" + unrelated.path]) != 0)
        let touch = URL(fileURLWithPath: "/usr/bin/touch")
        let writeProfile = OfflineWhisperPlan.profile(stage: stage, input: input, scratch: scratch, executable: touch)
        #expect(try invoke(touch, writeProfile, [unrelated.path]) != 0)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "private")
        #expect(try invoke(touch, writeProfile, [scratch.appendingPathComponent("result").path]) == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_SPEECH_STAGE_PATH"] != nil),
          .timeLimit(.minutes(3)))
    func provisionedCandidateRunsSyntheticOffline() throws {
        let stage = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_SPEECH_STAGE_PATH"]))
        try ApprovedWhisperRuntime.verify(at: stage)
        let scratch = stage.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("synthetic.wav")
        var wav = Data("RIFF".utf8)
        func word(_ number: UInt16) { withUnsafeBytes(of: number.littleEndian) { wav.append(contentsOf: $0) } }
        func doubleWord(_ number: UInt32) { withUnsafeBytes(of: number.littleEndian) { wav.append(contentsOf: $0) } }
        doubleWord(32_036)
        wav.append(contentsOf: Data("WAVEfmt ".utf8))
        doubleWord(16)
        word(1)
        word(1)
        doubleWord(16_000)
        doubleWord(32_000)
        word(2)
        word(16)
        wav.append(contentsOf: Data("data".utf8))
        doubleWord(32_000)
        wav.append(Data(repeating: 0, count: 32_000))
        try wav.write(to: input)
        let finalInput = scratch.appendingPathComponent("input.wav")
        try FileManager.default.moveItem(at: input, to: finalInput)
        let (episode, speaker) = episode()
        let selection = try PrimarySpeechSelection(episode: episode, speakerID: speaker)
        let plan = try OfflineWhisperPlan(selection: selection, stage: stage,
                                          inputWAV: finalInput, scratch: scratch)
        #expect(plan.executable.path == "/usr/bin/sandbox-exec")
        let started = ContinuousClock.now
        let output = try plan.run()
        let elapsed = started.duration(to: .now)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        let segments = report?["transcription"] as? [[String: Any]]
        #expect(segments != nil)
        #expect(segments?.allSatisfy { $0["offsets"] != nil && $0["timestamps"] != nil } == true)
        print("WWSpeech staged synthetic offline: seconds=1 elapsed=\(elapsed) status=0")
    }
}
