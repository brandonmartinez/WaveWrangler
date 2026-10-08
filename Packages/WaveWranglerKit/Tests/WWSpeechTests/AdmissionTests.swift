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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-model")
        let pin = try LocalSpeechAssetPin(name: "synthetic", version: "1", sizeBytes: 3,
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

    @Test func everyInferencePlanUsesNetworkDenialAndExplicitPaths() throws {
        let (value, speaker) = episode()
        let selection = try PrimarySpeechSelection(episode: value, speakerID: speaker)
        let executable = URL(fileURLWithPath: "/local/whisper-cli")
        let model = URL(fileURLWithPath: "/local/model")
        let input = URL(fileURLWithPath: "/scratch/input.wav")
        let prefix = URL(fileURLWithPath: "/scratch/result")
        let plan = OfflineWhisperPlan(selection: selection, executable: executable, model: model,
                                       inputWAV: input, outputPrefix: prefix)
        #expect(plan.executable.path == "/usr/bin/sandbox-exec")
        #expect(plan.arguments.prefix(2) == ["-p", "(version 1)(allow default)(deny network*)"])
        #expect(plan.arguments.contains(executable.path))
        #expect(plan.arguments.contains(model.path))
        #expect(plan.arguments.contains(input.path))
        #expect(plan.arguments.contains(prefix.path))
        #expect(!plan.arguments.contains("download"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_SPEECH_MODEL_PATH"] != nil),
          .timeLimit(.minutes(2)))
    func provisionedCandidateRunsSyntheticOffline() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["WW_SPEECH_MODEL_PATH"]))
        let executable = URL(fileURLWithPath: try #require(env["WW_SPEECH_CLI_PATH"]))
        try LocalSpeechAssetPin.whisperBaseEnglish.verify(at: model)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ww-speech-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
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
        let (episode, speaker) = episode()
        let selection = try PrimarySpeechSelection(episode: episode, speakerID: speaker)
        let prefix = scratch.appendingPathComponent("result")
        let plan = OfflineWhisperPlan(selection: selection, executable: executable, model: model,
                                       inputWAV: input, outputPrefix: prefix)
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = ["HOME": scratch.path, "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = ContinuousClock.now
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        let elapsed = started.duration(to: .now)
        #expect(process.terminationStatus == 0)
        let output = prefix.appendingPathExtension("json")
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        let segments = report?["transcription"] as? [[String: Any]]
        #expect(segments != nil)
        #expect(segments?.allSatisfy { $0["offsets"] != nil && $0["timestamps"] != nil } == true)
        print("WWSpeech synthetic offline: seconds=1 elapsed=\(elapsed) status=\(process.terminationStatus)")
    }
}
